local H = require("tests.harness")
local F = require("tests.fakes")
local Cloud = require("hub.transport.cloud")
local Parse = require("hub.transport.parse")
local test, eq, truthy, falsy, contains, not_contains = H.test, H.eq, H.truthy, H.falsy, H.contains, H.not_contains
local resp = F.resp

local KEY = "0123456789abcdefKEY"
local function new(opts)
  local rt = F.new(opts)
  local c = Cloud.new(rt)
  truthy(c:configure("shelly-42-eu.shelly.cloud", KEY))
  return rt, c
end

local function status_fixture()
  return {
    id = "b48a0a1cd978", sys = { mac = "B4:8A:0A:1C:D9:78" },
    wifi = { sta_ip = "192.168.1.40", status = "got ip" },
    ["switch:0"] = { id = 0, output = true }, ["switch:1"] = { id = 1, output = false },
    ["light:0"] = { id = 0, output = true, brightness = 60 },
    ["cover:0"] = { id = 0, state = "stopped", current_pos = 40 },
    ["input:0"] = { id = 0, state = false }, ["script:1"] = { id = 1, running = false },
  }
end

test("cloud: host normalisation accepts *.shelly.cloud and refuses everything else", function()
  eq(Cloud.normalizeHost("https://Shelly-42-EU.shelly.cloud/"), "shelly-42-eu.shelly.cloud")
  eq(Cloud.normalizeHost("  shelly-1-us.shelly.cloud "), "shelly-1-us.shelly.cloud")
  for _, bad in ipairs({ "evil.example.com", "shelly.cloud.evil.com", "x.shelly.cloud:6113", "", "https://", "a..shelly.cloud", "shelly.cloud" }) do
    eq((Cloud.normalizeHost(bad)), nil, bad)
  end
end)

test("cloud: a non-Shelly host is refused at configure time and no request is ever made", function()
  local rt = F.new()
  local c = Cloud.new(rt)
  local ok, err = c:configure("attacker.example.com", KEY)
  falsy(ok); truthy(err)
  local out
  c:read({ "a" }, "control", function(o) out = o end)
  eq(out.class, "CONFIG"); eq(#rt.http.log, 0)
end)

test("cloud: parse normalises components, identity and address from a Gen2 status", function()
  local d = Parse.device({ id = "B48A0A1CD978", online = true, gen = "G2", code = "SNSW-001P16EU" }, status_fixture())
  eq(d.id, "b48a0a1cd978"); eq(d.address, "192.168.1.40"); eq(d.identity.mac, "B48A0A1CD978")
  eq(#d.components, 5)
  eq(d.components[1].kind, "contact", "components come out in sorted key order")
  local function find(kind, ch) for _, c in ipairs(d.components) do if c.kind == kind and c.channel == ch then return c end end end
  eq(find("cover", 0), { kind = "cover", channel = 0, state = "stopped", position = 40, calibrated = true })
  eq(find("light", 0), { kind = "light", channel = 0, on = true, level = 60 })
  local sw, contact = find("switch", 0), find("contact", 0)
  eq(sw, { kind = "switch", channel = 0, on = true })
  eq(contact, { kind = "contact", channel = 0, closed = false, optional = true }, "a switch-type input is an OPTIONAL contact component")
  eq(d.unsupported, {})
end)

test("cloud: unknown/missing fields stay nil (unknown), never guessed; uncalibrated cover has no position", function()
  local d = Parse.device({ id = "aa11bb22cc33", online = true, gen = "G2" },
    { ["switch:0"] = { id = 0 }, ["cover:0"] = { id = 0, state = "stopped" } })
  eq(d.components[1].kind, "cover"); eq(d.components[1].position, nil); eq(d.components[1].calibrated, false)
  eq(d.components[2].on, nil)
end)

test("cloud: wired address wins over Wi-Fi; invalid addresses are ignored", function()
  eq((Parse.address({ eth = { ip = "10.0.0.5" }, wifi = { sta_ip = "192.168.1.9" } })), "10.0.0.5")
  eq((Parse.address({ eth = { ip = "0.0.0.0" }, wifi = { sta_ip = "192.168.1.9" } })), "192.168.1.9")
  eq((Parse.address({ wifi = { sta_ip = "garbage" } })), nil)
end)

test("cloud: Gen1 devices are marked unsupported", function()
  local d = Parse.device({ id = "abc123", gen = "G1" }, {})
  falsy(d.supported)
  truthy(Parse.device({ id = "abc123", gen = "G2" }, {}).supported)
  truthy(Parse.device({ id = "abc123", gen = "G4" }, {}).supported)
end)

test("cloud: read() posts the documented v2 body and returns normalised devices", function()
  local rt, c = new()
  rt.http.on("/v2/devices/api/get", function() return resp(200, { { id = "b48a0a1cd978", type = "relay", code = "SNSW-001P16EU", gen = "G2", online = 1, status = status_fixture() } }) end)
  local out, devs
  c:read({ "b48a0a1cd978" }, "background", function(o, d) out, devs = o, d end)
  rt.advance(500)
  truthy(out.ok); eq(#devs, 1); eq(devs[1].online, true); eq(c.status, "Connected")
  local req = rt.http.log[1]
  eq(req.method, "POST"); contains(req.url, "https://shelly-42-eu.shelly.cloud/v2/devices/api/get?auth_key=")
  eq(rt.json.decode(req.body), { ids = { "b48a0a1cd978" }, select = { "status" } })
  truthy(req.spec.verify, "cloud TLS is always verified")
end)

test("cloud: at most 10 ids per read request", function()
  local rt, c = new()
  rt.http.on("/get", function() return resp(200, {}) end)
  local ids = {}
  for i = 1, 25 do ids[i] = "id" .. i end
  c:read(ids, "background", function() end)
  rt.advance(500)
  eq(#rt.json.decode(rt.http.log[1].body).ids, 10)
end)

test("cloud: all_status parses devices_status with _dev_info, sorted by id", function()
  local rt, c = new()
  local a = status_fixture(); a._dev_info = { id = "b48a0a1cd978", gen = "G2", code = "X", online = true }
  local b = { ["switch:0"] = { output = false }, _dev_info = { id = "a8032abe41fc", gen = "G2", code = "Y", online = false } }
  rt.http.on("all_status", function() return resp(200, { isok = true, data = { devices_status = { k1 = a, k2 = b } } }) end)
  local devs
  c:allStatus(function(_, d) devs = d end)
  rt.advance(500)
  eq(#devs, 2); eq(devs[1].id, "a8032abe41fc"); eq(devs[1].online, false); eq(devs[2].address, "192.168.1.40")
  contains(rt.http.log[1].url, "show_info=true&no_shared=true&auth_key=")
end)

test("cloud: control bodies are absolute (light level 0 => off, >0 => on+brightness, cover position/open/stop)", function()
  eq(Cloud.controlBody("switch", "a", 0, { on = true }), { id = "a", channel = 0, on = true })
  eq(Cloud.controlBody("light", "a", 0, { level = 0 }), { id = "a", channel = 0, on = false })
  eq(Cloud.controlBody("light", "a", 0, { level = 60.4 }), { id = "a", channel = 0, on = true, brightness = 60 })
  eq(Cloud.controlBody("light", "a", 1, { on = false }), { id = "a", channel = 1, on = false })
  eq(Cloud.controlBody("cover", "a", 0, { cover = "stop" }), { id = "a", channel = 0, position = "stop" })
  eq(Cloud.controlBody("cover", "a", 0, { position = 140 }), { id = "a", channel = 0, position = 100 })
  eq(Cloud.controlBody("switch", "a", 0, { on = true, toggle_after = 2 }), { id = "a", channel = 0, on = true, toggle_after = 2 })
end)

test("cloud: control() never emits toggle or relative fields", function()
  local rt, c = new()
  rt.http.on("/set/", function() return resp(200, {}) end)
  c:set("light", "a", 0, { level = 30 }, "control", function() end)
  c:set("cover", "b", 0, { position = 50 }, "control", function() end)
  rt.advance(5000)
  for _, r in ipairs(rt.http.log) do
    not_contains(r.body, "toggle"); not_contains(r.body, "relative")
  end
end)

test("cloud: identical fallback commands to several targets merge into one groups request; failedCommands is honoured", function()
  local rt, c = new()
  rt.http.on("/set/", function() return resp(200, {}) end)
  rt.http.on("/set/groups", function() return resp(200, { failedCommands = { ["dev2_0"] = "DEVICE_NOT_FOUND" } }) end)
  local outs = {}
  c:set("switch", "busy", 0, { on = true }, "control", function() end)   -- occupies the gate
  for _, id in ipairs({ "dev1", "dev2", "dev3" }) do
    c:set("switch", id, 0, { on = false }, "control", function(o) outs[id] = o end)
  end
  rt.advance(10000)
  eq(#rt.http.log, 2, "one single + one group")
  local body = rt.json.decode(rt.http.log[2].body)
  eq(body.switch.ids, { "dev1_0", "dev2_0", "dev3_0" }); eq(body.switch.command, { on = false })
  truthy(outs.dev1.ok); falsy(outs.dev2.ok); eq(outs.dev2.class, "CONFIG"); truthy(outs.dev3.ok)
end)

test("cloud: different values are not merged", function()
  local rt, c = new()
  rt.http.on("/set/", function() return resp(200, {}) end)
  c:set("light", "busy", 0, { level = 10 }, "control", function() end)
  c:set("light", "a", 0, { level = 20 }, "control", function() end)
  c:set("light", "b", 0, { level = 80 }, "control", function() end)
  rt.advance(10000)
  eq(#rt.http.log, 3)
end)

test("cloud: error mapping follows the documented v2 error table", function()
  local rt, c = new()
  local cases = {
    { 400, { error = "DEVICE_OFFLINE", data = { messages = { "x" } } }, "UNREACHABLE" },
    { 400, { error = "DEVICE_FAILED_COMMAND" }, "DEVICE" },
    { 400, { error = "DEVICE_INVALID_CHANNEL" }, "CONFIG" },
    { 400, { error = "BAD_REQUEST" }, "CONFIG" },
    { 404, { error = "DEVICE_NOT_FOUND" }, "CONFIG" },
    { 404, { error = "INSTANCE_NOT_FOUND" }, "CLOUD" },
    { 500, { error = "UNEXPECTED_SUBSERVICE_ERROR" }, "CLOUD" },
    { 429, {}, "RATE" }, { 401, {}, "AUTH" }, { 403, {}, "AUTH" }, { 502, "<html>", "CLOUD" },
  }
  for _, cs in ipairs(cases) do
    eq(c:classify(resp(cs[1], cs[2])).class, cs[3], "HTTP " .. cs[1])
  end
  eq(c:classify(F.neterr("timeout")).class, "CLOUD")
  truthy(c:classify(resp(400, { error = "DEVICE_OFFLINE" })).offline)
end)

test("cloud: a bad key stops the cloud queue after ONE request and reports 'Auth failed'", function()
  local rt, c = new()
  rt.http.on("/v2/", function() return resp(401, {}) end)
  local outs = {}
  for i = 1, 4 do c:read({ "a" }, "background", function(o) outs[i] = o end) end
  rt.advance(30000)
  eq(#rt.http.log, 1); eq(c.status, "Auth failed")
  for i = 1, 4 do eq(outs[i].class, "AUTH") end
  -- correcting the key resumes traffic
  rt.http.on("/v2/", function() return resp(200, {}) end)
  truthy(c:configure("shelly-42-eu.shelly.cloud", "a-completely-new-key-123"))
  c:read({ "a" }, "background", function() end)
  rt.advance(3000)
  eq(#rt.http.log, 2)
end)

test("cloud: the key never appears in the log at Debug level", function()
  local rt, c = new()
  rt.http.on("/v2/", function() return resp(200, {}) end)
  rt.log:debug("request url auth_key=%s", KEY)
  rt.log:info("about to talk to %s using key %s", "cloud", KEY)
  c:read({ "a" }, "background", function() end)
  rt.advance(2000)
  not_contains(rt.output(), KEY)
end)

test("cloud: status transitions Degraded -> Connected -> Degraded on network loss", function()
  local rt, c = new()
  local seen = {}
  c.onStatus = function(s) seen[#seen + 1] = s end
  rt.http.on("/v2/", function() return resp(200, {}) end)
  c:read({ "a" }, "background", function() end); rt.advance(1500)
  rt.http.on("/v2/", function() return F.neterr("timeout") end)
  c:read({ "a" }, "background", function() end); rt.advance(1500)
  eq(seen, { "Connected", "Degraded" })
end)

test("cloud: two consecutive network failures make the cloud Offline (not a usable route); one success recovers", function()
  local rt, c = new()
  rt.http.on("/v2/", function() return resp(200, {}) end)
  c:read({ "a" }, "background", function() end); rt.advance(1500)
  rt.http.on("/v2/", function() return F.neterr("timeout") end)
  c:read({ "a" }, "background", function() end); rt.advance(1500)
  eq(c.status, "Degraded")
  c:read({ "a" }, "background", function() end); rt.advance(1500)
  eq(c.status, "Offline")
  rt.http.on("/v2/", function() return resp(200, {}) end)
  c:read({ "a" }, "background", function() end); rt.advance(1500)
  eq(c.status, "Connected")
end)

test("parse: a light mid-transition reports its TARGET; uncalibrated flag is carried", function()
  local Parse = require("hub.transport.parse")
  local comps = Parse.components({
    ["light:0"] = { id = 0, output = false, brightness = 20, transition = { target = { output = true, brightness = 80 }, started_at = 1, duration = 3 } },
    ["light:1"] = { id = 1, output = true, brightness = 100, flags = { "uncalibrated" } },
    ["light:2"] = { id = 2, output = true, brightness = 55 } })
  eq(comps[1].on, true); eq(comps[1].level, 80)
  eq(comps[2].uncalibrated, true); eq(comps[3].uncalibrated, nil)
end)

test("parse: pos_control is the calibration flag; a calibrated cover can have an unknown (null) position", function()
  local Parse = require("hub.transport.parse")
  local c = Parse.components({
    ["cover:0"] = { id = 0, state = "open", pos_control = true, current_pos = 100 },
    ["cover:1"] = { id = 1, state = "stopped", pos_control = true },                        -- position lost after a power cut
    ["cover:2"] = { id = 2, state = "closed", pos_control = false } })
  eq(c[1].calibrated, true); eq(c[1].position, 100)
  eq(c[2].calibrated, true); eq(c[2].position, nil)
  eq(c[3].calibrated, false)
end)

test("parse: the documented all_status example - G2 is kept; G1, BLE and a numeric-id virtual thermostat are not", function()
  local Parse = require("hub.transport.parse")
  local devs = Parse.from_all_status({ devices_status = {
    ["dc4f2276846a"] = { _dev_info = { id = "dc4f2276846a", gen = "G1", code = "SHSW-1", online = false } },
    ["84cca87c0144"] = { ["switch:0"] = { id = 0, output = true },
                         _dev_info = { id = "84cca87c0144", gen = "G2", code = "SPSW-001PE16EU", online = true } },
    ["1643370677417"] = { _dev_info = { gen = "V1", id = 1643370677417, code = "THERMOSTAT", online = false } },
    ["X1234"] = { _dev_info = { gen = "GBLE", id = "X1234", code = "SBBT", online = true } } } })
  local by = {}
  for _, d in ipairs(devs) do by[d.id] = d end
  eq(by["84cca87c0144"].supported, true); eq(by["84cca87c0144"].online, true); eq(by["84cca87c0144"].components[1].on, true)
  eq(by["dc4f2276846a"].supported, false); eq(by["x1234"].supported, false)
  eq(by["1643370677417"], nil, "a numeric (virtual) id is never treated as a Shelly device")
end)

test("parse: all_status tolerates a numeric online flag", function()
  local Parse = require("hub.transport.parse")
  local d = Parse.from_all_status({ devices_status = { a = { _dev_info = { id = "aabbccddeeff", gen = "G2", code = "X", online = 0 } } } })
  eq(d[1].online, false)
end)

test("parse: flood and smoke components carry alarm and mute; devicepower and inputs are not control gaps", function()
  local Parse = require("hub.transport.parse")
  local c, unsup = Parse.components({
    ["flood:0"] = { id = 0, alarm = true, mute = false }, ["smoke:1"] = { id = 1, alarm = false, mute = true },
    ["devicepower:0"] = { id = 0, battery = { V = 3, percent = 80 } }, ["temperature:0"] = { id = 0, tC = 21 } })
  eq(#c, 2)
  eq(c[1].kind, "flood"); eq(c[1].alarm, true); eq(c[1].mute, false)
  eq(c[2].kind, "smoke"); eq(c[2].channel, 1); eq(c[2].mute, true)
  for _, k in ipairs(unsup) do falsy(k:find("^flood") or k:find("^smoke")) end
end)
