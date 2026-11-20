-- Router failure and edge paths: identity gate, authentication rejection, cloud fallback limits, STOP via the cloud, verification.
local H = require("tests.harness")
local Rig = require("tests.rig")
local test, eq, truthy, falsy, contains = H.test, H.eq, H.truthy, H.falsy, H.contains

local function send(rig, ckey, intent)
  local out
  rig.router:send(ckey, intent, function(o) out = o end)
  rig.rt.advance(8000)
  return out
end
local function lanRpc(rig)
  local n = 0
  for _, r in ipairs(rig.rt.http.log) do if r.url:find("192.168", 1, true) and r.url:find("/rpc/", 1, true) then n = n + 1 end end
  return n
end

test("router paths: a DIFFERENT device at the address is never commanded; the command goes to the cloud and a refresh is requested", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = false })
  rig.ab:noteSuccess("dev1")                                       -- LAN usable, but the identity match is stale
  sim.mac = "FFEEDDCCBBAA"                                         -- someone else now answers at that address
  local out = send(rig, "dev1|switch|0", { on = true })
  truthy(out.ok); eq(out.route, "Cloud", "fell back to the cloud, never the imposter")
  eq(#sim.calls, 0, "the device at the address was not commanded")
  contains(rig.rt.output(), "answered as a different device")     -- the address book was told (and discards that address)
end)

test("router paths: LAN authentication rejected -> command goes through the cloud, and the stop is recorded", function()
  local rig = Rig.new({ devPass = "wrong" })
  local sim = rig:addDevice("dev1", { password = "right" }, { up = true })
  local out = send(rig, "dev1|switch|0", { on = true })
  truthy(out.ok); eq(out.route, "Cloud")
  eq(sim.rejected <= 1, true, "a wrong password is tried at most once")
  local again = send(rig, "dev1|switch|0", { on = false })
  truthy(again.ok); eq(again.route, "Cloud")
  eq(sim.rejected <= 1, true, "and never again")
end)

test("router paths: Cloud Fallback off -> a LAN failure is reported, nothing is sent to the cloud", function()
  local rig = Rig.new({ cloudFallback = false })
  local sim = rig:addDevice("dev1", nil, { up = true })
  sim.mode = "dead"
  local out = send(rig, "dev1|switch|0", { on = true })
  falsy(out.ok); eq(out.class, "UNREACHABLE"); contains(out.reason, "cloud fallback is off")
  eq(#rig.cloudCalls, 0)
end)

test("router paths: cloud unusable (auth failed) -> 'fallback unavailable', and a device the cloud calls offline is not tried", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  sim.mode = "dead"
  rig.cloud.status = "Auth failed"
  local out = send(rig, "dev1|switch|0", { on = true })
  falsy(out.ok); contains(out.reason, "cloud fallback unavailable")
  rig.cloud.status = "Connected"
  rig.ab:ensure("dev1").cloudOnline = false
  local out2 = send(rig, "dev1|switch|0", { on = true })
  falsy(out2.ok); contains(out2.reason, "cloud fallback unavailable")
end)

test("router paths: a device-level error is returned as is - not retried and not sent to the cloud", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  sim.errorFor["Switch.Set"] = { code = -109, message = "not allowed" }
  local before = lanRpc(rig)
  local out = send(rig, "dev1|switch|0", { on = true })
  falsy(out.ok); eq(out.class, "DEVICE")
  eq(lanRpc(rig) - before, 1, "one attempt only"); eq(#rig.cloudCalls, 0)
end)

test("router paths: STOP via the cloud reads the cover first and only stops a moving cover", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  sim.mode = "dead"
  sim.status["cover:0"].state = "stopped"
  local out = send(rig, "dev1|cover|0", { cover = "stop" })
  truthy(out.ok); eq(out.route, "Cloud")
  local stops = 0
  for _, c in ipairs(rig.cloudCalls) do if c.op == "set" or (c.body and tostring(c.body):find("stop", 1, true)) then stops = stops + 1 end end
  eq(stops, 0, "an already stopped cover is not sent another stop")
  sim.status["cover:0"].state = "opening"
  local out2 = send(rig, "dev1|cover|0", { cover = "stop" })
  truthy(out2.ok); eq(out2.route, "Cloud")
end)

test("router paths: STOP via the cloud when the cover state cannot be read -> reported, nothing guessed", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  sim.mode = "dead"
  rig.cloudSim.down = true
  local out = send(rig, "dev1|cover|0", { cover = "stop" })
  falsy(out.ok)
end)

test("router paths: after a fallback, the first LAN success raises 'restored' exactly once", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  sim.mode = "dead"
  truthy(send(rig, "dev1|switch|0", { on = true }).ok)
  sim.mode = "http"
  rig.ab:noteSuccess("dev1")
  truthy(send(rig, "dev1|switch|0", { on = false }).ok)
  truthy(send(rig, "dev1|switch|0", { on = true }).ok)
  local kinds = {}
  for _, e in ipairs(rig:eventsOf("route")) do kinds[#kinds + 1] = e.b end
  eq(table.concat(kinds, ","), "fallback,restored")
end)

test("router paths: a command that succeeds but cannot be verified raises the unverified hook (and does not crash)", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  truthy(send(rig, "dev1|switch|0", { on = true }).ok)
  rig:clearEvents()
  sim.mode = "dead"
  rig.router:verifyNow("dev1", "LAN")
  rig.rt.advance(10000)
  eq(#rig:eventsOf("unverified"), 1)
end)

test("router paths: a cloud verification that fails raises the unverified hook too", function()
  local rig = Rig.new()
  rig:addDevice("dev1", nil, { up = false, noAddress = true })
  rig.cloudSim.down = true
  rig:clearEvents()
  rig.router:verifyNow("dev1", "Cloud")
  rig.rt.advance(70000)
  eq(#rig:eventsOf("unverified"), 1)
end)

test("router paths: a LAN read answered by a different device is refused (identity gate on feedback)", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  local d = rig.ab:get("dev1")
  local ok = rig.router:ingestLan(d, { identity = { mac = "FFEEDDCCBBAA" }, components = {}, unsupported = {} }, {})
  falsy(ok)
  contains(rig.rt.output(), "answered as a different device")
end)

test("router paths: a value stream is limited to one send per 250 ms and the LAST value wins", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  local outs = {}
  for i, lv in ipairs({ 10, 20, 30, 40 }) do
    rig.router:send("dev1|light|0", { level = lv }, function(o) outs[i] = o end)
  end
  rig.rt.advance(3000)
  eq(outs[1].ok, true); eq(outs[2].class, "SUPERSEDED"); eq(outs[3].class, "SUPERSEDED"); eq(outs[4].ok, true)
  eq(sim.status["light:0"].brightness, 40)
end)

test("router paths: STOP cancels a deferred slider value for the same cover", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  local a, b
  rig.router:send("dev1|cover|0", { position = 20 }, function(o) a = o end)
  rig.router:send("dev1|cover|0", { position = 60 }, function(o) b = o end)      -- deferred (inside the 250 ms window)
  local s
  rig.router:send("dev1|cover|0", { cover = "stop" }, function(o) s = o end)
  rig.rt.advance(5000)
  eq(b.class, "SUPERSEDED"); truthy(s.ok)
end)

test("router paths: a password-protected stranger (different digest realm) never receives our login and the command goes to the cloud", function()
  local rig = Rig.new({ devPass = "right" })
  local sim = rig:addDevice("dev1", { password = "right" }, { up = true })
  rig.ab:noteSuccess("dev1"); rig.ab:noteIdentityOk("dev1")        -- identity looked fine a moment ago, so no probe precedes the command
  sim.id = "shellyplus1pm-ffeeddccbbaa"                            -- the realm now names a different device
  local out = send(rig, "dev1|switch|0", { on = true })
  truthy(out.ok); eq(out.route, "Cloud")
  local authed = 0
  for _, r in ipairs(rig.rt.http.log) do if r.headers and (r.headers.Authorization or r.headers.authorization) and r.url:find("192.168", 1, true) then authed = authed + 1 end end
  eq(authed, 0, "no credentials were sent to the stranger")
  contains(rig.rt.output(), "answered as a different device")
end)
