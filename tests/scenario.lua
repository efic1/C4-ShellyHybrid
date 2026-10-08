-- Shared system builder for the driver-level tests.
local Director = require("tests.director")
local Sim = require("tests.lan_sim")
local Gen1Sim = require("tests.gen1_sim")
local CloudSim = require("tests.cloud_sim")
local H = require("tests.harness")
local eq, not_contains = H.eq, H.not_contains

local KEY = "0123456789cloudkey"
local DEVICES = {
  { id = "aa0000000001", addr = "192.168.1.41", status = { ["light:0"] = { id = 0, output = false, brightness = 50 } } },
  { id = "aa0000000002", addr = "192.168.1.42", status = { ["switch:0"] = { id = 0, output = false }, ["switch:1"] = { id = 1, output = true } } },
  { id = "aa0000000003", addr = "192.168.1.43", status = { ["cover:0"] = { id = 0, state = "stopped", current_pos = 30 } } },
}

-- Build a whole system. opts: switchType, store, props, noSetup, cloudDown
local function system(opts)
  opts = opts or {}
  local dir = Director.new({ latency = 10 })
  local S = { dir = dir, sims = {} }
  for _, d in ipairs(opts.devices or DEVICES) do
    if d.gen1 then
      local st = {}
      for k, v in pairs(d.status) do st[k] = require("common.util").deepcopy(v) end
      S.sims[d.id] = Gen1Sim.new(dir.rt, { addr = d.addr, mac = d.id:upper(), id = d.id, model = d.gen1, status = st, password = d.password })
    else
    local st = { sys = { mac = d.id:upper() }, wifi = { sta_ip = d.addr } }
    for k, v in pairs(d.status) do st[k] = require("common.util").deepcopy(v) end
    S.sims[d.id] = Sim.new(dir.rt, { addr = d.addr, mac = d.id:upper(), id = "shelly-" .. d.id, status = st })
    end
    for k, v in pairs(d.sim or {}) do S.sims[d.id][k] = v end
    dir.sims[d.id] = S.sims[d.id]
  end
  S.cloud = CloudSim.install(dir.rt, dir.sims)
  if opts.cloudDown then S.cloud.down = true end
  S.hub = dir:load("shelly_hub", { store = opts.store, props = opts.props })
  if not opts.noSetup then
    S.hub:setProp("Server", "shelly-42-eu.shelly.cloud")
    S.hub:setProp("Authorization Key", KEY)
    if opts.switchType then S.hub:setProp("Switch Default Type", opts.switchType) end
    dir:advance(3000)
    S.hub:action("Fetch Devices")
    dir:advance(3000)
    S.hub:action("Auto-Setup Children")
    dir:advance(15000)
  end
  function S.light() return dir:byFile("shelly_light") end
  function S.blind() return dir:byFile("shelly_blind") end
  function S.onoff() return dir:all("shelly_light_onoff") end
  function S.relays() return dir:all("shelly_relay") end
  function S.lanCalls(id, method)
    local n = 0
    for _, c in ipairs(S.sims[id].calls) do if not method or c.method == method then n = n + 1 end end
    return n
  end
  function S.cloudSets()
    local n = 0
    for _, c in ipairs(S.cloud.calls) do if c.op == "set" then n = n + 1 end end
    return n
  end
  return S
end

local function assertClean(S, allowLoggedErrors)
  for _, inst in ipairs(S.dir:all()) do
    local out = inst:output()
    if not allowLoggedErrors then not_contains(out, "ERROR:", inst.file .. " logged an error:\n" .. out) end
    not_contains(out, "Control4 call failed")
  end
  eq(#S.dir.rt.errors, 0, "internal errors: " .. table.concat(S.dir.rt.errors, "; "))
end


return { system = system, assertClean = assertClean, KEY = KEY, DEVICES = DEVICES }
