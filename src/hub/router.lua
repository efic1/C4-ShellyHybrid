-- Router: LAN first, cloud as fallback, absolute commands only.
--
--   UNREACHABLE (device never answered)  -> retry once on the LAN, then fall back to the cloud
--   AUTH (credentials refused / missing) -> stop credentialed LAN traffic to that device, fall back
--   DEVICE / CONFIG (device answered, said no) -> report; NEVER fail over
--
-- Failing over after an ambiguous timeout is safe only because every command is an absolute set.
-- A cover STOP is the exception: it is never blindly failed over (see stopViaCloud).
local Lan = require("hub.transport.lan")

local Router = {}
Router.__index = Router

local function fail(class, reason, extra)
  local o = { ok = false, class = class, reason = reason }
  if extra then for k, v in pairs(extra) do o[k] = v end end
  return o
end

-- deps: registry, ab, lan, auth, dispatch, cloud, hooks{ onUnverified, onRouteEvent, onNeedRefresh, onVerified }
function Router.new(rt, deps)
  local self = setmetatable({}, Router)
  self.rt = rt
  for k, v in pairs(deps) do self[k] = v end
  self.hooks = deps.hooks or {}
  self.verifyIds = {}
  self.motion, self.motionN = {}, 0
  self.follow = {}
  self.lastValueSend, self.deferred = {}, {}
  return self
end

local function cfg(self) return self.rt.cfg end

function Router:cloudOk(d)
  local c = self.cloud
  return c:isUsable() and c.status ~= "Offline" and c.status ~= "Auth failed" and (not d or d.cloudOnline ~= false)
end

function Router:route(devId)
  return self.ab:route(devId, self.cloud:isUsable() and self.cloud.status ~= "Offline" and self.cloud.status ~= "Auth failed")
end

-- ---- identity gate ----------------------------------------------------------------------------
-- Probe first when the last identity match is stale (Strict: older than 2 s, Standard: older than
-- 3 poll intervals). The probe carries no credentials so it is safe to repeat.
function Router:ensureFresh(d, cb)
  local now = self.rt.clock.now()
  local strict = cfg(self).identityCheck == "Strict"
  local limit = strict and 2000 or 3 * (cfg(self).lanPollS or 20) * 1000
  if d.lastIdentityOk and now - d.lastIdentityOk <= limit then return cb(true) end
  self.lan:probe(d, function(out, info)
    if not out.ok then return cb(false, out) end
    local same = Lan.sameIdentity(d.identity, info.identity)
    if same == false then
      self.ab:noteIdentityMismatch(d.id, info.identity)
      if self.hooks.onNeedRefresh then self.hooks.onNeedRefresh(d.id) end
      return cb(false, fail("UNREACHABLE", "a different device answered at this address"))
    end
    if same == nil and info.identity and not d.identity then self.ab:setIdentity(d.id, info.identity) end
    self.ab:noteIdentityOk(d.id)
    cb(true)
  end)
end

-- ---- public: send ------------------------------------------------------------------------------
-- Failure reasons that prove the request never left the controller (a refused connection, a failed TLS handshake, no address).
local NOT_SENT = { connect = true, tls = true, ["no LAN address"] = true }

local VALUE_GAP_MS = 250

function Router:send(ckey, intent, cb)
  local comp = self.registry:component(ckey)
  if not comp then return cb(fail("CONFIG", "unknown component")) end
  if intent.toggle or intent.rel or intent.relative then
    return cb(fail("CONFIG", "toggle/relative commands are never sent to a device"))
  end
  local isStop = intent.cover == "stop"
  -- Continuous values (slider drags): at most one level/position per component per VALUE_GAP_MS, the
  -- latest wins. Bounds wire traffic when the UI streams values faster than the device needs them.
  if intent.level ~= nil or intent.position ~= nil then
    local now = self.rt.clock.now()
    local last = self.lastValueSend[ckey]
    if last and last > now then last = now end                                  -- clock stepped back
    if last and now - last < VALUE_GAP_MS then
      local pend = self.deferred[ckey]
      if pend then
        pend.cb(fail("SUPERSEDED", "newer value"))
        pend.intent, pend.cb = intent, cb
      else
        self.deferred[ckey] = { intent = intent, cb = cb }
        self.rt.sched:after(VALUE_GAP_MS - (now - last), function()
          local p = self.deferred[ckey]
          self.deferred[ckey] = nil
          if p then self:send(ckey, p.intent, p.cb) end
        end)
      end
      return
    end
    self.lastValueSend[ckey] = now
  end
  local key = ckey .. (isStop and "|stop" or "|v")
  if isStop then
    local pend = self.deferred[ckey]
    if pend then self.deferred[ckey] = nil; pend.cb(fail("SUPERSEDED", "stopped")) end
    self.dispatch:cancel(comp.devId, ckey .. "|v")
    self.cloud.queue:cancelKey("set|" .. comp.devId .. "|cover|" .. comp.channel .. "|v")
  end
  local d = self.ab:ensure(comp.devId)
  if self.ab:lanUsable(comp.devId) then
    self:viaLan(ckey, comp, d, intent, key, cb, 1)
  else
    self:viaCloud(ckey, comp, d, intent, cb, "LAN not available")
  end
end

function Router:viaLan(ckey, comp, d, intent, key, cb, attempt)
  self.dispatch:submit(comp.devId, "control", key, function(done)
    self:ensureFresh(d, function(ok, probeOut)
      if not ok then
        done()
        return self:lanFailed(ckey, comp, d, intent, key, cb, attempt, probeOut)
      end
      self.lan:set(d, comp.kind, comp.channel, intent, function(out)
        done()
        if out.ok then
          self.ab:noteSuccess(comp.devId)
          return self:succeeded(ckey, comp, intent, "LAN", cb)
        end
        self:lanFailed(ckey, comp, d, intent, key, cb, attempt, out)
      end)
    end)
  end, function(reason) cb(fail("SUPERSEDED", reason)) end)
end

function Router:lanFailed(ckey, comp, d, intent, key, cb, attempt, out)
  if out.identityMismatch then
    self.ab:noteIdentityMismatch(d.id, out.seen)
    if self.hooks.onNeedRefresh then self.hooks.onNeedRefresh(d.id) end
    return self:viaCloud(ckey, comp, d, intent, cb, out.reason)
  end
  if out.class == "DEVICE" or out.class == "CONFIG" then return cb(out) end
  if out.class == "AUTH" then
    local pw = self.lan.passwordFor(d)
    self.ab:noteAuthReject(comp.devId, pw and self.auth:passHash(comp.devId, pw) or "no-password")
    self.rt.log:warn("device %s: %s", comp.devId, out.reason)
    return self:viaCloud(ckey, comp, d, intent, cb, "LAN authentication failed: " .. tostring(out.reason))
  end
  -- UNREACHABLE
  self.ab:noteFailure(comp.devId, out.reason)
  -- A PULSE (toggle_after: a garage-door or gate trigger) is not idempotent: if the request reached the device and only the reply was
  -- lost, a retry or a cloud fallback would fire a second pulse (open, then stop or reverse). Absolute on/off commands may be repeated
  -- freely; a pulse may only be repeated when the failure proves nothing was sent.
  if intent.toggle_after and not NOT_SENT[out.reason] then
    return cb(fail("UNREACHABLE", "the pulse may or may not have reached the device (" .. tostring(out.reason) ..
      "); it was NOT repeated, so the door cannot be triggered twice - check the door", { ambiguous = true }))
  end
  if attempt == 1 and self.ab:lanUsable(comp.devId) then
    return self:viaLan(ckey, comp, d, intent, key, cb, 2)
  end
  return self:viaCloud(ckey, comp, d, intent, cb, "LAN unreachable: " .. tostring(out.reason))
end

function Router:viaCloud(ckey, comp, d, intent, cb, why)
  if d.gen == 1 then return cb(fail("UNREACHABLE", "Gen1 devices are controlled over the LAN only (cloud control of Gen1 is not used)")) end
  if cfg(self).cloudFallback == false then
    return cb(fail("UNREACHABLE", why .. "; cloud fallback is off"))
  end
  if not self:cloudOk(d) then
    return cb(fail("UNREACHABLE", why .. "; cloud fallback unavailable"))
  end
  if intent.cover == "stop" then return self:stopViaCloud(ckey, comp, d, cb, why) end
  self.cloud:set(comp.kind, comp.devId, comp.channel, intent, "control", function(out)
    if out.ok then return self:succeeded(ckey, comp, intent, "Cloud", cb, why) end
    if out.class == "SUPERSEDED" then return cb(out) end
    cb(fail(out.class or "CLOUD", out.reason or "cloud command failed", { offline = out.offline }))
  end)
end

-- A stop must not be blindly repeated after an ambiguous LAN failure: read the cover first.
function Router:stopViaCloud(ckey, comp, d, cb, why)
  self.cloud:read({ comp.devId }, "verify", function(out, devs)
    if not out.ok or not devs or not devs[1] then return cb(fail("UNREACHABLE", "cannot confirm cover state for STOP")) end
    local moving
    for _, c in ipairs(devs[1].components) do
      if c.kind == "cover" and c.channel == comp.channel then moving = (c.state == "opening" or c.state == "closing") end
    end
    if moving == false then return self:succeeded(ckey, comp, { cover = "stop" }, "Cloud", cb, "already stopped") end
    self.cloud:set("cover", comp.devId, comp.channel, { cover = "stop" }, "control", function(o2)
      if o2.ok then return self:succeeded(ckey, comp, { cover = "stop" }, "Cloud", cb, why) end
      cb(fail(o2.class or "CLOUD", o2.reason or "cloud stop failed"))
    end)
  end)
end

function Router:succeeded(ckey, comp, intent, route, cb, why)
  self.registry:applyCommand(ckey, intent, route == "LAN" and 2000 or 5000)
  if intent.toggle_after then self:followUp(comp.devId, route) end
  local d = self.ab:get(comp.devId)
  if d then
    if route == "Cloud" and not d.viaCloud then
      d.viaCloud = true                                   -- reported ONCE per transition, not once per command
      if self.hooks.onRouteEvent then self.hooks.onRouteEvent(comp.devId, "fallback", why) end
    elseif route == "LAN" and d.viaCloud then
      d.viaCloud = false
      if self.hooks.onRouteEvent then self.hooks.onRouteEvent(comp.devId, "restored") end
    end
  end
  cb({ ok = true, route = route })
  self:scheduleVerify(comp.devId, route)
end

-- ---- verification read ----------------------------------------------------------------------
-- One read per device per burst of commands; it is the CONFIRMATION, so it overrides any hold.
function Router:scheduleVerify(devId, route, delayMs)
  if self.verifyIds[devId] then return end
  self.verifyIds[devId] = self.rt.sched:after(delayMs or (route == "LAN" and 500 or 2000), function()
    self.verifyIds[devId] = nil
    self:verifyNow(devId, route)
  end)
end

-- A cover in motion is re-read until it stops, so the UI follows it and the final position is exact
-- without waiting for the next regular poll. Bounded: 80 reads per movement, slower when many move.
function Router:watchMotion(devId, norm, route)
  local moving = false
  for _, c in ipairs(norm.components or {}) do
    if c.kind == "cover" and (c.state == "opening" or c.state == "closing") then moving = true end
  end
  if not moving then
    if self.motion[devId] then self.motion[devId] = nil; self.motionN = self.motionN - 1 end
    return
  end
  local n = self.motion[devId]
  if not n then n = 0; self.motionN = self.motionN + 1 end
  if n >= 80 then return end
  self.motion[devId] = n + 1
  local delay = route == "LAN" and (self.motionN > 6 and 4000 or 1500) or 3000
  self:scheduleVerify(devId, route, delay)
end

-- After a PULSE (a garage door or gate trigger) whose device has a bound contact driver, the door starts moving seconds later; the next
-- regular poll could be 20 s away. Re-read the device on a short schedule for a minute (10 reads), then fall back to normal polling.
local FOLLOW_MS = { 2000, 4000, 6000, 8000, 10000, 15000, 20000, 30000, 45000, 60000 }

function Router:followUp(devId, route)
  local wanted = false
  for _, c in ipairs(self.registry:componentsOf(devId)) do
    if c.kind == "contact" and self.registry:childFor(c.key) then wanted = true end
  end
  if not wanted then return end
  for _, id in ipairs(self.follow[devId] or {}) do self.rt.sched:cancel(id) end        -- a new pulse restarts the window
  local ids = {}
  for i, ms in ipairs(FOLLOW_MS) do ids[i] = self.rt.sched:after(ms, function() self:verifyNow(devId, route) end) end
  self.follow[devId] = ids
end

function Router:verifyNow(devId, route)
  local d = self.ab:get(devId)
  local function unverified(why)
    self.rt.log:warn("device %s: could not verify last command (%s)", devId, tostring(why))
    if self.hooks.onUnverified then self.hooks.onUnverified(devId) end
  end
  if route == "LAN" and d and self.ab:lanUsable(devId) then
    self.dispatch:submit(devId, "verify", "verify", function(done)
      self.lan:status(d, function(out, norm)
        done()
        if out.ok and self:ingestLan(d, norm, { verify = true }) then return self:watchMotion(devId, norm, "LAN") end
        if not out.ok then self.ab:noteFailure(devId, out.reason) end
        unverified(out.reason or "identity")
      end)
    end)
  else
    self.cloud:read({ devId }, "verify", function(out, devs)
      if out.ok and devs and devs[1] then
        self.registry:applyRead(devId, devs[1], "cloud", { verify = true })
        self:watchMotion(devId, devs[1], "Cloud")
      else unverified(out.reason) end
    end)
  end
end

-- Apply a LAN status read: identity check first, then state. Returns true if accepted.
function Router:ingestLan(d, norm, opts)
  local same = Lan.sameIdentity(d.identity, norm.identity)
  if same == false then
    self.ab:noteIdentityMismatch(d.id, norm.identity)
    if self.hooks.onNeedRefresh then self.hooks.onNeedRefresh(d.id) end
    return false
  end
  if same == nil and norm.identity and (norm.identity.mac or norm.identity.id) and not d.identity then
    self.ab:setIdentity(d.id, norm.identity)              -- trust on first use, only when nothing better is known
  end
  self.ab:noteIdentityOk(d.id)
  self.ab:noteSuccess(d.id)
  -- Keep the component set current from LAN reads too: a profile change (switch <-> cover, light <-> rgb) must be noticed on a
  -- LAN-only install, which has no cloud refresh to notice it. A repeat read changes nothing (cheap: a few table lookups).
  if (norm.components and #norm.components > 0) or (norm.unsupported and #norm.unsupported > 0) then
    local changed = self.registry:upsert({ id = d.id, components = norm.components, unsupported = norm.unsupported }, "lan")
    if changed and self.hooks.onStructure then self.hooks.onStructure(d.id) end
  end
  self.registry:applyRead(d.id, norm, "lan", opts)
  return true
end

return Router
