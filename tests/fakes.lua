-- Fake runtime ("rt") used by every offline test: fake clock and timers, scriptable HTTP,
-- pure-Lua JSON, real SHA-256 (via sha256sum), and an optionally delayed persistence store.
local Sched = require("common.sched")
local Log = require("common.log")
local json = require("tests.lib.json")

local F = {}

local sha_cache = {}
local function sha256(data)
  local hit = sha_cache[data]
  if hit then return hit end
  local path = os.tmpname()
  local f = assert(io.open(path, "wb")); f:write(data); f:close()
  local p = assert(io.popen("sha256sum " .. path))
  local out = p:read("*l"); p:close(); os.remove(path)
  local hex = out:match("^(%x+)")
  sha_cache[data] = hex
  return hex
end
F.sha256 = sha256

function F.resp(code, body, headers)
  if type(body) == "table" then body = json.encode(body) end
  return { ok = true, code = code, body = body or "", headers = headers or {} }
end
function F.neterr(kind) return { ok = false, err = kind or "connect" } end

function F.new(opts)
  opts = opts or {}
  local rt = { cfg = {} }
  local now = opts.start or 1000000
  local offset = 0                                    -- wall-clock step (NTP) applied on top of elapsed time
  local timers = {}

  rt.clock = { now = function() return now + offset end }
  function rt.stepClock(delta) offset = offset + delta end
  function rt.setTimer(ms, fn)
    local t = { due = now + ms, fn = fn }
    timers[#timers + 1] = t
    return { cancel = function() t.cancelled = true end }
  end
  rt.timerCount = function() local n = 0 for _, t in ipairs(timers) do if not t.cancelled and not t.done then n = n + 1 end end return n end

  function rt.advance(ms)
    local target = now + ms
    while true do
      local best
      for _, t in ipairs(timers) do
        if not t.cancelled and not t.done and t.due <= target and (not best or t.due < best.due) then best = t end
      end
      if not best then break end
      if best.due > now then now = best.due end
      best.done = true
      best.fn()
    end
    now = target
    for i = #timers, 1, -1 do if timers[i].cancelled or timers[i].done then table.remove(timers, i) end end
  end
  function rt.settle() rt.advance(0) end

  function rt.everyNative(ms, fn)
    local cancelled, h = false, nil
    local function arm()
      h = rt.setTimer(ms, function()
        if cancelled then return end
        local ok, err = pcall(fn)
        if not ok then rt.onError(err) end
        arm()
      end)
    end
    arm()
    return { cancel = function() cancelled = true; if h then h.cancel() end end }
  end

  rt.errors = {}
  rt.onError = function(e) rt.errors[#rt.errors + 1] = tostring(e) end
  rt.sched = Sched.new(rt)
  rt.json = json
  rt.hash = function(_, data) return sha256(data) end

  rt.lines = {}
  rt.log = Log.new({ name = "t", level = opts.level or "Debug", clock = rt.clock.now,
    sink = function(l) rt.lines[#rt.lines + 1] = l end })
  function rt.output() return table.concat(rt.lines, "\n") end

  -- persistence store, optionally delayed
  local committed, pending = {}, {}
  rt.store = {}
  function rt.store.set(k, v)
    if opts.storeDelay then
      pending[#pending + 1] = { k = k, v = v }
      rt.sched:after(opts.storeDelay, function()
        for i, p in ipairs(pending) do if p.k == k and p.v == v then committed[k] = v; table.remove(pending, i); break end end
      end)
    else committed[k] = v end
  end
  function rt.store.get(k) return committed[k] end
  function rt.store.delete(k) committed[k] = nil end
  rt.committed = committed

  -- scriptable HTTP
  local http = { log = {}, routes = {}, latency = opts.latency or 20, inflight = 0, maxInflight = 0 }
  function http.on(match, fn)
    table.insert(http.routes, 1, { match = match, fn = fn })
  end
  function http.reset() http.routes = {}; http.log = {} end
  function http.count(pat)
    local n = 0
    for _, s in ipairs(http.log) do if s.url:find(pat, 1, true) then n = n + 1 end end
    return n
  end
  function http.request(spec, cb)
    http.log[#http.log + 1] = { method = spec.method, url = spec.url, body = spec.body, headers = spec.headers, at = now, spec = spec }
    local res
    for _, r in ipairs(http.routes) do
      local ok = type(r.match) == "function" and r.match(spec) or (type(r.match) == "string" and spec.url:find(r.match, 1, true))
      if ok then res = r.fn(spec); break end
    end
    if res == nil then res = F.neterr("connect") end
    if res == false then return end               -- black hole: never answers
    http.inflight = http.inflight + 1
    if http.inflight > http.maxInflight then http.maxInflight = http.inflight end
    local delay = http.latency
    if type(res) == "table" and res.delay then delay = res.delay end
    rt.sched:after(delay, function() http.inflight = http.inflight - 1; cb(res) end)
  end
  rt.http = http

  rt.random = function() return 0.5 end
  return rt
end

return F
