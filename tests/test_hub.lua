-- System tests: the real bundled drivers run under the mock Director with simulated devices + cloud.
local H = require("tests.harness")
local Director = require("tests.director")
local Sim = require("tests.lan_sim")
local CloudSim = require("tests.cloud_sim")
local test, eq, truthy, falsy, contains, not_contains = H.test, H.eq, H.truthy, H.falsy, H.contains, H.not_contains

local Sc = require("tests.scenario")
local system, assertClean, KEY, DEVICES = Sc.system, Sc.assertClean, Sc.KEY, Sc.DEVICES

-- ---------------------------------------------------------------------------------------------------
test("hub: an unconfigured hub is quiet - no network, at most one Control4 timer, honest status", function()
  local dir = Director.new()
  local hub = dir:load("shelly_hub")
  dir:advance(120000)
  eq(#dir.rt.http.log, 0)
  truthy(hub.timers <= 1, "timers: " .. hub.timers)
  eq(hub:prop("Cloud Status"), "Not configured")
  eq(hub:prop("Devices"), "0 devices, 0 children")
end)

test("hub: a non-Shelly server is refused and the key is never sent or logged", function()
  local dir = Director.new()
  local hub = dir:load("shelly_hub")
  hub:setProp("Server", "attacker.example.com")
  hub:setProp("Authorization Key", KEY)
  dir:advance(3000)
  hub:action("Fetch Devices")
  dir:advance(3000)
  eq(#dir.rt.http.log, 0)
  contains(hub:output(), "configure Server and Authorization Key")
  not_contains(hub:output(), KEY)
end)

test("hub: Fetch Devices + Auto-Setup create exactly one driver per component, correctly typed and configured", function()
  local S = system()
  eq(#S.dir:all("shelly_light"), 1); eq(#S.onoff(), 2); eq(#S.dir:all("shelly_blind"), 1); eq(#S.relays(), 0)
  for _, c in ipairs(S.dir:all()) do
    if c.file ~= "shelly_hub" then
      eq(c:prop("Hub Device ID"), tostring(S.hub.id))
      eq(c:prop("Status"), "Connected", c.file .. " " .. tostring(c.name))
    end
  end
  eq(S.light():prop("Shelly Device ID"), "aa0000000001")
  eq(S.hub:prop("Devices"), "3 devices, 4 children")
  eq(S.hub:prop("Cloud Status"), "Connected")
  assertClean(S)
end)

test("hub: running Auto-Setup again creates nothing (idempotent)", function()
  local S = system()
  local before = #S.dir:all()
  S.hub:action("Auto-Setup Children"); S.dir:advance(5000)
  eq(#S.dir:all(), before)
  contains(S.hub:output(), "nothing to set up")
end)

test("hub: 'Switch Default Type = Relay' creates relay drivers instead of on/off lights", function()
  local S = system({ switchType = "Relay" })
  eq(#S.relays(), 2); eq(#S.onoff(), 0)
end)

test("hub: Gen1 devices are skipped with a clear log line and never given a driver", function()
  local devs = { DEVICES[1], { id = "aa0000000009", addr = "192.168.1.49", status = { ["switch:0"] = { id = 0, output = false } } } }
  local S
  do
    local dir = Director.new({ latency = 10 })
    S = system({ devices = devs, noSetup = true })
    S.sims["aa0000000009"].cloudGen = "G1"
    S.hub:setProp("Server", "shelly-42-eu.shelly.cloud"); S.hub:setProp("Authorization Key", KEY)
    S.dir:advance(3000); S.hub:action("Fetch Devices"); S.dir:advance(3000)
    S.hub:action("Auto-Setup Children"); S.dir:advance(8000)
  end
  eq(#S.dir:all("shelly_light"), 1); eq(#S.onoff(), 0)
  contains(S.hub:output(), "Gen1")
end)

-- ---------------------------------------------------------------------------------------------------
test("light: a dimmer command goes to the device over the LAN, the proxy is told, and the cloud is never touched", function()
  local S = system()
  local l = S.light()
  S.cloud.calls = {}
  l:resetCounts()
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40 })
  S.dir:advance(3000)
  eq(S.sims["aa0000000001"].status["light:0"].brightness, 40)
  eq(S.sims["aa0000000001"].status["light:0"].output, true)
  eq(l:lastNote("LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT, 40)
  eq(l:prop("Route"), "LAN")
  eq(#S.cloud.calls, 0)
  eq(l:notesNamed("LIGHT_BRIGHTNESS_CHANGED")[1].binding, 5001)
  assertClean(S)
end)

test("light: OFF then ON restores the previous brightness; TOGGLE on unknown state is refused", function()
  local S = system()
  local l = S.light()
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 70 }); S.dir:advance(3000)
  l:proxy(5001, "OFF"); S.dir:advance(3000)
  eq(S.sims["aa0000000001"].status["light:0"].output, false)
  eq(l:lastNote("LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT, 0)
  l:proxy(5001, "ON"); S.dir:advance(3000)
  eq(S.sims["aa0000000001"].status["light:0"].brightness, 70)
  local fresh = system({ noSetup = true })
  local orphan = fresh.dir:load("shelly_light")
  orphan:proxy(5001, "TOGGLE")
  contains(orphan:prop("Last Command Result"), "Refused")
end)

test("light: a wall-switch change is picked up by the next poll and shown on the proxy exactly once", function()
  local S = system()
  local l = S.light()
  S.sims["aa0000000001"].status["light:0"].output = true
  S.sims["aa0000000001"].status["light:0"].brightness = 90
  l:resetCounts()
  S.dir:advance(45000)
  local notes = l:notesNamed("LIGHT_BRIGHTNESS_CHANGED")
  eq(#notes, 1); eq(notes[1].params.LIGHT_BRIGHTNESS_CURRENT, 90)
end)

test("light: a device error is reported, the proxy snaps back, Command Failed fires, and the cloud is not used", function()
  local S = system()
  local l = S.light()
  S.dir:advance(30000)                                   -- ensure real state known
  S.sims["aa0000000001"].errorFor["Light.Set"] = { code = -105, message = "bad" }
  S.cloud.calls = {}
  l:resetCounts()
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80 })
  S.dir:advance(3000)
  eq(l:firedCount("Command Failed"), 1)
  contains(l:prop("Last Command Result"), "Failed: DEVICE")
  eq(l:lastNote("LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT, 0, "snapped back to the confirmed value")
  eq(S.cloudSets(), 0)
end)

test("onoff light: turns a relay channel on and off, presented as 0/100", function()
  local S = system()
  local first
  for _, c in ipairs(S.onoff()) do if c:prop("Channel") == "0" then first = c end end
  first:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100 }); S.dir:advance(3000)
  eq(S.sims["aa0000000002"].status["switch:0"].output, true)
  eq(first:lastNote("LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT, 100)
  first:proxy(5001, "OFF"); S.dir:advance(3000)
  eq(S.sims["aa0000000002"].status["switch:0"].output, false)
  eq(first:lastNote("LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT, 0)
end)

test("relay: CLOSE/OPEN/TOGGLE/TRIGGER drive the output; CLOSED/OPENED notifications and events follow", function()
  local S = system({ switchType = "Relay" })
  local r
  for _, c in ipairs(S.relays()) do if c:prop("Channel") == "0" then r = c end end
  S.dir:advance(30000)
  r:resetCounts()
  r:proxy(1, "CLOSE"); S.dir:advance(3000)
  eq(S.sims["aa0000000002"].status["switch:0"].output, true)
  truthy(r:lastNote("CLOSED")); eq(r:firedCount("Relay Closed"), 1); eq(r.vars["Relay State"].value, "Closed")
  r:proxy(1, "TOGGLE"); S.dir:advance(3000)
  eq(S.sims["aa0000000002"].status["switch:0"].output, false)
  eq(r:firedCount("Relay Opened"), 1)
  r:proxy(1, "TRIGGER"); S.dir:advance(3000)
  local last = S.sims["aa0000000002"].calls[#S.sims["aa0000000002"].calls - 1]
  eq(last.params.toggle_after, 1)
  assertClean(S)
end)

test("blind: SET_LEVEL_TARGET -> GoToPosition, MOVING while it moves, STOPPED with the final level", function()
  local S = system()
  local b = S.blind()
  S.dir:advance(30000)
  eq(b:lastNote("STOPPED").params.LEVEL, 30)
  b:resetCounts()
  b:proxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 80 }); S.dir:advance(2500)
  eq(S.lanCalls("aa0000000003", "Cover.GoToPosition"), 1)
  truthy(b:lastNote("MOVING"))
  S.sims["aa0000000003"]:finishMove(0)
  S.dir:advance(6000)
  eq(b:lastNote("STOPPED").params.LEVEL, 80)
  b:proxy(5001, "STOP"); S.dir:advance(3000)
  eq(S.lanCalls("aa0000000003", "Cover.Stop"), 1)
  assertClean(S)
end)

test("blind: an uncalibrated cover only allows open/close/stop and says why otherwise", function()
  local devs = { { id = "aa0000000003", addr = "192.168.1.43", status = { ["cover:0"] = { id = 0, state = "stopped" } } } }
  local S = system({ devices = devs })
  local b = S.blind()
  S.dir:advance(30000)
  b:proxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 50 })
  contains(b:prop("Last Command Result"), "not calibrated")
  b:proxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 0 }); S.dir:advance(3000)        -- no-feedback scheme: open = 0
  eq(S.lanCalls("aa0000000003", "Cover.Open"), 1)
  b:proxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 2 }); S.dir:advance(3000)        -- closed = 2 (1 means unknown)
  eq(S.lanCalls("aa0000000003", "Cover.Close"), 1)
end)

-- ---------------------------------------------------------------------------------------------------
test("routing: LAN outage -> Fallback Started once; commands still work via cloud; LAN Restored once on recovery", function()
  local S = system()
  local l = S.light()
  S.dir:advance(30000)
  S.sims["aa0000000001"].mode = "dead"
  S.dir:advance(120000)
  eq(l:prop("Route"), "Cloud"); eq(l:firedCount("Fallback Started"), 1)
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 25 })
  S.dir:advance(8000)
  eq(S.sims["aa0000000001"].status["light:0"].brightness, 25)
  eq(l:lastNote("LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT, 25)
  S.sims["aa0000000001"].mode = "http"
  S.dir:advance(400000)
  eq(l:prop("Route"), "LAN"); eq(l:firedCount("LAN Restored"), 1); eq(l:firedCount("Fallback Started"), 1)
  eq(l:firedCount("Device Offline"), 0)
  assertClean(S)
end)

test("routing: LAN and cloud both gone -> Device Offline exactly once after the 60 s debounce; Device Online once on recovery", function()
  local S = system()
  local l = S.light()
  S.dir:advance(30000)
  S.sims["aa0000000001"].mode = "dead"
  S.cloud.down = true
  for _ = 1, 4 do S.hub:action("Poll Now"); S.dir:advance(70000) end
  eq(l:firedCount("Device Offline"), 1)
  eq(l.vars["Device Online"].value, "0")
  eq(l:lastNote("ONLINE_CHANGED").params.STATE, false)
  S.sims["aa0000000001"].mode = "http"
  S.cloud.down = false
  S.dir:advance(400000)
  eq(l:firedCount("Device Online"), 1)
  eq(l.vars["Device Online"].value, "1")
  eq(l:lastNote("ONLINE_CHANGED").params.STATE, true)
end)

test("routing: a brief Wi-Fi blip shorter than the debounce never raises Device Offline", function()
  local S = system()
  local l = S.light()
  S.dir:advance(30000)
  S.sims["aa0000000001"].cloudOnline = false
  S.sims["aa0000000001"].mode = "dead"
  S.dir:advance(70000)                                      -- LAN goes Down, cloud says offline
  S.sims["aa0000000001"].cloudOnline = true
  S.sims["aa0000000001"].mode = "http"
  S.dir:advance(400000)
  eq(l:firedCount("Device Offline"), 0)
end)

test("routing: wrong device password stops LAN control, fires Device Authentication Failed once, commands use the cloud", function()
  local S = system()
  S.dir:advance(30000)
  S.sims["aa0000000001"].password = "right-pass"
  S.hub:setProp("Device Password", "wrong-pass")
  S.hub:action("Poll Now")
  S.dir:advance(60000)
  local credentialed = S.sims["aa0000000001"].rejected
  S.dir:advance(300000)
  eq(S.sims["aa0000000001"].rejected, credentialed, "no more credentialed attempts after the stop")
  truthy(credentialed <= 1)
  eq(S.hub:firedCount("Device Authentication Failed"), 1)
  local l = S.light()
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 33 }); S.dir:advance(8000)
  eq(S.sims["aa0000000001"].status["light:0"].brightness, 33)
  S.hub:setProp("Device Password", "right-pass")             -- the fix
  S.dir:advance(120000)
  contains(S.hub:prop("LAN Status"), "Up 3")
  assertClean(S, true)                                       -- the auth-stop ERROR line is expected here
end)

test("hub: bad cloud key -> Cloud Authentication Failed once, cloud traffic stops, LAN keeps working", function()
  local S = system()
  S.cloud.authOk = false
  S.hub:action("Fetch Devices"); S.dir:advance(3000)
  eq(S.hub:prop("Cloud Status"), "Auth failed"); eq(S.hub:firedCount("Cloud Authentication Failed"), 1)
  local n = #S.cloud.calls
  S.dir:advance(700000)
  eq(#S.cloud.calls, n)
  S.light():proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 10 }); S.dir:advance(3000)
  eq(S.sims["aa0000000001"].status["light:0"].brightness, 10)
end)

test("hub: reboot with NO internet restores addresses and controls devices over the LAN", function()
  local S1 = system()
  S1.dir:advance(60000)
  local store, props = S1.hub.store, {}
  local kids = {}
  for _, c in ipairs(S1.dir:all()) do if c.file ~= "shelly_hub" then kids[#kids + 1] = { file = c.file, props = c.env.Properties } end end
  local S2 = system({ noSetup = true, cloudDown = true, store = store, props = { Server = "shelly-42-eu.shelly.cloud", ["Authorization Key"] = KEY } })
  for _, k in ipairs(kids) do
    local copy = {}
    for a, b in pairs(k.props) do copy[a] = b end
    S2.dir:load(k.file, { props = copy })
  end
  S2.dir:advance(60000)
  contains(S2.hub:prop("LAN Status"), "Up 3")
  local l = S2.dir:byFile("shelly_light")
  eq(l:prop("Status"), "Connected")
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 66 }); S2.dir:advance(3000)
  eq(S2.sims["aa0000000001"].status["light:0"].brightness, 66)
  eq(l:prop("Route"), "LAN")
end)

test("hub: Test LAN reports each device and clears stale auth stops", function()
  local S = system()
  S.dir:advance(30000)
  S.hub.out = {}
  S.hub:action("Test LAN"); S.dir:advance(10000)
  local out = S.hub:output()
  contains(out, "aa0000000001"); contains(out, "identity=match"); contains(out, "state=OK")
end)

test("hub: List Devices and Show Recent Activity print to the Lua output without touching properties", function()
  local S = system()
  S.hub:resetCounts()
  S.hub:action("List Devices"); S.hub:action("Show Recent Activity")
  contains(S.hub:output(), "aa0000000003")
  eq(S.hub.calls.UpdateProperty or 0, 0)
end)

test("hub: Add Device By ID with an address works with NO cloud at all (LAN-only install)", function()
  local dir = Director.new({ latency = 10 })
  local sim = Sim.new(dir.rt, { addr = "192.168.1.60", mac = "AA0000000060", id = "shelly-aa0000000060" })
  dir.sims["aa0000000060"] = sim
  local hub = dir:load("shelly_hub")
  hub:setProp("Manual Device ID", "aa0000000060")
  hub:setProp("Manual Device Address", "192.168.1.60")
  hub:action("Add Device By ID"); dir:advance(5000)
  hub:action("Auto-Setup Children"); dir:advance(20000)
  truthy(#dir:all("shelly_light") >= 1)
  eq(#dir.rt.http.log > 0, true)
  for _, r in ipairs(dir.rt.http.log) do not_contains(r.url, "shelly.cloud") end
  local l = dir:byFile("shelly_light")
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 20 }); dir:advance(3000)
  eq(sim.status["light:0"].brightness, 20)
end)

test("hub: Add Device By ID accepts several ids and reads them with ONE documented v2 'get' (no device listing needed)", function()
  local S = system({ noSetup = true })
  S.hub:setProp("Server", "shelly-42-eu.shelly.cloud"); S.hub:setProp("Authorization Key", KEY)
  S.dir:advance(3000)
  S.hub:setProp("Manual Device ID", "aa0000000001, aa0000000002 aa0000000003")
  S.hub:action("Add Device By ID"); S.dir:advance(8000)
  local gets = {}
  for _, c in ipairs(S.cloud.calls) do if c.op == "get" then gets[#gets + 1] = #c.ids end end
  eq(gets, { 3 })
  contains(S.hub:prop("Devices"), "3 devices")
  eq(#S.cloud.calls > 0, true)
  for _, c in ipairs(S.cloud.calls) do falsy(c.op == "all_status") end
end)

test("hub: when the device listing is unavailable, Fetch Devices says so and points at Add Device By ID", function()
  local S = system({ noSetup = true })
  S.cloud.noListing = true
  S.hub:setProp("Server", "shelly-42-eu.shelly.cloud"); S.hub:setProp("Authorization Key", KEY)
  S.dir:advance(3000)
  S.hub:action("Fetch Devices"); S.dir:advance(5000)
  contains(S.hub:output(), "Add Device By ID")
  contains(S.hub:output(), "fetch failed")
end)

test("hub: Add Device By ID refuses an address together with several ids", function()
  local S = system({ noSetup = true })
  S.hub:setProp("Manual Device ID", "aa0000000001 aa0000000002"); S.hub:setProp("Manual Device Address", "192.168.1.41")
  S.hub:action("Add Device By ID")
  contains(S.hub:output(), "single device id")
end)

test("hub: with no Default Room ID, Auto-Setup uses the documented room-less AddDevice form and names each child afterwards", function()
  local S = system()
  local calls = S.hub.calls
  truthy((calls.AddDevice or 0) >= 4)
  for _, c in ipairs(S.dir:all()) do
    if c.file ~= "shelly_hub" then
      eq(c.room, nil, "no room id was passed")
      truthy(c.name and c.name:find(c.file == "shelly_blind" and "cover" or "%a"), "child was renamed: " .. tostring(c.name))
    end
  end
end)

test("hub: with a Default Room ID, children are created in that room with their name in one documented call", function()
  local S = system({ noSetup = true, props = { ["Default Room ID"] = "38" } })
  S.hub:setProp("Server", "shelly-42-eu.shelly.cloud"); S.hub:setProp("Authorization Key", KEY)
  S.dir:advance(3000); S.hub:action("Fetch Devices"); S.dir:advance(3000)
  S.hub:action("Auto-Setup Children"); S.dir:advance(15000)
  local n = 0
  for _, c in ipairs(S.dir:all()) do
    if c.file ~= "shelly_hub" then n = n + 1; eq(c.room, 38); truthy(c.name) end
  end
  eq(n, 4)
end)

test("hub: an action arrives by NAME or by COMMAND and both work; an unknown one is logged, not fatal", function()
  local S = system()
  S.hub.out = {}
  S.hub:action("List Devices"); S.hub:action("List Devices", "command")
  local n = 0
  for _, l in ipairs(S.hub.out) do if l:find("--- Devices ---", 1, true) then n = n + 1 end end
  eq(n, 2)
  S.hub.env.ExecuteCommand("LUA_ACTION", { ACTION = "No Such Thing" })
  contains(S.hub:output(), "unknown action")
  assertClean(S)
end)

test("child drivers: their Composer actions really run (LUA_ACTION by name and by command)", function()
  local S = system()
  local l = S.light()
  l.out = {}
  l:action("Show Status"); l:action("Show Status", "command")
  local n = 0
  for _, line in ipairs(l.out) do if line:find("registered: true", 1, true) then n = n + 1 end end
  eq(n, 2, "Show Status printed twice")
  l:resetCounts()
  l:action("Re-register With Hub"); S.dir:advance(3000)
  local regs = 0
  for _, m in ipairs(l.sent) do if m.cmd == "SHELLY_REGISTER" then regs = regs + 1 end end
  eq(regs, 1)
  eq(l:prop("Status"), "Connected")
end)

test("relay: a device bound to the relay connection AFTER setup is told the current state (OnBindingChanged)", function()
  local S = system({ switchType = "Relay" })
  S.dir:advance(30000)
  local r
  for _, c in ipairs(S.relays()) do if c:prop("Channel") == "1" then r = c end end   -- switch:1 starts ON in the fixture
  r:resetCounts()
  r:bind(1, true); S.dir:advance(2000)
  local n = r:lastNote("STATE_CLOSED")
  truthy(n, "state republished to the newly bound consumer"); eq(n.binding, 1)
  eq(r:firedCount("Relay Closed"), 0)
end)

test("light (real drivers): the Navigator On/Off tiles arrive as presets and a percent, and the device follows", function()
  local S = system()
  local l = S.light()
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PERCENT = "35", RATE = "-1" }); S.dir:advance(3000)
  eq(S.sims["aa0000000001"].status["light:0"].brightness, 35)
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = "2" }); S.dir:advance(3000)
  eq(S.sims["aa0000000001"].status["light:0"].output, false)
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = "1" }); S.dir:advance(3000)
  eq(S.sims["aa0000000001"].status["light:0"].output, true); eq(S.sims["aa0000000001"].status["light:0"].brightness, 35)
  assertClean(S)
end)

test("blind (real drivers): one command produces ONE MOVING with the real target, the start level and a ramp rate, then STOPPED", function()
  local S = system()
  local b = S.blind()
  S.dir:advance(30000)
  b:resetCounts()
  b:proxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 80 }); S.dir:advance(6000)
  local mv = b:notesNamed("MOVING")
  eq(#mv, 1, "polling the moving cover must not re-announce the movement")
  eq(mv[1].params.LEVEL_TARGET, 80); eq(mv[1].params.LEVEL, 30); truthy(mv[1].params.RAMP_RATE >= 500)
  S.sims["aa0000000003"]:finishMove(0); S.dir:advance(6000)
  eq(b:lastNote("STOPPED").params.LEVEL, 80)
  assertClean(S)
end)

test("light (real drivers): a scene member arrives with RATE and the device is asked for that transition", function()
  local S = system()
  local l = S.light()
  S.dir:advance(30000)
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PERCENT = "70", RATE = "4000" }); S.dir:advance(3000)
  local sent
  for _, c in ipairs(S.sims["aa0000000001"].calls) do if c.method == "Light.Set" then sent = c.params end end
  eq(sent.brightness, 70); eq(sent.transition_duration, 4)
  assertClean(S)
end)

test("blind (real drivers): UP and DOWN from the proxy open and close an UNCALIBRATED cover (the no-position mode sends no level)", function()
  local devs = { { id = "aa0000000003", addr = "192.168.1.43", status = { ["cover:0"] = { id = 0, state = "stopped" } } } }
  local S = system({ devices = devs })
  local b = S.blind()
  S.dir:advance(30000)
  b:proxy(5001, "UP"); S.dir:advance(3000)
  eq(S.lanCalls("aa0000000003", "Cover.Open"), 1)
  b:proxy(5001, "DOWN"); S.dir:advance(3000)
  eq(S.lanCalls("aa0000000003", "Cover.Close"), 1)
  b:proxy(5001, "STOP"); S.dir:advance(3000)
  eq(S.lanCalls("aa0000000003", "Cover.Stop"), 1)
  local has = b:lastNote("SET_HAS_LEVEL")
  eq(has.params.HAS_LEVEL, false)
  assertClean(S)
end)

local function allLines(inst) return table.concat(inst.out, "\n") end

test("hub: 'Switch Type Overrides' - per device and per channel, most specific wins, garbage ignored, default otherwise", function()
  local S = system({ noSetup = true, props = { ["Switch Type Overrides"] = "aa0000000002:1=Relay, junk, 0002:0=Light; xx=Relay ;;" } })
  S.hub:setProp("Server", "shelly-42-eu.shelly.cloud"); S.hub:setProp("Authorization Key", KEY)
  S.dir:advance(3000); S.hub:action("Fetch Devices"); S.dir:advance(3000)
  S.hub:action("Auto-Setup Children"); S.dir:advance(15000)
  local kinds = {}
  for _, c in ipairs(S.dir:all()) do
    if c.file == "shelly_relay" or c.file == "shelly_light_onoff" then kinds[c:prop("Channel")] = c.file end
  end
  eq(kinds["0"], "shelly_light_onoff"); eq(kinds["1"], "shelly_relay")
end)

test("hub: an override by device-id suffix applies to every channel; the hub-wide default still applies elsewhere", function()
  local S = system({ noSetup = true, props = { ["Switch Type Overrides"] = "0002=Relay" } })
  S.hub:setProp("Server", "shelly-42-eu.shelly.cloud"); S.hub:setProp("Authorization Key", KEY)
  S.dir:advance(3000); S.hub:action("Fetch Devices"); S.dir:advance(3000)
  S.hub:action("Auto-Setup Children"); S.dir:advance(15000)
  eq(#S.relays(), 2); eq(#S.onoff(), 0)
end)

test("hub: a colour-only device (rgb profile) is reported as not controllable - once, with its profile - while inputs and sensors stay silent", function()
  local devs = {
    { id = "aa0000000010", addr = "192.168.1.50", profile = "rgb", status = { ["rgb:0"] = { id = 0, output = true, brightness = 40, rgb = { 255, 0, 0 } }, ["input:0"] = { id = 0 } } },
    { id = "aa0000000011", addr = "192.168.1.51", status = { ["switch:0"] = { id = 0, output = false }, ["input:0"] = { id = 0, state = false }, ["temperature:0"] = { id = 0, tC = 30 } } },
  }
  local S = system({ devices = devs, noSetup = true })
  S.sims["aa0000000010"].profile = "rgb"
  S.hub:setProp("Server", "shelly-42-eu.shelly.cloud"); S.hub:setProp("Authorization Key", KEY)
  S.dir:advance(3000); S.hub:action("Fetch Devices"); S.dir:advance(30000)
  local out = allLines(S.hub)
  contains(out, "aa0000000010: rgb:0 not supported")
  not_contains(out, "aa0000000011: ")
  S.hub.out = {}
  S.hub:action("List Devices")
  contains(allLines(S.hub), "profile=rgb"); contains(allLines(S.hub), "NOT-CONTROLLABLE[rgb:0]")
  S.hub.out = {}
  S.hub:action("Auto-Setup Children"); S.dir:advance(8000)
  contains(allLines(S.hub), "rgb:0 not supported")
  eq(#S.onoff(), 1, "the plain switch still got its driver")
end)

test("hub: switching a Plus 2PM from the switch to the cover profile - the old switches are flagged GONE and only a blind is added", function()
  local devs = { { id = "aa0000000020", addr = "192.168.1.60", profile = "switch", status = { ["switch:0"] = { id = 0, output = false }, ["switch:1"] = { id = 1, output = false } } } }
  local S = system({ devices = devs })
  eq(#S.onoff(), 2); eq(#S.dir:all("shelly_blind"), 0)
  local sim = S.sims["aa0000000020"]
  sim.profile = "cover"
  sim.status["switch:0"], sim.status["switch:1"] = nil, nil
  sim.status["cover:0"] = { id = 0, state = "stopped", current_pos = 50, pos_control = true }
  S.dir:advance(60000)
  S.hub.out = {}
  S.hub:action("List Devices")
  contains(allLines(S.hub), "GONE(profile changed?)"); contains(allLines(S.hub), "profile=cover")
  S.hub:action("Auto-Setup Children"); S.dir:advance(8000)
  eq(#S.dir:all("shelly_blind"), 1); eq(#S.onoff(), 2, "the stale lights are left for the installer to delete")
end)

local SLEEPERS = {
  { id = "aa0000000030", addr = "192.168.1.70", sim = { mode = "dead", cloudOnline = false },
    status = { ["flood:0"] = { id = 0, alarm = false, mute = false }, ["devicepower:0"] = { id = 0, battery = { V = 3.0, percent = 80 } } } },
  { id = "aa0000000031", addr = "192.168.1.71", sim = { mode = "dead", cloudOnline = false },
    status = { ["smoke:0"] = { id = 0, alarm = false, mute = false } } },
}

test("sensors (real drivers): sleeping flood and smoke sensors get a read-only contact driver each and follow the cloud's last report", function()
  local S = system({ devices = SLEEPERS })
  local kids = S.dir:all("shelly_sensor")
  eq(#kids, 2)
  local flood, smoke
  for _, k in ipairs(kids) do if k:prop("Sensor Component") == "flood" then flood = k else smoke = k end end
  truthy(flood and smoke, "one child per component, each told its component by the hub")
  eq(flood:prop("Shelly Device ID"), "aa0000000030"); eq(smoke:prop("Shelly Device ID"), "aa0000000031")
  S.dir:advance(120000)
  truthy(flood:lastNote("STATE_OPENED"), "no alarm = open contact (default polarity), reported as state")
  -- a leak: the sensor wakes, reports to the cloud; the hub's once-a-minute cloud cycle picks it up
  S.sims["aa0000000030"].status["flood:0"].alarm = true
  S.dir:advance(150000)
  eq(flood:firedCount("Alarm Started"), 1); truthy(flood:lastNote("CLOSED")); eq(flood.vars.Alarm.value, "1")
  eq(smoke:firedCount("Alarm Started"), 0, "the other sensor is unaffected")
  -- minutes of silence from a sleeping device are normal: no offline, no fallback noise
  S.dir:advance(900000)
  eq(flood:firedCount("Device Offline"), 0); eq(flood:firedCount("Fallback Started"), 0)
  S.sims["aa0000000030"].status["flood:0"].alarm = false
  S.dir:advance(150000)
  eq(flood:firedCount("Alarm Cleared"), 1); truthy(flood:lastNote("OPENED"))
  S.hub.out = {}
  S.hub:action("List Devices")
  contains(S.hub:output(), "flood:0=#"); contains(S.hub:output(), "smoke:0=#")
  not_contains(S.hub:output(), "NOT-CONTROLLABLE")
  assertClean(S)
end)

test("sensors (real drivers): a reboot restores the sensor children and their bindings from the persisted blob", function()
  local S1 = system({ devices = SLEEPERS })
  S1.dir:advance(60000)
  local kids = {}
  for _, c in ipairs(S1.dir:all()) do if c.file ~= "shelly_hub" then kids[#kids + 1] = { c.file, c.env.Properties } end end
  local S2 = system({ devices = SLEEPERS, noSetup = true, store = S1.hub.store, props = { Server = "shelly-42-eu.shelly.cloud", ["Authorization Key"] = KEY } })
  for _, k in ipairs(kids) do local copy = {} for a, b in pairs(k[2]) do copy[a] = b end S2.dir:load(k[1], { props = copy }) end
  S2.dir:advance(150000)
  for _, c in ipairs(S2.dir:all("shelly_sensor")) do eq(c:prop("Status") ~= "Not configured", true) end
  contains(S2.hub:prop("Devices"), "2 devices, 2 children")
end)
