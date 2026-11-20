-- Unified critical-alarm events for the hub: ONE trigger (and a set of variables) for every water-leak, smoke and gas sensor, so a
-- notification is programmed once - "When Critical Alarm Started, send '<Alarm Message>'" - instead of once per sensor driver.
--
-- It watches the registry, not the sensor child drivers, so it works whether or not a child driver exists for the sensor.
-- Rules:
--   * only a KNOWN alarm reading counts: an unknown/faulted reading (alarm == nil) neither starts nor clears an alarm;
--   * an alarm stays active until the sensor itself reports all-clear (a sensor that goes offline does not clear it);
--   * variables are set immediately BEFORE the event fires; simultaneous alarms are announced one at a time (ANNOUNCE_GAP_MS apart)
--     so a program reading the variables never sees the next alarm's values;
--   * after a controller restart an alarm that is still active is announced again (alarm values are not persisted, and a missed
--     critical alarm is worse than a repeated one).
local ids = require("common.ids")

local A = {}
A.__index = A

local ANNOUNCE_GAP_MS = 1500
local TEST_CLEAR_MS = 6000
local TYPE_OF = { flood = "Water leak", smoke = "Smoke", gas = "Gas" }

function A.new(rt, env, opts)
  local self = setmetatable({}, A)
  self.rt, self.env = rt, env
  self.registry = opts.registry
  self.nameOf = opts.nameOf or function() return nil end        -- (childId) -> display name or nil
  self.active = {}                                              -- ckey -> { type, source, id, since }
  self.queue, self.busy, self.testing = {}, false, false
  return self
end

-- Declare the hub variables (static names from the generated ids; a single place so core.lua declares none itself).
function A:setup()
  for _, v in ipairs(ids.variables.hub) do
    local initial = ""                                           -- values travel as strings, like every other variable in this suite
    if v.type == "BOOL" or v.type == "NUMBER" then initial = "0" end
    self.env.addVar(v.name, initial, v.type)
  end
end

local function stamp()
  local ok, s = pcall(os.date, "%Y-%m-%d %H:%M:%S")
  return ok and s or ""
end

local function describe(self, ckey)
  local c = self.registry:component(ckey)
  if not c then return nil end
  local dev = self.registry:device(c.devId) or {}
  local childId = self.registry:childFor(ckey)
  local name = childId and self.nameOf(childId) or nil
  if not name or name == "" then
    name = string.format("%s %s", dev.model or "Shelly", tostring(c.devId):sub(-4))
  end
  return { type = TYPE_OF[c.kind] or "Alarm", source = name, id = c.devId, child = childId or 0, kind = c.kind }
end

-- Drop alarms whose component no longer exists (device purged from the hub).
local function prune(self)
  for ckey in pairs(self.active) do
    if not self.registry:component(ckey) then self.active[ckey] = nil end
  end
end

local function sortedActive(self)
  local list = {}
  for ckey, a in pairs(self.active) do list[#list + 1] = { key = ckey, a = a } end
  table.sort(list, function(x, y) if x.a.since ~= y.a.since then return x.a.since < y.a.since end return x.key < y.key end)
  return list
end

function A:count() local n = 0; for _ in pairs(self.active) do n = n + 1 end; return n end

local function summary(self)
  local parts = {}
  for _, e in ipairs(sortedActive(self)) do parts[#parts + 1] = e.a.type .. ": " .. e.a.source end
  return table.concat(parts, "; ")
end

local function level(self, ckey)
  local v = self.registry:value(ckey)
  return v and v.level
end

local function message(info, started, lvl)
  local what = info.type == "Gas" and lvl and lvl ~= "" and lvl ~= "none" and ("Gas alarm (" .. lvl .. ")") or (info.type .. " alarm")
  if info.test then what = "TEST - " .. what end
  return what .. (started and " detected: " or " cleared: ") .. info.source
end

-- Set every variable, then fire. `entry` = { started = bool, info = {...}, lvl = string|nil }
local function announce(self, entry)
  local info, env = entry.info, self.env
  local n = self:count()
  env.setVar("Alarm Type", info.type)
  env.setVar("Alarm Source", info.source)
  env.setVar("Alarm Source ID", tostring(info.id))
  env.setVar("Alarm Device ID", tostring(info.child))
  env.setVar("Alarm Message", message(info, entry.started, entry.lvl))
  env.setVar("Alarm Time", stamp())
  env.setVar("Alarm Active", n > 0 and "1" or "0")
  env.setVar("Active Alarm Count", tostring(n))
  env.setVar("Active Alarms", summary(self))
  env.fire(entry.started and "Critical Alarm Started" or "Critical Alarm Cleared")
  if not entry.started and n == 0 and not info.test then env.fire("All Critical Alarms Cleared") end
end

function A:pump()
  if self.busy then return end
  local entry = table.remove(self.queue, 1)
  if not entry then return end
  self.busy = true
  announce(self, entry)
  self.rt.sched:after(ANNOUNCE_GAP_MS, function() self.busy = false; self:pump() end)
end

-- Called by the registry hook for every published component change.
function A:observe(ckey)
  local c = self.registry:component(ckey)
  if not c or not TYPE_OF[c.kind] then return end
  local v = self.registry:value(ckey)
  if not v or v.alarm == nil then return end                    -- unknown reading: never starts or clears an alarm
  local was = self.active[ckey] ~= nil
  if v.alarm and not was then
    prune(self)
    local info = describe(self, ckey)
    if not info then return end
    info.since = self.rt.clock.now()
    self.active[ckey] = info
    self.rt.log:warn("ALARM: %s", message(info, true, v.level))
    self.queue[#self.queue + 1] = { started = true, info = info, lvl = v.level }
    self:pump()
  elseif not v.alarm and was then
    local info = self.active[ckey]
    self.active[ckey] = nil
    self.rt.log:info("alarm cleared: %s", message(info, false))
    self.queue[#self.queue + 1] = { started = false, info = info }
    self:pump()
  end
end

-- Action: announce a made-up alarm so the notification program can be tested (does not touch real alarm state).
function A:test()
  if self.testing then return self.rt.log:info("a test alarm is already running") end
  self.testing = true
  local info = { type = "Water leak", source = "Test sensor", id = "TEST", child = 0, test = true }
  self.queue[#self.queue + 1] = { started = true, info = info }
  self:pump()
  self.rt.sched:after(TEST_CLEAR_MS, function()
    self.queue[#self.queue + 1] = { started = false, info = info }
    self:pump()
    self.testing = false
  end)
end

return A
