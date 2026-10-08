-- One-timer scheduler.
-- The driver owns at most ONE Control4 timer at a time, armed for the earliest due item.
-- Idle drivers therefore cause no wake-ups, and a burst of due work is bounded
-- (`maxPerFire`) so a single callback can never monopolise Director's Lua thread.
local Sched = {}
Sched.__index = Sched

function Sched.new(rt)
  local self = setmetatable({}, Sched)
  self.rt = rt
  self.items = {}          -- sorted ascending by due
  self.byId = {}
  self.nextId = 0
  self.handle, self.armedDue = nil, nil
  self.maxPerFire = rt.maxPerFire or 25
  self.onError = rt.onError or function() end
  self.fires = 0
  return self
end

local function insert(items, rec)
  local lo, hi = 1, #items + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if items[mid].due <= rec.due then lo = mid + 1 else hi = mid end
  end
  table.insert(items, lo, rec)
end

function Sched:arm()
  local items = self.items
  while items[1] and items[1].cancelled do table.remove(items, 1) end
  local head = items[1]
  if not head then
    if self.handle then self.handle.cancel(); self.handle = nil end
    self.armedDue = nil
    return
  end
  if self.handle and self.armedDue and self.armedDue <= head.due then return end
  if self.handle then self.handle.cancel() end
  local wait = head.due - self.rt.clock.now()
  if wait < 1 then wait = 1 end
  self.armedDue = head.due
  self.handle = self.rt.setTimer(wait, function() self:fire() end)
end

-- If the clock steps BACKWARDS (an NTP correction) every stored due time would sit in the future and the
-- scheduler would appear dead until the old time is reached. Detect the step and shift all due times.
function Sched:checkClock(now, fromFire)
  local last = self.lastSeen
  self.lastSeen = now
  if last and now < last - 2000 then
    -- Treat time as paused across the step: keep every item's remaining wait, and when we were woken
    -- by the timer the head item is due now.
    local base = last
    if fromFire and self.items[1] then base = self.items[1].due end
    for _, r in ipairs(self.items) do r.due = now + math.max(0, r.due - base) end
    if self.handle then self.handle.cancel(); self.handle = nil end
    self.armedDue = nil
    self.rt.log:warn("clock stepped back %ds; scheduler rebased", math.floor((last - now) / 1000))
  end
end

function Sched:fire()
  self.handle, self.armedDue = nil, nil
  self.fires = self.fires + 1
  self:checkClock(self.rt.clock.now(), true)
  local now, items, ran = self.rt.clock.now(), self.items, 0
  while items[1] and (items[1].cancelled or items[1].due <= now) and ran < self.maxPerFire do
    local rec = table.remove(items, 1)
    if not rec.cancelled then
      ran = ran + 1
      if rec.period then
        rec.due = math.max(rec.due + rec.period, now + math.floor(rec.period / 2))
        insert(items, rec)
      else
        self.byId[rec.id] = nil
      end
      local ok, err = pcall(rec.fn)
      if not ok then self.onError(err) end
    end
  end
  self:arm()
end

local function add(self, ms, fn, period)
  self:checkClock(self.rt.clock.now())
  self.nextId = self.nextId + 1
  local rec = { id = self.nextId, due = self.rt.clock.now() + (ms > 0 and ms or 0), fn = fn, period = period }
  self.byId[rec.id] = rec
  insert(self.items, rec)
  self:arm()
  return rec.id
end

function Sched:after(ms, fn) return add(self, ms, fn, nil) end
function Sched:every(ms, fn) return add(self, ms, fn, ms) end

function Sched:cancel(id)
  local rec = id and self.byId[id]
  if rec then rec.cancelled = true; self.byId[id] = nil end
end

function Sched:pending()
  local n = 0
  for _, r in ipairs(self.items) do if not r.cancelled then n = n + 1 end end
  return n
end

return Sched
