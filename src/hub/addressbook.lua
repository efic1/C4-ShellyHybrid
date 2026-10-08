-- Address book + per-device LAN state machine.
--
--   NoAddress -> Probing -> Up <-> Degraded -> Down -> Probing ...   (+ AuthStop from any state)
--
-- Nothing here does I/O; it only records outcomes and answers "may I use the LAN for this device,
-- and when should I probe again". Addresses are persisted so LAN control works immediately after
-- a controller reboot with no internet; nothing is TRUSTED until an identity-checked probe or read.
local U = require("common.util")

local AB = {}
AB.__index = AB

local BACKOFF_S = { 15, 30, 60, 300 }

function AB.new(rt, hooks)
  local self = setmetatable({}, AB)
  self.rt, self.hooks = rt, hooks or {}
  self.devs, self.order = {}, {}
  return self
end

local function dirty(self) if self.hooks.onDirty then self.hooks.onDirty() end end

local function setState(self, d, to, reason)
  local from = d.lan
  if from == to then return end
  d.lan = to
  self.rt.log:debug("lan %s: %s -> %s (%s)", d.id, from, to, tostring(reason))
  if self.hooks.onTransition then self.hooks.onTransition(d.id, from, to, reason) end
end

function AB:ensure(id)
  local d = self.devs[id]
  if not d then
    d = { id = id, lan = "NoAddress", failures = 0, backoffIdx = 0 }
    self.devs[id] = d
    self.order[#self.order + 1] = id
    table.sort(self.order)
  end
  return d
end
function AB:get(id) return self.devs[id] end
function AB:ids() return self.order end
function AB:count() return #self.order end

function AB:remove(id)
  self.devs[id] = nil
  for i, v in ipairs(self.order) do if v == id then table.remove(self.order, i) break end end
  dirty(self)
end

-- source: "cloud" or "override". Returns true when the address actually changed.
function AB:setAddress(id, addr, source)
  local d = self:ensure(id)
  if not U.is_ipv4(addr) then return false end
  if d.override and source ~= "override" then
    if d.override ~= addr and not d.overrideWarned then
      d.overrideWarned = true
      self.rt.log:warn("device %s: cloud reports %s but an address override (%s) is set; keeping the override", id, addr, d.override)
    end
    return false
  end
  if source == "override" then d.override = addr end
  if d.address == addr then return false end
  d.address, d.source = addr, source
  d.scheme = nil                                   -- re-detect for the new address
  d.failures = 0
  setState(self, d, "Probing", "address " .. (d.address and "changed" or "set"))
  dirty(self)
  return true
end

function AB:clearOverride(id)
  local d = self.devs[id]
  if d and d.override then d.override, d.overrideWarned = nil, nil; dirty(self) end
end

function AB:setIdentity(id, ident)
  local d = self:ensure(id)
  if ident and (ident.mac or ident.id) then d.identity = ident; dirty(self) end
end

function AB:setCloudOnline(id, online) local d = self:ensure(id); d.cloudOnline = online end

-- May a command be attempted over the LAN? Probing is allowed: the router probes first when the
-- last identity match is stale, so a persisted-but-unverified address is never trusted blindly.
function AB:lanUsable(id)
  local d = self.devs[id]
  return d ~= nil and d.address ~= nil and (d.lan == "Up" or d.lan == "Degraded" or d.lan == "Probing")
end

function AB:noteSuccess(id)
  local d = self:ensure(id)
  d.failures, d.backoffIdx, d.lastOk = 0, 0, self.rt.clock.now()
  if d.lan ~= "AuthStop" then setState(self, d, "Up", "success") end
end

function AB:noteIdentityOk(id) self:ensure(id).lastIdentityOk = self.rt.clock.now() end

function AB:noteFailure(id, reason)
  local d = self:ensure(id)
  if d.lan == "AuthStop" or d.lan == "NoAddress" then return end
  d.failures = d.failures + 1
  if d.lan == "Probing" or d.lan == "Down" then
    d.backoffIdx = math.min(d.backoffIdx + 1, #BACKOFF_S)
    d.nextProbeAt = self.rt.clock.now() + BACKOFF_S[d.backoffIdx] * 1000
    setState(self, d, "Down", reason)
    if self.hooks.onDown then self.hooks.onDown(id, reason) end
  elseif d.failures >= 3 then
    d.backoffIdx = 1
    d.nextProbeAt = self.rt.clock.now() + BACKOFF_S[1] * 1000
    setState(self, d, "Down", reason)
    if self.hooks.onDown then self.hooks.onDown(id, reason) end
  else
    setState(self, d, "Degraded", reason)
  end
end

-- A different device answered at this address: discard the address and ask for a refresh.
function AB:noteIdentityMismatch(id, seen)
  local d = self:ensure(id)
  self.rt.log:warn("device %s: address %s answered as a different device (%s); discarding the address",
    id, tostring(d.address), tostring(seen and (seen.mac or seen.id)))
  if d.override then
    setState(self, d, "Down", "identity mismatch (override)")
    d.backoffIdx = math.min(d.backoffIdx + 1, #BACKOFF_S)
    d.nextProbeAt = self.rt.clock.now() + BACKOFF_S[d.backoffIdx] * 1000
  else
    d.address, d.source, d.scheme = nil, nil, nil
    setState(self, d, "NoAddress", "identity mismatch")
  end
  d.lastIdentityOk = nil
  dirty(self)
  if self.hooks.onDown then self.hooks.onDown(id, "identity mismatch") end
end

function AB:noteAuthReject(id, stopHash)
  local d = self:ensure(id)
  d.authStopHash = stopHash
  setState(self, d, "AuthStop", "credentials rejected")
  dirty(self)
  if self.hooks.onAuthStop then self.hooks.onAuthStop(id) end
end

function AB:clearAuthStop(id)
  local d = self.devs[id]
  if d and d.lan == "AuthStop" then
    d.authStopHash, d.failures = nil, 0
    setState(self, d, d.address and "Probing" or "NoAddress", "auth stop cleared")
    dirty(self)
  end
end

function AB:probeDue(id)
  local d = self.devs[id]
  if not d or not d.address then return false end
  if d.lan == "Probing" then return true end
  return d.lan == "Down" and (d.nextProbeAt or 0) <= self.rt.clock.now()
end

-- "LAN" | "Cloud" | "Unreachable". cloudOk: cloud connected and usable.
function AB:route(id, cloudOk)
  local d = self.devs[id]
  if d and (d.lan == "Up" or d.lan == "Degraded") then return "LAN" end
  if cloudOk and (not d or d.cloudOnline ~= false) then return "Cloud" end
  return "Unreachable"
end

function AB:counts()
  local c = { Up = 0, Degraded = 0, Down = 0, AuthStop = 0, Probing = 0, NoAddress = 0 }
  for _, id in ipairs(self.order) do local s = self.devs[id].lan; c[s] = (c[s] or 0) + 1 end
  return c
end

-- ---- persistence: only what is needed to resume LAN control after a reboot -------------------
-- Compact on purpose: this blob is read at every driver start (one PersistGetValue per part).
-- i=id a=address s=source o=override h=scheme r=authRequired m/n=identity mac/id x=auth-stop hash
function AB:setGen(id, gen, model)
  local d = self.devs[id]
  if not d then return end
  local changed = false
  if gen and d.gen ~= gen then d.gen = gen; changed = true end
  if model and d.model ~= model then d.model = model; changed = true end
  if changed and self.hooks.onDirty then self.hooks.onDirty() end
end

function AB:export()
  local out = {}
  for _, id in ipairs(self.order) do
    local d = self.devs[id]
    local ident = d.identity or {}
    out[#out + 1] = { i = id, a = d.address, s = d.source, o = d.override or nil,
      h = (d.scheme ~= "http") and d.scheme or nil, r = d.authRequired, m = ident.mac, n = ident.id, x = d.authStopHash, g = d.gen, t = d.model }
  end
  return out
end

function AB:import(list)
  for _, e in ipairs(type(list) == "table" and list or {}) do
    if type(e) == "table" and type(e.i) == "string" then
      local d = self:ensure(e.i)
      d.address, d.source, d.override = e.a, e.s, e.o
      d.scheme, d.authRequired, d.authStopHash = e.h or "http", e.r, e.x
      d.gen, d.model = e.g, e.t
      if e.m or e.n then d.identity = { mac = e.m, id = e.n } end
      d.lan = d.authStopHash and "AuthStop" or (d.address and "Probing" or "NoAddress")
    end
  end
end

return AB
