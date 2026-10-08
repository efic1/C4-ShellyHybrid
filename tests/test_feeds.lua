local H = require("tests.harness")
local Rig = require("tests.rig")
local F = require("tests.fakes")
local test, eq, truthy, falsy = H.test, H.eq, H.truthy, H.falsy

local function lanReqs(rig, pat)
  local n = 0
  for _, r in ipairs(rig.rt.http.log) do if r.url:find(pat or "/rpc/", 1, true) and r.url:find("192.168", 1, true) then n = n + 1 end end
  return n
end

test("feeds: ONE scheduler item polls all devices; no burst - requests are spread across the interval", function()
  local rig = Rig.new({ lanPollS = 20 })
  for i = 1, 10 do rig:addDevice("d" .. i, nil, { up = true }) end
  rig.lanPoll:start()
  eq(rig.rt.timerCount(), 1, "one Control4 timer for the whole feed")
  rig.rt.advance(20000)
  eq(lanReqs(rig), 10, "each device polled once per interval")
  local times = {}
  for _, r in ipairs(rig.rt.http.log) do times[#times + 1] = r.at end
  local maxSame = 0
  local byBucket = {}
  for _, t in ipairs(times) do local b = math.floor(t / 1000); byBucket[b] = (byBucket[b] or 0) + 1; maxSame = math.max(maxSame, byBucket[b]) end
  truthy(maxSame <= 3, "at most 3 requests in any one second, saw " .. maxSame)
end)

test("feeds: LAN poll feeds state into the registry and unchanged polls notify nobody", function()
  local rig = Rig.new({ lanPollS = 10 })
  rig:addDevice("dev1", nil, { up = true })
  rig.lanPoll:start()
  rig.rt.advance(10500)
  local first = #rig:eventsOf("changed")
  truthy(first >= 1)
  rig.rt.advance(60000)
  eq(#rig:eventsOf("changed"), first, "six more identical polls, zero notifications")
end)

test("feeds: an external change (wall switch) is seen on the next poll and published", function()
  local rig = Rig.new({ lanPollS = 10 })
  local sim = rig:addDevice("dev1", nil, { up = true })
  rig.lanPoll:start()
  rig.rt.advance(10500)
  sim.status["switch:0"].output = true
  rig.rt.advance(11000)
  eq(rig.registry:value("dev1|switch|0"), { on = true })
end)

test("feeds: a covering in motion is re-read quickly until it stops (bounded)", function()
  local rig = Rig.new({ lanPollS = 60 })
  local sim = rig:addDevice("dev1", nil, { up = true })
  rig.lanPoll:start()
  rig.rt.advance(61000)
  sim.status["cover:0"].state = "opening"; sim.status["cover:0"].target_pos = 100
  rig.rt.advance(60000)                              -- next regular poll notices motion
  local before = lanReqs(rig)
  rig.rt.advance(6000)
  truthy(lanReqs(rig) - before >= 2, "fast polling while moving")
  sim:finishMove(0)
  rig.rt.advance(6000)
  eq(rig.registry:value("dev1|cover|0").state, "open")
  local after = lanReqs(rig)
  rig.rt.advance(6000)
  eq(lanReqs(rig), after, "fast polling stops once the cover stops")
end)

test("feeds: a device that stops answering goes Down after 3 misses, backs off, and is probed again", function()
  local rig = Rig.new({ lanPollS = 10 })
  local sim = rig:addDevice("dev1", nil, { up = true })
  rig.lanPoll:start()
  rig.rt.advance(10500)
  sim.mode = "dead"
  rig.rt.advance(60000)
  eq(rig.ab:get("dev1").lan, "Down")
  local probes = 0
  for _, r in ipairs(rig.rt.http.log) do if r.url:find("/shelly", 1, true) then probes = probes + 1 end end
  truthy(probes >= 1)
  sim.mode = "http"
  rig.rt.advance(400000)
  eq(rig.ab:get("dev1").lan, "Up", "recovers on its own")
end)

test("feeds: an unreachable device does not slow the polling of healthy ones", function()
  local rig = Rig.new({ lanPollS = 10 })
  for i = 1, 4 do local s = rig:addDevice("d" .. i, nil, { up = true }); if i <= 2 then s.mode = "dead" end end
  rig.lanPoll:start()
  rig.rt.advance(40000)
  truthy(rig.ab:get("d3").lastPoll and rig.rt.clock.now() - rig.ab:get("d3").lastPoll <= 15000)
  truthy(rig.ab:get("d4").lastPoll and rig.rt.clock.now() - rig.ab:get("d4").lastPoll <= 15000)
end)

test("feeds: DHCP change - device moves address, LAN goes Down, cloud refresh supplies the new address, control resumes on LAN", function()
  local rig = Rig.new({ lanPollS = 10 })
  local sim = rig:addDevice("dev1", nil, { up = true })
  rig.lanPoll:start(); rig.cloudCheck:start()
  rig.rt.advance(10500)
  local oldAddr = sim.addr
  sim.mode = "dead"                                   -- old address goes dark ...
  local newSim = require("tests.lan_sim").new(rig.rt, { addr = "192.168.1.200", mac = sim.mac, id = sim.id })
  newSim.status = sim.status
  sim.cloudAddr = "192.168.1.200"                     -- ... and the cloud knows the new one
  rig.rt.advance(90000)
  eq(rig.ab:get("dev1").address, "192.168.1.200")
  eq(rig.ab:get("dev1").lan, "Up")
  local out
  rig.router:send("dev1|switch|0", { on = true }, function(o) out = o end)
  rig.rt.advance(3000)
  truthy(out.ok); eq(out.route, "LAN")
end)

test("feeds: persisted addresses work after a reboot with NO internet (cloud down)", function()
  local rig = Rig.new({ cloud = false })
  local sim = rig:addDevice("dev1", nil, {})
  rig.ab:get("dev1").lan = "Probing"
  rig.lanPoll:start()
  rig.rt.advance(30000)
  eq(rig.ab:get("dev1").lan, "Up")
  local out
  rig.router:send("dev1|switch|0", { on = true }, function(o) out = o end)
  rig.rt.advance(2000)
  truthy(out.ok); eq(out.route, "LAN")
end)

test("feeds: cloud check batches ten devices per request, at background priority, and ignores values for LAN-up devices", function()
  local rig = Rig.new({ cloudCheckS = 300 })
  for i = 1, 23 do rig:addDevice("d" .. string.format("%02d", i), nil, { up = true }) end
  rig.cloudCheck:checkAll()
  rig.rt.advance(10000)
  local gets = {}
  for _, c in ipairs(rig.cloudCalls) do if c.op == "get" then gets[#gets + 1] = #c.ids end end
  eq(gets, { 10, 10, 3 })
  eq(rig.registry:value("d01|switch|0"), nil, "LAN-up devices take state from the LAN only")
end)

test("feeds: cloud-route devices get their STATE from the cloud check", function()
  local rig = Rig.new()
  local sim = rig:addDevice("dev1", nil, { noAddress = true })
  sim.status["switch:0"].output = true
  sim.status.wifi = nil
  rig.cloudCheck:checkCloudRoute()
  rig.rt.advance(5000)
  eq(rig.registry:value("dev1|switch|0"), { on = true })
end)

test("feeds: the cloud request rate stays bounded (background checks are spaced by the rate gate)", function()
  local rig = Rig.new({ cloudCheckS = 300 })
  for i = 1, 40 do rig:addDevice("d" .. string.format("%02d", i), nil, { up = true }) end
  rig.cloudCheck:start()
  rig.rt.advance(300000)
  truthy(rig.cloud.queue:requestsLastMinute() <= 50)
  local n = 0
  for _, c in ipairs(rig.cloudCalls) do if c.op == "get" then n = n + 1 end end
  truthy(n <= 4 + 5 * 4, "cloud gets in 5 minutes: " .. n)
end)
