-- Shared child-driver logic. A child driver is a thin proxy front-end: it registers with the hub,
-- forwards absolute intents, and renders hub state through a per-type "glue" module.
--
-- Rules implemented here (see docs/SPEC.md):
--   * every state the hub sends is applied with de-duplication: an unchanged value costs ZERO
--     SendToProxy / UpdateProperty / SetVariable calls;
--   * "changing" is always followed by "changed" or offline: a failed or timed-out command snaps the
--     proxy back to the last value the hub confirmed;
--   * Device Offline is debounced 60 s (so a Wi-Fi blip does not flicker every scene and UI);
--   * route changes fire Fallback Started / LAN Restored only on real transitions between known routes;
--   * toggles are resolved HERE from known state and sent as absolute values; unknown state refuses.
local ids = require("common.ids")
local Proto = require("common.protocol")
local U = require("common.util")

local Child = {}
Child.__index = Child

local OFFLINE_DEBOUNCE_MS = 60000
local REQUEST_TIMEOUT_MS = 20000
local RETRY_S = { 10, 20, 40, 60 }

function Child.new(rt, env, glue)
  local self = setmetatable({}, Child)
  self.rt, self.env, self.glue = rt, env, glue
  self.kind, self.component = glue.kind, glue.component
  self.hubId, self.shellyId, self.channel = 0, "", 0
  self.registered, self.retryIdx, self.retryId = false, 0, nil
  self.online, self.route, self.value = nil, nil, nil       -- value: last hub-confirmed value
  self.offlineFired, self.offlineTimer = false, nil
  self.pending, self.pendingN, self.reqSeq = {}, 0, 0
  self.sent = {}                                            -- glue-level de-dup memory
  self.settingProps = false
  return self
end

local function events(self)
  local names = {}
  for _, e in ipairs(ids.events.child) do names[e.name] = true end
  if self.glue.varSet == "relay" then for _, e in ipairs(ids.events.relay) do names[e.name] = true end end
  return names
end

function Child:fire(name) self.env.fire(name) end

function Child:setProp(name, value)
  self.settingProps = true
  self.env.setProp(name, value)
  self.settingProps = false
end

function Child:setStatus(s) self:setProp("Status", s) end

function Child:configured() return self.hubId > 0 and self.shellyId ~= "" and (self.component or "") ~= "" end

function Child:loadConfig()
  self.hubId = tonumber(self.env.prop("Hub Device ID")) or 0
  self.shellyId = U.norm_id(self.env.prop("Shelly Device ID")) or ""
  self.channel = tonumber(self.env.prop("Channel")) or 0
  -- most children bind to one fixed component kind; the alarm sensor serves flood:N or smoke:N, chosen per child
  if not self.glue.component then self.component = self.env.prop(self.glue.componentProp) end
end

-- ---- lifecycle ----------------------------------------------------------------------------------
function Child:init()
  self.rt.log:setLevel(self.env.prop("Log Level"))
  for _, v in ipairs(ids.variables.child) do self.env.addVar(v.name, "", v.type) end
  if self.glue.varSet then
    for _, v in ipairs(ids.variables[self.glue.varSet]) do self.env.addVar(v.name, "", v.type) end
  end
  self:setProp("Driver Version", ids.VERSION)
  if self.glue.init then self.glue.init(self) end
  self:loadConfig()
  if self:configured() then
    self:setStatus("Registering with hub")
    self:register()
  else
    self:setStatus("Not configured (waiting for the hub)")
  end
end

function Child:lateInit() if self.glue.lateInit then self.glue.lateInit(self) end end

function Child:destroy()
  if self.registered and self.hubId > 0 then
    self.env.sendToDevice(self.hubId, Proto.M.CHILD_UNREGISTER, { CHILD_ID = tostring(self.env.myId()) })
  end
end

function Child:register()
  self.registered = false
  if not self:configured() then return end
  self.env.sendToDevice(self.hubId, Proto.M.CHILD_REGISTER, {
    CHILD_ID = tostring(self.env.myId()), KIND = self.kind, SHELLY_ID = self.shellyId,
    COMPONENT = self.component, CHANNEL = tostring(self.channel),
  })
  if self.retryId then self.rt.sched:cancel(self.retryId) end
  self.retryIdx = math.min(self.retryIdx + 1, #RETRY_S)
  self.retryId = self.rt.sched:after(RETRY_S[self.retryIdx] * 1000, function()
    self.retryId = nil
    if not self.registered then self:register() end
  end)
end

-- ---- hub -> child ----------------------------------------------------------------------------------
function Child:executeCommand(cmd, params)
  local M = Proto.M
  if cmd == "LUA_ACTION" then
    local resolved = Proto.resolveAction(ids.actions.child, params and params.ACTION)
    if not resolved then self.rt.log:warn("unknown action %s", tostring(params and params.ACTION)); return end
    cmd = resolved
  end
  if cmd == M.HUB_CONFIG then return self:onConfig(params)
  elseif cmd == M.HUB_ACK then return self:onAck(params)
  elseif cmd == M.HUB_STATE then return self:onState(params)
  elseif cmd == M.HUB_RESULT then return self:onResult(params)
  elseif cmd == "ReRegister" then self.retryIdx = 0; return self:register()
  elseif cmd == "ShowStatus" then return self:showStatus()
  elseif cmd == "ResendState" then return self:replay()
  end
  self.rt.log:debug("ignored command %s", tostring(cmd))
end

function Child:onConfig(p)
  local hub = tonumber(p.HUB_ID) or 0
  local sid = U.norm_id(p.SHELLY_ID) or ""
  local ch = tonumber(p.CHANNEL) or 0
  local comp = self.component
  if not self.glue.component and p.COMPONENT and p.COMPONENT ~= "" then comp = p.COMPONENT end
  if hub == self.hubId and sid == self.shellyId and ch == self.channel and comp == self.component and self.registered then return end
  self.hubId, self.shellyId, self.channel, self.component = hub, sid, ch, comp
  self:setProp("Hub Device ID", hub); self:setProp("Shelly Device ID", sid); self:setProp("Channel", ch)
  if not self.glue.component then self:setProp(self.glue.componentProp, comp) end
  self.retryIdx = 0
  self:setStatus("Registering with hub")
  self:register()
end

-- A device created by C4:AddDevice may not have a listening proxy during OnDriverLateInit (found on real hardware in
-- efic1/C4-UnifiProtect). Everything this child sends is de-duplicated, so a notification the proxy missed would never be
-- repeated. Replay the current state twice, shortly after the first registration; bounded, once per driver load.
local REPLAY_S = { 4, 12 }

function Child:replay()
  self.sent = {}
  if self.glue.lateInit then self.glue.lateInit(self) end
  if self.online ~= nil and self.glue.online then self.glue.online(self, self.online) end
  if self.value then self.glue.apply(self, self.value) end
end

-- A consumer bound AFTER we published (an installer binds a device to the relay mid-session) hears nothing until the next
-- change, because unchanged state is never re-sent. Republish shortly after any binding is made.
function Child:bindingChanged(idBinding, bound)
  if bound == false or self.bindTimer then return end
  self.bindTimer = self.rt.sched:after(1000, function() self.bindTimer = nil; self:replay() end)
end

function Child:scheduleReplay()
  if self.replayScheduled then return end
  self.replayScheduled = true
  for _, s in ipairs(REPLAY_S) do self.rt.sched:after(s * 1000, function() self:replay() end) end
end

function Child:onAck(p)
  if p.STATUS == "OK" then
    self:scheduleReplay()
    self.registered = true
    self.retryIdx = 0
    if self.retryId then self.rt.sched:cancel(self.retryId); self.retryId = nil end
    self:setStatus(self.online == nil and "Registered (waiting for state)" or "Connected")
  else
    self:setStatus("Hub refused: " .. tostring(p.STATUS))
    self.rt.log:warn("hub refused registration: %s %s", tostring(p.STATUS), tostring(p.REASON or ""))
  end
end

function Child:onState(p)
  local online = Proto.fromTriState(p.ONLINE)
  local route = (p.ROUTE and p.ROUTE ~= "") and p.ROUTE or nil
  local value = (p.VALUE and p.VALUE ~= "") and self.rt.json.decode(p.VALUE) or nil
  if route then self:applyRoute(route) end
  if online ~= nil then self:applyOnline(online) end
  if value then
    self.value = value
    self.glue.apply(self, value)
    if self.everKnown ~= true then self.everKnown = true end
  end
end

function Child:applyRoute(route)
  if route == self.route then return end
  local prev = self.route
  self.route = route
  if self.glue.routeEvents == false then
    self:setProp("Route", route); self.env.setVar("Route", route)
    return                                              -- a sleepy sensor going LAN <-> cloud is not a "fallback"
  end
  self:setProp("Route", route)
  self.env.setVar("Route", route)
  -- "Restored" only follows a real fallback; the cloud-first route seen while the LAN is still being
  -- confirmed at start-up is not a fallback.
  if prev == "LAN" and route == "Cloud" then self.fellBack = true; self:fire("Fallback Started")
  elseif route == "LAN" and self.fellBack then self.fellBack = false; self:fire("LAN Restored") end
end

function Child:applyOnline(online)
  if online then
    if self.offlineTimer then self.rt.sched:cancel(self.offlineTimer); self.offlineTimer = nil end
    local changed = self.online ~= true
    self.online = true
    if changed then
      self.env.setVar("Device Online", "1")
      self:setStatus("Connected")
      if self.glue.online then self.glue.online(self, true) end
      if self.offlineFired then self.offlineFired = false; self:fire("Device Online") end
    end
  else
    if self.online == false or self.offlineTimer then return end
    -- battery devices sleep for hours and are "unreachable" by design: their glue sets a much longer debounce
    local debounce = self.glue.offlineDebounceMs or OFFLINE_DEBOUNCE_MS
    if type(debounce) == "function" then debounce = debounce(self) end
    debounce = debounce or OFFLINE_DEBOUNCE_MS
    self.offlineTimer = self.rt.sched:after(debounce, function()
      self.offlineTimer = nil
      self.online = false
      self.offlineFired = true
      self.env.setVar("Device Online", "0")
      self:setStatus("Offline")
      if self.glue.online then self.glue.online(self, false) end
      self:fire("Device Offline")
    end)
  end
end

-- ---- proxy -> child -> hub ----------------------------------------------------------------------------
function Child:fromProxy(binding, cmd, params)
  if cmd == "GET_CONNECTED_STATE" then
    -- The light_v2 proxy asks this at initialisation and expects ONLINE_CHANGED (Control4's sample answers it). Answer when known.
    if self.online ~= nil and self.glue.online then self.sent.online = nil; self.glue.online(self, self.online) end
    return
  end
  if cmd == "GET_LIGHT_LEVEL" or cmd == "SYNCHRONIZE" then
    -- Undocumented but sent by the light_v2 proxy (reported against a live Director): "tell me your state again".
    -- Debounced republish, so a burst of requests costs one round of notifications.
    self:bindingChanged(binding, true)
    return
  end
  local intent, reason = self.glue.toIntent(self, cmd, params or {})
  if intent == nil then
    if reason then self:refuse(reason) else self.rt.log:debug("ignored proxy command %s", tostring(cmd)) end
    return
  end
  self:send(intent)
end

function Child:refuse(reason)
  self:setProp("Last Command Result", "Refused: " .. reason)
  self.rt.log:warn("command refused: %s", reason)
  self:fire("Command Failed")
  if self.value then self.glue.apply(self, self.value, true) end
end

function Child:send(intent)
  if not self.registered then return self:refuse("not connected to the hub") end
  self.reqSeq = self.reqSeq + 1
  local id = tostring(self.env.myId()) .. "-" .. self.reqSeq
  if self.pendingN >= 20 then
    local oldest, oid
    for k, v in pairs(self.pending) do if not oldest or v.at < oldest.at then oldest, oid = v, k end end
    if oid then self:finish(oid) end
  end
  local timer = self.rt.sched:after(REQUEST_TIMEOUT_MS, function()
    self.pending[id].timer = nil
    self:failed(id, "TIMEOUT", "no answer from the hub")
  end)
  self.pending[id] = { intent = intent, at = self.rt.clock.now(), timer = timer }
  self.pendingN = self.pendingN + 1
  self.env.sendToDevice(self.hubId, Proto.M.CHILD_SET, {
    CHILD_ID = tostring(self.env.myId()), REQUEST_ID = id, INTENT = self.rt.json.encode(intent) })
end

function Child:finish(id)
  local p = self.pending[id]
  if not p then return nil end
  if p.timer then self.rt.sched:cancel(p.timer) end
  self.pending[id] = nil
  self.pendingN = self.pendingN - 1
  return p
end

function Child:onResult(p)
  local pend = self:finish(p.REQUEST_ID)
  if not pend then return end
  if p.OK == "1" then
    self:setProp("Last Command Result", "OK via " .. tostring(p.ROUTE))
    if p.ROUTE and p.ROUTE ~= "" then self:applyRoute(p.ROUTE) end
    if self.glue.optimistic then self.glue.optimistic(self, pend.intent) end
  elseif p.CLASS == "SUPERSEDED" then
    -- a newer command replaced this one; the newer result decides what the user sees
  else
    self:failedWith(p.CLASS, p.REASON)
  end
end

function Child:failed(id, class, reason)
  local pend = self:finish(id)
  if pend then self:failedWith(class, reason) end
end

function Child:failedWith(class, reason)
  self:setProp("Last Command Result", "Failed: " .. tostring(class) .. " " .. tostring(reason or ""))
  self.rt.log:warn("command failed: %s %s", tostring(class), tostring(reason))
  self:fire("Command Failed")
  if class == "AUTH" then self:fire("Authentication Failed") end
  if self.value then self.glue.apply(self, self.value, true) end       -- snap the UI back to what the hub last confirmed
end

function Child:showStatus()
  self.rt.log:block({
    "--- " .. self.kind .. " " .. self.shellyId .. " ch" .. self.channel .. " ---",
    "hub id: " .. self.hubId .. "  registered: " .. tostring(self.registered),
    "online: " .. tostring(self.online) .. "  route: " .. tostring(self.route),
    "value: " .. self.rt.json.encode(self.value or {}),
    "pending requests: " .. self.pendingN,
  })
end

function Child:propertyChanged(name)
  if self.settingProps then return end
  if name == "Log Level" then self.rt.log:setLevel(self.env.prop("Log Level")); return end
  if name == "Hub Device ID" or name == "Shelly Device ID" or name == "Channel" or (self.glue.componentProp and name == self.glue.componentProp) then
    local oldHub = self.hubId
    self:loadConfig()
    if oldHub > 0 and oldHub ~= self.hubId then
      self.env.sendToDevice(oldHub, Proto.M.CHILD_UNREGISTER, { CHILD_ID = tostring(self.env.myId()) })
    end
    self.retryIdx = 0
    if self:configured() then self:setStatus("Registering with hub"); self:register()
    else self.registered = false; self:setStatus("Not configured") end
    return
  end
  if self.glue.propertyChanged then self.glue.propertyChanged(self, name) end
end

-- glue helper: run `fn` only when `key` differs from the last thing sent (Director call de-dup)
function Child:once(slot, key, fn)
  if self.sent[slot] == key then return false end
  self.sent[slot] = key
  fn()
  return true
end

return Child
