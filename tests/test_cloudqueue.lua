local H = require("tests.harness")
local F = require("tests.fakes")
local Queue = require("hub.transport.cloudqueue")
local test, eq, truthy, falsy = H.test, H.eq, H.truthy, H.falsy

-- entry whose run() records its start time and finishes with `outcome` after `ms`
local function job(rt, log, name, prio, outcome, ms, extra)
  local e = { prio = prio, key = extra and extra.key, mergeKey = extra and extra.mergeKey,
    run = function(list, finish)
      log[#log + 1] = { name = name, at = rt.clock.now(), n = #list }
      rt.sched:after(ms or 10, function() finish(outcome or { ok = true }) end)
    end,
    cb = function(out) log[#log + 1] = { cb = name, ok = out.ok, class = out.class } end }
  return e
end

test("cloudqueue: requests start at least 1.2 s apart and never overlap", function()
  local rt = F.new()
  local q = Queue.new(rt)
  local log = {}
  for i = 1, 4 do q:enqueue(job(rt, log, "j" .. i, "control", nil, 300)) end
  rt.advance(10000)
  local starts = {}
  for _, l in ipairs(log) do if l.name then starts[#starts + 1] = l.at end end
  eq(#starts, 4)
  for i = 2, 4 do H.truthy(starts[i] - starts[i - 1] >= 1200, "gap " .. i) end
end)

test("cloudqueue: an idle gate starts the first request immediately", function()
  local rt = F.new()
  local q = Queue.new(rt)
  local log = {}
  local t0 = rt.clock.now()
  q:enqueue(job(rt, log, "a", "control"))
  eq(log[1].at, t0)
end)

test("cloudqueue: control beats verify beats background, regardless of arrival order", function()
  local rt = F.new()
  local q = Queue.new(rt)
  local log = {}
  q:enqueue(job(rt, log, "first", "background"))     -- starts immediately
  q:enqueue(job(rt, log, "bg", "background"))
  q:enqueue(job(rt, log, "verify", "verify"))
  q:enqueue(job(rt, log, "ctl", "control"))
  rt.advance(20000)
  local order = {}
  for _, l in ipairs(log) do if l.name then order[#order + 1] = l.name end end
  eq(order, { "first", "ctl", "verify", "bg" })
end)

test("cloudqueue: a waiting entry with the same key is replaced by the newest, the old one is told", function()
  local rt = F.new()
  local q = Queue.new(rt)
  local log = {}
  q:enqueue(job(rt, log, "busy", "control"))
  q:enqueue(job(rt, log, "old", "control", nil, 10, { key = "k" }))
  q:enqueue(job(rt, log, "new", "control", nil, 10, { key = "k" }))
  rt.advance(20000)
  local ran, superseded = {}, false
  for _, l in ipairs(log) do
    if l.name then ran[#ran + 1] = l.name end
    if l.cb == "old" and l.class == "SUPERSEDED" then superseded = true end
  end
  eq(ran, { "busy", "new" }); truthy(superseded)
end)

test("cloudqueue: a request already in flight is never replaced by a newer same-key entry", function()
  local rt = F.new()
  local q = Queue.new(rt)
  local log = {}
  q:enqueue(job(rt, log, "inflight", "control", nil, 500, { key = "k" }))
  q:enqueue(job(rt, log, "next", "control", nil, 10, { key = "k" }))
  rt.advance(20000)
  local ran = {}
  for _, l in ipairs(log) do if l.name then ran[#ran + 1] = l.name end end
  eq(ran, { "inflight", "next" })
end)

test("cloudqueue: control entries with the same mergeKey run as ONE request", function()
  local rt = F.new()
  local q = Queue.new(rt)
  local log = {}
  q:enqueue(job(rt, log, "busy", "control"))
  for i = 1, 3 do q:enqueue(job(rt, log, "m" .. i, "control", nil, 10, { mergeKey = "switch|off", key = "k" .. i })) end
  q:enqueue(job(rt, log, "other", "control", nil, 10, { mergeKey = "switch|on", key = "k9" }))
  rt.advance(20000)
  local runs = {}
  for _, l in ipairs(log) do if l.name then runs[#runs + 1] = l.name .. ":" .. l.n end end
  eq(runs, { "busy:1", "m1:3", "other:1" })
end)

test("cloudqueue: 429 backs the whole queue off (5s, 10s, 20s, 60s cap), retries the entry, and recovers", function()
  local rt = F.new()
  local q = Queue.new(rt)
  local log, n = {}, 0
  q:enqueue({ prio = "control", run = function(list, finish)
    n = n + 1; log[#log + 1] = rt.clock.now()
    rt.sched:after(10, function() finish(n < 3 and { ok = false, class = "RATE" } or { ok = true }) end)
  end, cb = function(out) log.final = out.ok end })
  rt.advance(60000)
  eq(n, 3); truthy(log.final)
  truthy(log[2] - log[1] >= 5000); truthy(log[3] - log[2] >= 10000)
  eq(q.backoffIdx, 0, "success resets the back-off")
end)

test("cloudqueue: authentication failure stops ALL cloud traffic and fails what is waiting, once", function()
  local rt = F.new()
  local q = Queue.new(rt)
  local log = {}
  q:enqueue(job(rt, log, "bad", "control", { ok = false, class = "AUTH", reason = "no" }))
  q:enqueue(job(rt, log, "w1", "control"))
  q:enqueue(job(rt, log, "w2", "background"))
  rt.advance(30000)
  local ran, authFails = {}, 0
  for _, l in ipairs(log) do
    if l.name then ran[#ran + 1] = l.name end
    if l.cb and l.class == "AUTH" then authFails = authFails + 1 end
  end
  eq(ran, { "bad" }, "nothing runs after the stop")
  eq(authFails, 3)
  falsy(q:enqueue(job(rt, log, "later", "control")))
  q:resume()
  truthy(q:enqueue(job(rt, log, "after resume", "control")))
end)

test("cloudqueue: depth is bounded; background is shed first; control overflow fails loudly", function()
  local rt = F.new()
  local q = Queue.new(rt, { max = 5 })
  local log = {}
  q:enqueue(job(rt, log, "busy", "control", nil, 100000))
  for i = 1, 4 do q:enqueue(job(rt, log, "bg" .. i, "background")) end
  eq(q:depth(), 4)
  q:enqueue(job(rt, log, "c1", "control"))
  eq(q:depth(), 5)
  q:enqueue(job(rt, log, "c2", "control"))            -- sheds bg1
  eq(q:depth(), 5)
  local shed
  for _, l in ipairs(log) do if l.cb == "bg1" and l.class == "CLOUD" then shed = true end end
  truthy(shed)
  for i = 3, 6 do q:enqueue(job(rt, log, "c" .. i, "control")) end   -- all bg gone, then full
  local rejected
  for _, l in ipairs(log) do if l.cb and l.cb:match("^c%d") and l.class == "CLOUD" then rejected = true end end
  truthy(rejected)
  eq(q:depth() <= 5, true)
end)

test("cloudqueue: control traffic cannot starve a background entry beyond its staleness deadline", function()
  local rt = F.new()
  local q = Queue.new(rt)
  local log = {}
  q:enqueue(job(rt, log, "busy", "control"))
  local bg = job(rt, log, "poll", "background"); bg.staleAfter = 3000
  q:enqueue(bg)
  for i = 1, 8 do q:enqueue(job(rt, log, "c" .. i, "control")) end
  rt.advance(60000)
  local pos
  local i = 0
  for _, l in ipairs(log) do if l.name then i = i + 1; if l.name == "poll" then pos = i end end end
  truthy(pos and pos < 9, "poll ran before the control flood drained (position " .. tostring(pos) .. ")")
end)

test("cloudqueue: requests-per-minute counter tracks recent starts only", function()
  local rt = F.new()
  local q = Queue.new(rt)
  local log = {}
  for i = 1, 3 do q:enqueue(job(rt, log, "j" .. i, "control")) end
  rt.advance(5000)
  eq(q:requestsLastMinute(), 3)
  rt.advance(61000)
  eq(q:requestsLastMinute(), 0)
end)

test("cloudqueue: an idle queue holds no timers", function()
  local rt = F.new()
  local q = Queue.new(rt)
  q:enqueue(job(rt, {}, "a", "control"))
  rt.advance(10000)
  eq(rt.timerCount(), 0)
end)

test("cloudqueue: a request that never completes is released by the watchdog and the queue keeps going", function()
  local rt = F.new()
  local q = Queue.new(rt, { watchdogMs = 5000 })
  local log = {}
  q:enqueue({ prio = "control", run = function() end, cb = function(o) log[#log + 1] = o.reason end })
  q:enqueue(job(rt, log, "next", "control"))
  rt.advance(20000)
  eq(log[1], "request timed out")
  local ran
  for _, l in ipairs(log) do if type(l) == "table" and l.name == "next" then ran = true end end
  truthy(ran)
end)
