-- LAN feed: one staggered round-robin timer for ALL devices.
--
-- Performance (Director): a single repeating scheduler item fires every interval/N (min 250 ms)
-- and services at most ONE device per tick, so N devices cost N/interval requests per second
-- spread evenly - never a synchronous burst. A device whose previous read is still in flight is
-- skipped, not stacked. Probes of Probing/Down devices share the same rotation, on back-off.
local Lan = require("hub.transport.lan")

local Feed = {}
Feed.__index = Feed

function Feed.new(rt, deps)
  local self = setmetatable({}, Feed)
  self.rt = rt
  for k, v in pairs(deps) do self[k] = v end       -- ab, registry, lan, dispatch, router, hooks
  self.hooks = deps.hooks or {}
  self.cursor, self.tickH = 0, nil
  self.inflight = {}
  return self
end

function Feed:intervalMs() return (self.rt.cfg.lanPollS or 20) * 1000 end

function Feed:start()
  self:stop()
  if self.ab:count() == 0 then return end                 -- nothing to poll: hold no timer at all
  local n = self.ab:count()
  local tick = math.max(250, math.floor(self:intervalMs() / n))
  self.tickH = self.rt.everyNative(tick, function() self:tick() end)     -- ONE native repeating timer
end
function Feed:stop() if self.tickH then self.tickH.cancel(); self.tickH = nil end end
function Feed:restart() self:start() end

-- A request that never completes is released by the dispatcher's watchdog, which cannot reach this flag:
-- a flag older than twice the watchdog is stale, otherwise the device would never be read again.
function Feed:isInflight(id)
  local t = self.inflight[id]
  if not t then return false end
  local limit = 2 * ((self.dispatch and self.dispatch.watchdogMs) or 15000)
  if self.rt.clock.now() - t >= limit then self.inflight[id] = nil; return false end
  return true
end

function Feed:tick()
  local ids = self.ab:ids()
  local n = #ids
  if n == 0 then return end
  local now = self.rt.clock.now()
  for _ = 1, n do
    self.cursor = self.cursor % n + 1
    local d = self.ab:get(ids[self.cursor])
    if d and not self:isInflight(d.id) then
      local due = (d.lastPoll or 0) + math.floor(self:intervalMs() * 0.9) <= now
      if (d.lan == "Up" or d.lan == "Degraded") and due then return self:poll(d) end
      if self.ab:probeDue(d.id) then return self:probe(d) end
    end
  end
end

function Feed:poll(d)
  self.inflight[d.id] = self.rt.clock.now()
  self.dispatch:submit(d.id, "poll", "poll", function(done)
    self.lan:status(d, function(out, norm)
      done()
      self.inflight[d.id] = nil
      d.lastPoll = self.rt.clock.now()
      if out.ok then
        if self.router:ingestLan(d, norm, {}) then self.router:watchMotion(d.id, norm, "LAN") end
      else self:failed(d, out) end
    end)
  end, function() self.inflight[d.id] = nil end)
end

function Feed:probe(d)
  self.inflight[d.id] = self.rt.clock.now()
  self.dispatch:submit(d.id, "poll", "probe", function(done)
    self.lan:probe(d, function(out, info)
      done()
      self.inflight[d.id] = nil
      if not out.ok then
        if out.class == "CONFIG" then self.rt.log:warn("device %s: %s", d.id, out.reason) end
        return self:failed(d, out)
      end
      local same = Lan.sameIdentity(d.identity, info.identity)
      if same == false then
        self.ab:noteIdentityMismatch(d.id, info.identity)
        if self.hooks.onNeedRefresh then self.hooks.onNeedRefresh(d.id) end
        return
      end
      if same == nil and not d.identity and info.identity then self.ab:setIdentity(d.id, info.identity) end
      self.ab:noteIdentityOk(d.id)
      self.ab:noteSuccess(d.id)
      d.lastPoll = nil                              -- read state on the very next tick
    end)
  end, function() self.inflight[d.id] = nil end)
end

function Feed:failed(d, out)
  if out.identityMismatch then
    self.ab:noteIdentityMismatch(d.id, out.seen)
    if self.hooks.onNeedRefresh then self.hooks.onNeedRefresh(d.id) end
    return
  end
  if out.class == "AUTH" then
    local pw = self.lan.passwordFor(d)
    self.ab:noteAuthReject(d.id, pw and self.lan.auth:passHash(d.id, pw) or "no-password")
  elseif out.class == "UNREACHABLE" then
    self.ab:noteFailure(d.id, out.reason)
  else
    self.rt.log:debug("device %s read: %s", d.id, tostring(out.reason))
  end
end

return Feed
