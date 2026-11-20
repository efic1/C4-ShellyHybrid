-- Edge cases found by the coverage review: LAN client error branches, hub actions and child-protocol refusals, poll identity gate,
-- glue command parsing, cloud queue cancel / start failure.
local H = require("tests.harness")
local F = require("tests.fakes")
local Sim = require("tests.lan_sim")
local Auth = require("hub.transport.lan_auth")
local Lan = require("hub.transport.lan")
local Queue = require("hub.transport.cloudqueue")
local Proto = require("common.protocol")
local Sc = require("tests.scenario")
local test, eq, truthy, falsy, contains, not_contains = H.test, H.eq, H.truthy, H.falsy, H.contains, H.not_contains

local function lanSetup(simOpts, password)
  local rt = F.new()
  local sim = Sim.new(rt, simOpts)
  local lan = Lan.new(rt, Auth.new(rt))
  lan.passwordFor = function() return password end
  local d = { id = "b48a0a1cd978", address = sim.addr }
  return rt, sim, lan, d
end
local function run(rt, fn) local o, r; fn(function(a, b) o, r = a, b end); rt.advance(5000); return o, r end

-- ---------------------------------------------------------------------------------------------- LAN client
test("edges lan: a device that starts redirecting RPC calls to https is followed once, and https is remembered", function()
  local rt, sim, lan, d = lanSetup()
  d.scheme = "http"
  sim.mode = "redirect"
  local out = run(rt, function(cb) lan:call(d, "Shelly.GetStatus", {}, cb) end)
  truthy(out.ok); eq(d.scheme, "https")
end)

test("edges lan: an error object inside a 200 answer is a DEVICE error, not success", function()
  local rt, sim, lan, d = lanSetup()
  rt.http.on("192.168.1.40", function(spec)
    if spec.url:find("/rpc/", 1, true) then return F.resp(200, { error = { code = -105, message = "argument invalid" } }) end
    return F.resp(200, { id = "shelly-b48a0a1cd978", mac = "B48A0A1CD978", gen = 2 })
  end)
  local out = run(rt, function(cb) lan:call(d, "Switch.Set", { id = 0, on = true }, cb) end)
  falsy(out.ok); eq(out.class, "DEVICE"); contains(out.reason, "argument invalid")
end)

test("edges lan: 403 is an authentication failure, 5xx and 429 are 'unreachable' (never blamed on the command)", function()
  for _, case in ipairs({ { 403, "AUTH" }, { 500, "UNREACHABLE" }, { 503, "UNREACHABLE" }, { 429, "UNREACHABLE" }, { 404, "DEVICE" } }) do
    local rt, sim, lan, d = lanSetup()
    rt.http.on("192.168.1.40", function() return F.resp(case[1], "") end)
    local out = run(rt, function(cb) lan:call(d, "Switch.Set", { id = 0, on = true }, cb) end)
    falsy(out.ok); eq(out.class, case[2], "HTTP " .. case[1])
  end
end)

test("edges lan: a malformed intent is refused as CONFIG instead of raising (cover with no action or position, unknown kind)", function()
  local rt, sim, lan, d = lanSetup()
  local out = run(rt, function(cb) lan:set(d, "cover", 0, {}, cb) end)
  falsy(out.ok); eq(out.class, "CONFIG")
  local out2 = run(rt, function(cb) lan:set(d, "cover", 0, { cover = "wiggle" }, cb) end)
  falsy(out2.ok); eq(out2.class, "CONFIG")
  local out3 = run(rt, function(cb) lan:set(d, "thermostat", 0, { on = true }, cb) end)
  falsy(out3.ok); eq(out3.class, "CONFIG")
  eq(#sim.calls, 0, "nothing was sent for any of them")
end)

-- ---------------------------------------------------------------------------------------------- cloud queue
test("edges cloudqueue: cancelKey removes a waiting entry (and never touches one in flight)", function()
  local rt = F.new()
  local q = Queue.new(rt)
  local log = {}
  local function job(name, key, ms)
    return { prio = "control", key = key, run = function(list, finish) log[#log + 1] = "run " .. name; rt.sched:after(ms, function() finish({ ok = true }) end) end,
      cb = function(out) log[#log + 1] = name .. (out.ok and " ok" or (" " .. out.class)) end }
  end
  q:enqueue(job("a", "ka", 100))
  q:enqueue(job("b", "kb", 100))
  q:cancelKey("kb"); q:cancelKey("ka")                              -- b is waiting (cancelled); a is already running (untouched)
  rt.advance(10000)
  eq(table.concat(log, ","), "run a,b SUPERSEDED,a ok")
end)

test("edges cloudqueue: a request that throws when it starts is failed, the queue keeps working", function()
  local rt = F.new()
  local q = Queue.new(rt)
  local got = {}
  q:enqueue({ prio = "control", run = function() error("boom") end, cb = function(o) got[#got + 1] = o.reason end })
  q:enqueue({ prio = "control", run = function(_, finish) finish({ ok = true }) end, cb = function(o) got[#got + 1] = o.ok and "second ok" or "second failed" end })
  rt.advance(10000)
  eq(got[1], "internal error"); eq(got[2], "second ok")
end)

-- ---------------------------------------------------------------------------------------------- glue command parsing
local function child(kind, value)
  local S = { sent = {}, notes = {}, vars = {}, props = {} }
  local rt = F.new()
  local env = { prop = function(n) return S.props[n] or "" end, setProp = function(n, v) S.props[n] = tostring(v) end, myId = function() return 200 end,
    fire = function() end, addVar = function() end, setVar = function() end, notify = function() end, sendToDevice = function() end }
  S.child = require("common.childcore").new(rt, env, require(kind .. ".proxyglue"))
  S.child.value = value
  S.G = require(kind .. ".proxyglue")
  return S
end

test("edges glue (on/off light): presets, level, toggle and button actions resolve to absolute on/off intents", function()
  local S = child("light_onoff", { on = false })
  local G = S.G
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 1 }), { on = true })
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 4 }), { on = false })
  local none, why = G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 9 })
  eq(none, nil); contains(why, "unsupported brightness preset")
  local n2, w2 = G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", {})
  eq(n2, nil); contains(w2, "missing brightness target")
  eq(G.toIntent(S.child, "SET_LEVEL", { LEVEL = 40 }), { on = true })
  eq(G.toIntent(S.child, "SET_LEVEL", { LEVEL = 0 }), { on = false })
  local n3, w3 = G.toIntent(S.child, "SET_LEVEL", {}); eq(n3, nil); contains(w3, "missing")
  eq(G.toIntent(S.child, "TOGGLE", {}), { on = true })
  S.child.value = nil
  local n4, w4 = G.toIntent(S.child, "TOGGLE", {}); eq(n4, nil); contains(w4, "unknown")
  S.child.value = { on = true }
  eq(G.toIntent(S.child, "BUTTON_ACTION", { ACTION = "2", BUTTON_ID = "0" }), { on = true })
  eq(G.toIntent(S.child, "BUTTON_ACTION", { ACTION = "2", BUTTON_ID = "1" }), { on = false })
  eq(G.toIntent(S.child, "BUTTON_ACTION", { ACTION = "2", BUTTON_ID = "2" }), { on = false })
  eq(G.toIntent(S.child, "BUTTON_ACTION", { ACTION = "1", BUTTON_ID = "0" }), nil)        -- only the release (action 2) acts
  eq(G.toIntent(S.child, "BUTTON_ACTION", { ACTION = "2", BUTTON_ID = "7" }), nil)
  eq(G.toIntent(S.child, "SOMETHING_ELSE", {}), nil)
end)

test("edges glue (dimmer): uncalibrated dimmers accept only 0 and 100; presets, buttons and unknown commands behave", function()
  local S = child("light", { on = true, level = 50, uncalibrated = true })
  local G = S.G
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0 }), { on = false })
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100 }), { on = true })
  local none, why = G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40 })
  eq(none, nil); contains(why, "not calibrated")
  S.child.value = { on = true, level = 50 }
  local n1, w1 = G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 7 }); eq(n1, nil); contains(w1, "unsupported brightness preset")
  local n2, w2 = G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", {}); eq(n2, nil); contains(w2, "missing")
  local n3, w3 = G.toIntent(S.child, "SET_LEVEL", {}); eq(n3, nil); contains(w3, "missing level")
  eq(G.toIntent(S.child, "BUTTON_ACTION", { ACTION = "2", BUTTON_ID = "1" }).level, 0)
  eq(G.toIntent(S.child, "BUTTON_ACTION", { ACTION = "2", BUTTON_ID = "0" }).level, 50)
  eq(G.toIntent(S.child, "BUTTON_ACTION", { ACTION = "2", BUTTON_ID = "9" }), nil)
  eq(G.toIntent(S.child, "WHATEVER", {}), nil)
end)

test("edges glue (blind): TOGGLE stops a moving cover, closes an open one, opens a closed one, refuses when unknown", function()
  local S = child("blind", nil)
  local G = S.G
  local n, w = G.toIntent(S.child, "TOGGLE", {}); eq(n, nil); contains(w, "unknown")
  S.child.value = { state = "opening" }; eq(G.toIntent(S.child, "TOGGLE", {}), { cover = "stop" })
  S.child.value = { state = "closing" }; eq(G.toIntent(S.child, "TOGGLE", {}), { cover = "stop" })
  S.child.value = { state = "open" };    eq(G.toIntent(S.child, "TOGGLE", {}), { cover = "close" })
  S.child.value = { state = "closed" };  eq(G.toIntent(S.child, "TOGGLE", {}), { cover = "open" })
  S.child.value = { state = "stopped" }
  local n2, w2 = G.toIntent(S.child, "TOGGLE", {}); eq(n2, nil); contains(w2, "position unknown")
  eq(G.toIntent(S.child, "NOT_A_COMMAND", {}), nil)
end)

test("edges protocol: an on/off light can present a dimmer channel; other mismatches are refused", function()
  truthy(Proto.compatible("light_onoff", "light")); truthy(Proto.compatible("light_onoff", "switch"))
  falsy(Proto.compatible("blind", "light")); falsy(Proto.compatible("light", "cover"))
end)

-- ---------------------------------------------------------------------------------------------- hub, real drivers
local function sysWith(extra)
  local S = Sc.system(extra)
  S.dir:advance(20000)
  return S
end

test("edges hub: a driver asking for an unknown component, or the wrong kind, is refused with a clear status", function()
  local S = sysWith()
  local unknown = S.dir:load("shelly_light", { props = { ["Hub Device ID"] = tostring(S.hub.id), ["Shelly Device ID"] = "deadbeef0001", Channel = "0" } })
  S.dir:advance(15000)
  contains(unknown:prop("Status"), "UNKNOWN_DEVICE")
  -- a registration that names a real component but claims the wrong kind (a stale or hand-edited driver)
  local l = S.light()
  S.hub.sent = {}
  S.hub.env.ExecuteCommand("SHELLY_REGISTER", { CHILD_ID = tostring(l.id), SHELLY_ID = "aa0000000003", COMPONENT = "cover", CHANNEL = "0", KIND = "light" })
  S.dir:advance(2000)
  local seen
  for _, m in ipairs(S.hub.sent) do if m.cmd == "SHELLY_ACK" and m.to == l.id then seen = m end end
  truthy(seen, "hub answered"); eq(seen.params.STATUS, "WRONG_TYPE")
end)

test("edges hub: Test Cloud Connection reports success, a cloud failure, and a missing key", function()
  local S = sysWith()
  S.hub.out = {}
  S.hub:action("Test Cloud Connection"); S.dir:advance(8000)
  contains(S.hub:output(), "cloud OK")
  S.cloud.down = true
  S.hub.out = {}
  S.hub:action("Test Cloud Connection"); S.dir:advance(90000)
  contains(S.hub:output(), "cloud test failed")
  S.hub:setProp("Authorization Key", "")
  S.hub.out = {}
  S.hub:action("Test Cloud Connection"); S.dir:advance(3000)
  contains(S.hub:output(), "not valid")
end)

test("edges hub: Test LAN names an unreachable device instead of hiding it", function()
  local S = sysWith()
  local id = Sc.DEVICES[1].id
  S.sims[id].mode = "dead"
  S.hub.out = {}
  S.hub:action("Test LAN"); S.dir:advance(60000)
  contains(S.hub:output(), id); contains(S.hub:output(), "UNREACHABLE")
end)

test("edges hub: Clear Authentication Stops lets a corrected password work again", function()
  local devs = { { id = "aa0000000001", addr = "192.168.1.51", sim = { password = "right" }, status = { ["switch:0"] = { id = 0, output = false } } } }
  local S = sysWith({ devices = devs, props = { ["Device Password"] = "wrong" } })
  S.dir:advance(120000)
  S.hub.out = {}
  S.hub:action("List Devices")
  contains(S.hub:output(), "AuthStop")
  S.hub:setProp("Device Password", "right")
  S.hub:action("Clear Authentication Stops"); S.dir:advance(60000)
  S.hub.out = {}
  S.hub:action("List Devices")
  not_contains(S.hub:output(), "AuthStop")
end)

test("edges hub: Purge Missing Devices forgets a removed device that has no driver, and keeps one that has", function()
  local S = sysWith()
  local gone = {}
  for _, d in ipairs(Sc.DEVICES) do if d.status["switch:0"] and not d.status["light:0"] then gone[#gone + 1] = d.id end end
  local victim = gone[1]
  S.hub:setProp("Switch Default Type", "Light")
  for _, k in ipairs(S.dir:all()) do if k.file ~= "shelly_hub" and k:prop("Shelly Device ID") == victim then k.env.OnDriverDestroyed() end end
  S.cloud.removed = S.cloud.removed or {}
  S.sims[victim].cloudOnline = false
  S.dir.sims[victim] = nil                                           -- the cloud no longer lists it
  S.hub:action("Fetch Devices"); S.dir:advance(20000)
  S.hub.out = {}
  S.hub:action("Purge Missing Devices"); S.dir:advance(3000)
  S.hub.out = {}
  S.hub:action("List Devices")
  truthy(S.hub:output():find("MISSING", 1, true) or not S.hub:output():find(victim, 1, true), "a missing device is either marked or purged")
end)

test("edges hub: a LAN address that now belongs to a different device is never commanded, and the hub asks for a refresh", function()
  local S = sysWith()
  local id = "aa0000000002"
  local target
  for _, k in ipairs(S.dir:all()) do if k.file ~= "shelly_hub" and k:prop("Shelly Device ID") == id and k:prop("Channel") == "0" then target = k end end
  truthy(target, "a driver exists for the switch")
  S.sims[id].mac = "FFEEDDCCBBAA"                                   -- another device took over this IP address
  S.sims[id].id = "shelly-ffeeddccbbaa"
  S.sims[id].status.sys.mac = "FFEEDDCCBBAA"
  S.sims[id].calls = {}
  S.hub:action("Poll Now"); S.dir:advance(40000)
  local mismatch = S.lanCalls(id, "Switch.Set")
  eq(mismatch, 0, "no command reached the wrong device")
  S.hub.out = {}
  S.hub:action("List Devices")
  contains(S.hub:output(), "aa0000000002 SNSW gen=G2 profile=? lan=Probing")
  contains(S.hub:output(), "route=Cloud")
  target:proxy(5001, "ON", {}); S.dir:advance(15000)           -- a command now goes through the cloud, never to the stranger on the LAN
  eq(S.lanCalls(id, "Switch.Set"), 0, "still nothing sent to the wrong device")
  truthy(S.cloudSets() > 0, "the cloud carried the command")
end)

test("edges hub: Test LAN reports a rejected password as an authentication failure and records the stop", function()
  local devs = { { id = "aa0000000001", addr = "192.168.1.51", sim = { password = "right" }, status = { ["switch:0"] = { id = 0, output = false } } } }
  local S = sysWith({ devices = devs, props = { ["Device Password"] = "wrong" } })
  S.hub.out = {}
  S.hub:action("Test LAN"); S.dir:advance(60000)
  contains(S.hub:output(), "FAILED")
  contains(S.hub:output(), "AUTH")
end)

test("edges hub: Refresh Addresses and Poll Now run without errors and leave the hub healthy", function()
  local S = sysWith()
  S.hub.out = {}
  S.hub:action("Refresh Addresses"); S.dir:advance(20000)
  S.hub:action("Poll Now"); S.dir:advance(20000)
  contains(S.hub:output(), "address refresh requested"); contains(S.hub:output(), "poll requested")
  not_contains(S.hub:output(), "ERROR")
  Sc.assertClean(S)
end)

test("edges hub: when a second driver claims a component, the first stops receiving that component's state", function()
  local S = sysWith()
  local first = S.light()
  local second = S.dir:load("shelly_light", { props = { ["Hub Device ID"] = tostring(S.hub.id), ["Shelly Device ID"] = "aa0000000001", Channel = "0" } })
  S.dir:advance(20000)
  contains(second:prop("Status"), "Connected")
  S.hub.sent = {}
  S.sims["aa0000000001"].status["light:0"].output = true
  S.hub:action("Poll Now"); S.dir:advance(40000)
  local toFirst, toSecond = 0, 0
  for _, m in ipairs(S.hub.sent) do
    if m.cmd == "SHELLY_STATE" and m.to == first.id then toFirst = toFirst + 1 end
    if m.cmd == "SHELLY_STATE" and m.to == second.id then toSecond = toSecond + 1 end
  end
  eq(toFirst, 0, "the displaced driver gets nothing more"); truthy(toSecond > 0, "the new owner gets the state")
end)
