-- Director-load profile. Prints the number of Director-bound API calls for the scenarios that matter.
-- Run:  python3 tools/build.py && lua5.1 tests/profile.lua      (also asserted in tests/test_regressions.lua)
package.path = "./src/?.lua;./?.lua;" .. package.path
local Sc = require("tests.scenario")
local P = {}

local function devices(n)
  local out = {}
  for i = 1, n do
    out[i] = { id = string.format("aa%010d", i), addr = "192.168." .. (1 + math.floor(i / 200)) .. "." .. (10 + i % 200),
      status = (i % 3 == 0) and { ["cover:0"] = { id = 0, state = "stopped", current_pos = 30 } }
        or (i % 3 == 1) and { ["light:0"] = { id = 0, output = false, brightness = 50 } }
        or { ["switch:0"] = { id = 0, output = false }, ["switch:1"] = { id = 1, output = true } } }
  end
  return out
end

function P.big(n)
  local S = Sc.system({ devices = devices(n) })
  S.dir:advance(120000)
  return S
end

local function row(name, inst) 
  local keys = {}
  for k in pairs(inst.calls) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. inst.calls[k] end
  return string.format("%-34s total=%-4d %s", name, inst.total, table.concat(parts, " "))
end
P.row = row

if arg and arg[0] and arg[0]:find("profile.lua", 1, true) then
  local Director = require("tests.director")
  print("== init cost (Director-bound calls during OnDriverInit + LateInit) ==")
  local d = Director.new()
  print(row("hub, empty", d:load("shelly_hub")))
  print(row("light child, unconfigured", d:load("shelly_light")))
  print(row("blind child, unconfigured", d:load("shelly_blind")))
  print(row("relay child, unconfigured", d:load("shelly_relay")))

  print("\n== steady state: 40 devices, nothing changing, 10 minutes ==")
  local S = P.big(40)
  local kids = 0
  for _, c in ipairs(S.dir:all()) do if c.file ~= "shelly_hub" then kids = kids + 1 end end
  print("children:", kids)
  for _, i in ipairs(S.dir:all()) do i:resetCounts() end
  local http0 = #S.dir.rt.http.log
  S.dir:advance(600000)
  local kidCalls = 0
  for _, c in ipairs(S.dir:all()) do if c.file ~= "shelly_hub" then kidCalls = kidCalls + c.total end end
  print(row("hub", S.hub))
  print("all children combined total=" .. kidCalls)
  print(string.format("network requests in 10 min: %d (%.1f/s), max LAN in flight %d",
    #S.dir.rt.http.log - http0, (#S.dir.rt.http.log - http0) / 600, S.dir.rt.http.maxInflight))
  print("Control4 timers held by the hub:", S.hub.timers)

  print("\n== one dimmer command, 40 devices ==")
  local l = S.dir:byFile("shelly_light")
  for _, i in ipairs(S.dir:all()) do i:resetCounts() end
  l:proxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60 })
  S.dir:advance(3000)
  print(row("light child", l))
  print(row("hub", S.hub))
end

return P
