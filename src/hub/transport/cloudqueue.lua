-- Cloud request queue: one request in flight, >= gapMs between request STARTS, priority
-- (control > verify > background), coalescing per key, merging of identical control commands,
-- bounded depth, whole-queue back-off on 429, and a hard stop on authentication failure.
--
-- Performance: the queue holds no timers while idle; a pump is scheduled only when work is
-- waiting for the rate gate.
local NEVER = -1e15                                   -- 'not blocked' sentinel that any clock value exceeds
local Q = {}
Q.__index = Q

local PRIO = { control = 1, verify = 2, background = 3 }
local BACKOFF = { 5000, 10000, 20000, 60000 }

function Q.new(rt, opts)
  opts = opts or {}
  local self = setmetatable({}, Q)
  self.rt = rt
  self.gapMs = opts.gapMs or 1200
  self.max = opts.max or 50
  self.watchdogMs = opts.watchdogMs or 60000
  self.waiting = { {}, {}, {} }
  self.index = {}
  self.inflight = false
  self.lastStart = nil
  self.blockedUntil = NEVER
  self.backoffIdx = 0
  self.authStopped = false
  self.pumpId = nil
  self.starts = {}                      -- request start times, for requests/minute
  self.dropped = 0
  return self
end

local function count(self) return #self.waiting[1] + #self.waiting[2] + #self.waiting[3] end
function Q:depth() return count(self) end

local function remove(list, entry)
  for i = 1, #list do if list[i] == entry then table.remove(list, i); return end end
end

local function fail(entry, class, reason)
  if entry.cb then entry.cb({ ok = false, class = class, reason = reason }) end
end

-- entry: { prio, key?, mergeKey?, staleAfter?, run(list, finish), cb(outcome) }
function Q:enqueue(entry)
  if self.authStopped then fail(entry, "AUTH", "cloud authentication failed; correct the key"); return false end
  local p = PRIO[entry.prio or "background"]
  entry.p, entry.at, entry.retries = p, self.rt.clock.now(), 0
  if entry.key then
    local old = self.index[entry.key]
    if old and not old.running then                  -- replace the waiting one; never touch one in flight
      remove(self.waiting[old.p], old)
      self.index[entry.key] = nil
      fail(old, "SUPERSEDED", "replaced by a newer command")
    end
  end
  if count(self) >= self.max then
    -- shed background first, then verify; a control entry is rejected loudly, never dropped silently
    local victim = self.waiting[3][1] or self.waiting[2][1]
    if victim then
      remove(self.waiting[victim.p], victim)
      if victim.key then self.index[victim.key] = nil end
      self.dropped = self.dropped + 1
      fail(victim, "CLOUD", "dropped: cloud queue full")
    else
      fail(entry, "CLOUD", "QUEUE_FULL")
      return false
    end
  end
  local list = self.waiting[p]
  list[#list + 1] = entry
  if entry.key then self.index[entry.key] = entry end
  self:pump()
  return true
end

function Q:cancelKey(key)
  local e = self.index[key]
  if e and not e.running then
    remove(self.waiting[e.p], e)
    self.index[key] = nil
    fail(e, "SUPERSEDED", "cancelled")
  end
end

local function pick(self)
  local now = self.rt.clock.now()
  local bg = self.waiting[3][1]
  if bg and bg.staleAfter and now - bg.at > bg.staleAfter then
    -- starvation guard: a background entry that has waited past its deadline runs NEXT,
    -- ahead of control traffic, for exactly one request
    return table.remove(self.waiting[3], 1)
  end
  for p = 1, 3 do
    local e = table.remove(self.waiting[p], 1)
    if e then return e end
  end
end

function Q:pump()
  if self.inflight or self.authStopped or count(self) == 0 then return end
  local now = self.rt.clock.now()
  if self.lastStart and self.lastStart > now then self.lastStart = now end               -- clock stepped back
  if self.blockedUntil > now + 60000 then self.blockedUntil = now + 60000 end
  local ready = self.blockedUntil
  if self.lastStart and self.lastStart + self.gapMs > ready then ready = self.lastStart + self.gapMs end
  if now < ready then
    if not self.pumpId then
      self.pumpId = self.rt.sched:after(ready - now, function() self.pumpId = nil; self:pump() end)
    end
    return
  end
  local first = pick(self)
  if not first then return end
  local list = { first }
  if first.mergeKey then
    local ctl = self.waiting[1]
    local i = 1
    while i <= #ctl do
      if ctl[i].mergeKey == first.mergeKey then list[#list + 1] = table.remove(ctl, i) else i = i + 1 end
    end
  end
  for _, e in ipairs(list) do e.running = true; if e.key and self.index[e.key] == e then self.index[e.key] = nil end end
  self.inflight, self.lastStart = true, now
  self.starts[#self.starts + 1] = now
  if #self.starts > 120 then table.remove(self.starts, 1) end

  local done = false
  local watchdog
  local function finish(outcomes)
    if done then return end
    done = true
    if watchdog then self.rt.sched:cancel(watchdog) end
    self.inflight = false
    local worst
    for i, e in ipairs(list) do
      local out = outcomes.ok ~= nil and outcomes or outcomes[i] or { ok = false, class = "CLOUD", reason = "no result" }
      e.running = false
      if out.class == "RATE" and e.retries < 2 then
        e.retries = e.retries + 1
        table.insert(self.waiting[e.p], 1, e)
        if e.key then self.index[e.key] = e end
        worst = worst or out
      else
        if e.cb then e.cb(out) end
        if out.class == "AUTH" or out.class == "RATE" then worst = worst or out end
      end
    end
    if worst and worst.class == "RATE" then
      self.backoffIdx = math.min(self.backoffIdx + 1, #BACKOFF)
      self.blockedUntil = self.rt.clock.now() + BACKOFF[self.backoffIdx]
      self.rt.log:warn("cloud rate limited; backing off %ds", BACKOFF[self.backoffIdx] / 1000)
    elseif worst and worst.class == "AUTH" then
      self:stop("authentication failed")
    else
      self.backoffIdx = 0
    end
    self.rt.sched:after(0, function() self:pump() end)
  end
  watchdog = self.rt.sched:after(self.watchdogMs, function()
    self.rt.log:error("cloud request never completed; releasing the queue")
    finish({ ok = false, class = "CLOUD", reason = "request timed out" })
  end)
  local ok, err = pcall(first.run, list, finish)
  if not ok then
    self.rt.log:error("cloud request failed to start: %s", tostring(err))
    finish({ ok = false, class = "CLOUD", reason = "internal error" })
  end
end

-- Authentication stop: everything waiting is failed once, loudly.
function Q:stop(reason)
  self.authStopped = true
  self.rt.log:error("cloud traffic stopped: %s", reason or "stopped")
  for p = 1, 3 do
    local list = self.waiting[p]
    self.waiting[p] = {}
    for _, e in ipairs(list) do fail(e, "AUTH", reason or "stopped") end
  end
  self.index = {}
end

function Q:resume()
  if self.authStopped then self.authStopped = false; self.backoffIdx = 0; self.blockedUntil = NEVER end
  self:pump()
end

function Q:requestsLastMinute()
  local now, n = self.rt.clock.now(), 0
  for i = #self.starts, 1, -1 do
    if now - self.starts[i] <= 60000 then n = n + 1 else break end
  end
  return n
end

return Q
