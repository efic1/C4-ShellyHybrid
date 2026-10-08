local H = require("tests.harness")
local F = require("tests.fakes")
local test, eq, truthy, falsy = H.test, H.eq, H.truthy, H.falsy

test("sched: runs items in due order and keeps at most one Control4 timer armed", function()
  local rt = F.new()
  local order = {}
  rt.sched:after(300, function() order[#order + 1] = "c" end)
  rt.sched:after(100, function() order[#order + 1] = "a" end)
  rt.sched:after(200, function() order[#order + 1] = "b" end)
  eq(rt.timerCount(), 1, "one timer for three items")
  rt.advance(1000)
  eq(order, { "a", "b", "c" })
  eq(rt.timerCount(), 0, "idle scheduler holds no timer")
end)

test("sched: cancel prevents the callback and a cancelled head does not keep the timer", function()
  local rt = F.new()
  local hit = false
  local id = rt.sched:after(100, function() hit = true end)
  rt.sched:cancel(id)
  rt.advance(500)
  falsy(hit); eq(rt.timerCount(), 0)
end)

test("sched: every() repeats at its period and does not catch up after a stall", function()
  local rt = F.new()
  local n = 0
  rt.sched:every(100, function() n = n + 1 end)
  rt.advance(450)
  eq(n, 4)
end)

test("sched: a burst of due work is bounded per timer fire", function()
  local rt = F.new()
  rt.sched.maxPerFire = 5
  local n = 0
  for _ = 1, 12 do rt.sched:after(10, function() n = n + 1 end) end
  local before = rt.sched.fires
  rt.advance(10)
  eq(n, 5, "first fire is bounded")
  rt.advance(50)
  eq(n, 12, "all eventually run")
  truthy(rt.sched.fires - before >= 3, "spread over several fires")
end)

test("sched: an error in one callback is reported and does not stop the others", function()
  local rt = F.new()
  local ok = false
  rt.sched:after(10, function() error("boom") end)
  rt.sched:after(20, function() ok = true end)
  rt.advance(100)
  truthy(ok); eq(#rt.errors, 1)
end)

test("sched: scheduling an earlier item re-arms the timer earlier", function()
  local rt = F.new()
  local t = {}
  rt.sched:after(1000, function() t[#t + 1] = rt.clock.now() end)
  rt.sched:after(100, function() t[#t + 1] = rt.clock.now() end)
  local start = rt.clock.now()
  rt.advance(2000)
  eq(t[1] - start, 100); eq(t[2] - start, 1000)
end)
