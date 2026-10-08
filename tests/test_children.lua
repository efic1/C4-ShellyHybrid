local H = require("tests.harness")
local F = require("tests.fakes")
local Child = require("common.childcore")
local Proto = require("common.protocol")
local test, eq, truthy, falsy, contains = H.test, H.eq, H.truthy, H.falsy, H.contains
local M = Proto.M

-- A child wired to a recording env (no Director involved).
local function new(kind, props)
  local rt = F.new()
  local S = { rt = rt, sent = {}, notes = {}, fired = {}, vars = {}, props = props or {} }
  local env = {
    prop = function(n) return S.props[n] or "" end,
    setProp = function(n, v) S.props[n] = tostring(v) end,
    myId = function() return 200 end,
    fire = function(n) S.fired[#S.fired + 1] = n end,
    addVar = function(n, v) S.vars[n] = v end,
    setVar = function(n, v) S.vars[n] = v end,
    notify = function(b, n, p) S.notes[#S.notes + 1] = { b = b, name = n, p = p } end,
    sendToDevice = function(id, cmd, p) S.sent[#S.sent + 1] = { id = id, cmd = cmd, p = p } end,
  }
  S.child = Child.new(rt, env, require(kind .. ".proxyglue"))
  function S.count(list, key, val) local n = 0 for _, x in ipairs(list) do if (key and x[key] or x) == val then n = n + 1 end end return n end
  function S.state(online, route, value) S.child:executeCommand(M.HUB_STATE, { ONLINE = Proto.triState(online), ROUTE = route or "", VALUE = value and rt.json.encode(value) or "" }) end
  function S.ack(status) S.child:executeCommand(M.HUB_ACK, { STATUS = status or "OK" }) end
  function S.registers() return S.count(S.sent, "cmd", M.CHILD_REGISTER) end
  return S
end

local CFG = { ["Hub Device ID"] = "100", ["Shelly Device ID"] = "aa0000000001", Channel = "0" }
local function configured(kind) local S = new(kind, { ["Hub Device ID"] = "100", ["Shelly Device ID"] = "aa0000000001", Channel = "0" }); S.child:init(); return S end

test("child: unconfigured child sends nothing and says it is waiting for the hub", function()
  local S = new("light"); S.child:init(); S.rt.advance(120000)
  eq(#S.sent, 0); contains(S.props.Status, "Not configured")
end)

test("child: registers at init, retries 10/20/40/60/60 s until acknowledged, then stops", function()
  local S = configured("light")
  eq(S.registers(), 1)
  S.rt.advance(10500); eq(S.registers(), 2)
  S.rt.advance(20500); eq(S.registers(), 3)
  S.rt.advance(40500); eq(S.registers(), 4)
  S.rt.advance(60500); eq(S.registers(), 5)
  S.rt.advance(60500); eq(S.registers(), 6)
  S.ack("OK")
  S.rt.advance(300000); eq(S.registers(), 6)
  eq(S.props.Status, "Registered (waiting for state)")
end)

test("child: an UNKNOWN_DEVICE refusal is shown and registration keeps retrying until the hub learns the device", function()
  local S = configured("light")
  S.ack("UNKNOWN_DEVICE")
  contains(S.props.Status, "UNKNOWN_DEVICE")
  S.rt.advance(11000); truthy(S.registers() >= 2)
  S.ack("OK"); eq(S.props.Status, "Registered (waiting for state)")
end)

test("child: CONFIG from the hub fills the properties and registers exactly once; a repeat is ignored", function()
  local S = new("light"); S.child:init()
  S.child:executeCommand(M.HUB_CONFIG, { HUB_ID = "100", SHELLY_ID = "AA0000000001", CHANNEL = "2", COMPONENT = "light" })
  eq(S.props["Hub Device ID"], "100"); eq(S.props["Shelly Device ID"], "aa0000000001"); eq(S.props.Channel, "2")
  eq(S.registers(), 1)
  S.ack("OK")
  S.child:executeCommand(M.HUB_CONFIG, { HUB_ID = "100", SHELLY_ID = "AA0000000001", CHANNEL = "2" })
  eq(S.registers(), 1)
end)

test("child: unchanged hub state sends nothing to the proxy (Director call de-duplication)", function()
  local S = configured("light"); S.ack("OK")
  S.state(true, "LAN", { on = true, level = 60 })
  eq(#S.notes, 2, "ONLINE_CHANGED + LIGHT_BRIGHTNESS_CHANGED (default feedback mode; the guide says dimmers use only this)")
  for _ = 1, 10 do S.state(true, "LAN", { on = true, level = 60 }) end
  eq(#S.notes, 2)
  S.state(true, "Cloud", { on = true, level = 60 })
  eq(#S.notes, 2, "a route change with the same value sends no proxy notification")
end)

test("child: the first online report after load is silent (no Device Online event)", function()
  local S = configured("light"); S.ack("OK")
  S.state(true, "LAN", { on = false })
  eq(#S.fired, 0)
end)

test("child: unknown light state never publishes brightness 0; an offline device reports ONLINE_CHANGED false, not level 0", function()
  local S = configured("light"); S.ack("OK")
  S.state(nil, "", nil)
  eq(S.count(S.notes, "name", "LIGHT_BRIGHTNESS_CHANGED"), 0)
  S.state(false, "", nil); S.rt.advance(61000)
  eq(S.count(S.notes, "name", "LIGHT_BRIGHTNESS_CHANGED"), 0)
  local off = S.notes[#S.notes]
  eq(off.name, "ONLINE_CHANGED"); eq(off.p.STATE, false)
end)

test("child: offline is debounced 60 s - a blip raises nothing; a real outage raises Device Offline once, recovery Device Online once", function()
  local S = configured("light"); S.ack("OK"); S.state(true, "LAN", { on = false })
  S.state(false); S.rt.advance(30000); S.state(true, "LAN", { on = false })
  S.rt.advance(120000)
  eq(#S.fired, 0)
  S.state(false); S.rt.advance(61000); S.state(false); S.rt.advance(120000)
  eq(S.count(S.fired, nil, "Device Offline"), 1)
  eq(S.vars["Device Online"], "0")
  S.state(true, "LAN", { on = false }); S.state(true, "LAN", { on = false })
  eq(S.count(S.fired, nil, "Device Online"), 1)
end)

test("child: route events - cloud-first start is not a fallback; LAN->Cloud->LAN fires each event exactly once", function()
  local S = configured("light"); S.ack("OK")
  S.state(true, "Cloud", { on = false }); S.state(true, "LAN", { on = false })
  eq(#S.fired, 0)
  S.state(true, "Cloud", { on = false }); S.state(true, "Cloud", { on = false })
  eq(S.count(S.fired, nil, "Fallback Started"), 1)
  S.state(true, "LAN", { on = false }); S.state(true, "LAN", { on = false })
  eq(S.count(S.fired, nil, "LAN Restored"), 1)
end)

test("child: a command is always followed by a confirmation or a failure - a silent hub times out at 20 s and the proxy snaps back", function()
  local S = configured("light"); S.ack("OK"); S.state(true, "LAN", { on = true, level = 40 })
  S.child:fromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 90 })
  eq(S.count(S.sent, "cmd", M.CHILD_SET), 1)
  S.rt.advance(19000); eq(S.count(S.fired, nil, "Command Failed"), 0)
  S.rt.advance(2000)
  eq(S.count(S.fired, nil, "Command Failed"), 1)
  contains(S.props["Last Command Result"], "TIMEOUT")
  local last
  for _, n in ipairs(S.notes) do if n.name == "LIGHT_BRIGHTNESS_CHANGED" then last = n end end
  eq(last.p.LIGHT_BRIGHTNESS_CURRENT, 40)
end)

test("child: hub RESULT ok shows the new value at once; failure snaps back and fires Command Failed; SUPERSEDED changes nothing", function()
  local S = configured("light"); S.ack("OK"); S.state(true, "LAN", { on = true, level = 40 })
  local function bright() local v; for _, n in ipairs(S.notes) do if n.name == "LIGHT_BRIGHTNESS_CHANGED" then v = n.p.LIGHT_BRIGHTNESS_CURRENT end end return v end
  local function cmd(level)
    S.child:fromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = level })
    return S.sent[#S.sent].p.REQUEST_ID
  end
  local id = cmd(70)
  S.child:executeCommand(M.HUB_RESULT, { REQUEST_ID = id, OK = "1", ROUTE = "LAN" })
  eq(bright(), 70)
  id = cmd(20)
  S.child:executeCommand(M.HUB_RESULT, { REQUEST_ID = id, OK = "0", CLASS = "UNREACHABLE", REASON = "no route" })
  eq(bright(), 40, "snapped back to the hub-confirmed 40")
  eq(S.count(S.fired, nil, "Command Failed"), 1)
  local n = #S.notes
  id = cmd(10)
  S.child:executeCommand(M.HUB_RESULT, { REQUEST_ID = id, OK = "0", CLASS = "SUPERSEDED" })
  eq(#S.notes, n); eq(S.count(S.fired, nil, "Command Failed"), 1)
end)

test("child: an AUTH failure also fires Authentication Failed", function()
  local S = configured("light"); S.ack("OK"); S.state(true, "LAN", { on = true, level = 40 })
  S.child:fromProxy(5001, "OFF")
  S.child:executeCommand(M.HUB_RESULT, { REQUEST_ID = S.sent[#S.sent].p.REQUEST_ID, OK = "0", CLASS = "AUTH", REASON = "rejected" })
  eq(S.count(S.fired, nil, "Authentication Failed"), 1)
end)

test("child: at most 20 requests are pending; the oldest is failed rather than growing without bound", function()
  local S = configured("light"); S.ack("OK"); S.state(true, "LAN", { on = true, level = 40 })
  for i = 1, 30 do S.rt.advance(10); S.child:fromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = i }) end
  truthy(S.child.pendingN <= 20)
end)

test("child: commands before the hub has acknowledged are refused (never silently dropped)", function()
  local S = configured("light")
  S.child:fromProxy(5001, "OFF")
  eq(S.count(S.sent, "cmd", M.CHILD_SET), 0)
  contains(S.props["Last Command Result"], "not connected")
  eq(S.count(S.fired, nil, "Command Failed"), 1)
end)

test("child: changing Hub Device ID unregisters from the old hub and registers with the new one; destroy unregisters", function()
  local S = configured("light"); S.ack("OK")
  S.props["Hub Device ID"] = "101"; S.child:propertyChanged("Hub Device ID")
  local un = S.sent[#S.sent - 1]
  eq(un.cmd, M.CHILD_UNREGISTER); eq(un.id, 100)
  eq(S.sent[#S.sent].id, 101); eq(S.sent[#S.sent].cmd, M.CHILD_REGISTER)
  S.ack("OK"); S.child:destroy()
  eq(S.sent[#S.sent].cmd, M.CHILD_UNREGISTER); eq(S.sent[#S.sent].id, 101)
end)

test("child: garbage from the hub is ignored without error", function()
  local S = configured("light")
  S.child:executeCommand(M.HUB_STATE, { VALUE = "{not json", ONLINE = "x" })
  S.child:executeCommand(M.HUB_RESULT, { REQUEST_ID = "nope" })
  S.child:executeCommand("WHATEVER", {})
  S.child:executeCommand(M.HUB_CONFIG, {})
  truthy(true)
end)

-- ---- glue behaviour -----------------------------------------------------------------------------------
test("light glue: level is rounded and clamped; ON restores the last level; TOGGLE resolves from known state", function()
  local S = configured("light"); S.ack("OK"); S.state(true, "LAN", { on = true, level = 55 })
  local G = require("light.proxyglue")
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "140.6" }), { level = 100 })
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = -5 }), { level = 0 })
  eq(G.toIntent(S.child, "TOGGLE", {}), { level = 0 })
  S.state(true, "LAN", { on = false, level = 55 })
  eq(G.toIntent(S.child, "TOGGLE", {}), { level = 55 })
  local _, why = G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", {})
  contains(why, "missing")
end)

test("blind glue: an uncalibrated cover uses the guide's no-feedback scheme (open 0, closed 2, unknown 1)", function()
  local S = configured("blind"); S.ack("OK")
  S.state(true, "LAN", { state = "stopped", calibrated = false })
  local G = require("blind.proxyglue")
  eq(G.toIntent(S.child, "SET_LEVEL_TARGET", { LEVEL_TARGET = 0 }), { cover = "open" })
  eq(G.toIntent(S.child, "SET_LEVEL_TARGET", { LEVEL_TARGET = 2 }), { cover = "close" })
  local _, why = G.toIntent(S.child, "SET_LEVEL_TARGET", { LEVEL_TARGET = 40 })
  contains(why, "not calibrated")
  local has
  for _, n in ipairs(S.notes) do if n.name == "SET_HAS_LEVEL" then has = n end end
  eq(S.count(S.notes, "name", "SET_HAS_LEVEL"), 1)
  eq(has.p, { HAS_LEVEL = false, LEVEL_OPEN = 0, LEVEL_CLOSED = 2, LEVEL_DISCRETE_CONTROL = false })
  local stopped
  for _, n in ipairs(S.notes) do if n.name == "STOPPED" then stopped = n end end
  eq(stopped.p.LEVEL, 1, "unknown position is level 1 - never a fake 0 or 2")
  S.state(true, "LAN", { state = "closed", calibrated = false })
  eq(S.notes[#S.notes].p.LEVEL, 2, "a closed no-feedback cover reports the closed level")
end)

test("blind glue: MOVING is sent ONCE per movement with LEVEL_TARGET, RAMP_RATE and the START level; STOPPED ends it", function()
  local S = configured("blind"); S.ack("OK")
  S.state(true, "LAN", { state = "stopped", position = 20, calibrated = true })
  S.state(true, "LAN", { state = "opening", position = 35, calibrated = true })
  S.state(true, "LAN", { state = "opening", position = 60, calibrated = true })
  S.state(true, "LAN", { state = "opening", position = 80, calibrated = true })
  local names = {}
  for _, n in ipairs(S.notes) do names[#names + 1] = n.name end
  eq(names, { "ONLINE_CHANGED", "SET_HAS_LEVEL", "STOPPED", "MOVING" }, "progress reports send nothing")
  local mv = S.notes[4].p
  eq(mv.LEVEL_TARGET, 100); eq(mv.LEVEL, 20, "where it started, not where it is now"); eq(mv.RAMP_RATE, 16000, "20 s full travel * 80% of the range")
  S.state(true, "LAN", { state = "stopped", position = 82, calibrated = true })
  eq(S.notes[#S.notes].name, "STOPPED"); eq(S.notes[#S.notes].p.LEVEL, 82)
end)

test("blind glue: a mid-move reversal sends a new MOVING that starts from where the blind is NOW; a target position is honoured", function()
  local S = configured("blind"); S.ack("OK")
  S.state(true, "LAN", { state = "stopped", position = 0, calibrated = true })
  S.state(true, "LAN", { state = "opening", position = 10, calibrated = true, target = 70 })
  S.state(true, "LAN", { state = "closing", position = 40, calibrated = true, target = 0 })
  local mv = {}
  for _, n in ipairs(S.notes) do if n.name == "MOVING" then mv[#mv + 1] = n.p end end
  eq(#mv, 2)
  eq(mv[1].LEVEL_TARGET, 70); eq(mv[1].LEVEL, 0)
  eq(mv[2].LEVEL_TARGET, 0);  eq(mv[2].LEVEL, 40, "interrupted: the start level is the current position")
  eq(mv[2].RAMP_RATE, 8000)
end)

test("blind glue: the travel time property scales RAMP_RATE", function()
  local S = configured("blind"); S.props["Full Travel Time (s)"] = "60"; S.ack("OK")
  S.state(true, "LAN", { state = "stopped", position = 0, calibrated = true })
  S.state(true, "LAN", { state = "opening", position = 0, calibrated = true })
  for _, n in ipairs(S.notes) do if n.name == "MOVING" then eq(n.p.RAMP_RATE, 60000) end end
end)

test("relay glue: first value uses STATE_ notifications, a later change fires the relay event exactly once", function()
  local S = configured("relay"); S.ack("OK")
  S.state(true, "LAN", { on = false })
  eq(S.count(S.notes, "name", "STATE_OPENED"), 1); eq(#S.fired, 0)
  S.state(true, "LAN", { on = true }); S.state(true, "LAN", { on = true })
  eq(S.count(S.notes, "name", "CLOSED"), 1); eq(S.count(S.fired, nil, "Relay Closed"), 1)
  eq(S.vars["Relay State"], "Closed")
end)

test("relay glue: TRIGGER becomes a device-side auto-off pulse using the configured length; TOGGLE with unknown state is refused", function()
  local S = configured("relay"); S.props["Trigger Pulse (ms)"] = "2500"; S.ack("OK")
  local G = require("relay.proxyglue")
  eq(G.toIntent(S.child, "TRIGGER", {}), { on = true, toggle_after = 2.5 })
  local _, why = G.toIntent(S.child, "TOGGLE", {})
  contains(why, "unknown")
end)

test("light glue: an uncalibrated dimmer accepts only on/off (the device would answer -109), and says why", function()
  local S = configured("light"); S.ack("OK"); S.state(true, "LAN", { on = true, level = 100, uncalibrated = true })
  local G = require("light.proxyglue")
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100 }), { on = true })
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0 }), { on = false })
  local _, why = G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 40 })
  contains(why, "not calibrated")
end)

test("blind glue: a CALIBRATED cover that lost its position accepts open/close/stop and explains a numeric level", function()
  local S = configured("blind"); S.ack("OK"); S.state(true, "LAN", { state = "stopped", calibrated = true })
  local G = require("blind.proxyglue")
  eq(G.toIntent(S.child, "SET_LEVEL_TARGET", { LEVEL_TARGET = 0 }), { cover = "open" })
  eq(G.toIntent(S.child, "SET_LEVEL_TARGET", { LEVEL_TARGET = 2 }), { cover = "close" })
  local _, why = G.toIntent(S.child, "SET_LEVEL_TARGET", { LEVEL_TARGET = 40 })
  contains(why, "position is unknown")
end)

test("child: proxy state is replayed twice shortly after first registration (an AddDevice-created device may have no listening proxy yet), then never again", function()
  local S = configured("blind"); S.ack("OK"); S.state(true, "LAN", { state = "stopped", position = 40, calibrated = true })
  local function count(name) local n = 0 for _, x in ipairs(S.notes) do if x.name == name then n = n + 1 end end return n end
  local stopped0, online0 = count("STOPPED"), count("ONLINE_CHANGED")
  eq(count("SET_CAN_STOP"), 0, "lateInit has not run in this harness")
  S.rt.advance(4500)
  eq(count("STOPPED"), stopped0 + 1, "first replay"); eq(count("ONLINE_CHANGED"), online0 + 1); eq(count("SET_CAN_STOP"), 1, "replay re-sends the configuration too")
  S.rt.advance(9000)
  eq(count("STOPPED"), stopped0 + 2, "second replay")
  S.rt.advance(600000)
  eq(count("STOPPED"), stopped0 + 2, "nothing more, ever")
  eq(#S.fired, 0, "a replay never raises driver events")
end)

test("child: a relay replay re-sends STATE_ notifications but never fires Relay Closed/Opened", function()
  local S = configured("relay"); S.ack("OK"); S.state(true, "LAN", { on = true })
  S.rt.advance(30000)
  eq(S.count(S.fired, nil, "Relay Closed"), 0)
  truthy(S.count(S.notes, "name", "STATE_CLOSED") >= 2)
end)

test("protocol: an action is identified by its name, its command, or either normalised (Composer/authors disagree which arrives)", function()
  local Proto = require("common.protocol")
  local list = require("common.ids").actions.hub
  for _, raw in ipairs({ "Test Cloud Connection", "TestCloud", "TEST_CLOUD_CONNECTION", "test cloud connection" }) do
    eq(Proto.resolveAction(list, raw), "TestCloud", raw)
  end
  eq(Proto.resolveAction(list, "Nope"), nil); eq(Proto.resolveAction(list, nil), nil)
end)

test("relay glue: STATE_ only on the first report, the transition only on a change, nothing when unchanged (contact semantics)", function()
  local S = configured("relay"); S.ack("OK")
  local function names() local o = {} for _, n in ipairs(S.notes) do o[#o + 1] = n.name end return o end
  S.state(true, "LAN", { on = false })
  local first = {}
  for _, n in ipairs(names()) do if n ~= "ONLINE_CHANGED" then first[#first + 1] = n end end
  eq(first, { "STATE_OPENED" }, "first report announces state, not a transition")
  S.state(true, "LAN", { on = false }); S.state(true, "LAN", { on = false })
  eq(S.count(S.notes, "name", "OPENED"), 0)
  S.state(true, "LAN", { on = true })
  eq(S.count(S.notes, "name", "CLOSED"), 1); eq(S.count(S.notes, "name", "STATE_CLOSED"), 0, "a change is a transition only")
  S.state(true, "LAN", { on = true })
  eq(S.count(S.notes, "name", "CLOSED"), 1)
end)

test("child: ResendState republishes state as a STATE_ report without raising events", function()
  local S = configured("relay"); S.ack("OK"); S.state(true, "LAN", { on = true })
  local before = S.count(S.notes, "name", "STATE_CLOSED")
  S.child:executeCommand("ResendState", {})
  eq(S.count(S.notes, "name", "STATE_CLOSED"), before + 1); eq(S.count(S.fired, nil, "Relay Closed"), 0)
end)

test("child: a consumer bound AFTER publication is told the current state once (debounced), unbinding does nothing", function()
  local S = configured("relay"); S.ack("OK"); S.state(true, "LAN", { on = true })
  S.rt.advance(60000)
  local before = S.count(S.notes, "name", "STATE_CLOSED")
  S.child:bindingChanged(1, false); S.rt.advance(5000)
  eq(S.count(S.notes, "name", "STATE_CLOSED"), before, "unbinding is silent")
  S.child:bindingChanged(1, true); S.child:bindingChanged(1, true); S.rt.advance(1500)
  eq(S.count(S.notes, "name", "STATE_CLOSED"), before + 1, "one republish for two rapid bindings")
end)

test("light glue: feedback mode selects LIGHT_BRIGHTNESS_CHANGED, the official sample's LIGHT_LEVEL <number>, or both", function()
  local function run(mode)
    local S = configured("light"); S.props["Feedback Notification"] = mode; S.ack("OK"); S.state(true, "LAN", { on = true, level = 60 })
    return S
  end
  local both = run("Both")
  eq(both.count(both.notes, "name", "LIGHT_BRIGHTNESS_CHANGED"), 1); eq(both.count(both.notes, "name", "LIGHT_LEVEL"), 1)
  local one = run("Brightness Changed")
  eq(one.count(one.notes, "name", "LIGHT_BRIGHTNESS_CHANGED"), 1); eq(one.count(one.notes, "name", "LIGHT_LEVEL"), 0)
  local legacy = run("Light Level")
  eq(legacy.count(legacy.notes, "name", "LIGHT_BRIGHTNESS_CHANGED"), 0)
  local n
  for _, x in ipairs(legacy.notes) do if x.name == "LIGHT_LEVEL" then n = x end end
  eq(n.p, 60, "the sample passes the bare level as the parameter")
end)

test("light glue: legacy SET_LEVEL / RAMP_TO_LEVEL {LEVEL} and BUTTON_ACTION (act on release only; 0 on, 1 off, 2 toggle)", function()
  local S = configured("light"); S.ack("OK"); S.state(true, "LAN", { on = true, level = 55 })
  local G = require("light.proxyglue")
  eq(G.toIntent(S.child, "SET_LEVEL", { LEVEL = "30" }), { level = 30 })
  eq(G.toIntent(S.child, "RAMP_TO_LEVEL", { LEVEL = 80, TIME = 500 }), { level = 80, rate = 500 })
  eq(G.toIntent(S.child, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" }), nil, "press is ignored")
  eq(G.toIntent(S.child, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "2" }), { level = 55 }, "on = last level")
  eq(G.toIntent(S.child, "BUTTON_ACTION", { BUTTON_ID = "1", ACTION = "2" }), { level = 0 })
  eq(G.toIntent(S.child, "BUTTON_ACTION", { BUTTON_ID = "2", ACTION = "2" }), { level = 0 }, "toggle from on")
  S.state(true, "LAN", { on = false, level = 55 })
  eq(G.toIntent(S.child, "BUTTON_ACTION", { BUTTON_ID = "2", ACTION = "2" }), { level = 55 }, "toggle from off")
  local fresh = configured("light")
  local _, why = require("light.proxyglue").toIntent(fresh.child, "BUTTON_ACTION", { BUTTON_ID = "2", ACTION = "2" })
  contains(why, "unknown")
  local oo = configured("light_onoff"); oo.ack("OK"); oo.state(true, "LAN", { on = false })
  local G2 = require("light_onoff.proxyglue")
  eq(G2.toIntent(oo.child, "SET_LEVEL", { LEVEL = 40 }), { on = true }); eq(G2.toIntent(oo.child, "BUTTON_ACTION", { BUTTON_ID = "2", ACTION = "2" }), { on = true })
end)

test("child: GET_CONNECTED_STATE (asked by the light proxy at init) is answered with ONLINE_CHANGED when known, silently ignored when not", function()
  local S = configured("light"); S.ack("OK")
  S.child:fromProxy(5001, "GET_CONNECTED_STATE", {})
  eq(S.count(S.notes, "name", "ONLINE_CHANGED"), 0, "unknown: say nothing")
  S.state(true, "LAN", { on = false })
  local before = S.count(S.notes, "name", "ONLINE_CHANGED")
  S.child:fromProxy(5001, "GET_CONNECTED_STATE", {})
  eq(S.count(S.notes, "name", "ONLINE_CHANGED"), before + 1)
  eq(S.notes[#S.notes].p.STATE, true)
end)

test("child: GET_LIGHT_LEVEL and SYNCHRONIZE (sent by the light proxy, undocumented) republish the level once, debounced", function()
  local S = configured("light"); S.ack("OK"); S.state(true, "LAN", { on = true, level = 70 })
  S.rt.advance(60000)
  local function levels() return S.count(S.notes, "name", "LIGHT_BRIGHTNESS_CHANGED") end
  local before = levels()
  for _ = 1, 5 do S.child:fromProxy(5001, "GET_LIGHT_LEVEL", {}) end
  S.child:fromProxy(5001, "SYNCHRONIZE", {})
  eq(levels(), before, "nothing until the debounce elapses")
  S.rt.advance(1500)
  eq(levels(), before + 1, "one republish for six requests")
  eq(S.count(S.fired, nil, "Command Failed"), 0, "not treated as an unhandled command")
end)

test("child: scene and toggle-button commands the light proxy may send are ignored quietly, never refused as failures", function()
  local S = configured("light"); S.ack("OK"); S.state(true, "LAN", { on = true, level = 70 })
  for _, c in ipairs({ "PUSH_SCENE", "ACTIVATE_SCENE", "CLEAR_ALL_SCENES", "RAMP_SCENE_UP", "STOP_RAMP_SCENE", "PUSH_TOGGLE_BUTTON", "RELEASE_TOGGLE_BUTTON", "TOGGLE_PRESET", "DO_PUSH" }) do
    S.child:fromProxy(5001, c, {})
  end
  eq(S.count(S.fired, nil, "Command Failed"), 0); eq(S.count(S.sent, "cmd", "SHELLY_SET"), 0)
end)

test("light glue: a scene activation arrives as individual SET_BRIGHTNESS_TARGET commands; alternate parameter spellings are tolerated", function()
  local S = configured("light"); S.ack("OK"); S.state(true, "LAN", { on = false, level = 50 })
  local G = require("light.proxyglue")
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "35", RATE = "0" }), { level = 35 })
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { PERCENT = 20 }), { level = 20 })
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LEVEL = 90 }), { level = 90 })
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0 }), { level = 0 }, "scene 'off' member")
  local _, why = G.toIntent(S.child, "SET_COLOR_TARGET", { })
  eq(why, nil, "colour targets are ignored quietly (no colour support)")
end)

test("light glue: the DOCUMENTED SET_BRIGHTNESS_TARGET parameters - _PERCENT, _LEVEL, _PRESET_ID (1 On, 2 Off, 3 Slow On, 4 Slow Off)", function()
  local S = configured("light"); S.ack("OK"); S.state(true, "LAN", { on = false, level = 45 })
  local G = require("light.proxyglue")
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PERCENT = "65", RATE = "-1" }), { level = 65 })
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_LEVEL = 12.4, RATE = 500 }), { level = 12, rate = 500 })
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = "1" }), { level = 45 }, "On preset = the last level")
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 3 }), { level = 45 }, "Slow On")
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 2 }), { level = 0 }, "Off preset")
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 4 }), { level = 0 }, "Slow Off")
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PERCENT = 30, LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 1 }), { level = 30 }, "an explicit level wins")
  local _, why = G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 7 })
  contains(why, "unsupported brightness preset 7")
  local _, why2 = G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { RATE = 0 })
  contains(why2, "missing")
end)

test("onoff light glue: documented parameters and presets reduce to on/off", function()
  local S = configured("light_onoff"); S.ack("OK"); S.state(true, "LAN", { on = false })
  local G = require("light_onoff.proxyglue")
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PERCENT = 1 }), { on = true })
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PERCENT = 0 }), { on = false })
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 1 }), { on = true })
  eq(G.toIntent(S.child, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 2 }), { on = false })
end)

test("light glue: the default feedback is LIGHT_BRIGHTNESS_CHANGED {LIGHT_BRIGHTNESS_CURRENT} only (per the guide); the legacy notify is opt-in", function()
  local S = configured("light"); S.ack("OK"); S.state(true, "LAN", { on = true, level = 40 })
  local n
  for _, x in ipairs(S.notes) do if x.name == "LIGHT_BRIGHTNESS_CHANGED" then n = x end end
  eq(n.p.LIGHT_BRIGHTNESS_CURRENT, 40); eq(S.count(S.notes, "name", "LIGHT_LEVEL"), 0)
end)

test("blind glue: sends SET_CAN_STOP {CAN_STOP = true} but never SET_TYPE or SET_MOVEMENT (each would lock the dealer's pull-down)", function()
  local S = configured("blind"); S.ack("OK"); S.child:lateInit()
  for _, v in ipairs({ { state = "stopped", position = 20, calibrated = true }, { state = "opening", position = 40, calibrated = true, target = 100 },
                       { state = "stopped", position = 90, calibrated = true }, { state = "stopped", calibrated = false }, { state = "closed", calibrated = false } }) do
    S.state(true, "LAN", v)
  end
  S.rt.advance(60000)
  for _, name in ipairs({ "SET_TYPE", "SET_MOVEMENT" }) do eq(S.count(S.notes, "name", name), 0, name) end
  local n = 0
  for _, x in ipairs(S.notes) do if x.name == "SET_CAN_STOP" then n = n + 1; eq(x.p, { CAN_STOP = true }) end end
  truthy(n >= 1)
end)

test("blind glue: UP / DOWN / STOP / OPEN / CLOSE work in level mode AND in the no-position mode (where the proxy sends UP/DOWN instead of a level)", function()
  local lvl = configured("blind"); lvl.ack("OK"); lvl.state(true, "LAN", { state = "stopped", position = 40, calibrated = true })
  local none = configured("blind"); none.ack("OK"); none.state(true, "LAN", { state = "stopped", calibrated = false })
  local G = require("blind.proxyglue")
  for _, S in ipairs({ lvl, none }) do
    eq(G.toIntent(S.child, "UP", {}), { cover = "open" }); eq(G.toIntent(S.child, "DOWN", {}), { cover = "close" })
    eq(G.toIntent(S.child, "STOP", {}), { cover = "stop" })
    eq(G.toIntent(S.child, "OPEN", {}), { cover = "open" }); eq(G.toIntent(S.child, "CLOSE", {}), { cover = "close" })
  end
end)

test("light glue: load-group level commands behave like SET_LEVEL / RAMP_TO_LEVEL", function()
  local S = configured("light"); S.ack("OK"); S.state(true, "LAN", { on = true, level = 50 })
  local G = require("light.proxyglue")
  eq(G.toIntent(S.child, "GROUP_SET_LEVEL", { LEVEL = 25 }), { level = 25 })
  eq(G.toIntent(S.child, "GROUP_RAMP_TO_LEVEL", { LEVEL = 75, TIME = 3000 }), { level = 75, rate = 3000 })
  local oo = configured("light_onoff"); oo.ack("OK"); oo.state(true, "LAN", { on = false })
  eq(require("light_onoff.proxyglue").toIntent(oo.child, "GROUP_SET_LEVEL", { LEVEL = 100 }), { on = true })
end)

-- ---- alarm sensor (flood / smoke) ---------------------------------------------------------------------------
local function sensor(extra)
  local props = { ["Hub Device ID"] = "100", ["Shelly Device ID"] = "aa0000000030", Channel = "0", ["Sensor Component"] = "flood" }
  for k, v in pairs(extra or {}) do props[k] = v end
  local S = new("sensor", props); S.child:init(); S.ack("OK")
  return S
end

test("sensor: registers for the component chosen in its property (flood or smoke); with none chosen it stays unconfigured", function()
  local f = sensor()
  eq(f.sent[1].p.COMPONENT, "flood"); eq(f.sent[1].p.KIND, "sensor")
  local s = sensor({ ["Sensor Component"] = "smoke" })
  eq(s.sent[1].p.COMPONENT, "smoke")
  local none = new("sensor", { ["Hub Device ID"] = "100", ["Shelly Device ID"] = "aa0000000030", ["Sensor Component"] = "" }); none.child:init()
  eq(#none.sent, 0); contains(none.props.Status, "Not configured")
end)

test("sensor: CONFIG from the hub chooses the component and registers", function()
  local S = new("sensor", {}); S.child:init()
  S.child:executeCommand(M.HUB_CONFIG, { HUB_ID = "100", SHELLY_ID = "aa0000000031", CHANNEL = "0", COMPONENT = "smoke" })
  eq(S.props["Sensor Component"], "smoke"); eq(S.sent[#S.sent].p.COMPONENT, "smoke")
end)

test("sensor: contact semantics - STATE_ on the first report, the transition only on a change, events only on changes (alarm closes the contact by default)", function()
  local S = sensor()
  S.state(true, "Cloud", { alarm = false, mute = false })
  eq(S.count(S.notes, "name", "STATE_OPENED"), 1); eq(S.count(S.notes, "name", "OPENED"), 0); eq(#S.fired, 0)
  S.state(true, "Cloud", { alarm = false, mute = false }); S.state(true, "Cloud", { alarm = false, mute = false })
  eq(S.count(S.notes, "name", "STATE_OPENED"), 1)
  S.state(true, "Cloud", { alarm = true, mute = false })
  eq(S.count(S.notes, "name", "CLOSED"), 1); eq(S.count(S.notes, "name", "STATE_CLOSED"), 0)
  eq(S.count(S.fired, nil, "Alarm Started"), 1); eq(S.vars.Alarm, "1")
  S.state(true, "Cloud", { alarm = true, mute = false })
  eq(S.count(S.notes, "name", "CLOSED"), 1)
  S.state(true, "Cloud", { alarm = false, mute = false })
  eq(S.count(S.notes, "name", "OPENED"), 1); eq(S.count(S.fired, nil, "Alarm Cleared"), 1); eq(S.vars.Alarm, "0")
end)

test("sensor: 'Alarm Contact State = Open' inverts the contact; flipping the property republishes the state without raising an event", function()
  local S = sensor({ ["Alarm Contact State"] = "Open" })
  S.state(true, "Cloud", { alarm = true, mute = false })
  eq(S.count(S.notes, "name", "STATE_OPENED"), 1)                   -- alarm = open contact
  S.props["Alarm Contact State"] = "Closed"; S.child:propertyChanged("Alarm Contact State")
  eq(S.count(S.notes, "name", "STATE_CLOSED"), 1); eq(#S.fired, 0)
end)

test("sensor: an alarm already active at load reports STATE_ (so a security zone sees it) but raises no Alarm Started event", function()
  local S = sensor()
  S.state(true, "Cloud", { alarm = true, mute = false })
  eq(S.count(S.notes, "name", "STATE_CLOSED"), 1); eq(S.count(S.fired, nil, "Alarm Started"), 0)
end)

test("sensor: mute state is reported in a variable; the driver is read-only and accepts no commands", function()
  local S = sensor()
  S.state(true, "Cloud", { alarm = false, mute = true })
  eq(S.vars.Muted, "1")
  S.child:fromProxy(1, "CLOSE", {}); S.child:fromProxy(1, "OPEN", {}); S.child:fromProxy(1, "TRIGGER", {}); S.child:fromProxy(1, "TOGGLE", {})
  eq(S.count(S.sent, "cmd", M.CHILD_SET), 0); eq(S.count(S.fired, nil, "Command Failed"), 0)
end)

test("sensor: a sleeping battery device is NOT 'offline' after 60 s - Device Offline waits 25 hours, and route changes raise no fallback events", function()
  local S = sensor()
  S.state(true, "LAN", { alarm = false, mute = false })
  S.state(false, "", nil)
  S.rt.advance(3 * 3600 * 1000)
  eq(S.count(S.fired, nil, "Device Offline"), 0)
  S.state(true, "Cloud", { alarm = false }); S.state(true, "LAN", { alarm = false }); S.state(true, "Cloud", { alarm = false })
  eq(S.count(S.fired, nil, "Fallback Started"), 0); eq(S.count(S.fired, nil, "LAN Restored"), 0)
  eq(S.props.Route, "Cloud")
  S.state(false, "", nil); S.rt.advance(26 * 3600 * 1000)
  eq(S.count(S.fired, nil, "Device Offline"), 1, "a sensor silent for over a day IS reported")
end)

test("sensor: an UNKNOWN alarm (omitted) leaves the contact untouched, still updates the state variables, and a replay re-publishes the last KNOWN alarm", function()
  local S = sensor()
  S.state(true, "LAN", { alarm = true, level = "mild", state = "normal" })
  eq(S.count(S.notes, "name", "STATE_CLOSED"), 1)
  local notes = #S.notes
  S.state(true, "LAN", { level = "unknown", state = "fault" })           -- alarm omitted: the detector cannot say
  eq(#S.notes, notes, "no contact notification"); eq(S.count(S.fired, nil, "Alarm Cleared"), 0)
  eq(S.vars["Sensor State"], "fault"); eq(S.vars["Alarm Level"], "unknown"); eq(S.vars.Alarm, "1", "the last known alarm is still shown")
  S.rt.advance(5000)                                                      -- the start-up replay
  truthy(S.count(S.notes, "name", "STATE_CLOSED") >= 2, "replay re-publishes the last known alarm, not nothing")
end)

test("sensor: a faulted Gen1 flood/smoke reading (alarm unknown) still updates the battery level", function()
  local S = sensor()
  S.state(true, "Cloud", { alarm = false, mute = false, battery = 80 })
  S.state(true, "Cloud", { mute = false, battery = 79 })                 -- alarm omitted
  eq(S.vars["Battery Level"], "79"); eq(S.count(S.fired, nil, "Alarm Started"), 0)
end)
