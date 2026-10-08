-- Mock Control4 Director. Loads the REAL bundled driver.lua files (build/<driver>/driver.lua) into
-- sandboxed environments, validates every property / event name against the generated driver.xml,
-- routes SendToDevice between driver instances, and counts every Director-bound API call so the
-- performance budgets in docs/ARCHITECTURE.md can be enforced by tests.
local F = require("tests.fakes")
local json = require("tests.lib.json")

local Director = {}
Director.__index = Director

local FILES = { shelly_hub = "hub", shelly_light = "light", shelly_light_onoff = "light_onoff", shelly_relay = "relay", shelly_blind = "blind", shelly_sensor = "sensor", shelly_contact = "contact" }
local COUNTED = { "SendToProxy", "SendToDevice", "UpdateProperty", "AddVariable", "SetVariable", "FireEvent",
  "SetTimer", "AddDevice", "PersistSetValue", "PersistGetValue", "url" }

local function readfile(path) local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end

local function parseXml(xml)
  local x = { props = {}, propOrder = {}, events = {}, actions = {} }
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    x.props[name] = { type = block:match("<type>(.-)</type>"), default = (block:match("<default>(.-)</default>") or ""):gsub("&amp;", "&"),
      readonly = block:match("<readonly>(.-)</readonly>") == "true" }
    x.propOrder[#x.propOrder + 1] = name
  end
  for id, name in xml:gmatch("<event><id>(%d+)</id><name>(.-)</name>") do x.events[name] = tonumber(id) end
  for label, cmd in xml:gmatch("<action><name>(.-)</name><command>(.-)</command></action>") do x.actions[#x.actions + 1] = { label = label, cmd = cmd } end
  return x
end

function Director.new(opts)
  local d = setmetatable({}, Director)
  d.f = F.new(opts)
  d.rt = d.f
  d.sims = {}
  d.instances, d.nextId = {}, 100
  d.buildDir = opts and opts.buildDir or "build"
  return d
end

function Director:byFile(file) for _, i in pairs(self.instances) do if i.file == file then return i end end end
function Director:all(file)
  local out = {}
  for _, i in pairs(self.instances) do if not file or i.file == file then out[#out + 1] = i end end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function Director:makeC4(inst)
  local d, f = self, self.f
  local C4 = {}
  local function count(name) inst.calls[name] = (inst.calls[name] or 0) + 1; inst.total = inst.total + 1 end
  function C4:GetTime() return f.clock.now() end
  function C4:GetDeviceID() return inst.id end
  function C4:SetTimer(ms, cb, rep)
    count("SetTimer")
    inst.timers = inst.timers + 1
    if rep then
      local live = true
      local h
      local function arm() h = f.setTimer(ms, function() if live then cb({}, 0); arm() end end) end
      arm()
      return { Cancel = function() if live then live = false; inst.timers = inst.timers - 1; h.cancel() end end }
    end
    local handle = f.setTimer(ms, function() inst.timers = inst.timers - 1; cb({}, 0) end)
    return { Cancel = function() inst.timers = inst.timers - 1; handle.cancel() end }
  end
  function C4:UpdateProperty(name, value)
    count("UpdateProperty")
    if not inst.xml.props[name] then error("UpdateProperty on undeclared property '" .. tostring(name) .. "' in " .. inst.file, 2) end
    inst.env.Properties[name] = tostring(value)
  end
  function C4:FireEvent(name)
    count("FireEvent")
    if not inst.xml.events[name] then error("FireEvent for undeclared event '" .. tostring(name) .. "' in " .. inst.file, 2) end
    inst.fired[#inst.fired + 1] = name
  end
  function C4:AddVariable(name, value, vtype) count("AddVariable"); inst.vars[name] = { value = value, type = vtype } end
  function C4:SetVariable(name, value)
    count("SetVariable")
    if not inst.vars[name] then error("SetVariable on undeclared variable '" .. tostring(name) .. "'", 2) end
    inst.vars[name].value = value
  end
  function C4:SendToProxy(binding, name, params, kind)
    count("SendToProxy")
    inst.notes[#inst.notes + 1] = { binding = binding, name = name, params = params or {}, kind = kind }
  end
  function C4:SendToDevice(id, cmd, params)
    count("SendToDevice")
    inst.sent[#inst.sent + 1] = { to = id, cmd = cmd, params = params }
    local target = d.instances[id]
    f.sched:after(1, function() if target and target.env.ExecuteCommand then target.env.ExecuteCommand(cmd, params or {}) end end)
  end
  -- Documented forms only (Snap One DriverWorks API): (file, cb) | (file, roomId, cb) | (file, roomId, name, cb)
  function C4:AddDevice(file, a, b, c)
    count("AddDevice")
    local room, name, cb
    if type(a) == "function" then cb = a
    elseif type(a) == "number" and type(b) == "function" then room, cb = a, b
    elseif type(a) == "number" and type(b) == "string" and type(c) == "function" then room, name, cb = a, b, c
    else error("AddDevice: not a documented call form", 2) end
    if room ~= nil and room <= 0 then error("AddDevice: " .. tostring(room) .. " is not a room id", 2) end
    local key = FILES[file:gsub("%.c4z$", "")]
    if not key then error("AddDevice: unknown driver file " .. tostring(file)) end
    local child = d:load((file:gsub("%.c4z$", "")), { name = name, room = room })
    f.sched:after(5, function() cb(child.id) end)
  end
  function C4:RenameDevice(id, name)
    count("RenameDevice")
    local t = d.instances[id]
    if not t then error("RenameDevice: no such device " .. tostring(id), 2) end
    t.name = name
  end
  function C4:JsonEncode(v) return json.encode(v) end
  function C4:JsonDecode(s) return (json.decode(s)) end
  function C4:Hash(alg, data) return f.hash(alg, data):upper() end
  function C4:url()
    count("url")
    local t = { opts = {} }
    function t:SetOptions(o) self.opts = o; return self end
    function t:OnDone(fn) self.done = fn; return self end
    local function go(method, url, body, headers)
      local spec = { method = method, url = url, body = body, headers = headers, timeout = t.opts.timeout,
        verify = t.opts.ssl_verify_peer, noRedirect = t.opts.follow_redirects == false }
      f.http.request(spec, function(res)
        if res.ok then t.done(t, { { code = res.code, body = res.body, headers = res.headers } }, 0, "")
        else
          local code = ({ timeout = 28, connect = 7, tls = 35 })[res.err] or 1
          t.done(t, {}, code, res.err)
        end
      end)
    end
    function t:Get(url, headers) go("GET", url, nil, headers) end
    function t:Post(url, body, headers) go("POST", url, body, headers) end
    return t
  end
  return C4
end

-- Load a driver instance. Returns the instance table.
function Director:load(file, opts)
  opts = opts or {}
  local id = self.nextId; self.nextId = id + 1
  local base = self.buildDir .. "/" .. file
  local inst = { id = id, file = file, name = opts.name, room = opts.room, calls = {}, total = 0, timers = 0,
    fired = {}, notes = {}, sent = {}, vars = {}, out = {}, store = opts.store or {}, xml = parseXml(readfile(base .. "/driver.xml")) }
  local env = setmetatable({}, { __index = _G })
  env.Properties = {}
  for name, p in pairs(inst.xml.props) do env.Properties[name] = p.default end
  for name, v in pairs(opts.props or {}) do env.Properties[name] = v end
  env.print = function(...) local t = {}; for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end; inst.out[#inst.out + 1] = table.concat(t, " ") end
  local function count(name) inst.calls[name] = (inst.calls[name] or 0) + 1; inst.total = inst.total + 1 end
  env.PersistSetValue = function(k, v) count("PersistSetValue"); inst.store[k] = v end
  env.PersistGetValue = function(k) count("PersistGetValue"); return inst.store[k] end
  env.PersistDeleteValue = function(k) inst.store[k] = nil end
  inst.env = env
  env.C4 = self:makeC4(inst)
  env._G = env
  self.instances[id] = inst
  local chunk = assert(loadfile(base .. "/driver.lua"))
  setfenv(chunk, env)
  chunk()
  function inst:setProp(name, value)
    if not self.xml.props[name] then error("no such property " .. name) end
    self.env.Properties[name] = tostring(value)
    if self.env.OnPropertyChanged then self.env.OnPropertyChanged(name) end
  end
  function inst:prop(name) return self.env.Properties[name] end
  -- Composer's LUA_ACTION carries either the action <name> or its <command> (two drivers by the same author disagree): both work.
  function inst:action(label, form)
    for _, a in ipairs(self.xml.actions) do
      if a.label == label then return self.env.ExecuteCommand("LUA_ACTION", { ACTION = form == "command" and a.cmd or a.label }) end
    end
    error("no such action " .. label)
  end
  function inst:bind(idBinding, bound) if self.env.OnBindingChanged then self.env.OnBindingChanged(idBinding, "RELAY", bound ~= false, 999, 1) end end
  function inst:proxy(binding, cmd, params) return self.env.ReceivedFromProxy(binding, cmd, params or {}) end
  function inst:resetCounts() self.calls, self.total = {}, 0; self.notes, self.fired, self.sent = {}, {}, {} end
  function inst:lastNote(name)
    for i = #self.notes, 1, -1 do if self.notes[i].name == name then return self.notes[i] end end
  end
  function inst:notesNamed(name)
    local o = {}
    for _, n in ipairs(self.notes) do if n.name == name then o[#o + 1] = n end end
    return o
  end
  function inst:firedCount(name) local n = 0; for _, e in ipairs(self.fired) do if e == name then n = n + 1 end end; return n end
  function inst:output() return table.concat(self.out, "\n") end
  -- lifecycle as Control4 does it
  env.OnDriverInit()
  if env.OnDriverLateInit then env.OnDriverLateInit() end
  return inst
end

function Director:advance(ms) self.f.advance(ms) end

return Director
