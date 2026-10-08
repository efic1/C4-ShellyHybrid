-- Simulated Shelly Cloud (v2 control API + all_status) backed by the LAN simulators.
local F = require("tests.fakes")
local U = require("common.util")
local resp = F.resp

local M = {}

-- sims: id -> Sim. Returns a state table with `calls` (recorded requests) and knobs.
function M.install(rt, sims)
  local cloud = { calls = {}, authOk = true, down = false }
  local function statusOf(id)
    local sim = sims[id]
    local st = U.deepcopy(sim.status)
    if sim.gen == 1 then st.wifi_sta = { connected = true, ip = sim.cloudAddr or sim.addr } else st.wifi = { sta_ip = sim.cloudAddr or sim.addr } end
    return st
  end
  rt.http.on("shelly.cloud", function() return resp(404, {}) end)
  local function guard(fn)
    return function(spec)
      if cloud.down then return F.neterr("timeout") end
      if not cloud.authOk then return resp(401, {}) end
      return fn(spec)
    end
  end
  rt.http.on("/v2/devices/api/get", guard(function(spec)
    local body = rt.json.decode(spec.body)
    local out = {}
    for _, id in ipairs(body.ids) do
      local sim = sims[id]
      if sim then
        out[#out + 1] = { id = id, type = "relay", code = sim.model or "SNSW", gen = sim.cloudGen or "G2", online = sim.cloudOnline == false and 0 or 1, status = statusOf(id) }
      end
    end
    cloud.calls[#cloud.calls + 1] = { op = "get", ids = body.ids }
    return resp(200, out)
  end))
  rt.http.on("all_status", guard(function()
    if cloud.noListing then return resp(404, {}) end
    local map, n = {}, 0
    for id, sim in pairs(sims) do
      local st = statusOf(id)
      st._dev_info = { id = id, gen = sim.cloudGen or "G2", code = sim.model or "SNSW", online = sim.cloudOnline ~= false }
      n = n + 1; map["k" .. n] = st
    end
    cloud.calls[#cloud.calls + 1] = { op = "all_status" }
    return resp(200, { isok = true, data = { devices_status = map } })
  end))
  local function set(kind)
    return guard(function(spec)
      local b = rt.json.decode(spec.body)
      local sim = sims[b.id]
      cloud.calls[#cloud.calls + 1] = { op = "set", kind = kind, body = b }
      if not sim then return resp(404, { error = "DEVICE_NOT_FOUND" }) end
      if sim.cloudOnline == false then return resp(400, { error = "DEVICE_OFFLINE" }) end
      sim:applyCloud(kind, b)
      return resp(200, {})
    end)
  end
  rt.http.on("/v2/devices/api/set/switch", set("switch"))
  rt.http.on("/v2/devices/api/set/light", set("light"))
  rt.http.on("/v2/devices/api/set/cover", set("cover"))
  return cloud
end

return M
