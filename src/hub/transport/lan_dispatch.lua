-- LAN dispatcher: one lane per device, at most ONE request in flight per device (Shelly documents
-- six simultaneous non-persistent RPC channels per device, shared with the Shelly app and other
-- integrations) and at most `globalMax` in flight across the hub (bounds controller CPU and
-- sockets). Waiting work is coalesced per key, ordered control > verify > poll, and lanes are
-- served round-robin so a scene touching many devices cannot starve any of them.
--
-- Performance: no timers while idle (only a watchdog per running request); O(lanes) per pump.
local D = {}
D.__index = D

local PRIO = { control = 1, verify = 2, poll = 3 }

function D.new(rt, opts)
  opts = opts or {}
  local self = setmetatable({}, D)
  self.rt = rt
  self.globalMax = opts.globalMax or 3
  self.watchdogMs = opts.watchdogMs or 15000
  self.lanes, self.order, self.cursor = {}, {}, 0
  self.running, self.maxRunning = 0, 0
  self.pumping, self.again, self.sweepId = false, false, nil
  return self
end

local function lane(self, devId)
  local l = self.lanes[devId]
  if not l then
    l = { id = devId, waiting = { {}, {}, {} }, index = {}, busy = false }
    self.lanes[devId] = l
    self.order[#self.order + 1] = devId
  end
  return l
end

local function remove(list, e) for i = 1, #list do if list[i] == e then table.remove(list, i); return end end end

-- entry.run(done) must call done() exactly once. entry.onDrop(reason) is optional.
function D:submit(devId, prio, key, run, onDrop)
  local l = lane(self, devId)
  local p = PRIO[prio] or 3
  local e = { run = run, key = key, p = p, onDrop = onDrop }
  if key and l.index[key] then
    local old = l.index[key]
    remove(l.waiting[old.p], old)
    if old.onDrop then old.onDrop("superseded") end
  end
  local w = l.waiting[p]
  w[#w + 1] = e
  if key then l.index[key] = e end
  self:kick()
  return e
end

function D:cancel(devId, key)
  local l = self.lanes[devId]
  local e = l and key and l.index[key]
  if e then
    remove(l.waiting[e.p], e); l.index[key] = nil
    if e.onDrop then e.onDrop("cancelled") end
    return true
  end
  return false
end

function D:waitingCount(devId)
  local l = self.lanes[devId]
  return l and (#l.waiting[1] + #l.waiting[2] + #l.waiting[3]) or 0
end
function D:isBusy(devId) local l = self.lanes[devId]; return l ~= nil and l.busy end

-- Dispatch is synchronous (no timer per submit); a re-entrancy guard turns nested calls into a loop.
function D:kick() self:pump() end

local function nextEntry(l)
  for p = 1, 3 do
    local e = table.remove(l.waiting[p], 1)
    if e then
      if e.key and l.index[e.key] == e then l.index[e.key] = nil end
      return e
    end
  end
end

-- ONE shared sweeper replaces a watchdog timer per request: it exists only while there has been
-- recent activity, and releases any lane whose request has been running longer than watchdogMs.
function D:ensureSweeper()
  if self.sweepId then return end
  local period = math.min(5000, math.floor(self.watchdogMs / 2))
  self.sweepId = self.rt.everyNative(period, function()
    local now = self.rt.clock.now()
    for _, id in ipairs(self.order) do
      local l = self.lanes[id]
      if l.busy and l.release and now - l.startedAt >= self.watchdogMs then
        self.rt.log:error("LAN request to %s never completed; releasing its slot", tostring(l.id))
        l.release()
      end
    end
    if self.running == 0 and now - (self.lastActive or now) > 30000 then
      self.sweepId.cancel(); self.sweepId = nil
    end
  end)
end

function D:pump()
  if self.pumping then self.again = true; return end
  self.pumping = true
  repeat
    self.again = false
    local n = #self.order
    local scanned = 0
    while n > 0 and self.running < self.globalMax and scanned < n do
      self.cursor = self.cursor % n + 1
      scanned = scanned + 1
      local l = self.lanes[self.order[self.cursor]]
      if not l.busy and (#l.waiting[1] + #l.waiting[2] + #l.waiting[3]) > 0 then
        local e = nextEntry(l)
        l.busy, l.startedAt = true, self.rt.clock.now()
        self.running = self.running + 1
        if self.running > self.maxRunning then self.maxRunning = self.running end
        self.lastActive = l.startedAt
        self:ensureSweeper()
        scanned = 0
        local finished = false
        local function done()
          if finished then return end
          finished = true
          l.busy, l.release = false, nil
          self.running = self.running - 1
          self.lastActive = self.rt.clock.now()
          self:pump()
        end
        l.release = done
        local ok, err = pcall(e.run, done)
        if not ok then
          self.rt.log:error("LAN request failed to start: %s", tostring(err))
          done()
        end
      end
    end
  until not self.again
  self.pumping = false
end

return D
