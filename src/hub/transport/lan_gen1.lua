-- Gen1 LAN client (Shelly 1, Flood SHWT-1, Smoke SHSM-01, Gas SHGS-1). Gen1 is a plain REST/HTTP API, not JSON-RPC:
--   * GET /shelly is unauthenticated: { type, mac, auth, fw, num_outputs } (no `gen` field - that is how Gen1 is recognised);
--   * every other resource needs HTTP BASIC auth (user admin) when login is enabled; there is no HTTPS and no digest;
--   * GET /status returns the whole state (relays[], flood, smoke, gas_sensor, wifi_sta, mac ...);
--   * GET /relay/<n>?turn=on|off|toggle[&timer=<seconds>] controls a relay and answers with the relay object.
-- Same lockout policy as Gen2: one rejected password stops credentialed traffic to the device (see lan_auth.lua).
-- Commands are absolute here too (turn=on / turn=off, never toggle).
local U = require("common.util")
local Parse = require("hub.transport.parse")
local Persist = require("common.persist")

local G = {}

local function fail(class, reason, extra)
  local o = { ok = false, class = class, reason = reason }
  if extra then for k, v in pairs(extra) do o[k] = v end end
  return o
end

-- cb(outcome, decodedJson)
function G.get(lan, d, path, cb)
  if not d.address then return cb(fail("UNREACHABLE", "no LAN address")) end
  local pw = lan.passwordFor(d)
  local function go(withAuth)
    local headers, sent = {}, nil
    if withAuth and pw then
      headers.Authorization = "Basic " .. Persist.b64enc("admin:" .. pw)
      sent = pw
      lan.auth:countSent(d.id)
    end
    lan.rt.http.request({ method = "GET", url = "http://" .. d.address .. path, headers = headers,
      timeout = lan.rt.cfg.lanTimeoutS or 3, verify = false, noRedirect = true }, function(res)
      if not res.ok then return cb(fail("UNREACHABLE", tostring(res.err))) end
      local code = res.code
      if code >= 200 and code < 300 then
        if sent then lan.auth:markGood(d.id, sent) end
        local raw = res.body or ""
        if raw:match("^%s*$") or raw:match("^%s*null%s*$") then return cb({ ok = true }, {}) end
        local j = lan.rt.json.decode(raw)
        if j == nil then return cb(fail("UNREACHABLE", "unreadable response from the device")) end
        return cb({ ok = true }, j)
      elseif code == 401 or code == 403 then
        if sent then
          lan.auth:stop(d.id, sent)
          return cb(fail("AUTH", "device rejected the password", { rejected = true }))
        end
        if not pw then return cb(fail("AUTH", "device requires a password (set Device Password)", { needsPassword = true })) end
        if lan.auth:isStopped(d.id, pw) then return cb(fail("AUTH", "authentication stopped for this device (wrong password)", { rejected = true })) end
        d.authRequired = true
        return go(true)
      elseif code == 429 or code >= 500 then
        return cb(fail("UNREACHABLE", "device error HTTP " .. code))
      else
        return cb(fail("DEVICE", "HTTP " .. code))
      end
    end)
  end
  -- Basic auth is sent up front once the device is known to need it (and the password has not been rejected)
  go(d.authRequired == true and pw ~= nil and not lan.auth:isStopped(d.id, pw))
end

function G.status(lan, d, cb)
  G.get(lan, d, "/status", function(out, result)
    if not out.ok then return cb(out) end
    local ok, dev = pcall(Parse.device, { id = d.id, online = true, gen = "G1", code = d.model }, result)
    if not ok then return cb(fail("DEVICE", "unparseable status")) end
    dev.address = nil
    dev.identity = { mac = dev.identity and dev.identity.mac }
    cb(out, dev)
  end)
end

function G.set(lan, d, kind, channel, intent, cb)
  if kind ~= "switch" then return cb(fail("CONFIG", "unsupported component " .. tostring(kind) .. " on a Gen1 device")) end
  local path = string.format("/relay/%d?turn=%s", channel, intent.on and "on" or "off")
  if intent.toggle_after and intent.toggle_after > 0 then path = path .. "&timer=" .. math.max(1, math.floor(intent.toggle_after + 0.5)) end
  G.get(lan, d, path, function(out) cb(out) end)
end

return G
