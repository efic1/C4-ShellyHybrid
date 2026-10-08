-- Simulated Gen1 Shelly (Shelly 1, Flood SHWT-1, Smoke SHSM-01, Gas SHGS-1), behaving as the Gen1 docs describe:
-- plain HTTP only, GET /shelly open, HTTP Basic auth on everything else when a password is set, GET /status,
-- GET /relay/<n>?turn=on|off|toggle[&timer=<s>] answering with the relay object.
local F = require("tests.fakes")
local Persist = require("common.persist")
local resp = F.resp

local Sim = {}
Sim.__index = Sim

function Sim.new(rt, opts)
  opts = opts or {}
  local s = setmetatable({}, Sim)
  s.rt = rt
  s.addr = opts.addr or "192.168.1.80"
  s.mac = (opts.mac or "112233445566"):upper()
  s.id = opts.id or s.mac:lower()
  s.model = opts.model or "SHSW-1"
  s.password = opts.password
  s.mode = opts.mode or "http"              -- http | dead | blackhole
  s.gen, s.cloudGen = 1, "G1"
  s.calls, s.rejected, s.requests = {}, 0, {}
  s.status = opts.status or { mac = s.mac, relays = { { ison = false, has_timer = false, source = "input" } } }
  s.status.mac = s.status.mac or s.mac
  s.status.wifi_sta = s.status.wifi_sta or { connected = true, ip = s.addr }
  s:install()
  return s
end

function Sim:install()
  local host = "://" .. self.addr
  self.rt.http.on(function(spec) return spec.url:find(host, 1, true) end, function(spec)
    local scheme = spec.url:match("^(%a+)://")
    local path, query = (spec.url:match("^%a+://[^/]+(.*)$") or ""):match("^([^?]*)%??(.*)$")
    if self.mode == "blackhole" then return false end
    if self.mode == "dead" or scheme == "https" then return F.neterr(scheme == "https" and "connect" or "timeout") end
    self.requests[#self.requests + 1] = { path = path, query = query, auth = spec.headers and spec.headers.Authorization }
    if path == "/shelly" then
      return resp(200, { type = self.model, mac = self.mac, auth = self.password ~= nil, fw = "20230913-114003/v1.14.0-gcb84623", num_outputs = #(self.status.relays or {}) })
    end
    if self.password then
      local want = "Basic " .. Persist.b64enc("admin:" .. self.password)
      local got = spec.headers and spec.headers.Authorization
      if got ~= want then
        if got then self.rejected = self.rejected + 1 end
        return resp(401, "Unauthorized", { ["www-authenticate"] = 'Basic realm="shelly"' })
      end
    end
    if path == "/status" then return resp(200, self.status) end
    local n = path:match("^/relay/(%d+)$")
    if n then
      local relay = self.status.relays and self.status.relays[tonumber(n) + 1]
      if not relay then return resp(404, "") end
      local turn = query:match("turn=(%a+)")
      self.calls[#self.calls + 1] = { path = path .. "?" .. query }
      if turn == "on" then relay.ison = true elseif turn == "off" then relay.ison = false elseif turn == "toggle" then relay.ison = not relay.ison end
      relay.has_timer = query:find("timer=", 1, true) ~= nil
      return resp(200, relay)
    end
    return resp(404, "")
  end)
end

return Sim
