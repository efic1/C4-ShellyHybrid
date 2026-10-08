-- Gen1 support: Shelly 1 (relay) and the Flood SHWT-1 / Smoke SHSM-01 / Gas SHGS-1 alarm sensors.
local H = require("tests.harness")
local F = require("tests.fakes")
local Gen1Sim = require("tests.gen1_sim")
local Auth = require("hub.transport.lan_auth")
local Lan = require("hub.transport.lan")
local Parse = require("hub.transport.parse")
local Sc = require("tests.scenario")
local test, eq, truthy, falsy, contains, not_contains = H.test, H.eq, H.truthy, H.falsy, H.contains, H.not_contains
local system, assertClean, KEY = Sc.system, Sc.assertClean, Sc.KEY

local function setup(simOpts, password)
  local rt = F.new()
  local sim = Gen1Sim.new(rt, simOpts)
  local auth = Auth.new(rt)
  local lan = Lan.new(rt, auth)
  lan.passwordFor = function() return password end
  local d = { id = sim.id, address = sim.addr }
  return rt, sim, lan, d, auth
end

local function run(rt, fn)
  local a, b
  fn(function(x, y) a, b = x, y end)
  rt.advance(5000)
  return a, b
end

-- ---------------------------------------------------------------------------------------------- LAN client
test("gen1 lan: the probe recognises Gen1 from /shelly (type + mac, no gen), learns model, auth and identity, stays on plain HTTP", function()
  local rt, sim, lan, d = setup({ model = "SHSW-1" })
  local out, info = run(rt, function(cb) lan:probe(d, cb) end)
  truthy(out.ok); eq(d.gen, 1); eq(d.model, "SHSW-1"); eq(d.scheme, "http"); eq(d.authRequired, false)
  eq(info.identity.mac, "112233445566"); eq(info.gen, 1)
end)

test("gen1 lan: /status becomes normalised components (relays[] -> switch:N), with MAC identity and no address echoed back", function()
  local rt, sim, lan, d = setup({ model = "SHSW-1" })
  d.gen, d.model = 1, "SHSW-1"
  local out, dev = run(rt, function(cb) lan:status(d, cb) end)
  truthy(out.ok)
  eq(#dev.components, 1); eq(dev.components[1].kind, "switch"); eq(dev.components[1].channel, 0); eq(dev.components[1].on, false)
  eq(dev.identity.mac, "112233445566"); eq(dev.address, nil)
end)

test("gen1 lan: a relay command is GET /relay/N?turn=on|off (absolute, never toggle), with a flip-back timer when asked", function()
  local rt, sim, lan, d = setup({ model = "SHSW-1" })
  d.gen = 1
  truthy((run(rt, function(cb) lan:set(d, "switch", 0, { on = true }, cb) end)).ok)
  truthy((run(rt, function(cb) lan:set(d, "switch", 0, { on = false }, cb) end)).ok)
  truthy((run(rt, function(cb) lan:set(d, "switch", 0, { on = true, toggle_after = 2.6 }, cb) end)).ok)
  eq(sim.calls[1].path, "/relay/0?turn=on"); eq(sim.calls[2].path, "/relay/0?turn=off"); eq(sim.calls[3].path, "/relay/0?turn=on&timer=3")
  for _, c in ipairs(sim.calls) do not_contains(c.path, "toggle") end
  eq(sim.status.relays[1].ison, true)
end)

test("gen1 lan: only relays can be commanded on a Gen1 device; anything else is a CONFIG error and nothing is sent", function()
  local rt, sim, lan, d = setup({})
  d.gen = 1
  local out = run(rt, function(cb) lan:set(d, "light", 0, { level = 50 }, cb) end)
  falsy(out.ok); eq(out.class, "CONFIG"); eq(#sim.requests, 0)
end)

test("gen1 lan: HTTP Basic auth - /shelly stays open, a 401 is answered once with the password, later calls authenticate up front", function()
  local rt, sim, lan, d, auth = setup({ password = "right" }, "right")
  d.gen = 1
  run(rt, function(cb) lan:probe(d, cb) end)
  eq(d.authRequired, true)
  eq(sim.requests[1].auth, nil, "/shelly carries no credentials")
  truthy((run(rt, function(cb) lan:status(d, cb) end)).ok)
  eq(auth:credentialedRequests(d.id), 1)
  local before = #sim.requests
  truthy((run(rt, function(cb) lan:status(d, cb) end)).ok)
  eq(#sim.requests - before, 1, "no extra 401 round trip once authentication is known")
  eq(sim.rejected, 0)
end)

test("gen1 lan: a wrong password is tried ONCE, then credentialed traffic to that device stops (and stays stopped)", function()
  local rt, sim, lan, d, auth = setup({ password = "right" }, "wrong")
  d.gen = 1
  local out = run(rt, function(cb) lan:status(d, cb) end)
  falsy(out.ok); eq(out.class, "AUTH"); truthy(out.rejected)
  eq(sim.rejected, 1)
  for _ = 1, 4 do run(rt, function(cb) lan:status(d, cb) end) end
  eq(sim.rejected, 1, "no further credentialed attempt")
end)

test("gen1 lan: no password configured on a protected device -> 'set Device Password', nothing is guessed", function()
  local rt, sim, lan, d = setup({ password = "right" }, nil)
  d.gen = 1
  local out = run(rt, function(cb) lan:status(d, cb) end)
  eq(out.class, "AUTH"); truthy(out.needsPassword); eq(sim.rejected, 0)
end)

test("gen1 lan: an unreachable device is UNREACHABLE; a non-JSON 200 is not a success", function()
  local rt, sim, lan, d = setup({ mode = "dead" })
  d.gen = 1
  eq((run(rt, function(cb) lan:status(d, cb) end)).class, "UNREACHABLE")
  sim.mode = "http"
  rt.http.on(function(spec) return spec.url:find("192.168.1.80", 1, true) end, function() return F.resp(200, "<html>portal</html>") end)
  eq((run(rt, function(cb) lan:status(d, cb) end)).class, "UNREACHABLE")
end)

-- ------------------------------------------------------------------------------------------------ parsing
test("gen1 parse: Shelly 1 relays, Flood, Smoke and Gas statuses become components; gas mild/heavy are alarms, test and none are not", function()
  local relay = Parse.device({ id = "aabbccddeeff", gen = "G1", code = "SHSW-1", online = true },
    { mac = "AABBCCDDEEFF", relays = { { ison = true } }, wifi_sta = { ip = "192.168.1.5" } })
  eq(relay.supported, true); eq(relay.components[1].kind, "switch"); eq(relay.components[1].on, true)
  eq(relay.address, "192.168.1.5"); eq(relay.identity.mac, "AABBCCDDEEFF")
  local flood = Parse.device({ id = "a", gen = "G1", code = "SHWT-1" }, { flood = true, bat = { value = 80 } })
  eq(flood.components[1].kind, "flood"); eq(flood.components[1].alarm, true); eq(flood.supported, true)
  local smoke = Parse.device({ id = "b", gen = "G1", code = "SHSM-01" }, { smoke = false })
  eq(smoke.components[1].kind, "smoke"); eq(smoke.components[1].alarm, false)
  for state, want in pairs({ none = false, test = false, mild = true, heavy = true }) do
    local g = Parse.device({ id = "c", gen = "G1", code = "SHGS-1" }, { gas_sensor = { alarm_state = state }, concentration = { ppm = 120 } })
    eq(g.components[1].kind, "gas"); eq(g.components[1].alarm, want, state); eq(g.components[1].level, state)
  end
end)

test("gen1 parse: Gen1 models that are not supported (2.5 / Uni / roller devices) produce no components, so they are never offered", function()
  local d = Parse.device({ id = "d", gen = "G1", code = "SHSW-25" }, { relays = { { ison = false }, { ison = false } }, rollers = { { state = "stop" } } })
  eq(#d.components, 0); eq(d.supported, false)
  eq(Parse.genNumber("G1"), 1); eq(Parse.genNumber("G2"), 2); eq(Parse.genNumber("GBLE"), nil); eq(Parse.genNumber(nil), nil)
end)

test("gen1 persistence: generation and model survive the compact address-book and registry blobs, and the gas kind has a letter", function()
  local rt = F.new()
  local AB = require("hub.addressbook")
  local ab = AB.new(rt, {})
  ab:ensure("aabbccddeeff"); ab:setGen("aabbccddeeff", 1, "SHSW-1")
  local ab2 = AB.new(F.new(), {}); ab2:import(ab:export())
  eq(ab2:get("aabbccddeeff").gen, 1); eq(ab2:get("aabbccddeeff").model, "SHSW-1")
  local Registry = require("hub.registry")
  local reg = Registry.new(rt, {})
  reg:upsert({ id = "g", components = { { kind = "gas", channel = 0, alarm = false, level = "none" } } })
  local reg2 = Registry.new(F.new(), {}); reg2:import(reg:export())
  eq(reg2:component("g|gas|0").kind, "gas")
end)

-- ---------------------------------------------------------------------------------- real drivers, whole system
local GEN1 = {
  { id = "bb0000000001", addr = "192.168.1.81", gen1 = "SHSW-1", status = { relays = { { ison = false, has_timer = false, source = "input" } } } },
  { id = "bb0000000002", addr = "192.168.1.82", gen1 = "SHGS-1", status = { gas_sensor = { alarm_state = "none" }, concentration = { ppm = 40, is_valid = true } } },
  { id = "bb0000000003", addr = "192.168.1.83", gen1 = "SHWT-1", sim = { mode = "dead", cloudOnline = false }, status = { flood = false, bat = { value = 90, voltage = 2.9 } } },
  { id = "bb0000000004", addr = "192.168.1.84", gen1 = "SHSW-25", status = { relays = { { ison = false }, { ison = false } }, rollers = { { state = "stop" } } } },
}

test("gen1 (real drivers): Fetch Devices + Auto-Setup add the Shelly 1 as a light, the gas and flood sensors as alarm sensors, and skip the unsupported 2.5", function()
  local S = system({ devices = GEN1 })
  eq(#S.onoff(), 1); eq(#S.dir:all("shelly_sensor"), 2)
  eq(#S.dir:all("shelly_blind"), 0)
  local comps = {}
  for _, c in ipairs(S.dir:all("shelly_sensor")) do comps[c:prop("Sensor Component")] = c end
  truthy(comps.gas and comps.flood)
  contains(S.hub:output(), "bb0000000004"); contains(S.hub:output(), "no supported components")
  S.hub.out = {}
  S.hub:action("List Devices")
  local line
  for _, l in ipairs(S.hub.out) do if l:find("bb0000000004", 1, true) then line = l end end
  truthy(line and line:find("UNSUPPORTED", 1, true), "an unsupported Gen1 device is listed, flagged, with no children: " .. tostring(line))
  not_contains(line, "=unassigned")
  assertClean(S)
end)

test("gen1 (real drivers): the Shelly 1 turns on and off over the LAN with absolute commands, feedback follows, and the cloud is never used", function()
  local S = system({ devices = GEN1 })
  S.dir:advance(60000)
  local l = S.onoff()[1]
  local sim = S.sims["bb0000000001"]
  S.cloud.calls = {}
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PERCENT = "100" }); S.dir:advance(3000)
  eq(sim.status.relays[1].ison, true)
  eq(l:lastNote("LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT, 100)
  l:proxy(5001, "OFF"); S.dir:advance(3000)
  eq(sim.status.relays[1].ison, false)
  for _, c in ipairs(sim.calls) do not_contains(c.path, "toggle") end
  eq(S.cloudSets(), 0)
  -- someone presses the wall switch: the next poll shows it
  sim.status.relays[1].ison = true
  S.dir:advance(45000)
  eq(l:lastNote("LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT, 100)
  assertClean(S)
end)

test("gen1 (real drivers): a Shelly 1 that is unreachable on the LAN fails the command cleanly - Gen1 is never commanded through the cloud", function()
  local S = system({ devices = GEN1 })
  S.dir:advance(30000)
  local l = S.onoff()[1]
  S.sims["bb0000000001"].mode = "dead"
  S.dir:advance(120000)
  S.cloud.calls = {}
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PERCENT = "100" }); S.dir:advance(8000)
  eq(S.cloudSets(), 0)
  eq(l:firedCount("Command Failed"), 1); contains(l:prop("Last Command Result"), "LAN only")
end)

test("gen1 (real drivers): a gas alarm reaches Control4 within one LAN poll (the detector is mains-powered), with its level", function()
  local S = system({ devices = GEN1 })
  S.dir:advance(60000)
  local gas
  for _, c in ipairs(S.dir:all("shelly_sensor")) do if c:prop("Sensor Component") == "gas" then gas = c end end
  truthy(gas:lastNote("STATE_OPENED"))
  local sim = S.sims["bb0000000002"]
  sim.status.gas_sensor.alarm_state = "mild"
  S.dir:advance(45000)
  eq(gas:firedCount("Alarm Started"), 1); truthy(gas:lastNote("CLOSED")); eq(gas.vars["Alarm Level"].value, "mild")
  sim.status.gas_sensor.alarm_state = "heavy"
  S.dir:advance(45000)
  eq(gas:firedCount("Alarm Started"), 1, "mild -> heavy is still one alarm"); eq(gas.vars["Alarm Level"].value, "heavy")
  sim.status.gas_sensor.alarm_state = "test"
  S.dir:advance(45000)
  eq(gas:firedCount("Alarm Cleared"), 1, "the self-test buzzer is not an alarm"); eq(gas.vars["Alarm Level"].value, "test")
  assertClean(S)
end)

test("gen1 (real drivers): a silent gas detector (mains-powered) is reported offline after ~10 minutes, not 25 hours like a battery sensor", function()
  local S = system({ devices = GEN1 })
  S.dir:advance(60000)
  local gas, flood
  for _, c in ipairs(S.dir:all("shelly_sensor")) do if c:prop("Sensor Component") == "gas" then gas = c else flood = c end end
  S.sims["bb0000000002"].mode = "dead"; S.sims["bb0000000002"].cloudOnline = false
  S.dir:advance(1500000)
  eq(gas:firedCount("Device Offline"), 1); eq(flood:firedCount("Device Offline"), 0)
end)

test("gen1 (real drivers): a sleeping Flood SHWT-1 follows the cloud's last report like the Gen2 sleepers", function()
  local S = system({ devices = GEN1 })
  S.dir:advance(120000)
  local flood
  for _, c in ipairs(S.dir:all("shelly_sensor")) do if c:prop("Sensor Component") == "flood" then flood = c end end
  S.sims["bb0000000003"].status.flood = true
  S.dir:advance(150000)
  eq(flood:firedCount("Alarm Started"), 1); truthy(flood:lastNote("CLOSED"))
  eq(flood:firedCount("Device Offline"), 0)
end)

test("gen1 (real drivers): a password-protected Shelly 1 works with the Device Password (Basic auth) and stops after one wrong attempt", function()
  local devs = { { id = "bb0000000010", addr = "192.168.1.90", gen1 = "SHSW-1", password = "right", status = { relays = { { ison = false } } } } }
  local S = system({ devices = devs, noSetup = true, props = { ["Device Password"] = "wrong" } })
  S.hub:setProp("Server", "shelly-42-eu.shelly.cloud"); S.hub:setProp("Authorization Key", KEY)
  S.dir:advance(3000); S.hub:action("Fetch Devices"); S.dir:advance(3000)
  S.hub:action("Auto-Setup Children"); S.dir:advance(15000)
  S.hub:action("Poll Now"); S.dir:advance(200000)
  local sim = S.sims["bb0000000010"]
  eq(sim.rejected, 1)
  eq(S.hub:firedCount("Device Authentication Failed"), 1)
  S.hub:setProp("Device Password", "right"); S.dir:advance(120000)
  contains(S.hub:prop("LAN Status"), "Up 1")
  eq(sim.rejected, 1)
end)

test("gen1 parse: a faulted battery sensor (null values, is_valid false / sensor_error) keeps its component but concludes NOTHING - no stale alarm, no guessed all-clear", function()
  local ok = Parse.device({ id = "a", gen = "G1", code = "SHWT-1" }, { flood = true, is_valid = true, sensor_error = 0 })
  eq(ok.components[1].alarm, true)
  for _, bad in ipairs({ { is_valid = false, bat = { value = 70 } }, { flood = true, is_valid = false }, { flood = true, is_valid = true, sensor_error = 2 } }) do
    local d = Parse.device({ id = "a", gen = "G1", code = "SHWT-1" }, bad)
    eq(#d.components, 1, "the component is still known"); eq(d.components[1].kind, "flood"); eq(d.components[1].alarm, nil)
  end
  local smoke = Parse.device({ id = "b", gen = "G1", code = "SHSM-01" }, { is_valid = false })
  eq(smoke.components[1].kind, "smoke"); eq(smoke.components[1].alarm, nil)
  local gas = Parse.device({ id = "c", gen = "G1", code = "SHGS-1" }, { concentration = { ppm = 0 } })
  eq(gas.components[1].kind, "gas"); eq(gas.components[1].alarm, nil)
end)

test("gen1 (registry): an unknown reading never clears or sets an alarm - the last good value stays", function()
  local Registry = require("hub.registry")
  local reg = Registry.new(F.new(), {})
  reg:upsert({ id = "f", components = { { kind = "flood", channel = 0, alarm = false } } })
  reg:applyRead("f", { components = { { kind = "flood", channel = 0, alarm = true } } }, "cloud")
  eq(reg:value("f|flood|0").alarm, true)
  reg:applyRead("f", { components = { { kind = "flood", channel = 0, alarm = nil } } }, "cloud")
  eq(reg:value("f|flood|0").alarm, true, "a faulted read did not clear the alarm")
end)

-- The exact /status examples from the Gen1 documentation (Shelly Smoke and Shelly Flood).
local DOC_SMOKE = { is_valid = true, smoke = false, tmp = { value = 22, units = "C", tC = 22, tF = 71.6, is_valid = true },
  bat = { value = 71, voltage = 2.73 }, act_reasons = { "button" } }
local DOC_FLOOD = { is_valid = true, flood = false, tmp = { value = 20, units = "C", tC = 20, tF = 68, is_valid = true },
  bat = { value = 71, voltage = 2.73 }, act_reasons = { "periodic" }, rain_sensor = false }

test("gen1 parse: the documented Smoke and Flood /status examples parse to one alarm component each, with the battery percentage", function()
  local s = Parse.device({ id = "a", gen = "G1", code = "SHSM-01" }, DOC_SMOKE)
  eq(#s.components, 1); eq(s.components[1].kind, "smoke"); eq(s.components[1].alarm, false); eq(s.components[1].battery, 71)
  local f = Parse.device({ id = "b", gen = "G1", code = "SHWT-1" }, DOC_FLOOD)
  eq(#f.components, 1); eq(f.components[1].kind, "flood"); eq(f.components[1].alarm, false); eq(f.components[1].battery, 71)
  local alarm = Parse.device({ id = "b", gen = "G1", code = "SHWT-1" }, { is_valid = true, flood = true, bat = { value = 70 }, act_reasons = { "alarm" } })
  eq(alarm.components[1].alarm, true)
end)

test("gen1 parse: sensor_error (only present on error) and is_valid=false make the reading unknown; the temperature sensor's own is_valid is irrelevant", function()
  local bad = Parse.device({ id = "a", gen = "G1", code = "SHSM-01" }, { is_valid = true, smoke = true, sensor_error = 3, bat = { value = 50 } })
  eq(bad.components[1].alarm, nil); eq(bad.components[1].battery, 50, "the battery is still reported")
  local tmpBad = Parse.device({ id = "a", gen = "G1", code = "SHSM-01" }, { is_valid = true, smoke = true, tmp = { is_valid = false } })
  eq(tmpBad.components[1].alarm, true, "a faulty temperature sensor does not invalidate the smoke reading")
end)

test("gen1 (real drivers): the sensor child shows the battery percentage in a variable, updated only when it changes", function()
  local S = system({ devices = GEN1 })
  S.dir:advance(120000)
  local flood
  for _, c in ipairs(S.dir:all("shelly_sensor")) do if c:prop("Sensor Component") == "flood" then flood = c end end
  eq(flood.vars["Battery Level"].value, "90")
  flood:resetCounts()
  S.dir:advance(600000)
  eq(flood.total, 0, "no Director calls while nothing changes")
  S.sims["bb0000000003"].status.bat.value = 89
  S.dir:advance(150000)
  eq(flood.vars["Battery Level"].value, "89")
end)

-- The exact Shelly Gas /status example from the Gen1 documentation.
local DOC_GAS = { gas_sensor = { sensor_state = "normal", self_test_state = "completed", alarm_state = "none" },
  concentration = { ppm = 100, is_valid = true }, valves = { { state = "not_connected" } } }
local function gasOf(gs) return Parse.device({ id = "g", gen = "G1", code = "SHGS-1" }, { gas_sensor = gs }).components[1] end

test("gen1 parse: the documented Gas /status example is one gas component - no alarm, level none, sensor normal", function()
  local d = Parse.device({ id = "g", gen = "G1", code = "SHGS-1" }, DOC_GAS)
  eq(#d.components, 1); eq(d.components[1].kind, "gas"); eq(d.components[1].alarm, false); eq(d.components[1].level, "none"); eq(d.components[1].state, "normal")
end)

test("gen1 parse: gas - mild and heavy are alarms whatever the sensor state; 'none' and 'test' are trusted only from a NORMAL sensor", function()
  for _, state in ipairs({ "normal", "warmup", "fault", "unknown" }) do
    eq(gasOf({ alarm_state = "mild", sensor_state = state }).alarm, true, "mild/" .. state)
    eq(gasOf({ alarm_state = "heavy", sensor_state = state }).alarm, true, "heavy/" .. state)
  end
  eq(gasOf({ alarm_state = "none", sensor_state = "normal" }).alarm, false)
  eq(gasOf({ alarm_state = "test", sensor_state = "normal" }).alarm, false, "the self-test result is not an alarm")
  eq(gasOf({ alarm_state = "none" }).alarm, false, "older firmware without sensor_state is trusted")
  for _, state in ipairs({ "warmup", "fault", "unknown" }) do
    eq(gasOf({ alarm_state = "none", sensor_state = state }).alarm, nil, "a " .. state .. " sensor cannot assert all-clear")
  end
end)

test("gen1 parse: gas alarm_state 'unknown' (documented) is UNKNOWN, never 'no alarm'; an unrecognised value is unknown too", function()
  local u = gasOf({ alarm_state = "unknown", sensor_state = "normal" })
  eq(u.alarm, nil); eq(u.level, "unknown"); eq(u.state, "normal")
  eq(gasOf({ alarm_state = "something-new", sensor_state = "normal" }).alarm, nil)
end)

test("gen1 (real drivers): a gas detector that reports a fault does not clear or set the contact, and the fault is visible in Sensor State", function()
  local S = system({ devices = GEN1 })
  S.dir:advance(60000)
  local gas
  for _, c in ipairs(S.dir:all("shelly_sensor")) do if c:prop("Sensor Component") == "gas" then gas = c end end
  local sim = S.sims["bb0000000002"]
  sim.status.gas_sensor.alarm_state = "mild"; sim.status.gas_sensor.sensor_state = "normal"
  S.dir:advance(45000)
  eq(gas:firedCount("Alarm Started"), 1)
  sim.status.gas_sensor.alarm_state = "none"; sim.status.gas_sensor.sensor_state = "fault"      -- a faulted sensor must not announce an all-clear
  S.dir:advance(45000)
  eq(gas:firedCount("Alarm Cleared"), 0); eq(gas.vars["Sensor State"].value, "fault")
  sim.status.gas_sensor.sensor_state = "normal"
  S.dir:advance(45000)
  eq(gas:firedCount("Alarm Cleared"), 1, "back to normal and reporting none: now it clears")
  assertClean(S)
end)
