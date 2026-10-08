-- Device LAN client (Gen2+ JSON-RPC over HTTP/HTTPS). The ONLY file that knows device RPC
-- methods and payloads. All wire details marked [Unverified] are exercised in milestone M0.
--
-- Rules enforced here:
--   * requests are POST /rpc/<Method> with a JSON body (parameters never appear in URLs/logs);
--   * probing uses the unauthenticated /shelly endpoint, so it can never trip a failed-login counter;
--   * redirects are followed only http -> https on the SAME host, once;
--   * commands are absolute (see Cloud.controlBody); nothing relative or toggle-like is sent;
--   * a rejection of supplied credentials is final for that device (see lan_auth.lua).
local U = require("common.util")
local Parse = require("hub.transport.parse")
local AuthMod = require("hub.transport.lan_auth")

local Lan = {}
Lan.__index = Lan

function Lan.new(rt, auth)
  local self = setmetatable({}, Lan)
  self.rt, self.auth = rt, auth
  self.passwordFor = function() return nil end     -- set by the hub: device override, else hub password
  self.verifyTls = false                            -- hub property "LAN TLS Verification"
  return self
end

local function fail(class, reason, extra)
  local o = { ok = false, class = class, reason = reason }
  if extra then for k, v in pairs(extra) do o[k] = v end end
  return o
end

-- Identity comparison. true / false / nil (cannot tell).
-- A record identifies a device by MAC, or by the trailing 12 hex digits of its id (Gen2+ ids embed
-- the MAC). [Unverified] until M0 confirms cloud ids equal the device MAC on all models.
local function macTag(x)
  if type(x) ~= "table" then return nil end
  if x.mac then return x.mac:upper() end
  local suffix = x.id and x.id:match("(%x%x%x%x%x%x%x%x%x%x%x%x)$")
  return suffix and suffix:upper() or nil
end

function Lan.sameIdentity(expected, seen)
  local a, b = macTag(expected), macTag(seen)
  if a and b then return a == b end
  return nil
end

local function bodyError(self, res)
  local j = res.body and res.body ~= "" and self.rt.json.decode(res.body)
  if type(j) == "table" then
    local e = type(j.error) == "table" and j.error or j
    if e.message or e.code then return tostring(e.message or "device error") .. (e.code and (" (" .. tostring(e.code) .. ")") or ""), j end
  end
  return "HTTP " .. tostring(res.code), j
end

-- Core request. cb(outcome, result)
function Lan:call(d, method, params, cb, opts)
  opts = opts or {}
  if not d.address then return cb(fail("UNREACHABLE", "no LAN address")) end
  local path = "/rpc/" .. method
  local body = self.rt.json.encode(params or {})
  local st = { redirected = false, challenged = false, freshRetry = false }

  local go
  local function handle(res, scheme, sent)
    if not res.ok then return cb(fail("UNREACHABLE", tostring(res.err))) end
    local code = res.code
    if code >= 200 and code < 300 then
      if sent then self.auth:markGood(d.id, sent) end
      -- Cover.* / Light.Set answer with the JSON literal null on success (Shelly docs), so null and empty are success;
      -- anything else that is not JSON is NOT (a captive portal or proxy page must not count as "done").
      local raw = res.body or ""
      local j
      if raw:match("^%s*$") or raw:match("^%s*null%s*$") then j = {}
      else
        j = self.rt.json.decode(raw)
        if j == nil then return cb(fail("UNREACHABLE", "unreadable response from the device")) end
      end
      if type(j) == "table" and type(j.error) == "table" then
        return cb(fail("DEVICE", tostring(j.error.message or "device error"), { code = j.error.code }))
      end
      if type(j) == "table" and j.result ~= nil and j.id ~= nil then j = j.result end
      return cb({ ok = true }, j)
    elseif code == 301 or code == 302 or code == 307 or code == 308 then
      local loc = res.headers and (res.headers.location or res.headers.Location)
      if scheme == "http" and not st.redirected and type(loc) == "string" and loc:find("^https://" .. U.escape_pattern(d.address)) then
        st.redirected = true
        d.scheme = "https"
        return go("https")
      end
      return cb(fail("UNREACHABLE", "unexpected redirect"))
    elseif code == 401 then
      local pw = self.passwordFor(d)
      local ch = AuthMod.parseChallenge(res.headers and (res.headers["www-authenticate"] or res.headers["WWW-Authenticate"]))
      d.authRequired = true
      if sent then
        -- our credentials were refused. A refused STALE nonce after a known-good password gets exactly one fresh-nonce retry.
        if ch and self.auth:wasGood(d.id, sent) and not st.freshRetry then
          st.freshRetry = true
          self.auth:setChallenge(d.id, ch)
          return go(scheme)
        end
        self.auth:stop(d.id, sent)
        self.auth:dropChallenge(d.id)
        return cb(fail("AUTH", "device rejected the password", { rejected = true }))
      end
      -- an ordinary challenge to an unauthenticated request
      if not ch then return cb(fail("CONFIG", "device requires an authentication method this driver does not support")) end
      if not pw then return cb(fail("AUTH", "device requires a password (set Device Password)", { needsPassword = true })) end
      if self.auth:isStopped(d.id, pw) then return cb(fail("AUTH", "authentication stopped for this device (wrong password)", { rejected = true })) end
      if st.challenged then return cb(fail("AUTH", "device keeps challenging", { rejected = true })) end
      -- The digest realm IS the device id (model-MAC). Check it BEFORE answering, so a different device that now
      -- holds this address never receives (or counts) a login attempt made with our password.
      if ch.realm and Lan.sameIdentity(d.identity or { id = d.id }, { id = U.norm_id(ch.realm) }) == false then
        return cb(fail("UNREACHABLE", "the device at this address is not the expected one (realm " .. tostring(ch.realm) .. ")",
          { identityMismatch = true, seen = { id = U.norm_id(ch.realm) } }))
      end
      st.challenged = true
      self.auth:setChallenge(d.id, ch)
      return go(scheme)
    elseif code == 403 then
      if sent then self.auth:stop(d.id, sent) end
      return cb(fail("AUTH", "access denied by device", { rejected = true }))
    elseif code == 429 then
      -- firmware 2.0+ answers 429 when its nonce table is full or after repeated failed logins: back off, don't blame the command
      return cb(fail("UNREACHABLE", "device is throttling requests (HTTP 429)"))
    elseif code >= 500 then
      return cb(fail("UNREACHABLE", "device error HTTP " .. code))
    else
      local msg, j = bodyError(self, res)
      return cb(fail("DEVICE", msg, { code = type(j) == "table" and j.code or nil }))
    end
  end

  function go(scheme)
    local headers = { ["Content-Type"] = "application/json" }
    local sent
    local pw = self.passwordFor(d)
    if d.authRequired ~= false and pw and self.auth:hasChallenge(d.id) and not self.auth:isStopped(d.id, pw) then
      headers.Authorization = self.auth:header(d.id, "POST", path, "admin", pw)
      sent = pw
    end
    self.rt.http.request({
      method = "POST", url = scheme .. "://" .. d.address .. path, headers = headers, body = body,
      timeout = opts.timeout or self.rt.cfg.lanTimeoutS or 3, verify = self.verifyTls, noRedirect = true,
    }, function(res) handle(res, scheme, sent) end)
  end

  go(d.scheme or "http")
end

-- Unauthenticated probe: detects scheme, identity, whether auth is required. cb(outcome, info)
function Lan:probe(d, cb)
  if not d.address then return cb(fail("UNREACHABLE", "no LAN address")) end
  local order = d.scheme == "https" and { "https", "http" } or { "http", "https" }
  local idx, redirected, lastErr = 1, false, "no answer"
  local function try(scheme)
    self.rt.http.request({
      method = "GET", url = scheme .. "://" .. d.address .. "/shelly", headers = {},
      timeout = self.rt.cfg.lanTimeoutS or 3, verify = self.verifyTls, noRedirect = true,
    }, function(res)
      if res.ok and res.code == 200 then
        local j = self.rt.json.decode(res.body or "")
        if type(j) ~= "table" then return cb(fail("UNREACHABLE", "not a Shelly response")) end
        local gen = tonumber(j.gen)
        if gen == nil and j.type and not j.id then
          -- Gen1: /shelly = { type, mac, auth, fw, num_outputs } and no `gen`. Plain HTTP only, Basic auth.
          d.gen, d.scheme, d.model = 1, "http", tostring(j.type)
          if type(j.auth) == "boolean" then d.authRequired = j.auth end
          return cb({ ok = true }, { scheme = "http", identity = { mac = U.normalize_mac(j.mac) }, authRequired = j.auth, gen = 1, fw = j.fw })
        end
        if gen and gen < 2 then return cb(fail("CONFIG", "Gen0 device at this address (unsupported)")) end
        d.gen = gen or 2
        d.scheme = (j.enhanced_security == true) and "https" or scheme      -- firmware 2.0 Enhanced Security: HTTPS on 443
        if type(j.auth_en) == "boolean" then d.authRequired = j.auth_en end
        if type(j.profile) == "string" then d.profile = j.profile end          -- multi-profile devices (Plus 2PM, RGBW PM, ...)
        local ident = { id = U.norm_id(j.id), mac = U.normalize_mac(j.mac) }
        return cb({ ok = true }, { scheme = scheme, identity = ident, authRequired = j.auth_en, gen = gen, fw = j.ver or j.fw_id })
      elseif res.ok and (res.code == 301 or res.code == 302 or res.code == 307 or res.code == 308) then
        local loc = res.headers and (res.headers.location or res.headers.Location)
        if scheme == "http" and not redirected and type(loc) == "string" and loc:find("^https://" .. U.escape_pattern(d.address)) then
          redirected = true
          return try("https")
        end
        lastErr = "unexpected redirect"
      else
        lastErr = res.ok and ("HTTP " .. res.code) or tostring(res.err)
      end
      idx = idx + 1
      if order[idx] and not redirected then return try(order[idx]) end
      return cb(fail("UNREACHABLE", lastErr))
    end)
  end
  try(order[1])
end

-- Full status read. cb(outcome, normalisedDevice)
function Lan:status(d, cb)
  if d.gen == 1 then return require("hub.transport.lan_gen1").status(self, d, cb) end
  self:call(d, "Shelly.GetStatus", {}, function(out, result)
    if not out.ok then return cb(out) end
    local ok, dev = pcall(Parse.device, { id = d.id, online = true }, result)
    if not ok then return cb(fail("DEVICE", "unparseable status")) end
    dev.address = nil                        -- the LAN address we used is authoritative
    dev.identity = { mac = dev.identity and dev.identity.mac }   -- GetStatus proves identity by MAC only; never echo our own id back
    cb(out, dev)
  end)
end

-- Absolute command for one component. intent per Cloud.controlBody. cb(outcome)
function Lan:set(d, kind, channel, intent, cb)
  if d.gen == 1 then return require("hub.transport.lan_gen1").set(self, d, kind, channel, intent, cb) end
  local method, params
  if kind == "switch" then
    method, params = "Switch.Set", { id = channel, on = intent.on and true or false, toggle_after = intent.toggle_after }
  elseif kind == "light" then
    if intent.level ~= nil then
      if intent.level <= 0 then params = { id = channel, on = false }
      else params = { id = channel, on = true, brightness = U.clamp(U.round(intent.level), 1, 100) } end
    else params = { id = channel, on = intent.on and true or false } end
    -- The proxy's RATE (ms) is the requested transition. Light.Set takes transition_duration in seconds (one-time override);
    -- below the device's 0.5 s minimum the request is left to the device's configured transition.
    if intent.rate and intent.rate >= 500 then params.transition_duration = U.clamp(intent.rate / 1000, 0.5, 10800) end
    method = "Light.Set"
  elseif kind == "cover" then
    if intent.cover == "open" then method, params = "Cover.Open", { id = channel }
    elseif intent.cover == "close" then method, params = "Cover.Close", { id = channel }
    elseif intent.cover == "stop" then method, params = "Cover.Stop", { id = channel }
    else method, params = "Cover.GoToPosition", { id = channel, pos = U.clamp(U.round(intent.position), 0, 100) } end
  else
    return cb(fail("CONFIG", "unsupported component " .. tostring(kind)))
  end
  self:call(d, method, params, function(out) cb(out) end)
end

return Lan
