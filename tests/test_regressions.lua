-- One test per defect class, named for the failure it locks down (see docs/ARCHITECTURE.md, "Testing").
-- Run before shipping "a small fix".
local H = require("tests.harness")
local Rig = require("tests.rig")
local Sc = require("tests.scenario")
local Director = require("tests.director")
local Sim = require("tests.lan_sim")
local F = require("tests.fakes")
local test, eq, truthy, falsy, contains, not_contains = H.test, H.eq, H.truthy, H.falsy, H.contains, H.not_contains
local system = Sc.system

local function send(rig, ckey, intent)
  local out
  rig.router:send(ckey, intent, function(o) out = o end)
  rig.rt.advance(8000)
  return out
end
local function count(list, method) local n = 0 for _, c in ipairs(list) do if c.method == method then n = n + 1 end end return n end

-- ================================================================================= routing and state
test("lan_first_when_up: zero cloud calls for LAN-up devices", function()
  local rig = Rig.new(); rig:addDevice("d", nil, { up = true })
  truthy(send(rig, "d|switch|0", { on = true }).ok); eq(#rig.cloudCalls, 0)
end)

test("ambiguous_lan_timeout_then_cloud_fallback_is_idempotent: a command that WAS applied but whose reply was lost is safe to repeat", function()
  local rig = Rig.new(); local sim = rig:addDevice("d", nil, { up = true })
  sim.dropReply = true
  local out = send(rig, "d|switch|0", { on = true })
  truthy(out.ok); eq(out.route, "Cloud")
  eq(sim.status["switch:0"].output, true)
  for _, c in ipairs(sim.calls) do if c.method == "Switch.Set" then eq(c.params.on, true, "every wire command was absolute") end end
end)

test("toggle_never_appears_on_either_wire: absolute commands only, on the LAN and through the cloud", function()
  local rig = Rig.new(); local sim = rig:addDevice("d", nil, { up = true })
  local intents = { { on = true }, { on = false }, { level = 40 }, { position = 60 }, { cover = "stop" }, { on = true, toggle_after = 2 } }
  local keys = { "d|switch|0", "d|switch|0", "d|light|0", "d|cover|0", "d|cover|0", "d|switch|0" }
  for pass = 1, 2 do
    sim.mode = pass == 1 and "http" or "dead"
    for i, it in ipairs(intents) do send(rig, keys[i], it) end
  end
  send(rig, "d|switch|0", { toggle = true })
  for _, r in ipairs(rig.rt.http.log) do
    local blob = (r.url or "") .. " " .. (r.body or "")
    local stripped = blob:gsub("toggle_after", "")
    not_contains(stripped:lower(), "toggle", "toggle on the wire: " .. blob)
  end
end)

test("device_rpc_error_is_never_failed_over", function()
  local rig = Rig.new(); local sim = rig:addDevice("d", nil, { up = true })
  sim.errorFor["Switch.Set"] = { code = -105, message = "x" }
  eq(send(rig, "d|switch|0", { on = true }).class, "DEVICE"); eq(#rig.cloudCalls, 0)
end)

test("fallback_logs_once_per_transition_not_per_command", function()
  local rig = Rig.new(); local sim = rig:addDevice("d", nil, { up = true })
  sim.mode = "dead"
  for i = 1, 5 do send(rig, "d|switch|0", { on = i % 2 == 0 }) end
  eq(#rig:eventsOf("route"), 1)
  sim.mode = "http"
  rig.lanPoll:start(); rig.rt.advance(400000)                       -- the feed re-probes and the device comes back Up
  for i = 1, 3 do send(rig, "d|switch|0", { on = i % 2 == 0 }) end
  local r = rig:eventsOf("route")
  eq(#r, 2); eq(r[2].b, "restored")
end)

test("stop_after_lan_timeout_reads_cover_state_before_failover", function()
  local rig = Rig.new(); local sim = rig:addDevice("d", nil, { up = true })
  sim.mode = "dead"; sim.status["cover:0"].state = "stopped"
  truthy(send(rig, "d|cover|0", { cover = "stop" }).ok)
  for _, c in ipairs(rig.cloudCalls) do falsy(c.op == "set") end
end)

-- ==================================================================================== LAN dispatch
test("on_off_on_off_flurry_last_value_wins with few wire commands", function()
  local rig = Rig.new(); local sim = rig:addDevice("d", nil, { up = true })
  for i = 1, 12 do rig.router:send("d|switch|0", { on = i % 2 == 1 }, function() end) end
  rig.rt.advance(8000)
  eq(sim.status["switch:0"].output, false)                         -- 12th command is on=false
  truthy(count(sim.calls, "Switch.Set") <= 3, "wire commands: " .. count(sim.calls, "Switch.Set"))
end)

test("ten_light_scene_runs_in_parallel_without_cloud_traffic", function()
  local rig = Rig.new()
  for i = 1, 10 do rig:addDevice("l" .. i, nil, { up = true }) end
  local done = 0
  local t0 = rig.rt.clock.now()
  for i = 1, 10 do rig.router:send("l" .. i .. "|light|0", { level = 50 }, function(o) if o.ok then done = done + 1 end end) end
  rig.rt.advance(1500)
  eq(done, 10); eq(#rig.cloudCalls, 0); truthy(rig.dispatch.maxRunning <= 3)
  for i = 1, 10 do eq(rig.sims["l" .. i].status["light:0"].brightness, 50) end
end)

test("healthy_device_latency_bounded_beside_black_holed_devices", function()
  local rig = Rig.new()
  for i = 1, 3 do rig:addDevice("bad" .. i, nil, { up = true }).mode = "blackhole" end
  rig:addDevice("good", nil, { up = true })
  for i = 1, 3 do rig.router:send("bad" .. i .. "|switch|0", { on = true }, function() end) end
  local t0, tdone = rig.rt.clock.now(), nil
  rig.router:send("good|switch|0", { on = true }, function(o) tdone = rig.rt.clock.now() end)
  rig.rt.advance(30000)
  truthy(tdone, "the healthy device was never served")
  truthy(tdone - t0 <= 20000, "healthy device waited " .. (tdone - t0) .. " ms")
end)

test("a_request_that_never_completes_does_not_stop_polling_that_device_for_good", function()
  local S = system({ devices = { { id = "aa0000000001", addr = "192.168.1.11", status = { ["switch:0"] = { id = 0, output = false } } } } })
  S.dir:advance(30000)
  local sim = S.sims.aa0000000001
  local function lanReqs() local n = 0; for _, r in ipairs(S.dir.rt.http.log) do if r.url:find("192.168.1.11", 1, true) then n = n + 1 end end; return n end
  sim.mode = "blackhole"                        -- the request is never answered (the dispatcher watchdog frees the lane)
  S.dir:advance(60000)
  sim.mode = "http"                             -- device recovers
  local before = lanReqs()
  S.dir:advance(600000)
  truthy(lanReqs() - before >= 20, "device was not polled again after recovering: " .. (lanReqs() - before) .. " requests in 10 min")
end)

-- =================================================================================== auth and lockout
test("wrong_password_is_tried_once_per_device / shared_wrong_password_costs_one_attempt_per_device", function()
  local rig = Rig.new({ devPass = "wrong" })
  for i = 1, 3 do rig:addDevice("d" .. i, { password = "right" }, { up = true }) end
  for round = 1, 4 do
    for i = 1, 3 do send(rig, "d" .. i .. "|switch|0", { on = round % 2 == 0 }) end
  end
  local rejected = 0
  for i = 1, 3 do rejected = rejected + rig.sims["d" .. i].rejected end
  eq(rejected, 3)
end)

test("auth_stop_survives_reload and no_credentials_sent_to_auth_stopped_device", function()
  local S1 = system()
  S1.dir:advance(30000)
  S1.sims["aa0000000001"].password = "right"
  S1.hub:setProp("Device Password", "wrong")
  S1.hub:action("Poll Now"); S1.dir:advance(120000)
  eq(S1.sims["aa0000000001"].rejected, 1)
  S1.dir:advance(60000)                                  -- lets the debounced persist happen
  local kids = {}
  for _, c in ipairs(S1.dir:all()) do if c.file ~= "shelly_hub" then kids[#kids + 1] = { c.file, c.env.Properties } end end
  local S2 = system({ noSetup = true, store = S1.hub.store, props = { ["Device Password"] = "wrong", Server = "shelly-42-eu.shelly.cloud", ["Authorization Key"] = Sc.KEY } })
  S2.sims["aa0000000001"].password = "right"
  S2.dir:advance(300000)
  eq(S2.sims["aa0000000001"].rejected, 0, "no credentialed attempt after reboot")
end)

test("challenge_401_is_not_a_failure: a device that needs auth and has the right password never counts a rejection", function()
  local rig = Rig.new({ devPass = "right" })
  local sim = rig:addDevice("d", { password = "right" }, { up = true })
  truthy(send(rig, "d|switch|0", { on = true }).ok)
  eq(sim.rejected, 0); eq(rig.ab:get("d").lan, "Up")
end)

-- =================================================================================== scheme and TLS
test("redirect_http_to_https_is_followed_once_and_remembered", function()
  local rig = Rig.new(); local sim = rig:addDevice("d", { mode = "redirect" }, {})
  rig.ab:get("d").lan = "Probing"
  truthy(send(rig, "d|switch|0", { on = true }).ok)
  local before = rig.rt.http.count("http://192.168")
  send(rig, "d|switch|0", { on = false }); send(rig, "d|switch|0", { on = true })
  eq(rig.rt.http.count("http://192.168"), before, "later commands go straight to https")
end)

test("scheme_change_after_firmware_update_is_redetected", function()
  local rig = Rig.new({ lanPollS = 10 }); local sim = rig:addDevice("d", nil, { up = true })
  rig.lanPoll:start(); rig.rt.advance(15000)
  truthy(rig.ab:get("d").scheme ~= "https")
  sim.mode = "https-only"
  rig.rt.advance(300000)
  eq(rig.ab:get("d").scheme, "https"); eq(rig.ab:get("d").lan, "Up")
end)

-- ============================================================================ identity and addressing
test("renumbered_site_heals_without_wrong_device_command", function()
  local rig = Rig.new({ lanPollS = 10 })
  local a = rig:addDevice("aa", nil, { up = true })
  local b = rig:addDevice("bb", nil, { up = true })
  rig.lanPoll:start(); rig.rt.advance(15000)
  -- swap addresses: A now lives where B was and vice versa; the cloud reports the new truth
  a.addr, b.addr = b.addr, a.addr
  a.cloudAddr, b.cloudAddr = a.addr, b.addr
  rig.rt.http.routes = rig.rt.http.routes                       -- (routes resolve by address at request time)
  local wrongB0, wrongA0 = count(b.calls, "Switch.Set"), count(a.calls, "Switch.Set")
  for i = 1, 6 do send(rig, "aa|switch|0", { on = i % 2 == 0 }); rig.rt.advance(20000) end
  eq(count(b.calls, "Switch.Set"), wrongB0, "B must never receive A's commands")
  eq(a.status["switch:0"].output, true, "the 6th command (on=true) reached A, wherever it now lives")
end)

-- ==================================================================================== cloud and clock
test("backwards_clock_does_not_wedge_gate_or_timers", function()
  local rig = Rig.new()
  local fired = false
  rig.rt.sched:after(10000, function() fired = true end)
  rig.rt.stepClock(-3600000)                                    -- NTP steps the wall clock back an hour
  rig.rt.advance(12000)
  truthy(fired, "scheduler item never fired after the clock stepped back")
  local rig2 = Rig.new(); rig2:addDevice("d", nil, { noAddress = true })
  send(rig2, "d|switch|0", { on = true })
  rig2.rt.stepClock(-3600000)
  local out = send(rig2, "d|switch|0", { on = false })
  truthy(out and out.ok, "cloud gate wedged after a backwards clock step")
end)

-- ===================================================================================== child conformance
test("reload_fires_no_proxy_or_driver_event and first_online_after_load_is_silent", function()
  local S1 = system(); S1.dir:advance(60000)
  local store, kids = S1.hub.store, {}
  for _, c in ipairs(S1.dir:all()) do if c.file ~= "shelly_hub" then kids[#kids + 1] = { c.file, c.env.Properties } end end
  local S2 = system({ noSetup = true, store = store, props = { Server = "shelly-42-eu.shelly.cloud", ["Authorization Key"] = Sc.KEY } })
  for _, k in ipairs(kids) do local copy = {} for a, b in pairs(k[2]) do copy[a] = b end S2.dir:load(k[1], { props = copy }) end
  S2.dir:advance(120000)
  for _, c in ipairs(S2.dir:all()) do
    local ev = {}
    for _, e in ipairs(c.fired) do if e ~= "Cloud Connected" then ev[#ev + 1] = e end end
    eq(ev, {}, c.file .. " fired events after a plain reload")
  end
end)

test("ten_identical_polls_send_no_notifications: 40 devices, nothing changing => children cost zero Director calls", function()
  local P = require("tests.profile")
  local S = P.big(40)
  for _, i in ipairs(S.dir:all()) do i:resetCounts() end
  S.dir:advance(600000)
  local kidCalls, kids = 0, 0
  for _, c in ipairs(S.dir:all()) do if c.file ~= "shelly_hub" then kidCalls = kidCalls + c.total; kids = kids + 1 end end
  truthy(kids >= 50, "expected ~53 children, got " .. kids)
  eq(kidCalls, 0)
  truthy(S.hub.total - (S.hub.calls.url or 0) <= 80, "hub non-network Director calls in 10 min: " .. (S.hub.total - (S.hub.calls.url or 0)))
  eq(S.hub.calls.SendToProxy or 0, 0); eq(S.hub.calls.PersistSetValue or 0, 0); eq(S.hub.calls.FireEvent or 0, 0)
  truthy(S.hub.timers <= 3)
end)

test("blind_driver_handles_toggle_is_false and light/blind capabilities are declared", function()
  local d = Director.new()
  local f = io.open("build/shelly_blind/driver.xml"); local xml = f:read("*a"); f:close()
  contains(xml, "<driver_handles_toggle>False</driver_handles_toggle>")
end)

-- ============================================================================================== setup
test("auto_setup_twice_creates_no_duplicates / renamed_child_is_not_duplicated_by_auto_setup", function()
  local S = system()
  local n = #S.dir:all()
  for _, c in ipairs(S.dir:all()) do c.name = "Kitchen renamed" end
  S.hub:action("Auto-Setup Children"); S.dir:advance(10000)
  S.hub:action("Fetch Devices"); S.dir:advance(5000)
  S.hub:action("Auto-Setup Children"); S.dir:advance(10000)
  eq(#S.dir:all(), n)
end)

test("child_registers_before_hub_is_ready_and_is_acked_later", function()
  local dir = Director.new({ latency = 10 })
  local child = dir:load("shelly_light", { props = { ["Hub Device ID"] = "101", ["Shelly Device ID"] = "aa0000000001", Channel = "0" } })
  dir:advance(35000)                                             -- no hub exists yet; the child must just keep trying
  eq(child:prop("Status"), "Registering with hub")
  local sims = dir.sims
  sims["aa0000000001"] = Sim.new(dir.rt, { addr = "192.168.1.41", mac = "AA0000000001", id = "shelly-aa0000000001",
    status = { sys = { mac = "AA0000000001" }, ["light:0"] = { id = 0, output = false, brightness = 50 } } })
  local cloud = require("tests.cloud_sim").install(dir.rt, sims)
  local hub = dir:load("shelly_hub", { props = { Server = "shelly-42-eu.shelly.cloud", ["Authorization Key"] = Sc.KEY } })
  hub:action("Fetch Devices")
  dir:advance(200000)
  eq(child:prop("Status"), "Connected")
end)

test("uncalibrated_cover_refuses_numeric_level (through the real drivers)", function()
  local devs = { { id = "aa0000000003", addr = "192.168.1.43", status = { ["cover:0"] = { id = 0, state = "stopped" } } } }
  local S = system({ devices = devs })
  S.dir:advance(30000)
  S.blind():proxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = 40 })
  contains(S.blind():prop("Last Command Result"), "not calibrated")
  eq(S.lanCalls("aa0000000003", "Cover.GoToPosition"), 0)
end)

-- ==================================================================================== robustness
test("no_secret_appears_in_any_log_at_debug: cloud key and every device password", function()
  local S = system({ noSetup = true })
  S.hub:setProp("Log Level", "Debug")
  S.hub:setProp("Device Password", "S3cretDevicePw!")
  S.hub:setProp("Server", "shelly-42-eu.shelly.cloud"); S.hub:setProp("Authorization Key", Sc.KEY)
  S.dir:advance(3000)
  S.sims["aa0000000001"].password = "S3cretDevicePw!"
  S.hub:action("Fetch Devices"); S.dir:advance(3000)
  S.hub:action("Auto-Setup Children"); S.dir:advance(20000)
  S.hub:action("Test LAN"); S.hub:action("List Devices"); S.hub:action("Show Recent Activity")
  S.light():proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30 }); S.dir:advance(60000)
  for _, inst in ipairs(S.dir:all()) do
    local out = inst:output()
    not_contains(out, Sc.KEY, inst.file .. " logged the cloud key")
    not_contains(out, "S3cretDevicePw!", inst.file .. " logged the device password")
    not_contains(inst:prop("Recent Activity") or "", Sc.KEY)
  end
  truthy(#S.hub.out > 10, "expected a busy Debug log")
end)

test("garbage_commands_never_crash_the_hub", function()
  local S = system()
  local h = S.hub.env
  local before = #S.dir.rt.errors
  h.ExecuteCommand("SHELLY_SET", {})
  h.ExecuteCommand("SHELLY_SET", { CHILD_ID = "abc", REQUEST_ID = "1", INTENT = "{oops" })
  h.ExecuteCommand("SHELLY_REGISTER", { CHILD_ID = "x" })
  h.ExecuteCommand("SHELLY_REGISTER", {})
  h.ExecuteCommand("SHELLY_UNREGISTER", {})
  h.ExecuteCommand("LUA_ACTION", { ACTION = "NoSuchAction" })
  h.ExecuteCommand("LUA_ACTION", {})
  h.ExecuteCommand("SOMETHING", nil)
  h.ExecuteCommand("SHELLY_SET", { CHILD_ID = tostring(S.light().id), REQUEST_ID = "9", INTENT = '{"level":"abc"}' })
  S.dir:advance(5000)
  eq(#S.dir.rt.errors, before)
end)

test("corrupt_persisted_blob_starts_clean_instead_of_crashing", function()
  for _, junk in ipairs({ "garbage", "shelly.v1|1|x", "\0\0\0", string.rep("A", 5000) }) do
    local dir = Director.new()
    local hub = dir:load("shelly_hub", { store = { ["shelly.hub.v1"] = junk } })
    dir:advance(1000)
    eq(hub:prop("Devices"), "0 devices, 0 children")
    eq(#dir.rt.errors, 0)
  end
end)

test("json_empty_table_is_an_object_not_an_array: GetStatus body is {}", function()
  local S = system()
  S.dir:advance(30000)
  local seen
  for _, r in ipairs(S.dir.rt.http.log) do if r.url:find("Shelly.GetStatus", 1, true) then seen = r.body end end
  eq(seen, "{}")
end)

test("bundles_define_only_the_entry_points_as_globals", function()
  local allowed = { OnDriverInit = 1, OnDriverLateInit = 1, OnDriverDestroyed = 1, OnPropertyChanged = 1, ExecuteCommand = 1, ReceivedFromProxy = 1, OnBindingChanged = 1,
    Properties = 1, print = 1, PersistSetValue = 1, PersistGetValue = 1, PersistDeleteValue = 1, C4 = 1, _G = 1 }
  local dir = Director.new()
  for _, f in ipairs({ "shelly_hub", "shelly_light", "shelly_light_onoff", "shelly_relay", "shelly_blind", "shelly_sensor", "shelly_contact" }) do
    local inst = dir:load(f)
    for k in pairs(inst.env) do truthy(allowed[k], f .. " leaked global '" .. tostring(k) .. "'") end
  end
end)

-- ================================================================================= Director-load budgets
test("hub_init_blocking_calls_within_budget (empty and restored 40-device state)", function()
  local dir = Director.new()
  local hub = dir:load("shelly_hub")
  truthy(hub.total <= 12, "empty hub init: " .. hub.total)
  local P = require("tests.profile")
  local S = P.big(40); S.dir:advance(60000)
  local store = S.hub.store
  local dir2 = Director.new()
  local hub2 = dir2:load("shelly_hub", { store = store })
  truthy(hub2.total <= 40, "restored 40-device init: " .. hub2.total .. " (" .. require("tests.profile").row("hub", hub2) .. ")")
end)

test("child_init_blocking_calls_within_budget", function()
  local dir = Director.new()
  for _, f in ipairs({ "shelly_light", "shelly_light_onoff", "shelly_relay", "shelly_blind" }) do
    local c = dir:load(f)
    truthy(c.total <= 10, f .. " init: " .. c.total)
  end
end)

test("one_command_costs_the_child_at_most_six_director_calls", function()
  local S = system()
  S.dir:advance(30000)
  local l = S.light(); l:resetCounts()
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 45 }); S.dir:advance(3000)
  truthy(l.total <= 6, "child calls for one command: " .. l.total)
end)

test("slider_drag_through_the_real_drivers: 20 values in 1 s => at most one wire command per 250 ms, final value wins", function()
  local S = system()
  S.dir:advance(30000)
  local l = S.light()
  for i = 1, 20 do l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = i * 5 }); S.dir:advance(50) end
  S.dir:advance(6000)
  eq(S.sims["aa0000000001"].status["light:0"].brightness, 100)
  truthy(S.lanCalls("aa0000000001", "Light.Set") <= 6, "wire commands: " .. S.lanCalls("aa0000000001", "Light.Set"))
end)

test("xml_and_lua_versions_agree", function()
  local ids = require("common.ids")
  for _, f in ipairs({ "shelly_hub", "shelly_light", "shelly_light_onoff", "shelly_relay", "shelly_blind" }) do
    local fh = io.open("build/" .. f .. "/driver.xml"); local xml = fh:read("*a"); fh:close()
    contains(xml, "<version>" .. ids.VERSION .. "</version>")
  end
end)

-- ============================================================================ pulses (garage door / gate triggers)
test("pulse_is_never_repeated_after_an_ambiguous_lan_failure: reply lost => ONE pulse on the wire, no retry, no cloud, failure reported", function()
  local rig = Rig.new(); local sim = rig:addDevice("d", nil, { up = true })
  sim.dropReply = true                                      -- the pulse is applied, the answer never arrives
  local out = send(rig, "d|switch|0", { on = true, toggle_after = 1 })
  falsy(out.ok); truthy(out.ambiguous); contains(out.reason, "NOT repeated")
  eq(count(sim.calls, "Switch.Set"), 1, "exactly one pulse reached the device")
  eq(#rig.cloudCalls, 0)
end)

test("pulse_falls_back_to_the_cloud_when_the_lan_proved_nothing_was_sent: connection refused => exactly one cloud pulse", function()
  local rig = Rig.new(); local sim = rig:addDevice("d", nil, { up = true })
  sim.mode = "refuse"
  local out = send(rig, "d|switch|0", { on = true, toggle_after = 1 })
  truthy(out.ok); eq(out.route, "Cloud")
  local pulses = 0
  for _, c in ipairs(rig.cloudCalls) do if c.op == "set" and c.body.toggle_after then pulses = pulses + 1 end end
  eq(pulses, 1)
end)

test("on_off_commands_still_retry_and_fall_back_after_an_ambiguous_failure (idempotent, so safe)", function()
  local rig = Rig.new(); local sim = rig:addDevice("d", nil, { up = true })
  sim.dropReply = true
  local out = send(rig, "d|switch|0", { on = true })
  truthy(out.ok); eq(out.route, "Cloud")
end)
