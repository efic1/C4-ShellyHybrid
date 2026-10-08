-- Shelly Cloud Control API client (v2, authorization-key). The ONLY file that knows cloud
-- URLs and payloads. All traffic goes through the rate-gated queue. The key is never logged
-- (the logger scrubs it) and URLs are never printed by this module.
local U = require("common.util")
local Parse = require("hub.transport.parse")
local Queue = require("hub.transport.cloudqueue")

local Cloud = {}
Cloud.__index = Cloud

function Cloud.new(rt)
  local self = setmetatable({}, Cloud)
  self.rt = rt
  self.queue = Queue.new(rt, { gapMs = rt.cfg.cloudGapMs or 1200, max = 50 })
  self.host, self.key = nil, nil
  self.status = "Not configured"        -- Connected / Degraded / Offline / Auth failed / Not configured
  self.lastOkAt = nil
  return self
end

-- Accepts "shelly-42-eu.shelly.cloud", "https://shelly-42-eu.shelly.cloud/", etc. Anything that is
-- not a *.shelly.cloud host is refused so the key can never be sent elsewhere.
function Cloud.normalizeHost(s)
  if type(s) ~= "string" then return nil, "Server is empty" end
  s = U.trim(s):lower():gsub("^https?://", ""):gsub("/.*$", "")
  if s == "" then return nil, "Server is empty" end
  if s:find(":", 1, true) then return nil, "Server must not include a port" end
  if not s:match("^[a-z0-9][a-z0-9%-%.]*%.shelly%.cloud$") or s:find("..", 1, true) then
    return nil, "Server must be a *.shelly.cloud host (copy it from the Shelly app)"
  end
  return s
end

function Cloud:configure(server, key)
  local host, err = Cloud.normalizeHost(server)
  if not host then self.host = nil; self:setStatus("Not configured"); return false, err end
  if type(key) ~= "string" or #U.trim(key) < 8 then self.host = nil; self:setStatus("Not configured"); return false, "Authorization Key is missing" end
  key = U.trim(key)
  local changed = key ~= self.key or host ~= self.host
  self.host, self.key = host, key
  self.rt.log:setSecret("cloudKey", key)
  if changed then self.queue:resume(); self:setStatus("Degraded") end   -- until the first success
  return true
end

function Cloud:setStatus(s)
  if s ~= self.status then
    local old = self.status
    self.status = s
    if self.onStatus then self.onStatus(s, old) end
  end
end

function Cloud:isUsable() return self.host ~= nil and not self.queue.authStopped end
function Cloud:isConnected() return self.status == "Connected" end

local function urlencode(s) return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)) end

local function spec(self, path, query, body)
  return {
    method = "POST",
    url = "https://" .. self.host .. path .. "?" .. (query and (query .. "&") or "") .. "auth_key=" .. urlencode(self.key),
    headers = { ["Content-Type"] = "application/json" },
    body = self.rt.json.encode(body or {}),
    timeout = self.rt.cfg.cloudTimeoutS or 10,
    verify = true,
  }
end

-- Map an HTTP result to an outcome. `res` is the http adapter's result.
local V2ERR = {
  DEVICE_OFFLINE = { "UNREACHABLE", "device is offline (cloud)", offline = true },
  DEVICE_FAILED_COMMAND = { "DEVICE", "device failed the command" },
  DEVICE_INVALID_MODE = { "CONFIG", "device is in the wrong mode for this command" },
  DEVICE_INVALID_CHANNEL = { "CONFIG", "invalid channel" },
  BAD_REQUEST = { "CONFIG", "cloud rejected the request" },
  DEVICE_NOT_FOUND = { "CONFIG", "device not found on this account", missing = true },
  INSTANCE_NOT_FOUND = { "CLOUD", "cloud instance not found; the server may have changed" },
  UNEXPECTED_SUBSERVICE_ERROR = { "CLOUD", "Shelly cloud error", retry = true },
}

function Cloud:classify(res)
  if not res.ok then return { ok = false, class = "CLOUD", reason = "network: " .. tostring(res.err) } end
  local code = res.code
  if code == 200 then return { ok = true } end
  if code == 401 or code == 403 then return { ok = false, class = "AUTH", reason = "cloud rejected the authorization key" } end
  if code == 429 then return { ok = false, class = "RATE", reason = "rate limited" } end
  local body = res.body and self.rt.json.decode(res.body)
  local m = type(body) == "table" and V2ERR[body.error]
  if m then
    local msg = body.data and body.data.messages and body.data.messages[1]
    return { ok = false, class = m[1], reason = msg or m[2], offline = m.offline, missing = m.missing, code = body.error }
  end
  return { ok = false, class = "CLOUD", reason = "HTTP " .. tostring(code) }
end

-- Two consecutive transport failures make the cloud "Offline" (not usable as a route); one is "Degraded".
function Cloud:noteOutcome(out)
  if out.ok then
    self.lastOkAt, self.fails = self.rt.clock.now(), 0
    self:setStatus("Connected")
  elseif out.class == "AUTH" then self:setStatus("Auth failed")
  elseif out.class == "CLOUD" and tostring(out.reason):find("^network") or out.class == "RATE" then
    self.fails = (self.fails or 0) + 1
    if self.status ~= "Auth failed" then
      self:setStatus((self.lastOkAt and self.fails < 2) and "Degraded" or "Offline")
    end
  end
  return out
end

-- Generic single request through the queue.
local function submit(self, prio, key, request, parseFn, cb)
  self.queue:enqueue({
    prio = prio, key = key,
    staleAfter = prio == "background" and (self.rt.cfg.cloudCheckS or 300) * 3000 or nil,
    run = function(_, finish)
      self.rt.http.request(request, function(res)
        local out = self:classify(res)
        if out.ok and parseFn then
          local ok, parsed = pcall(parseFn, res)
          if ok and parsed ~= nil then out.result = parsed else out = { ok = false, class = "CLOUD", reason = "unparseable response" } end
        end
        finish(self:noteOutcome(out))
      end)
    end,
    cb = function(out) if cb then cb(out, out.result) end end,
  })
end

-- Read up to 10 devices. cb(outcome, devices)
function Cloud:read(ids, prio, cb)
  if not self:isUsable() then return cb({ ok = false, class = "CONFIG", reason = "cloud not configured" }) end
  local list = {}
  for i = 1, math.min(#ids, 10) do list[i] = ids[i] end
  submit(self, prio or "background", nil,
    spec(self, "/v2/devices/api/get", nil, { ids = list, select = { "status" } }),
    function(res) return Parse.from_v2(self.rt.json.decode(res.body)) end, cb)
end

function Cloud:allStatus(cb)
  if not self:isUsable() then return cb({ ok = false, class = "CONFIG", reason = "cloud not configured" }) end
  submit(self, "background", "allstatus",
    spec(self, "/device/all_status", "show_info=true&no_shared=true", {}),
    function(res)
      local body = self.rt.json.decode(res.body)
      if type(body) ~= "table" or body.isok == false then error("isok false") end
      return Parse.from_all_status(body.data)
    end, cb)
end

-- Build the v2 control body for one component from an absolute intent.
function Cloud.controlBody(kind, id, channel, intent)
  local b = { id = id, channel = channel }
  if kind == "switch" then
    b.on = intent.on and true or false
    if intent.toggle_after then b.toggle_after = intent.toggle_after end
  elseif kind == "light" then
    if intent.level ~= nil then
      if intent.level <= 0 then b.on = false else b.on = true; b.brightness = U.clamp(U.round(intent.level), 1, 100) end
    else b.on = intent.on and true or false end
  elseif kind == "cover" then
    if intent.cover then b.position = intent.cover      -- open | close | stop
    else b.position = U.clamp(U.round(intent.position), 0, 100) end
  end
  return b
end

local PATH = { switch = "/v2/devices/api/set/switch", light = "/v2/devices/api/set/light", cover = "/v2/devices/api/set/cover" }

-- prio is normally "control". cb(outcome)
function Cloud:set(kind, id, channel, intent, prio, cb)
  if not self:isUsable() then return cb({ ok = false, class = "CONFIG", reason = "cloud not configured" }) end
  local body = Cloud.controlBody(kind, id, channel, intent)
  local command = U.copy(body); command.id, command.channel = nil, nil
  local key = "set|" .. id .. "|" .. kind .. "|" .. channel .. "|" .. (intent.cover == "stop" and "stop" or "v")
  self.queue:enqueue({
    prio = prio or "control", key = key,
    mergeKey = (kind ~= "cover" or intent.cover) and (kind .. "|" .. self.rt.json.encode(command)) or nil,
    group = { kind = kind, target = id .. "_" .. channel, command = command },
    body = body,
    run = function(list, finish) self:runSet(list, finish) end,
    cb = cb,
  })
end

function Cloud:runSet(list, finish)
  local first = list[1]
  local request
  if #list == 1 then
    request = spec(self, PATH[first.group.kind], nil, first.body)
  else
    local ids = {}
    for i, e in ipairs(list) do ids[i] = e.group.target end
    request = spec(self, "/v2/devices/api/set/groups", nil,
      { [first.group.kind] = { ids = ids, command = first.group.command } })
  end
  self.rt.http.request(request, function(res)
    local out = self:classify(res)
    if #list > 1 and out.ok then
      -- HTTP 200 does not mean every target succeeded: walk failedCommands
      local body = self.rt.json.decode(res.body or "")
      local failed = type(body) == "table" and body.failedCommands or {}
      local outs = {}
      for i, e in ipairs(list) do
        local err = failed[e.group.target]
        outs[i] = err and { ok = false, class = (err == "DEVICE_NOT_FOUND" and "CONFIG") or "DEVICE", reason = tostring(err) } or { ok = true }
      end
      self:noteOutcome({ ok = true })
      return finish(outs)
    end
    finish(self:noteOutcome(out))
  end)
end

function Cloud:resume() self.queue:resume() end

return Cloud
