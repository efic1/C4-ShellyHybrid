-- Contact sensors: a device's input terminal (reed / limit switch, e.g. a garage door) and the Gen1 Door/Window 1/2.
local H = require("tests.harness")
local F = require("tests.fakes")
local Child = require("common.childcore")
local Proto = require("common.protocol")
local Parse = require("hub.transport.parse")
local Sc = require("tests.scenario")
local test, eq, truthy, falsy, contains, not_contains = H.test, H.eq, H.truthy, H.falsy, H.contains, H.not_contains
local system, assertClean, KEY = Sc.system, Sc.assertClean, Sc.KEY
local M = Proto.M

-- ------------------------------------------------------------------------------------------------ parsing
-- The real Shelly Door/Window status (from the Gen1 documentation page and a published device dump).
local DOC_DW = { is_valid = true, mac = "AABBCCDDEEFF", lux = { value = 474, illumination = "bright", is_valid = true },
  accel = { tilt = 30, vibration = 0 }, sensor = { state = "close", is_valid = true }, bat = { value = 96, voltage = 5.82 }, act_reasons = { "button" } }

test("contact parse (Gen2): a switch-type input is an OPTIONAL contact; a stateless button input and analog/count inputs are nothing", function()
  local c = Parse.components({ ["input:0"] = { id = 0, state = true }, ["input:1"] = { id = 1, state = false },
    ["input:2"] = { id = 2 }, ["input:3"] = { id = 3, percent = 40 }, ["switch:0"] = { id = 0, output = false } })
  local contacts = {}
  for _, x in ipairs(c) do if x.kind == "contact" then contacts[#contacts + 1] = x end end
  eq(#contacts, 2)
  eq(contacts[1], { kind = "contact", channel = 0, closed = true, optional = true })
  eq(contacts[2], { kind = "contact", channel = 1, closed = false, optional = true })
end)

test("contact parse (Gen1): Shelly 1 inputs[] are optional contacts; other relay models' inputs are not touched", function()
  local one = Parse.device({ id = "a", gen = "G1", code = "SHSW-1" }, { relays = { { ison = false } }, inputs = { { input = 1, event = "", event_cnt = 0 } } })
  local contact
  for _, x in ipairs(one.components) do if x.kind == "contact" then contact = x end end
  eq(contact, { kind = "contact", channel = 0, closed = true, optional = true })
  local other = Parse.device({ id = "b", gen = "G1", code = "SHSW-25" }, { relays = { { ison = false } }, inputs = { { input = 1 } } })
  eq(#other.components, 0)
end)

test("contact parse (Gen1 Door/Window): the documented status gives a NON-optional contact with battery; open/close/invalid map correctly", function()
  local d = Parse.device({ id = "d", gen = "G1", code = "SHDW-2" }, DOC_DW)
  eq(#d.components, 1); eq(d.components[1], { kind = "contact", channel = 0, closed = true, battery = 96 }); eq(d.supported, true)
  local open = Parse.device({ id = "d", gen = "G1", code = "SHDW-1" }, { is_valid = true, sensor = { state = "open", is_valid = true }, bat = { value = 80 } })
  eq(open.components[1].closed, false)
  for _, bad in ipairs({ { is_valid = false, sensor = { state = "open" } }, { is_valid = true, sensor = { state = "open", is_valid = false } }, { is_valid = true, sensor = {} } }) do
    bad.bat = { value = 70 }
    local x = Parse.device({ id = "d", gen = "G1", code = "SHDW-2" }, bad)
    eq(x.components[1].closed, nil, "an invalid read concludes nothing"); eq(x.components[1].battery, 70)
  end
end)

test("contact registry: value, unknown, and persistence letter", function()
  local Registry = require("hub.registry")
  local reg = Registry.new(F.new(), {})
  reg:upsert({ id = "d", components = { { kind = "contact", channel = 0, closed = false, optional = true } } })
  reg:applyRead("d", { components = { { kind = "contact", channel = 0, closed = true } } }, "lan")
  eq(reg:value("d|contact|0"), { closed = true })
  reg:applyRead("d", { components = { { kind = "contact", channel = 0 } } }, "lan")
  eq(reg:value("d|contact|0"), { closed = true }, "an unknown read leaves the last known value")
  truthy(reg:component("d|contact|0").optional)
  local reg2 = Registry.new(F.new(), {}); reg2:import(reg:export())
  eq(reg2:component("d|contact|0").kind, "contact")
end)

-- ------------------------------------------------------------------------------------------- child glue
local function new(props)
  local rt = F.new()
  local S = { rt = rt, sent = {}, notes = {}, fired = {}, vars = {}, props = props or {} }
  local env = {
    prop = function(n) return S.props[n] or "" end, setProp = function(n, v) S.props[n] = tostring(v) end, myId = function() return 300 end,
    fire = function(n) S.fired[#S.fired + 1] = n end, addVar = function(n, v) S.vars[n] = v end, setVar = function(n, v) S.vars[n] = v end,
    notify = function(b, n, p) S.notes[#S.notes + 1] = { b = b, name = n, p = p } end, sendToDevice = function(id, cmd, p) S.sent[#S.sent + 1] = { id = id, cmd = cmd, p = p } end,
  }
  S.child = Child.new(rt, env, require("contact.proxyglue"))
  function S.count(list, key, val) local n = 0 for _, x in ipairs(list) do if (key and x[key] or x) == val then n = n + 1 end end return n end
  function S.state(online, route, value) S.child:executeCommand(M.HUB_STATE, { ONLINE = Proto.triState(online), ROUTE = route or "", VALUE = value and rt.json.encode(value) or "" }) end
  return S
end
local function contact(extra)
  local props = { ["Hub Device ID"] = "100", ["Shelly Device ID"] = "aa0000000040", Channel = "0" }
  for k, v in pairs(extra or {}) do props[k] = v end
  local S = new(props); S.child:init(); S.child:executeCommand(M.HUB_ACK, { STATUS = "OK" })
  return S
end

test("contact glue: STATE_ on the first report, the transition only on a change; Contact Opened / Closed events on changes only", function()
  local S = contact()
  S.state(true, "LAN", { closed = true })
  eq(S.count(S.notes, "name", "STATE_CLOSED"), 1); eq(#S.fired, 0); eq(S.vars["Contact State"], "Closed")
  S.state(true, "LAN", { closed = true }); S.state(true, "LAN", { closed = true })
  eq(S.count(S.notes, "name", "STATE_CLOSED"), 1); eq(S.count(S.notes, "name", "CLOSED"), 0)
  S.state(true, "LAN", { closed = false })
  eq(S.count(S.notes, "name", "OPENED"), 1); eq(S.count(S.fired, nil, "Contact Opened"), 1); eq(S.vars["Contact State"], "Open")
  S.state(true, "LAN", { closed = true })
  eq(S.count(S.notes, "name", "CLOSED"), 1); eq(S.count(S.fired, nil, "Contact Closed"), 1)
end)

test("contact glue: 'Invert Contact = Yes' flips the Control4 side only; changing it republishes the state without an event", function()
  local S = contact({ ["Invert Contact"] = "Yes" })
  S.state(true, "LAN", { closed = true })
  eq(S.count(S.notes, "name", "STATE_OPENED"), 1)
  S.props["Invert Contact"] = "No"; S.child:propertyChanged("Invert Contact")
  eq(S.count(S.notes, "name", "STATE_CLOSED"), 1); eq(#S.fired, 0)
end)

test("contact glue: an unknown reading (self-check fault) leaves the contact as it was; the battery is still reported; replay re-publishes the last known state", function()
  local S = contact()
  S.state(true, "Cloud", { closed = false, battery = 90 })
  local n = #S.notes
  S.state(true, "Cloud", { battery = 89 })                          -- closed omitted
  eq(#S.notes, n, "no contact notification"); eq(S.vars["Battery Level"], "89"); eq(#S.fired, 0)
  S.rt.advance(5000)
  truthy(S.count(S.notes, "name", "STATE_OPENED") >= 2, "replay publishes the last KNOWN state")
end)

test("contact glue: a battery Door/Window waits 25 hours before Device Offline; a mains-powered input waits 60 seconds", function()
  local dw = contact()
  dw.state(true, "Cloud", { closed = true, battery = 96 }); dw.state(false, "", nil); dw.rt.advance(3600 * 1000)
  eq(dw.count(dw.fired, nil, "Device Offline"), 0)
  dw.rt.advance(25 * 3600 * 1000); eq(dw.count(dw.fired, nil, "Device Offline"), 1)
  local input = contact()
  input.state(true, "LAN", { closed = true }); input.state(false, "", nil); input.rt.advance(70000)
  eq(input.count(input.fired, nil, "Device Offline"), 1)
end)

test("contact glue: read-only - proxy commands are ignored and nothing is sent to the hub", function()
  local S = contact()
  S.child:fromProxy(1, "CLOSE", {}); S.child:fromProxy(1, "OPEN", {}); S.child:fromProxy(1, "TRIGGER", {})
  eq(S.count(S.sent, "cmd", M.CHILD_SET), 0); eq(S.count(S.fired, nil, "Command Failed"), 0)
end)

-- ------------------------------------------------------------------------------- real drivers, whole system
local GARAGE = {
  { id = "aa0000000040", addr = "192.168.1.100", status = { ["switch:0"] = { id = 0, output = false }, ["input:0"] = { id = 0, state = false } } },
}
local function garageSystem(props, devices)
  local p = { ["Switch Default Type"] = "Relay" }
  for k, v in pairs(props or {}) do p[k] = v end
  return system({ devices = devices or GARAGE, noSetup = false, props = p })
end

test("contact (real drivers): an input is NOT given a driver by default - wall switches would flood the project - and List Devices says how to opt in", function()
  local S = garageSystem()
  eq(#S.dir:all("shelly_contact"), 0); eq(#S.relays(), 1)
  S.hub.out = {}
  S.hub:action("List Devices")
  contains(S.hub:output(), "contact:0=optional(see Contact Inputs)")
end)

test("contact (real drivers): listing the device in 'Contact Inputs' creates the contact driver (by id, by suffix, per channel)", function()
  for _, entry in ipairs({ "aa0000000040", "0040", "0040:0", " junk; 0040:0 ,xx", "AA0000000040", "00 40;0040" }) do
    local S = garageSystem({ ["Contact Inputs"] = entry })
    eq(#S.dir:all("shelly_contact"), 1, "entry: " .. entry)
    eq(S.dir:all("shelly_contact")[1]:prop("Status") ~= "Not configured", true)
  end
  local wrongChannel = garageSystem({ ["Contact Inputs"] = "0040:1" })
  eq(#wrongChannel.dir:all("shelly_contact"), 0, "a different channel is not selected")
  local tooShort = garageSystem({ ["Contact Inputs"] = "40" })
  eq(#tooShort.dir:all("shelly_contact"), 0, "suffixes shorter than 4 characters are ignored")
end)

test("contact (real drivers): a garage door - the pulse, then the door opening is seen within seconds (follow-up reads), not at the next 20 s poll", function()
  local S = garageSystem({ ["Contact Inputs"] = "0040" })
  S.dir:advance(60000)
  local relay, door = S.relays()[1], S.dir:all("shelly_contact")[1]
  local sim = S.sims["aa0000000040"]
  truthy(door:lastNote("STATE_OPENED"), "door reported open-circuit (closed contact = door closed, state false) as STATE_ at start")
  door:resetCounts()
  local t0 = S.dir.rt.clock.now()
  relay:proxy(1, "TRIGGER"); S.dir:advance(1500)
  eq(S.lanCalls("aa0000000040", "Switch.Set"), 1, "exactly one pulse")
  S.dir.rt.setTimer(3000, function() sim.status["input:0"].state = true end)          -- the door starts moving 3 s after the pulse
  local seenAt
  for _ = 1, 40 do
    S.dir:advance(500)
    if not seenAt and door:lastNote("CLOSED") then seenAt = S.dir.rt.clock.now() - t0 end
  end
  truthy(seenAt, "the change was never reported")
  truthy(seenAt <= 12000, "door change seen after " .. tostring(seenAt) .. " ms")
  eq(door:firedCount("Contact Closed"), 1)
  assertClean(S)
end)

test("contact (real drivers): follow-up reads happen only after a pulse AND only when a contact driver is bound - bounded to ten reads", function()
  local plain = system({ devices = GARAGE, props = { ["Switch Default Type"] = "Relay" } })      -- no contact driver
  plain.dir:advance(60000)
  local reads0 = plain.lanCalls("aa0000000040", "Shelly.GetStatus")
  plain.relays()[1]:proxy(1, "TRIGGER"); plain.dir:advance(70000)
  local plainReads = plain.lanCalls("aa0000000040", "Shelly.GetStatus") - reads0
  local watched = garageSystem({ ["Contact Inputs"] = "0040" })
  watched.dir:advance(60000)
  local reads1 = watched.lanCalls("aa0000000040", "Shelly.GetStatus")
  watched.relays()[1]:proxy(1, "TRIGGER"); watched.dir:advance(70000)
  local watchedReads = watched.lanCalls("aa0000000040", "Shelly.GetStatus") - reads1
  truthy(watchedReads - plainReads >= 8 and watchedReads - plainReads <= 12, "extra reads: " .. (watchedReads - plainReads))
end)

test("contact (real drivers): an AMBIGUOUS pulse failure starts no follow-up and is never repeated", function()
  local S = garageSystem({ ["Contact Inputs"] = "0040" })
  S.dir:advance(60000)
  local sim = S.sims["aa0000000040"]
  sim.dropReply = true
  local relay = S.relays()[1]
  relay:proxy(1, "TRIGGER"); S.dir:advance(8000)
  eq(S.lanCalls("aa0000000040", "Switch.Set"), 1, "one pulse only")
  eq(relay:firedCount("Command Failed"), 1); contains(relay:prop("Last Command Result"), "NOT repeated")
end)

test("contact (real drivers): a Gen1 Shelly 1 as a garage door - relay pulse with timer=, input as the contact, same follow-up", function()
  local devs = { { id = "bb0000000040", addr = "192.168.1.101", gen1 = "SHSW-1",
    status = { relays = { { ison = false } }, inputs = { { input = 0, event = "", event_cnt = 0 } } } } }
  local S = garageSystem({ ["Contact Inputs"] = "0040" }, devs)
  S.dir:advance(60000)
  local relay, door = S.relays()[1], S.dir:all("shelly_contact")[1]
  truthy(relay and door, "both drivers were created")
  local sim = S.sims["bb0000000040"]
  relay:proxy(1, "TRIGGER"); S.dir:advance(1500)
  eq(sim.calls[#sim.calls].path, "/relay/0?turn=on&timer=1")
  S.dir.rt.setTimer(2000, function() sim.status.inputs[1].input = 1 end)
  S.dir:advance(12000)
  truthy(door:lastNote("CLOSED")); eq(door:firedCount("Contact Closed"), 1)
  eq(S.cloudSets(), 0)
  assertClean(S)
end)

local DW = { { id = "bb0000000050", addr = "192.168.1.110", gen1 = "SHDW-2", sim = { mode = "dead", cloudOnline = false },
  status = { is_valid = true, sensor = { state = "close", is_valid = true }, bat = { value = 96, voltage = 5.82 }, accel = { tilt = 30, vibration = 0 },
    lux = { value = 474, illumination = "bright", is_valid = true }, act_reasons = { "periodic" } } } }

test("contact (real drivers): a sleeping Gen1 Door/Window gets a contact driver automatically and follows the cloud's last report, with battery", function()
  local S = system({ devices = DW })
  eq(#S.dir:all("shelly_contact"), 1, "a dedicated sensor is not optional")
  local door = S.dir:all("shelly_contact")[1]
  S.dir:advance(120000)
  truthy(door:lastNote("STATE_CLOSED")); eq(door.vars["Battery Level"].value, "96")
  S.sims["bb0000000050"].status.sensor.state = "open"
  S.dir:advance(150000)
  truthy(door:lastNote("OPENED")); eq(door:firedCount("Contact Opened"), 1)
  S.dir:advance(900000)
  eq(door:firedCount("Device Offline"), 0)
  assertClean(S)
end)

test("contact (real drivers): the hub remembers contact children across a restart (persistence letter)", function()
  local S1 = garageSystem({ ["Contact Inputs"] = "0040" })
  S1.dir:advance(60000)
  local kids = {}
  for _, c in ipairs(S1.dir:all()) do if c.file ~= "shelly_hub" then kids[#kids + 1] = { c.file, c.env.Properties } end end
  local S2 = system({ devices = GARAGE, noSetup = true, store = S1.hub.store, props = { Server = "shelly-42-eu.shelly.cloud", ["Authorization Key"] = KEY } })
  for _, k in ipairs(kids) do local copy = {} for a, b in pairs(k[2]) do copy[a] = b end S2.dir:load(k[1], { props = copy }) end
  S2.dir:advance(120000)
  contains(S2.hub:prop("Devices"), "1 devices, 2 children")
end)
