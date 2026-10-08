-- Soak: a mixed, misbehaving fleet for N simulated hours. Reports memory growth, persist writes, log volume,
-- Director-bound calls and HTTP requests per hour. Run: python3 tools/build.py --quiet && lua5.1 tests/soak.lua [hours] [devices]
package.path = "./src/?.lua;./?.lua;" .. package.path
local Sc = require("tests.scenario")
local hours = tonumber(arg and arg[1]) or 3
local n = tonumber(arg and arg[2]) or 30

local devs = {}
local function add(d) devs[#devs + 1] = d end
for i = 1, n do
  local id = string.format("aa%010d", i)
  local addr = "192.168.1." .. (10 + i)
  local k = i % 6
  if k == 0 then add({ id = id, addr = addr, status = { ["cover:0"] = { id = 0, state = "stopped", current_pos = 30 } } })
  elseif k == 1 then add({ id = id, addr = addr, status = { ["light:0"] = { id = 0, output = false, brightness = 50 } } })
  elseif k == 2 then add({ id = id, addr = addr, status = { ["switch:0"] = { id = 0, output = false }, ["switch:1"] = { id = 1, output = true } } })
  elseif k == 3 then add({ id = id, addr = addr, gen1 = "SHSW-1", status = { relays = { { ison = false } }, inputs = { { input = 0 } } } })
  elseif k == 4 then add({ id = id, addr = addr, gen1 = "SHWT-1", sim = { cloudOnline = false }, status = { flood = false, bat = { value = 80 }, is_valid = true, sensor_error = 0 } })
  else add({ id = id, addr = addr, gen1 = "SHGS-1", status = { gas_sensor = { sensor_state = "normal", self_test_state = "not_completed", alarm_state = "none" }, concentration = { ppm = 3, is_valid = true } } }) end
end
local flap = devs[1]; flap.id = flap.id
local S = Sc.system({ devices = devs, props = { ["Contact Inputs"] = "aa0000000004" } })
S.dir:advance(60000)

local function mem() collectgarbage(); collectgarbage(); return collectgarbage("count") end
local function sum(f) local t = 0; for _, i in ipairs(S.dir:all()) do t = t + f(i) end; return t end
local function logs(i) return #i.out end
local base = mem()
print(string.format("devices=%d instances=%d baseline=%.0f KB", n, #S.dir:all(), base))
local function census(root)
  local seen, counts = {}, {}
  local function walk(t, path, depth)
    if seen[t] or depth > 7 then return end
    seen[t] = true
    local c = 0
    for k, v in pairs(t) do
      c = c + 1
      if type(v) == "table" then walk(v, path .. "." .. tostring(k):sub(1, 24), depth + 1) end
    end
    counts[path] = c
  end
  walk(root, "env", 0)
  return counts
end
_G.__census = census
print("hour  memKB   hubCalls  kidCalls  persistSet  logLines  http")
local http0 = #S.dir.rt.http.log
local lastHub, lastKid, lastPS, lastLog, lastHttp = 0, 0, 0, 0, http0
local floodId, flapSim = nil, S.sims[devs[2].id]
for id, s in pairs(S.sims) do if s.model == "SHWT-1" then floodId = id end end
local light = S.dir:byFile("shelly_light")
local minute = 0
local snaps = {}
for h = 1, hours do
  for m = 1, 60 do
    minute = minute + 1
    local ph = minute % 7
    flapSim.mode = (ph >= 5) and "dead" or "http"
    if minute % 30 == 0 then S.cloud.down = not S.cloud.down end
    if minute % 5 == 0 and light then light:proxy(5001, (minute % 10 == 0) and "ON" or "OFF") end
    if minute % 11 == 0 and floodId then S.sims[floodId].status.flood = not S.sims[floodId].status.flood end
    S.dir:advance(60000)
  end
  local hub = S.hub
  local kid = sum(function(i) return i.file ~= "shelly_hub" and i.total or 0 end)
  local ps = sum(function(i) return i.calls.PersistSetValue or 0 end)
  local lg = sum(logs)
  local hp = #S.dir.rt.http.log
  -- the harness records every request; clear it so memory numbers measure the DRIVER only
  for k in pairs(S.dir.rt.http.log) do S.dir.rt.http.log[k] = nil end
  lastHttp = 0
  for _, s in pairs(S.sims) do s.calls, s.requests = {}, {} end
  S.cloud.calls = {}
  for _, i in ipairs(S.dir:all()) do i.notes, i.sent, i.fired, i.out = {}, {}, {}, {} end
  if h == 2 or h == hours then snaps[#snaps + 1] = census(S.hub.env) end
  print(string.format("%-5d %-7.0f %-9d %-9d %-11d %-9d %d", h, mem(), hub.total - lastHub, kid - lastKid, ps - lastPS, lg - lastLog, hp - lastHttp))
  lastHub, lastKid, lastPS, lastLog = hub.total, kid, ps, lg
end
print(string.format("memory growth: %.0f KB over %d h", mem() - base, hours))
print("hub timers held:", S.hub.timers, " internal errors:", #S.dir.rt.errors)
local big, bn = nil, 0
for _, i in ipairs(S.dir:all()) do if #i.out > bn then big, bn = i, #i.out end end
if big then print("largest log:", big.file, bn, "lines") end
local keys = {}
for k in pairs(S.hub.calls) do keys[#keys + 1] = k end
table.sort(keys)
local parts = {}
for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. S.hub.calls[k] end
print("hub calls by type (whole run): " .. table.concat(parts, " "))

if #snaps == 2 then
  local diffs = {}
  for p, c in pairs(snaps[2]) do local d = c - (snaps[1][p] or 0); if d ~= 0 then diffs[#diffs + 1] = { p, d, c } end end
  table.sort(diffs, function(a, b) return a[2] > b[2] end)
  print("-- hub tables that grew between hour 2 and the end (path, delta, size) --")
  for i = 1, math.min(12, #diffs) do print(diffs[i][1], diffs[i][2], diffs[i][3]) end
end
