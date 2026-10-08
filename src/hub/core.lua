-- Hub core: wires transports, state, feeds and the child protocol together, and implements the
-- properties and actions. Contains no Control4 calls of its own - everything goes through `rt`
-- and `env` (see common/runtime.lua), so the whole hub runs under the mock Director in tests.
--
-- Director-load rules applied here:
--   * property writes go through SetProp (skipped when unchanged) and status is refreshed at most
--     once per STATUS_MS, however many devices change;
--   * a child hears about a component only when its (online, route, value) tuple changed;
--   * persistence is debounced (PERSIST_MS) and never written from a poll;
--   * Auto-Setup creates ONE child every ADD_GAP_MS instead of a burst;
--   * feeds start in OnDriverLateInit, not OnDriverInit.
local U = require("common.util")
local Proto = require("common.protocol")
local Persist = require("common.persist")
local Parse = require("hub.transport.parse")
local Cloud = require("hub.transport.cloud")
local LanAuth = require("hub.transport.lan_auth")
local Lan = require("hub.transport.lan")
local Dispatch = require("hub.transport.lan_dispatch")
local AB = require("hub.addressbook")
local Registry = require("hub.registry")
local Router = require("hub.router")
local LanPoll = require("hub.feed.lan_poll")
local CloudCheck = require("hub.feed.cloud_check")

local Core = {}
Core.__index = Core

local STATUS_MS, PERSIST_MS, ADD_GAP_MS, CLOUD_LOST_MS = 2000, 30000, 400, 60000
local BLOB = "shelly.hub.v1"

function Core.new(rt, env)
  local self = setmetatable({}, Core)
  self.rt, self.env = rt, env
  self.pushed = {}                  -- child id -> last pushed tuple key
  self.pendingCfg = {}              -- child id -> { comp, tries }
  self.setupBusy = false
  self.persist = Persist.new(rt)
  self.cloud = Cloud.new(rt)
  self.auth = LanAuth.new(rt)
  self.lan = Lan.new(rt, self.auth)
  self.lan.passwordFor = function() local p = rt.prop("Device Password"); return p ~= "" and p or nil end
  self.dispatch = Dispatch.new(rt)

  self.registry = Registry.new(rt, {
    onChanged = function(ckey) self:pushComponent(ckey) end,
    onOnline = function(devId) self:pushDevice(devId) end,
    onDisagree = function(ckey, want, got)
      rt.log:warn("%s: device did not do what was asked (wanted %s, found %s)", ckey, rt.json.encode(want), rt.json.encode(got))
    end,
  })
  self.ab = AB.new(rt, {
    onDirty = function() self:markDirty() end,
    onTransition = function(id) self:pushDevice(id); self:scheduleStatus() end,
    onDown = function(id) self.cloudCheck:requestRefresh(id) end,
    onAuthStop = function(id)
      rt.log:error("device %s rejected the Device Password; LAN control to it is stopped until the password is changed or Test LAN is run", id)
      env.fire("Device Authentication Failed")
    end,
  })
  local hooks = {
    onUnverified = function(id) self:pushDevice(id) end,
    onRouteEvent = function() end,
    onNeedRefresh = function(id) self.cloudCheck:requestRefresh(id) end,
    onStructure = function(id) self:markDirty(); if id then self:reportGaps({ id }) end end,   -- the device's component set changed
  }
  self.router = Router.new(rt, { registry = self.registry, ab = self.ab, lan = self.lan, auth = self.auth,
    dispatch = self.dispatch, cloud = self.cloud, hooks = hooks })
  self.lanPoll = LanPoll.new(rt, { ab = self.ab, registry = self.registry, lan = self.lan, dispatch = self.dispatch,
    router = self.router, hooks = hooks })
  self.cloudCheck = CloudCheck.new(rt, { cloud = self.cloud, registry = self.registry, ab = self.ab, router = self.router,
    hooks = {
      onRoute = function(id) self:pushDevice(id) end,
      onStructure = function() self:markDirty(); self.lanPoll:restart() end,
      onCloudError = function(out) rt.log:debug("cloud read: %s", tostring(out.reason)) end,
    } })

  self.cloud.onStatus = function(s, old) self:onCloudStatus(s, old) end
  rt.log.onRecord = function() self:scheduleStatus() end
  return self
end

-- ================================================================================= configuration
function Core:applyConfig()
  local rt, p = self.rt, self.rt.prop
  local cfg = rt.cfg
  cfg.lanPollS = U.clamp(tonumber(p("LAN Poll Interval (s)")) or 20, 5, 300)
  cfg.cloudCheckS = U.clamp(tonumber(p("Cloud Check Interval (min)")) or 5, 1, 60) * 60
  cfg.cloudFallback = p("Cloud Fallback") ~= "Off"
  cfg.identityCheck = p("Identity Check") == "Strict" and "Strict" or "Standard"
  self.lan.verifyTls = p("LAN TLS Verification") == "On"
  rt.log:setLevel(p("Log Level"))
  rt.log:setSecret("devPass", p("Device Password"))
end

function Core:configureCloud()
  local ok, err = self.cloud:configure(self.rt.prop("Server"), self.rt.prop("Authorization Key"))
  if not ok and self.rt.prop("Server") ~= "" then self.rt.log:warn("cloud not configured: %s", tostring(err)) end
  self:scheduleStatus()
  return ok
end

-- ================================================================================== lifecycle
function Core:init()
  local rt = self.rt
  self:applyConfig()
  self.rt.props.set("Driver Version", require("common.ids").VERSION)
  local data = self.persist:readTable(BLOB)
  if data then
    self.ab:import(data.ab)
    self.registry:import(data.reg)
    for _, id in ipairs(self.ab:ids()) do
      local d = self.ab:get(id)
      if d.authStopHash then self.auth:restoreStop(id, d.authStopHash) end
    end
    rt.log:info("restored %d device(s) from the last session", self.ab:count())
  end
  self:configureCloud()
  self:refreshStatus()
end

function Core:lateInit()
  self.lanPoll:start()
  self.cloudCheck:start()
  if self.cloud:isUsable() then self.rt.sched:after(5000, function() self.cloudCheck:checkAll() end) end
  self.rt.sched:every(60000, function() self:scheduleStatus() end)
end

function Core:destroy()
  if self.dirty then self:persistNow() end
end

function Core:propertyChanged(name)
  local rt = self.rt
  if name == "Server" or name == "Authorization Key" then
    if self.cfgTimer then rt.sched:cancel(self.cfgTimer) end
    self.cfgTimer = rt.sched:after(1500, function() self.cfgTimer = nil; self:configureCloud()
      if self.cloud:isUsable() then self.cloudCheck:checkAll() end end)
  elseif name == "Device Password" then
    self:applyConfig()
    local pw = rt.prop("Device Password")
    for _, id in ipairs(self.ab:ids()) do
      local d = self.ab:get(id)
      if d.lan == "AuthStop" and not (pw ~= "" and self.auth:isStopped(id, pw)) then
        self.auth:clear(id); self.ab:clearAuthStop(id)
        rt.log:info("device %s: password changed, LAN control re-enabled", id)
      end
    end
  elseif name == "LAN Poll Interval (s)" then self:applyConfig(); self.lanPoll:restart()
  elseif name == "Cloud Check Interval (min)" then self:applyConfig(); self.cloudCheck:start()
  else self:applyConfig() end
end

-- ===================================================================================== status
function Core:scheduleStatus()
  if self.statusId then return end
  self.statusId = self.rt.sched:after(STATUS_MS, function() self.statusId = nil; self:refreshStatus() end)
end

function Core:refreshStatus()
  local rt, set = self.rt, self.rt.props.set
  set("Cloud Status", self.cloud.status)
  local c = self.ab:counts()
  set("LAN Status", string.format("Up %d, Degraded %d, Down %d, Auth stop %d, Probing %d, No address %d",
    c.Up, c.Degraded, c.Down, c.AuthStop, c.Probing, c.NoAddress))
  local kids = 0
  for _ in pairs(self.registry.children) do kids = kids + 1 end
  set("Devices", string.format("%d devices, %d children", #self.registry:deviceIds(), kids))
  set("Cloud Requests Per Minute", self.cloud.queue:requestsLastMinute())
  set("Recent Activity", rt.log:recentText(4, 300))
end

function Core:onCloudStatus(s, old)
  local rt = self.rt
  if s == "Connected" then
    if self.lostTimer then rt.sched:cancel(self.lostTimer); self.lostTimer = nil end
    if not self.everConnected or self.lostFired then
      self.env.fire("Cloud Connected")
      self.everConnected, self.lostFired = true, false
    end
  elseif s == "Auth failed" then
    self.env.fire("Cloud Authentication Failed")
    rt.log:error("the Shelly cloud rejected the Authorization Key; cloud traffic is stopped")
  elseif old == "Connected" and not self.lostTimer then
    self.lostTimer = rt.sched:after(CLOUD_LOST_MS, function()
      self.lostTimer = nil
      if self.cloud.status ~= "Connected" then self.lostFired = true; self.env.fire("Cloud Lost") end
    end)
  end
  self:pushAll()
  self:scheduleStatus()
end

-- ================================================================================ persistence
function Core:markDirty()
  self.dirty = true
  if self.persistId then return end
  self.persistId = self.rt.sched:after(PERSIST_MS, function() self.persistId = nil; self:persistNow() end)
end

function Core:persistNow()
  self.dirty = false
  self.persist:writeTable(BLOB, { v = 1, ab = self.ab:export(), reg = self.registry:export() })
end

-- ============================================================================ child state push
function Core:onlineOf(devId)
  local route = self.router:route(devId)
  if route ~= "Unreachable" then return true end
  local d = self.ab:get(devId)
  if d and d.lan == "Probing" then return nil end
  return false
end

function Core:pushComponent(ckey)
  local childId = self.registry:childFor(ckey)
  if not childId then return end
  local c = self.registry:component(ckey)
  if not c then return end
  local online = self:onlineOf(c.devId)
  local route = self.router:route(c.devId)
  local value = self.registry:value(ckey)
  local vjson = value and self.rt.json.encode(value) or ""
  local key = Proto.triState(online) .. "|" .. route .. "|" .. vjson
  if self.pushed[childId] == key then return end
  self.pushed[childId] = key
  self.env.sendToDevice(childId, Proto.M.HUB_STATE, { ONLINE = Proto.triState(online), ROUTE = route == "Unreachable" and "" or route, VALUE = vjson })
end

function Core:pushDevice(devId)
  for _, c in ipairs(self.registry:componentsOf(devId)) do self:pushComponent(c.key) end
end

function Core:pushAll()
  for _, id in ipairs(self.registry:deviceIds()) do self:pushDevice(id) end
end

-- ============================================================================ child protocol
function Core:executeCommand(cmd, p)
  local M = Proto.M
  if cmd == M.CHILD_REGISTER then return self:onRegister(p)
  elseif cmd == M.CHILD_SET then return self:onSet(p)
  elseif cmd == M.CHILD_UNREGISTER then
    local childId = tonumber(p.CHILD_ID)
    if childId then self.registry:unbindChild(childId); self.pushed[childId] = nil; self:markDirty() end
    return
  end
  self.rt.log:debug("ignored command %s", tostring(cmd))
end

local function ack(self, childId, status, reason)
  self.env.sendToDevice(childId, Proto.M.HUB_ACK, { STATUS = status, REASON = reason or "" })
end

function Core:onRegister(p)
  local childId = tonumber(p.CHILD_ID)
  if not childId then return end
  local sid, ch = U.norm_id(p.SHELLY_ID), tonumber(p.CHANNEL) or 0
  local ckey = Parse.key(sid or "", tostring(p.COMPONENT), ch)
  local comp = self.registry:component(ckey)
  if not comp then
    self.rt.log:warn("child %d asks for %s which is not known; run Fetch Devices", childId, ckey)
    return ack(self, childId, "UNKNOWN_DEVICE", "component not known to the hub (run Fetch Devices)")
  end
  if not Proto.compatible(tostring(p.KIND), comp.kind) then
    return ack(self, childId, "WRONG_TYPE", "this driver cannot control a " .. comp.kind)
  end
  self.registry:unbindChild(childId)
  local other = self.registry:childFor(ckey)
  if other and other ~= childId then
    self.rt.log:warn("%s was already controlled by child %d; child %d now owns it", ckey, other, childId)
    self.pushed[other] = nil
  end
  self.registry:bindChild(ckey, childId)
  self.pendingCfg[childId] = nil
  self.pushed[childId] = nil
  ack(self, childId, "OK")
  self:pushComponent(ckey)
  self:markDirty(); self:scheduleStatus()
end

function Core:onSet(p)
  local childId = tonumber(p.CHILD_ID)
  local reqId = p.REQUEST_ID
  local function result(out)
    self.env.sendToDevice(childId, Proto.M.HUB_RESULT, { REQUEST_ID = reqId, OK = out.ok and "1" or "0",
      CLASS = out.class or "", REASON = out.reason or "", ROUTE = out.route or "" })
  end
  local ckey = childId and self.registry.childOf[childId]
  if not ckey then return result({ ok = false, class = "CONFIG", reason = "child is not registered with the hub" }) end
  local intent = self.rt.json.decode(p.INTENT or "")
  if type(intent) ~= "table" then return result({ ok = false, class = "CONFIG", reason = "unreadable command" }) end
  self.router:send(ckey, intent, result)
end

-- ================================================================================== actions
function Core:action(raw)
  local name = Proto.resolveAction(require("common.ids").actions.hub, raw)
  local fn = name and self["do" .. name]
  if not fn then self.rt.log:warn("unknown action %s", tostring(raw)); return end
  local ok, err = pcall(fn, self)
  if not ok then self.rt.log:error("action %s failed: %s", tostring(name), tostring(err)) end
end

-- Components this driver cannot control, so a device does not just silently show "nothing to set up". Only control-capable kinds are
-- reported (inputs, sensors and meters are expected to be ignored).
local CONTROL_GAPS = { rgb = true, rgbw = true, cct = true, rgbcct = true }

function Core:gapsOf(id)
  local out = {}
  local dev = self.registry:device(id)
  for _, key in ipairs(dev and dev.unsupported or {}) do
    if CONTROL_GAPS[key:match("^(%a+):")] then out[#out + 1] = key end
  end
  return out
end

function Core:reportGaps(ids)
  for _, id in ipairs(ids or self.registry:deviceIds()) do
    local gaps = self:gapsOf(id)
    if #gaps > 0 then
      local d = self.ab:get(id)
      self.rt.log:warn("%s: %s not supported by this driver (device profile: %s). Colour/tunable-white outputs cannot be controlled yet; "
        .. "if the device has a plain 'light' profile, switch it in the Shelly app to control its channels as dimmable lights",
        id, table.concat(gaps, ", "), tostring(d and d.profile or "unknown"))
    end
  end
end

function Core:doTestCloud()
  if not self:configureCloud() then return self.rt.log:error("Server / Authorization Key are not valid") end
  self.cloud:allStatus(function(out, devs)
    if out.ok then self.rt.log:info("cloud OK: %d device(s) on this account", #devs)
    else self.rt.log:error("cloud test failed: %s (%s)", tostring(out.reason), tostring(out.class)) end
    self:scheduleStatus()
  end)
end

function Core:doFetchDevices()
  if not self.cloud:isUsable() then return self.rt.log:error("configure Server and Authorization Key first") end
  self.cloud:allStatus(function(out, devs)
    if not out.ok then
      return self.rt.log:error("fetch failed: %s. If the device list stays unavailable, add devices with 'Add Device By ID' instead "
        .. "(ids are in the Shelly app: Device > Settings > Device Information; several ids may be separated by commas)", tostring(out.reason))
    end
    local before, seen, gen1 = #self.registry:deviceIds(), {}, 0
    for _, norm in ipairs(devs) do seen[norm.id] = true; if norm.supported == false then gen1 = gen1 + 1 end end
    self.cloudCheck:ingest(devs, "background")
    self.registry:markMissing(seen)
    self:reportGaps()
    self.lanPoll:restart()
    self:markDirty(); self:scheduleStatus()
    self.rt.log:info("fetched %d device(s) (%d new, %d Gen1 skipped). Next: Auto-Setup Children", #devs, #self.registry:deviceIds() - before, gen1)
  end)
end

function Core:doAddManual()
  local rt = self.rt
  local ids = {}
  for tok in tostring(rt.prop("Manual Device ID")):gmatch("[^,;%s]+") do
    local id = U.norm_id(tok)
    if id and id ~= "" then ids[#ids + 1] = id end
  end
  local addr = U.trim(rt.prop("Manual Device Address"))
  if #ids == 0 then return rt.log:error("enter Manual Device ID first (one or more ids separated by commas)") end
  if addr ~= "" and not U.is_ipv4(addr) then return rt.log:error("Manual Device Address is not a valid IPv4 address") end
  if addr ~= "" and #ids > 1 then return rt.log:error("an address can only be given together with a single device id") end
  local function added(id)
    self:reportGaps({ id })
    self.lanPoll:restart(); self:markDirty(); self:scheduleStatus()
    rt.log:info("added %s (%d component(s)); next: Auto-Setup Children", id, #self.registry:componentsOf(id))
  end
  if addr ~= "" then
    local id = ids[1]
    self.ab:setAddress(id, addr, "override")
    local d = self.ab:ensure(id)
    self.dispatch:submit(id, "control", "add", function(done)
      self.lan:probe(d, function(out, info)
        if not out.ok then done(); return rt.log:error("cannot reach %s at %s: %s", id, d.address, tostring(out.reason)) end
        self.ab:setIdentity(id, info.identity)
        self.lan:status(d, function(o2, norm)
          done()
          if not o2.ok then return rt.log:error("cannot read %s: %s (%s)", id, tostring(o2.reason), tostring(o2.class)) end
          norm.id, norm.online, norm.supported = id, true, true
          self.registry:upsert(norm, "lan")
          self.router:ingestLan(d, norm, {})
          added(id)
        end)
      end)
    end)
  end
  if self.cloud:isUsable() then
    for _, id in ipairs(ids) do self.ab:ensure(id) end
    -- documented v2 "get" (up to 10 ids per request) - this path does not need the device listing
    self.cloudCheck:read(ids, "verify", function(out)
      if out.ok then for _, id in ipairs(ids) do if self.registry:device(id) then added(id) else rt.log:warn("%s was not found in the cloud account", id) end end
      else rt.log:error("cloud read failed: %s", tostring(out.reason)) end
    end)
  elseif addr == "" then rt.log:error("the cloud is not configured and no address was given") end
end

-- "Switch Type Overrides": "<device id or its last 4+ characters>[:<channel>]=Relay|Light", separated by commas, semicolons or newlines.
-- The most specific entry wins (id:channel, id, suffix:channel, suffix), then the hub-wide Switch Default Type.
function Core:switchTypeFor(comp)
  local overrides = {}
  for entry in tostring(self.rt.prop("Switch Type Overrides")):gmatch("[^,;\n]+") do
    local key, typ = entry:match("^%s*([%w:]+)%s*=%s*(%a+)%s*$")
    if key then
      typ = typ:lower()
      if typ == "relay" or typ == "light" then overrides[key:lower()] = typ end
    end
  end
  local id, ch = comp.devId, tostring(comp.channel)
  local best, bestScore = nil, 0
  for key, typ in pairs(overrides) do
    local kid, kch = key:match("^([%w]+):?(%d*)$")
    if kid and #kid >= 4 and (kch == "" or kch == ch) then
      local score = (kid == id and 4 or (id:sub(-#kid) == kid and 2 or 0))
      if score > 0 then score = score + (kch ~= "" and 1 or 0) end
      if score > bestScore then best, bestScore = typ, score end
    end
  end
  if best then return best == "relay" and "Relay" or "Light" end
  return self.rt.prop("Switch Default Type") == "Relay" and "Relay" or "Light"
end

local function childFile(self, comp)
  if comp.kind == "light" then return "shelly_light.c4z" end
  if comp.kind == "cover" then return "shelly_blind.c4z" end
  if comp.kind == "flood" or comp.kind == "smoke" or comp.kind == "gas" then return "shelly_sensor.c4z" end
  if comp.kind == "contact" then return "shelly_contact.c4z" end
  return self:switchTypeFor(comp) == "Relay" and "shelly_relay.c4z" or "shelly_light_onoff.c4z"
end

-- "Contact Inputs": which OPTIONAL contact components (a device's input terminals) get a contact driver: "<device id or its last 4+
-- characters>[:<channel>]" separated by commas, semicolons or newlines. Dedicated Door/Window sensors are not optional.
function Core:contactInputWanted(comp)
  if not comp.optional then return true end
  for entry in tostring(self.rt.prop("Contact Inputs")):gmatch("[^,;\n]+") do
    local kid, kch = entry:match("^%s*([%w]+):?(%d*)%s*$")
    if kid and #kid >= 4 then
      kid = kid:lower()
      local did = tostring(comp.devId):lower()
      local idMatch = (kid == did) or (did:sub(-#kid) == kid)
      if idMatch and (kch == "" or kch == tostring(comp.channel)) then return true end
    end
  end
  return false
end

function Core:sendConfig(childId, comp, attempt)
  attempt = attempt or 1
  local pend = self.pendingCfg[childId]
  if not pend and attempt > 1 then return end
  self.env.sendToDevice(childId, Proto.M.HUB_CONFIG, { HUB_ID = tostring(self.env.myId()), SHELLY_ID = comp.devId,
    COMPONENT = comp.kind, CHANNEL = tostring(comp.channel) })
  if attempt < 3 then
    self.rt.sched:after(attempt == 1 and 3000 or 7000, function() self:sendConfig(childId, comp, attempt + 1) end)
  end
end

function Core:doAutoSetup()
  local rt = self.rt
  if self.setupBusy then return rt.log:warn("auto-setup is already running") end
  local list = {}
  for _, c in ipairs(self.registry:unassigned()) do
    if self:contactInputWanted(c) then list[#list + 1] = c end
  end
  self:reportGaps()
  if #list == 0 then return rt.log:info("nothing to set up (every supported component already has a driver)") end
  if #list > 200 then rt.log:warn("%d components found; creating the first 200 now, run again for the rest", #list) end
  self.setupBusy = true
  local idx, created = 0, 0
  local room = tonumber(rt.prop("Default Room ID")) or 0
  local function nextOne()
    idx = idx + 1
    local comp = list[idx]
    if not comp or idx > 200 then
      self.setupBusy = false
      rt.log:info("auto-setup created %d driver(s)", created)
      self:markDirty(); self:scheduleStatus()
      return
    end
    local dev = self.registry:device(comp.devId) or {}
    local name = string.format("%s %s %s %d", dev.model or "Shelly", comp.devId:sub(-4), comp.kind, comp.channel + 1)
    self.env.addDevice(childFile(self, comp), room, name, function(childId)
      if childId then
        created = created + 1
        self.registry:bindChild(comp.key, childId)
        self.pendingCfg[childId] = { comp = comp }
        self:sendConfig(childId, comp)
      else
        rt.log:error("could not create a driver for %s", comp.key)
      end
      rt.sched:after(ADD_GAP_MS, nextOne)
    end)
  end
  nextOne()
end

function Core:doTestLan()
  local rt = self.rt
  local ids, i = self.ab:ids(), 0
  local report = { "--- Test LAN ---" }
  local function nextDev()
    i = i + 1
    local id = ids[i]
    if not id then
      report[#report + 1] = "--- end ---"
      rt.log:block(report)
      return
    end
    local d = self.ab:get(id)
    self.auth:clear(id); self.ab:clearAuthStop(id)
    if not d.address then report[#report + 1] = id .. ": no LAN address"; return nextDev() end
    self.lan:probe(d, function(out, info)
      if not out.ok then
        report[#report + 1] = string.format("%s: %s UNREACHABLE (%s)", id, d.address, tostring(out.reason))
        self.ab:noteFailure(id, out.reason)
        return nextDev()
      end
      local same = Lan.sameIdentity(d.identity, info.identity)
      self.lan:status(d, function(o2, norm)
        local line = string.format("%s: %s %s auth=%s identity=%s", id, d.address, info.scheme, tostring(info.authRequired),
          same == true and "match" or (same == false and "MISMATCH" or "unverified"))
        if o2.ok then line = line .. string.format(" state=OK components=%d", #norm.components); self.ab:noteSuccess(id); self.ab:noteIdentityOk(id)
        else line = line .. " state=FAILED " .. tostring(o2.reason) .. " (" .. tostring(o2.class) .. ")"
          if o2.class == "AUTH" then self.ab:noteAuthReject(id, "test") end end
        report[#report + 1] = line
        nextDev()
      end)
    end)
  end
  if #ids == 0 then return rt.log:info("no devices known") end
  nextDev()
end

function Core:doPollNow()
  for _, id in ipairs(self.ab:ids()) do self.ab:get(id).lastPoll = nil end
  self.cloudCheck:checkAll()
  self.rt.log:info("poll requested")
end

function Core:doRefreshAddresses()
  self.cloudCheck:read(self.registry:deviceIds(), "verify")
  self.rt.log:info("address refresh requested")
end

function Core:doClearAuthStops()
  local n = 0
  for _, id in ipairs(self.ab:ids()) do
    if self.ab:get(id).lan == "AuthStop" then self.auth:clear(id); self.ab:clearAuthStop(id); n = n + 1 end
  end
  self.rt.log:info("cleared %d authentication stop(s); the next command to each will try the password once", n)
end

function Core:doListDevices()
  local lines = { "--- Devices ---" }
  for _, id in ipairs(self.registry:deviceIds()) do
    local dev, d = self.registry:device(id), self.ab:get(id) or {}
    local kids = {}
    for _, c in ipairs(self.registry:componentsOf(id)) do
      kids[#kids + 1] = c.kind .. ":" .. c.channel .. (c.gone and "=GONE(profile changed?)" or (self.registry:childFor(c.key) and ("=#" .. self.registry:childFor(c.key)) or (c.optional and not self:contactInputWanted(c) and "=optional(see Contact Inputs)" or "=unassigned")))
    end
    local gaps = self:gapsOf(id)
    lines[#lines + 1] = string.format("%s %s gen=%s profile=%s lan=%s addr=%s route=%s%s%s%s [%s]", id, tostring(dev.model or "?"),
      tostring(dev.gen or "?"), tostring(d.profile or "?"), tostring(d.lan or "-"), tostring(d.address or "-"), self.router:route(id),
      dev.missing and " MISSING-FROM-CLOUD" or "", dev.supported == false and " UNSUPPORTED(Gen1)" or "",
      #gaps > 0 and (" NOT-CONTROLLABLE[" .. table.concat(gaps, ",") .. "]") or "", table.concat(kids, " "))
  end
  lines[#lines + 1] = "--- end ---"
  self.rt.log:block(lines)
end

function Core:doShowActivity()
  local lines = { "--- Recent activity (newest first) ---" }
  for _, l in ipairs(self.rt.log:recent()) do lines[#lines + 1] = l end
  self.rt.log:block(lines)
end

function Core:doPurgeMissing()
  local n = 0
  for _, id in ipairs(self.registry:deviceIds()) do
    local dev = self.registry:device(id)
    local assigned = false
    for _, c in ipairs(self.registry:componentsOf(id)) do if self.registry:childFor(c.key) then assigned = true end end
    if dev.missing and not assigned then self.registry:removeDevice(id); self.ab:remove(id); n = n + 1 end
  end
  self.rt.log:info("purged %d missing device(s) that had no driver (missing devices with drivers are kept)", n)
  self.lanPoll:restart(); self:markDirty(); self:scheduleStatus()
end

return Core
