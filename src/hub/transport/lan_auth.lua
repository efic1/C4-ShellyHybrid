-- Digest authentication (RFC 7616, SHA-256) for Gen2+ device RPC, plus lockout protection.
--
-- Shelly's network guidance describes exponential back-off and lockout after failed logins on
-- newer firmware, so the rules here are hard requirements, not tuning:
--   * a 401 to a request that carried NO credentials is a normal challenge, never a failure;
--   * a rejection of credentials we supplied stops credentialed traffic to that device
--     until the password changes or the installer runs "Test LAN";
--   * after a password has worked once, ONE fresh-nonce retry is allowed (nonces expire);
--     before it has ever worked, a rejection is final at once.
-- Exact digest field details for pre-2.0.0 firmware are [Unverified] (milestone M0).
local Auth = {}
Auth.__index = Auth

function Auth.new(rt)
  return setmetatable({ rt = rt, chal = {}, stops = {}, good = {}, sent = {} }, Auth)
end

-- 'Digest qop="auth", realm="x", nonce="y", algorithm=SHA-256'
function Auth.parseChallenge(header)
  if type(header) ~= "string" then return nil, "no challenge" end
  local rest = header:match("^%s*[Dd]igest%s+(.*)$")
  if not rest then return nil, "not a digest challenge" end
  local ch = {}
  for k, v in rest:gmatch('([%w_]+)%s*=%s*"([^"]*)"') do ch[k:lower()] = v end
  for k, v in rest:gmatch('([%w_]+)%s*=%s*([^",%s]+)') do if ch[k:lower()] == nil then ch[k:lower()] = v end end
  if not ch.realm or not ch.nonce then return nil, "incomplete challenge" end
  local alg = (ch.algorithm or ""):upper()
  if alg ~= "SHA-256" then return nil, "unsupported digest algorithm " .. (ch.algorithm or "(none)") end
  if ch.qop and not ch.qop:find("auth", 1, true) then return nil, "unsupported qop" end
  ch.qop = ch.qop and "auth" or nil
  ch.stale = ch.stale and ch.stale:lower() == "true" or false
  return ch
end

function Auth:setChallenge(devId, ch) ch.nc = 0; self.chal[devId] = ch end
function Auth:hasChallenge(devId) return self.chal[devId] ~= nil end
function Auth:dropChallenge(devId) self.chal[devId] = nil end

local function hex8(rt)
  local t = {}
  for i = 1, 8 do t[i] = string.format("%x", math.floor(rt.random() * 16) % 16) end
  return table.concat(t)
end

-- Header value for a request using the cached challenge. `cnonce` is injectable for tests.
function Auth:header(devId, method, uri, user, password, cnonce)
  local ch = self.chal[devId]
  if not ch then return nil end
  local h = self.rt.hash
  ch.nc = ch.nc + 1
  local nc = string.format("%08x", ch.nc)
  cnonce = cnonce or hex8(self.rt)
  local ha1 = h("SHA256", user .. ":" .. ch.realm .. ":" .. password)
  local ha2 = h("SHA256", method .. ":" .. uri)
  local response
  if ch.qop then response = h("SHA256", ha1 .. ":" .. ch.nonce .. ":" .. nc .. ":" .. cnonce .. ":" .. ch.qop .. ":" .. ha2)
  else response = h("SHA256", ha1 .. ":" .. ch.nonce .. ":" .. ha2) end
  self.sent[devId] = (self.sent[devId] or 0) + 1
  local parts = { 'username="' .. user .. '"', 'realm="' .. ch.realm .. '"', 'nonce="' .. ch.nonce .. '"',
    'uri="' .. uri .. '"', 'algorithm=SHA-256', 'response="' .. response .. '"' }
  if ch.qop then parts[#parts + 1] = "qop=auth"; parts[#parts + 1] = "nc=" .. nc; parts[#parts + 1] = 'cnonce="' .. cnonce .. '"' end
  if ch.opaque then parts[#parts + 1] = 'opaque="' .. ch.opaque .. '"' end
  return "Digest " .. table.concat(parts, ", ")
end

-- ---- lockout protection --------------------------------------------------------------------
-- We remember a HASH of the password that failed, never the password.
function Auth:passHash(devId, password)
  return self.rt.hash("SHA256", "shelly-auth-stop:" .. devId .. ":" .. password)
end
function Auth:stop(devId, password) self.stops[devId] = self:passHash(devId, password) end
function Auth:isStopped(devId, password)
  local s = self.stops[devId]
  return s ~= nil and password ~= nil and s == self:passHash(devId, password)
end
function Auth:countSent(devId) self.sent[devId] = (self.sent[devId] or 0) + 1 end
function Auth:clear(devId) self.stops[devId] = nil end
function Auth:stopHash(devId) return self.stops[devId] end
function Auth:restoreStop(devId, hash) self.stops[devId] = hash end
function Auth:markGood(devId, password) self.good[devId] = self:passHash(devId, password) end
function Auth:wasGood(devId, password) return self.good[devId] ~= nil and self.good[devId] == self:passHash(devId, password) end
function Auth:credentialedRequests(devId) return self.sent[devId] or 0 end

return Auth
