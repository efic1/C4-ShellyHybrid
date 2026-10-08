-- A scriptable simulated Gen2 device for LAN tests: /shelly, /rpc/<Method>, optional SHA-256 digest
-- auth verified with an independent implementation, HTTP->HTTPS redirect and refuse-plain-HTTP modes.
local F = require("tests.fakes")
local resp = F.resp

local Sim = {}
Sim.__index = Sim

function Sim.new(rt, opts)
  opts = opts or {}
  local s = setmetatable({}, Sim)
  s.rt = rt
  s.addr = opts.addr or "192.168.1.40"
  s.mac = opts.mac or "B48A0A1CD978"
  s.id = opts.id or ("shellyplus1pm-" .. s.mac:lower())
  s.password = opts.password             -- nil => authentication off
  s.mode = opts.mode or "http"           -- http | redirect | https-only | dead
  s.nonce = "nonce-0001"
  s.nonceN = 1
  s.calls = {}                           -- accepted RPC calls { method, params }
  s.rejected = 0                         -- credentialed requests that failed verification
  s.challenges = 0
  s.status = opts.status or {
    sys = { mac = s.mac }, ["switch:0"] = { id = 0, output = false },
    ["light:0"] = { id = 0, output = true, brightness = 50 },
    ["cover:0"] = { id = 0, state = "stopped", current_pos = 30, pos_control = true },
    wifi = { sta_ip = s.addr },
  }
  s.errorFor = {}                        -- method -> { code, message } to simulate device-level errors
  s.gen = opts.gen or 2
  s.profile = opts.profile                  -- multi-profile devices report their profile in /shelly (Plus 2PM: switch|cover, RGBW PM: light|rgb|rgbw)
  s.enhanced = opts.enhanced                -- firmware 2.0 Enhanced Security: port 80 redirects everything to HTTPS
  s.lightTransition = opts.lightTransition  -- Light.Set starts a transition; status shows the moving value + transition.target
  s.throttle = opts.throttle                -- answer 429 (nonce table full / brute-force protection)
  s:install()
  return s
end

-- Mutate the simulated device the way the real one would.
function Sim:applyRpc(method, p)
  local st = self.status
  local kind = method:match("^(%a+)%.")
  if not kind or not st[kind:lower() .. ":" .. tostring(p.id)] then return end   -- unknown channel: nothing changes
  if method == "Switch.Set" then st["switch:" .. p.id].output = p.on
  elseif method == "Light.Set" then
    local l = st["light:" .. p.id]
    if self.lightTransition then
      l.transition = { target = { output = p.on, brightness = p.brightness or l.brightness }, started_at = 0, duration = 3 }
    else
      l.output = p.on
      if p.brightness then l.brightness = p.brightness end
    end
  elseif method == "Cover.GoToPosition" then
    local c = st["cover:" .. p.id]
    c.target_pos = p.pos
    c.state = (p.pos > (c.current_pos or 0)) and "opening" or "closing"
  elseif method == "Cover.Open" then local c = st["cover:" .. p.id]; c.target_pos = 100; c.state = "opening"
  elseif method == "Cover.Close" then local c = st["cover:" .. p.id]; c.target_pos = 0; c.state = "closing"
  elseif method == "Cover.Stop" then st["cover:" .. p.id].state = "stopped"; st["cover:" .. p.id].target_pos = nil
  end
end

-- End a light transition: the moving value reaches the target.
function Sim:finishTransition(ch)
  local l = self.status["light:" .. (ch or 0)]
  if l.transition then
    l.output, l.brightness = l.transition.target.output, l.transition.target.brightness
    l.transition = nil
  end
end

function Sim:applyCloud(kind, b)
  local ch = b.channel or 0
  if kind == "switch" then self:applyRpc("Switch.Set", { id = ch, on = b.on })
  elseif kind == "light" then self:applyRpc("Light.Set", { id = ch, on = b.on, brightness = b.brightness })
  elseif kind == "cover" then
    if b.position == "open" then self:applyRpc("Cover.Open", { id = ch })
    elseif b.position == "close" then self:applyRpc("Cover.Close", { id = ch })
    elseif b.position == "stop" then self:applyRpc("Cover.Stop", { id = ch })
    else self:applyRpc("Cover.GoToPosition", { id = ch, pos = b.position }) end
  end
end

function Sim:finishMove(ch)
  local c = self.status["cover:" .. (ch or 0)]
  if c.target_pos then
    c.current_pos = c.target_pos
    c.state = c.target_pos == 100 and "open" or (c.target_pos == 0 and "closed" or "stopped")
    c.target_pos = nil
  end
end

function Sim:rotateNonce() self.nonceN = self.nonceN + 1; self.nonce = string.format("nonce-%04d", self.nonceN) end

function Sim:challenge()
  self.challenges = self.challenges + 1
  return resp(401, "", { ["www-authenticate"] =
    string.format('Digest qop="auth", realm="%s", nonce="%s", algorithm=SHA-256', self.id, self.nonce) })
end

function Sim:verify(spec, path)
  local h = spec.headers and spec.headers.Authorization
  if not h then return false, "none" end
  local f = {}
  for k, v in h:gmatch('(%w+)="([^"]*)"') do f[k] = v end
  for k, v in h:gmatch('(%w+)=([^",%s]+)') do if f[k] == nil then f[k] = v end end
  if f.nonce ~= self.nonce then return false, "stale" end
  local ha1 = F.sha256("admin:" .. self.id .. ":" .. self.password)
  local ha2 = F.sha256("POST:" .. path)
  local want = F.sha256(ha1 .. ":" .. f.nonce .. ":" .. f.nc .. ":" .. f.cnonce .. ":auth:" .. ha2)
  if f.response == want and f.username == "admin" and f.realm == self.id then return true end
  return false, "bad"
end

function Sim:install()
  local host = "://" .. self.addr
  self.rt.http.on(function(spec) return spec.url:find(host, 1, true) end, function(spec)
    local scheme = spec.url:match("^(%a+)://")
    local path = spec.url:match("^%a+://[^/]+(.*)$")
    if self.mode == "refuse" then return F.neterr("connect") end        -- connection refused: nothing was sent
    if self.mode == "blackhole" then return false end            -- never answers at all
    if self.mode == "dead" then return F.neterr("timeout") end
    if self.mode == "https-only" and scheme == "http" then return F.neterr("connect") end
    if (self.mode == "redirect" or self.enhanced) and scheme == "http" then
      return resp(302, "", { location = "https://" .. self.addr .. path })
    end
    if path == "/shelly" then
      return resp(200, { id = self.id, mac = self.mac, gen = self.gen, ver = "1.4.4", auth_en = self.password ~= nil,
        auth_domain = self.password and self.id or nil, enhanced_security = self.enhanced or false,
        profile = self.profile })
    end
    local method = path:match("^/rpc/([%w%.]+)$")
    if not method then return resp(404, {}) end
    if self.throttle then return resp(429, "") end
    if self.password then
      local ok, why = self:verify(spec, path)
      if not ok then
        if why == "none" or why == "stale" then
          if why == "stale" then self:rotateNonce() end
          return self:challenge()
        end
        self.rejected = self.rejected + 1
        return self:challenge()
      end
    end
    local params = spec.body and self.rt.json.decode(spec.body) or {}
    if self.errorFor[method] then return resp(400, self.errorFor[method]) end
    self.calls[#self.calls + 1] = { method = method, params = params }
    if method == "Shelly.GetStatus" then return resp(200, self.status) end
    self:applyRpc(method, params)
    if self.dropReply then return F.neterr("timeout") end            -- applied, but the answer never arrives
    -- Cover.* and Light.Set answer with the JSON literal null (Shelly docs); Switch.Set answers { was_on }
    if method:match("^Cover%.") or method == "Light.Set" then return resp(200, "null") end
    return resp(200, { was_on = false })
  end)
end

return Sim
