local H = require("tests.harness")
local Rig = require("tests.rig")
local F = require("tests.fakes")
local test, eq, truthy, falsy, contains = H.test, H.eq, H.truthy, H.falsy, H.contains

local function send(rig, ckey, intent)
  local out
  rig.router:send(ckey, intent, function(o) out = o end)
  rig.rt.advance(6000)
  return out
end

test("router: LAN first - a command on an Up device makes zero cloud calls", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  local out = send(rig, "dev1|switch|0", { on = true })
  truthy(out.ok); eq(out.route, "LAN")
  eq(sim.status["switch:0"].output, true)
  eq(#rig.cloudCalls, 0)
end)

test("router: toggle/relative intents are refused before any I/O", function()
  local rig = Rig.new()
  rig:addDevice("dev1", nil, { up = true })
  local out = send(rig, "dev1|switch|0", { toggle = true })
  eq(out.class, "CONFIG"); eq(#rig.rt.http.log, 0)
  eq(send(rig, "dev1|cover|0", { rel = 10 }).class, "CONFIG")
end)

test("router: LAN unreachable -> one LAN retry -> cloud fallback succeeds, route reported as fallback", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  sim.mode = "dead"
  local out = send(rig, "dev1|switch|0", { on = true })
  truthy(out.ok); eq(out.route, "Cloud")
  local lanTries = 0
  for _, r in ipairs(rig.rt.http.log) do if r.url:find("192.168", 1, true) and r.url:find("/rpc/", 1, true) then lanTries = lanTries + 1 end end
  truthy(lanTries >= 2, "retried on the LAN before failing over")
  eq(#rig:eventsOf("route"), 1); eq(rig:eventsOf("route")[1].b, "fallback")
end)

test("router: a DEVICE error is reported and NEVER fails over to the cloud", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  sim.errorFor["Switch.Set"] = { code = -105, message = "bad channel" }
  local out = send(rig, "dev1|switch|0", { on = true })
  eq(out.class, "DEVICE"); eq(#rig.cloudCalls, 0)
end)

test("router: rejected LAN credentials stop LAN traffic to that device and fall back to the cloud", function()
  local rig = Rig.new({ devPass = "wrong-pass" })
  local sim = rig:addDevice("dev1", { password = "right-pass" }, { up = true })
  local out = send(rig, "dev1|switch|0", { on = true })
  truthy(out.ok); eq(out.route, "Cloud")
  eq(rig.ab:get("dev1").lan, "AuthStop")
  local creds = rig.auth:credentialedRequests("dev1")
  send(rig, "dev1|switch|0", { on = false }); send(rig, "dev1|switch|0", { on = true })
  eq(rig.auth:credentialedRequests("dev1"), creds, "no further credentialed attempts")
  eq(sim.rejected, 1)
end)

test("router: cloud fallback disabled -> UNREACHABLE, never touches the cloud", function()
  local rig = Rig.new({ cloudFallback = false })
  local sim = rig:addDevice("dev1", nil, { up = true })
  sim.mode = "dead"
  local out = send(rig, "dev1|switch|0", { on = true })
  eq(out.class, "UNREACHABLE"); eq(#rig.cloudCalls, 0)
end)

test("router: device with no address is controlled through the cloud", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { noAddress = true })
  local out = send(rig, "dev1|switch|0", { on = true })
  truthy(out.ok); eq(out.route, "Cloud"); eq(sim.status["switch:0"].output, true)
end)

test("router: device offline in the cloud and unreachable on the LAN -> UNREACHABLE with a reason", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  sim.mode = "dead"; sim.cloudOnline = false
  local out = send(rig, "dev1|switch|0", { on = true })
  falsy(out.ok); eq(out.class, "UNREACHABLE")
end)

test("router: identity check - a DIFFERENT device at the cached address is never commanded", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  sim.mac = "FFFFFFFFFFFF"                        -- someone else now holds the address (DHCP reuse)
  sim.status.sys.mac = "FFFFFFFFFFFF"
  rig.ab:get("dev1").lastIdentityOk = nil          -- stale, so the router must probe first
  local out = send(rig, "dev1|switch|0", { on = true })
  for _, c in ipairs(sim.calls) do falsy(c.method == "Switch.Set", "command reached the wrong device") end
  truthy(out.ok); eq(out.route, "Cloud", "commanded through the cloud instead")
  local discarded = false
  for _, e in ipairs(rig:eventsOf("lan")) do if e.c == "NoAddress" then discarded = true end end
  truthy(discarded, "the address that answered as someone else was discarded")
end)

test("router: Strict identity mode probes before EVERY command", function()
  local rig = Rig.new({ identityCheck = "Strict" })
  local sim = rig:addDevice("dev1", nil, { up = true })
  rig.rt.advance(3000)                              -- the fresh match from setup is now older than 2 s
  send(rig, "dev1|switch|0", { on = true }); rig.rt.advance(5000)
  send(rig, "dev1|switch|0", { on = false })
  local probes = 0
  for _, r in ipairs(rig.rt.http.log) do if r.url:find("/shelly", 1, true) then probes = probes + 1 end end
  eq(probes, 2)
end)

test("router: Standard mode reuses a fresh identity match (no probe per command)", function()
  local rig = Rig.new()
  rig:addDevice("dev1", nil, { up = true })
  send(rig, "dev1|switch|0", { on = true }); send(rig, "dev1|switch|0", { on = false })
  for _, r in ipairs(rig.rt.http.log) do falsy(r.url:find("/shelly", 1, true), "unexpected probe") end
end)

test("router: verification read follows a command, is ONE per burst, and confirms the state to children", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  for _, lvl in ipairs({ 10, 20, 30 }) do
    rig.router:send("dev1|light|0", { level = lvl }, function() end)
  end
  rig.rt.advance(6000)
  local reads = 0
  for _, c in ipairs(sim.calls) do if c.method == "Shelly.GetStatus" then reads = reads + 1 end end
  eq(reads, 1, "one verification read for the burst")
  eq(sim.status["light:0"].brightness, 30)
  local lastLight
  for _, e in ipairs(rig:eventsOf("changed")) do if e.a == "dev1|light|0" then lastLight = e end end
  eq(lastLight.b.level, 30); eq(lastLight.c, true, "confirmed")
end)

test("router: a verification read that disagrees overrides the optimistic value and is reported", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  rig.registry:applyRead("dev1", { components = { { kind = "switch", channel = 0, on = false } } }, "lan")
  local realSet = sim.applyRpc
  sim.applyRpc = function() end                    -- device acknowledges but does not change (physical override)
  send(rig, "dev1|switch|0", { on = true })
  eq(rig.registry:value("dev1|switch|0"), { on = false })
  eq(#rig:eventsOf("disagree"), 1)
end)

test("router: slider drag - 20 rapid levels send at most a handful of LAN commands, and the last one wins", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  for i = 1, 20 do rig.router:send("dev1|light|0", { level = i * 5 }, function() end) end
  rig.rt.advance(6000)
  local sets = 0
  for _, c in ipairs(sim.calls) do if c.method == "Light.Set" then sets = sets + 1 end end
  truthy(sets <= 3, "sent " .. sets)
  eq(sim.status["light:0"].brightness, 100)
end)

test("router: a scene across 6 devices runs in parallel waves (never more than 3 in flight)", function()
  local rig = Rig.new()
  for i = 1, 6 do rig:addDevice("d" .. i, nil, { up = true }) end
  local done, t0 = 0, rig.rt.clock.now()
  for i = 1, 6 do rig.router:send("d" .. i .. "|switch|0", { on = true }, function() done = done + 1 end) end
  rig.rt.advance(2000)
  eq(done, 6); truthy(rig.dispatch.maxRunning <= 3)
  for i = 1, 6 do eq(rig.sims["d" .. i].status["switch:0"].output, true) end
end)

test("router: cover STOP cancels a pending position command", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  rig.router:send("dev1|switch|0", { on = true }, function() end)      -- occupies the lane
  rig.rt.advance(1)
  local posOut
  rig.router:send("dev1|cover|0", { position = 80 }, function(o) posOut = o end)
  rig.router:send("dev1|cover|0", { cover = "stop" }, function() end)
  rig.rt.advance(6000)
  eq(posOut.class, "SUPERSEDED")
  local sawPos = false
  for _, c in ipairs(sim.calls) do if c.method == "Cover.GoToPosition" then sawPos = true end end
  falsy(sawPos)
end)

test("router: STOP after a LAN failure reads the cover first and does not blindly repeat the stop", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  sim.mode = "dead"
  sim.status["cover:0"].state = "stopped"          -- it had already stopped
  local out = send(rig, "dev1|cover|0", { cover = "stop" })
  truthy(out.ok)
  for _, c in ipairs(rig.cloudCalls) do falsy(c.op == "set", "no cloud stop was sent") end
end)

test("router: STOP after a LAN failure DOES go to the cloud when the cover is still moving", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { up = true })
  sim.mode = "dead"
  sim.status["cover:0"].state = "opening"
  local out = send(rig, "dev1|cover|0", { cover = "stop" })
  truthy(out.ok); eq(out.route, "Cloud")
  eq(sim.status["cover:0"].state, "stopped")
end)

test("router: command timings - LAN command on an Up device completes within one round trip", function()
  local rig = Rig.new({ latency = 20 })
  rig:addDevice("dev1", nil, { up = true })
  local t0, tdone = rig.rt.clock.now(), nil
  rig.router:send("dev1|switch|0", { on = true }, function() tdone = rig.rt.clock.now() end)
  rig.rt.advance(1000)
  truthy(tdone - t0 <= 100, "took " .. (tdone - t0))
end)

test("router: a verification read DURING a light transition reports the target, not the moving value (no false disagreement)", function()
  local rig = Rig.new(); local sim = rig:addDevice("dev1", { lightTransition = true }, { up = true })
  rig.registry:applyRead("dev1", { components = { { kind = "light", channel = 0, on = true, level = 50 } } }, "lan")
  send(rig, "dev1|light|0", { level = 80 })
  eq(rig.registry:value("dev1|light|0").level, 80)
  eq(#rig:eventsOf("disagree"), 0, "the moving value was mistaken for a device override")
  sim:finishTransition(0)
  rig.lanPoll:start(); rig.rt.advance(60000)
  eq(rig.registry:value("dev1|light|0").level, 80)
  eq(#rig:eventsOf("disagree"), 0)
end)
