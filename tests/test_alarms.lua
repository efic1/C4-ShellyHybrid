-- Unified critical-alarm events on the hub: one trigger + variables for every water / smoke / gas sensor.
local H = require("tests.harness")
local Sc = require("tests.scenario")
local test, eq, truthy, falsy, contains, not_contains = H.test, H.eq, H.truthy, H.falsy, H.contains, H.not_contains
local system, assertClean, KEY = Sc.system, Sc.assertClean, Sc.KEY

local function gasStatus(alarm, sensor)
  return { gas_sensor = { sensor_state = sensor or "normal", self_test_state = "not_completed", alarm_state = alarm or "none" },
           concentration = { ppm = 3, is_valid = true } }
end
local DEVS = {
  { id = "aa0000000041", addr = "192.168.1.71", status = { ["flood:0"] = { id = 0, alarm = false, mute = false } } },
  { id = "aa0000000042", addr = "192.168.1.72", status = { ["smoke:0"] = { id = 0, alarm = false, mute = false } } },
  { id = "aa0000000043", addr = "192.168.1.73", gen1 = "SHGS-1", status = gasStatus() },
  { id = "aa0000000044", addr = "192.168.1.74", status = { ["switch:0"] = { id = 0, output = false } } },
}
local function var(S, name) return S.hub.vars[name] and S.hub.vars[name].value end
local function started(S) return S.hub:firedCount("Critical Alarm Started") end
local function cleared(S) return S.hub:firedCount("Critical Alarm Cleared") end
local function flood(S) return S.sims["aa0000000041"].status["flood:0"] end
local function smoke(S) return S.sims["aa0000000042"].status["smoke:0"] end

test("alarms: the hub declares the variables and a quiet start (no event, nothing active)", function()
  local S = system({ devices = DEVS })
  S.dir:advance(60000)
  for _, n in ipairs({ "Alarm Active", "Active Alarm Count", "Alarm Type", "Alarm Source", "Alarm Source ID", "Alarm Device ID",
                       "Alarm Message", "Alarm Time", "Active Alarms" }) do truthy(S.hub.vars[n], "missing hub variable " .. n) end
  eq(started(S), 0); eq(var(S, "Alarm Active"), "0"); eq(var(S, "Active Alarm Count"), "0")
  assertClean(S)
end)

test("alarms: a water leak fires ONE 'Critical Alarm Started' with type, source, ids and a ready-made message; clearing fires Cleared and All Cleared", function()
  local S = system({ devices = DEVS })
  S.dir:advance(60000)
  local child
  for _, k in ipairs(S.dir:all("shelly_sensor")) do if k:prop("Sensor Component") == "flood" then child = k end end
  child.name = "Kitchen leak sensor"                                   -- the installer renamed it in Composer
  flood(S).alarm = true
  S.dir:advance(45000)
  eq(started(S), 1)
  eq(var(S, "Alarm Type"), "Water leak"); eq(var(S, "Alarm Source"), "Kitchen leak sensor")
  eq(var(S, "Alarm Source ID"), "aa0000000041"); eq(var(S, "Alarm Device ID"), tostring(child.id))
  eq(var(S, "Alarm Message"), "Water leak alarm detected: Kitchen leak sensor")
  eq(var(S, "Alarm Active"), "1"); eq(var(S, "Active Alarm Count"), "1")
  eq(var(S, "Active Alarms"), "Water leak: Kitchen leak sensor"); truthy(#var(S, "Alarm Time") > 0)
  S.dir:advance(120000)
  eq(started(S), 1, "repeated polls of an active alarm announce nothing more")
  flood(S).alarm = false
  S.dir:advance(45000)
  eq(cleared(S), 1); eq(S.hub:firedCount("All Critical Alarms Cleared"), 1)
  eq(var(S, "Alarm Message"), "Water leak alarm cleared: Kitchen leak sensor")
  eq(var(S, "Alarm Active"), "0"); eq(var(S, "Active Alarm Count"), "0")
  assertClean(S)
end)

test("alarms: with no sensor driver created for it, the alarm is still announced (named from model and id)", function()
  local S = system({ devices = DEVS })
  S.dir:advance(60000)
  for _, k in ipairs(S.dir:all("shelly_sensor")) do k.env.OnDriverDestroyed() ; k.env.ReceivedFromProxy = nil end
  S.hub.env.ExecuteCommand("SHELLY_UNREGISTER", { CHILD_ID = tostring(S.dir:all("shelly_sensor")[1].id) })
  smoke(S).alarm = true
  S.dir:advance(45000)
  eq(started(S), 1); eq(var(S, "Alarm Type"), "Smoke")
  truthy(var(S, "Alarm Source"):find("0042", 1, true), "source falls back to model + short id: " .. tostring(var(S, "Alarm Source")))
end)

test("alarms: gas is announced with its level; an unknown/faulted reading never clears an active alarm", function()
  local S = system({ devices = DEVS })
  S.dir:advance(60000)
  local sim = S.sims["aa0000000043"]
  sim.status.gas_sensor.alarm_state = "heavy"
  S.dir:advance(45000)
  eq(started(S), 1); eq(var(S, "Alarm Type"), "Gas"); contains(var(S, "Alarm Message"), "Gas alarm (heavy) detected")
  sim.status.gas_sensor.sensor_state = "fault"; sim.status.gas_sensor.alarm_state = "none"      -- a faulted sensor is NOT an all-clear
  S.dir:advance(120000)
  eq(cleared(S), 0); eq(var(S, "Active Alarm Count"), "1")
  sim.status.gas_sensor.sensor_state = "normal"
  S.dir:advance(45000)
  eq(cleared(S), 1); eq(var(S, "Active Alarm Count"), "0")
end)

local SLEEPERS = {
  { id = "aa0000000041", addr = "192.168.1.71", sim = { mode = "dead", cloudOnline = false }, status = { ["flood:0"] = { id = 0, alarm = false, mute = false } } },
  { id = "aa0000000042", addr = "192.168.1.72", sim = { mode = "dead", cloudOnline = false }, status = { ["smoke:0"] = { id = 0, alarm = false, mute = false } } },
}
test("alarms: two active alarms are counted and listed; All Cleared fires only when the last one clears", function()
  local S = system({ devices = SLEEPERS })
  S.dir:advance(120000)
  flood(S).alarm = true; smoke(S).alarm = true
  S.dir:advance(150000)
  eq(started(S), 2); eq(var(S, "Active Alarm Count"), "2")
  contains(var(S, "Active Alarms"), "Water leak"); contains(var(S, "Active Alarms"), "Smoke")
  flood(S).alarm = false
  S.dir:advance(150000)
  eq(cleared(S), 1); eq(S.hub:firedCount("All Critical Alarms Cleared"), 0, "one alarm is still active")
  eq(var(S, "Active Alarms"), "Smoke: " .. var(S, "Active Alarms"):match("Smoke: (.*)"))
  smoke(S).alarm = false
  S.dir:advance(150000)
  eq(cleared(S), 2); eq(S.hub:firedCount("All Critical Alarms Cleared"), 1); eq(var(S, "Active Alarm Count"), "0")
end)

test("alarms (unit): alarms arriving at the same instant are announced one at a time, each with its own variables", function()
  local F = require("tests.fakes")
  local Alarms = require("hub.alarms")
  local rt = F.new()
  rt.sched = require("common.sched").new(rt)
  rt.log = { warn = function() end, info = function() end, debug = function() end }
  local comps = { ["a|flood|0"] = { devId = "a", kind = "flood" }, ["b|smoke|0"] = { devId = "b", kind = "smoke" } }
  local values = { ["a|flood|0"] = { alarm = true }, ["b|smoke|0"] = { alarm = true } }
  local reg = { component = function(_, k) return comps[k] end, value = function(_, k) return values[k] end,
    device = function() return { model = "X" } end, childFor = function() return nil end }
  local vars, log = {}, {}
  local env = { addVar = function() end, setVar = function(n, v) vars[n] = v end,
    fire = function(name) log[#log + 1] = { name = name, type = vars["Alarm Type"], source = vars["Alarm Source ID"], at = rt.clock.now() } end }
  local a = Alarms.new(rt, env, { registry = reg })
  a:observe("a|flood|0"); a:observe("b|smoke|0")
  eq(#log, 1, "only the first is announced at once")
  rt.advance(1000); eq(#log, 1)
  rt.advance(1000); eq(#log, 2)
  eq(log[1].type, "Water leak"); eq(log[1].source, "a"); eq(log[2].type, "Smoke"); eq(log[2].source, "b")
  truthy(log[2].at - log[1].at >= 1500, "gap between announcements: " .. (log[2].at - log[1].at))
  eq(a:count(), 2)
end)

test("alarms: a sensor that goes unreachable while alarming stays active (silence is not an all-clear)", function()
  local S = system({ devices = DEVS })
  S.dir:advance(60000)
  flood(S).alarm = true
  S.dir:advance(45000)
  eq(started(S), 1)
  S.sims["aa0000000041"].mode = "dead"; S.sims["aa0000000041"].cloudOnline = false
  S.dir:advance(3600000)
  eq(cleared(S), 0); eq(var(S, "Active Alarm Count"), "1")
end)

test("alarms: after a controller restart an alarm that is still active is announced again", function()
  local S1 = system({ devices = DEVS })
  S1.dir:advance(60000)
  flood(S1).alarm = true
  S1.dir:advance(45000)
  eq(started(S1), 1)
  local S2 = system({ devices = DEVS, noSetup = true, store = S1.hub.store, props = { Server = "shelly-42-eu.shelly.cloud", ["Authorization Key"] = KEY } })
  S2.sims["aa0000000041"].status["flood:0"].alarm = true
  S2.dir:advance(150000)
  eq(started(S2), 1)
end)

test("alarms: 'Send Test Alarm' announces a made-up alarm and clears it, without touching real alarm state", function()
  local S = system({ devices = DEVS })
  S.dir:advance(60000)
  S.hub:action("Send Test Alarm")
  eq(started(S), 1); contains(var(S, "Alarm Message"), "TEST")
  eq(var(S, "Active Alarm Count"), "0", "a test is not an active alarm")
  S.dir:advance(8000)
  eq(cleared(S), 1); eq(S.hub:firedCount("All Critical Alarms Cleared"), 0)
  S.hub:action("Send Test Alarm"); S.hub:action("Send Test Alarm")
  eq(started(S), 2, "a second request while one runs is ignored")
end)

test("alarms: a plain switch or a contact never produces a critical alarm", function()
  local S = system({ devices = DEVS })
  S.dir:advance(60000)
  S.sims["aa0000000044"].status["switch:0"].output = true
  S.dir:advance(60000)
  eq(started(S), 0)
end)
