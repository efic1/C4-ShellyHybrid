local H = require("tests.harness")
local F = require("tests.fakes")
local Dispatch = require("hub.transport.lan_dispatch")
local test, eq, truthy, falsy = H.test, H.eq, H.truthy, H.falsy

local function job(rt, log, name, ms)
  return function(done)
    log[#log + 1] = { name = name, at = rt.clock.now() }
    rt.sched:after(ms or 100, done)
  end
end

test("dispatch: at most ONE request in flight per device", function()
  local rt = F.new()
  local d = Dispatch.new(rt)
  local log, live, peak = {}, 0, 0
  for i = 1, 5 do
    d:submit("dev", "control", "k" .. i, function(done)
      live = live + 1; peak = math.max(peak, live)
      rt.sched:after(50, function() live = live - 1; done() end)
    end)
  end
  rt.advance(2000)
  eq(peak, 1)
end)

test("dispatch: at most 3 requests in flight across the hub", function()
  local rt = F.new()
  local d = Dispatch.new(rt)
  local log = {}
  for i = 1, 10 do d:submit("dev" .. i, "control", nil, job(rt, log, "d" .. i, 200)) end
  rt.advance(3000)
  eq(#log, 10); eq(d.maxRunning, 3)
end)

test("dispatch: a 10-light scene with different values finishes in ~4 waves, not 10 serial requests", function()
  local rt = F.new()
  local d = Dispatch.new(rt)
  local t0, last = rt.clock.now(), 0
  for i = 1, 10 do
    d:submit("dev" .. i, "control", nil, function(done)
      rt.sched:after(100, function() last = rt.clock.now(); done() end)
    end)
  end
  rt.advance(5000)
  truthy(last - t0 <= 500, "took " .. (last - t0) .. " ms")
end)

test("dispatch: a waiting entry with the same key is replaced (slider drag coalesces)", function()
  local rt = F.new()
  local d = Dispatch.new(rt)
  local log, dropped = {}, 0
  d:submit("dev", "control", "busy", job(rt, log, "busy", 100))
  rt.advance(1)
  for i = 1, 20 do d:submit("dev", "control", "level", job(rt, log, "v" .. i, 10), function() dropped = dropped + 1 end) end
  rt.advance(2000)
  local names = {}
  for _, l in ipairs(log) do names[#names + 1] = l.name end
  eq(names, { "busy", "v20" }); eq(dropped, 19)
  eq(d:waitingCount("dev"), 0)
end)

test("dispatch: within a lane control runs before verify before poll", function()
  local rt = F.new()
  local d = Dispatch.new(rt)
  local log = {}
  d:submit("dev", "control", "first", job(rt, log, "first", 100))
  rt.advance(1)
  d:submit("dev", "poll", "p", job(rt, log, "poll"))
  d:submit("dev", "verify", "v", job(rt, log, "verify"))
  d:submit("dev", "control", "c", job(rt, log, "control"))
  rt.advance(2000)
  local names = {}
  for _, l in ipairs(log) do names[#names + 1] = l.name end
  eq(names, { "first", "control", "verify", "poll" })
end)

test("dispatch: lanes are served round-robin so one busy device cannot starve another", function()
  local rt = F.new()
  local d = Dispatch.new(rt, { globalMax = 1 })
  local order = {}
  local function j(name) return function(done) order[#order + 1] = name; rt.sched:after(10, done) end end
  for i = 1, 3 do d:submit("A", "control", "a" .. i, j("A" .. i)) end
  for i = 1, 3 do d:submit("B", "control", "b" .. i, j("B" .. i)) end
  rt.advance(2000)
  eq(order, { "A1", "B1", "A2", "B2", "A3", "B3" })
end)

test("dispatch: cancel removes a waiting entry (a STOP cancels a pending position)", function()
  local rt = F.new()
  local d = Dispatch.new(rt)
  local log, dropped = {}, nil
  d:submit("dev", "control", "busy", job(rt, log, "busy", 100))
  rt.advance(1)
  d:submit("dev", "control", "pos", job(rt, log, "pos"), function(r) dropped = r end)
  truthy(d:cancel("dev", "pos")); eq(dropped, "cancelled")
  rt.advance(1000)
  eq(#log, 1)
end)

test("dispatch: a request that never completes is released by the watchdog and the lane recovers", function()
  local rt = F.new()
  local d = Dispatch.new(rt, { watchdogMs = 5000 })
  local log = {}
  d:submit("dev", "control", "stuck", function(done) log[#log + 1] = "stuck" end)   -- never calls done
  d:submit("dev", "control", "next", job(rt, log, "next"))
  rt.advance(4000)
  eq(#log, 1)
  rt.advance(2000)
  eq(#log, 2)
  truthy(rt.output():find("never completed", 1, true))
end)

test("dispatch: healthy devices are not delayed beyond a request timeout by unreachable ones", function()
  local rt = F.new()
  local d = Dispatch.new(rt)
  local t0, healthyAt = rt.clock.now(), nil
  for i = 1, 3 do d:submit("dead" .. i, "poll", nil, function(done) rt.sched:after(3000, done) end) end
  d:submit("good", "control", nil, function(done) healthyAt = rt.clock.now(); rt.sched:after(50, done) end)
  rt.advance(10000)
  truthy(healthyAt - t0 <= 3100, "healthy device waited " .. tostring(healthyAt - t0))
end)

test("dispatch: an error thrown by a request is contained and frees the slot", function()
  local rt = F.new()
  local d = Dispatch.new(rt)
  local ok = false
  d:submit("dev", "control", "boom", function() error("kaboom") end)
  d:submit("dev", "control", "fine", function(done) ok = true; done() end)
  rt.advance(1000)
  truthy(ok); eq(d.running, 0)
end)

test("dispatch: after a quiet period the dispatcher holds no timers at all", function()
  local rt = F.new()
  local d = Dispatch.new(rt)
  d:submit("dev", "control", nil, job(rt, {}, "x", 10))
  rt.advance(1000)
  eq(rt.timerCount(), 1, "the shared sweeper is alive right after activity")
  rt.advance(60000)
  eq(rt.timerCount(), 0)
end)

test("dispatch: 200 sequential requests cost ONE sweeper, not a timer per request", function()
  local rt = F.new()
  local d = Dispatch.new(rt)
  local made = 0
  local orig = rt.setTimer
  rt.setTimer = function(...) made = made + 1; return orig(...) end
  for _ = 1, 200 do d:submit("dev", "poll", nil, function(done) done() end) end
  rt.advance(1000)
  truthy(made <= 3, "Control4 timers armed: " .. made)
end)
