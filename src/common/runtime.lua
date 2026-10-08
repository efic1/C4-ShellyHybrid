-- Production runtime: the ONLY module that calls Control4 APIs. Everything else receives `rt` and
-- `env`, which tests replace with fakes. `c4` is the C4 object and `g` the driver's globals, both
-- passed in (never read from _G here) so the same code runs under the mock Director.
--
-- [Unverified until milestone M0] C4:url option names/callback shape and C4:Hash options are isolated
-- in the two adapters below; nothing else in the code base depends on them.
local Sched = require("common.sched")
local Log = require("common.log")
local SetProp = require("common.setprop")
local U = require("common.util")

local R = {}

local TLS_ERR = { [35] = true, [51] = true, [53] = true, [54] = true, [58] = true, [59] = true, [60] = true,
  [64] = true, [66] = true, [77] = true, [80] = true, [82] = true, [83] = true, [90] = true, [91] = true }

local function mapErr(code, msg)
  if code == 28 then return "timeout" end
  if code == 6 or code == 7 then return "connect" end
  if TLS_ERR[code] then return "tls" end
  return "net:" .. tostring(code) .. (msg and (" " .. tostring(msg)) or "")
end

local function lowerKeys(h)
  local o = {}
  if type(h) == "table" then for k, v in pairs(h) do o[tostring(k):lower()] = v end end
  return o
end

function R.httpAdapter(c4, rt)
  local http = {}
  function http.request(spec, cb)
    local called = false
    local function once(res)
      if called then return end
      called = true
      cb(res)
    end
    local ok, err = pcall(function()
      local t = c4:url()
      local timeout = spec.timeout or 5
      local opts = { fail_on_error = false, timeout = timeout, connect_timeout = math.min(timeout, 3),
        ssl_verify_host = spec.verify and true or false, ssl_verify_peer = spec.verify and true or false }
      if spec.noRedirect then opts.follow_redirects = false end               -- [Unverified] option name
      pcall(function() t:SetOptions(opts) end)
      t:OnDone(function(_, responses, errCode, errMsg)
        if (errCode or 0) ~= 0 or type(responses) ~= "table" or #responses == 0 then
          return once({ ok = false, err = mapErr(errCode or -1, errMsg) })
        end
        local last = responses[#responses]
        once({ ok = true, code = tonumber(last.code) or 0, body = last.body or "", headers = lowerKeys(last.headers) })
      end)
      if spec.method == "GET" then t:Get(spec.url, spec.headers or {})
      else t:Post(spec.url, spec.body or "", spec.headers or {}) end
    end)
    if not ok then
      rt.sched:after(0, function() once({ ok = false, err = "internal: " .. tostring(err) }) end)
    end
  end
  return http
end

function R.build(c4, g, opts)
  opts = opts or {}
  local rt = { cfg = {} }
  rt.clock = { now = function() return c4:GetTime() end }
  rt.setTimer = function(ms, fn)
    local t = c4:SetTimer(ms, function() fn() end, false)
    return { cancel = function() if t then t:Cancel() end end }
  end
  -- One native repeating timer: a single Director call for the life of the feed, instead of a re-arm per tick.
  rt.everyNative = function(ms, fn)
    local t = c4:SetTimer(ms, function()
      local ok, err = pcall(fn)
      if not ok then rt.onError(err) end
    end, true)
    return { cancel = function() if t then t:Cancel(); t = nil end end }
  end
  rt.json = {
    encode = function(v)
      if type(v) == "table" and next(v) == nil then return "{}" end        -- never "[]": Shelly expects an object
      return c4:JsonEncode(v)
    end,
    decode = function(s)
      if type(s) ~= "string" or s == "" then return nil, "empty" end
      local ok, v = pcall(function() return c4:JsonDecode(s) end)
      if ok and type(v) == "table" then return v end
      return nil, "invalid json"
    end,
  }
  rt.hash = function(alg, data)
    local ok, h = pcall(function() return c4:Hash(alg, data, { return_encoding = "HEX", data_encoding = "NONE" }) end)
    return ok and h and h:lower() or nil
  end
  rt.store = {
    get = function(k) local ok, v = pcall(g.PersistGetValue, k); return ok and v or nil end,
    set = function(k, v) g.PersistSetValue(k, v) end,
    delete = function(k) if g.PersistDeleteValue then g.PersistDeleteValue(k) else g.PersistSetValue(k, "") end end,
  }
  local seed = (os.time() or 0) + (tonumber(c4:GetDeviceID()) or 0) * 7919
  math.randomseed(seed)
  rt.random = function() return math.random() end
  rt.props = SetProp.new(function(name, value) c4:UpdateProperty(name, value) end)
  rt.prop = function(name)
    local v = g.Properties and g.Properties[name]
    return v == nil and "" or tostring(v)
  end
  rt.log = Log.new({ name = opts.name or "shelly", level = "Info",
    clock = function() return os.time() * 1000 end, sink = function(line) print(line) end })
  rt.onError = function(e) rt.log:error("internal error: %s", tostring(e)) end
  rt.sched = Sched.new(rt)
  rt.http = R.httpAdapter(c4, rt)
  return rt
end

-- Director-facing helpers used by hub core and child core (all wrapped in pcall so one bad
-- call can never take the driver down).
function R.env(c4, g, rt)
  local env = {}
  local function safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then rt.log:error("Control4 call failed: %s", tostring(err)) end
    return ok
  end
  env.prop = rt.prop
  env.setProp = function(name, value) return rt.props.set(name, value) end
  env.myId = function() return c4:GetDeviceID() end
  env.fire = function(name) safe(function() c4:FireEvent(name) end) end
  env.addVar = function(name, value, vtype) safe(function() c4:AddVariable(name, value, vtype) end) end
  env.setVar = function(name, value) safe(function() c4:SetVariable(name, value) end) end
  env.notify = function(binding, name, params) safe(function() c4:SendToProxy(binding, name, params or {}, "NOTIFY") end) end
  env.sendToDevice = function(id, cmd, params) safe(function() c4:SendToDevice(id, cmd, params or {}) end) end
  -- C4:AddDevice(driverFile, [roomId], [newName], callback) - documented forms (Snap One DriverWorks API, Helper Interface):
  --   AddDevice(file, cb) | AddDevice(file, roomId, cb) | AddDevice(file, roomId, name, cb)
  -- With no room the driver lands in the CALLER's room, and a room of 0 is not a room, so that case uses the two-argument
  -- form and names the new driver afterwards. [Unverified] C4:RenameDevice(deviceId, name) argument order.
  env.addDevice = function(file, room, name, cb)
    local ok
    if room and room > 0 then
      ok = safe(function() c4:AddDevice(file, room, name, function(id) cb(id) end) end)
    else
      ok = safe(function()
        c4:AddDevice(file, function(id)
          if id and name and name ~= "" then safe(function() c4:RenameDevice(id, name) end) end
          cb(id)
        end)
      end)
    end
    if not ok then cb(nil) end
  end
  return env
end

return R
