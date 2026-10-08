-- Inventory (devices, components, children) and component STATE with hold logic.
--
--   * A component's value is nil until a real read supplies it ("unknown", never a default).
--   * A control command applies an OPTIMISTIC value and opens a short hold; while the hold is open
--     a POLLED value that disagrees is ignored (flip-flop guard). A VERIFICATION read always wins
--     and reports a disagreement.
--   * Children hear about a component only when the value they were last told differs, or when a
--     pending optimistic value is confirmed. So identical polls cost zero notifications.
local U = require("common.util")
local Parse = require("hub.transport.parse")

local R = {}
R.__index = R

function R.new(rt, hooks)
  local self = setmetatable({}, R)
  self.rt, self.hooks = rt, hooks or {}
  self.devices, self.comps, self.states, self.children = {}, {}, {}, {}
  self.childOf = {}          -- child C4 device id -> ckey
  return self
end

local function valueOf(c)
  if c.kind == "switch" then
    if c.on == nil then return nil end
    return { on = c.on and true or false }
  elseif c.kind == "light" then
    if c.on == nil then return nil end
    return { on = c.on and true or false, level = c.level, uncalibrated = c.uncalibrated }
  elseif c.kind == "flood" or c.kind == "smoke" then
    if c.alarm == nil and c.battery == nil then return nil end
    -- alarm is OMITTED when unknown (a faulted sensor): consumers keep their last known alarm and never see a guessed all-clear
    local alarm = nil
    if c.alarm ~= nil then alarm = c.alarm and true or false end
    return { alarm = alarm, mute = c.mute and true or false, battery = c.battery }
  elseif c.kind == "contact" then
    if c.closed == nil and c.battery == nil then return nil end
    local closed = nil
    if c.closed ~= nil then closed = c.closed and true or false end            -- omitted = unknown (never guessed)
    return { closed = closed, battery = c.battery }
  elseif c.kind == "gas" then
    if c.alarm == nil and c.level == nil and c.state == nil then return nil end
    local alarm = nil
    if c.alarm ~= nil then alarm = c.alarm and true or false end
    return { alarm = alarm, level = c.level, state = c.state }
  elseif c.kind == "cover" then
    if c.state == nil then return nil end
    return { state = c.state, position = c.position, calibrated = c.calibrated, target = c.target }
  end
end
R.valueOf = valueOf

local function eqv(a, b) return U.flat_eq(a, b) end

function R:device(id) return self.devices[id] end
function R:deviceIds()
  local ids = {}
  for id in pairs(self.devices) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end
function R:component(ckey) return self.comps[ckey] end
function R:state(ckey) return self.states[ckey] end

-- Add/update a device from a normalised record. Returns true if the component set changed.
function R:upsert(norm, source)
  local d = self.devices[norm.id]
  if not d then
    d = { id = norm.id, components = {}, unsupported = {} }
    self.devices[norm.id] = d
  end
  d.model = norm.model or d.model
  d.gen = norm.gen or d.gen
  d.supported = norm.supported ~= false
  d.missing = nil
  if norm.online ~= nil then d.online = norm.online end
  local changed = false
  for _, c in ipairs(norm.components or {}) do
    local ckey = Parse.key(norm.id, c.kind, c.channel)
    if not self.comps[ckey] then
      self.comps[ckey] = { key = ckey, devId = norm.id, kind = c.kind, channel = c.channel, optional = c.optional }
      d.components[ckey] = true
      changed = true
    end
  end
  if norm.unsupported ~= nil then d.unsupported = norm.unsupported end
  -- A read that reported components (a status with content, never an offline device's empty one) is the full truth: components it no
  -- longer lists were removed by a profile change (switch <-> cover, light <-> rgb) and must not be offered for Auto-Setup.
  local seen, sawAny = {}, false
  for _, c in ipairs(norm.components or {}) do seen[Parse.key(norm.id, c.kind, c.channel)] = true; sawAny = true end
  if sawAny or (norm.unsupported and #norm.unsupported > 0) then
    for ckey in pairs(d.components) do
      local c = self.comps[ckey]
      local gone = not seen[ckey]
      if c and (c.gone or false) ~= gone then c.gone = gone or nil; changed = true end
    end
  end
  return changed
end

function R:removeDevice(id)
  local d = self.devices[id]
  if not d then return end
  for ckey in pairs(d.components) do
    local child = self.children[ckey]
    if child then self.childOf[child] = nil end
    self.children[ckey], self.comps[ckey], self.states[ckey] = nil, nil, nil
  end
  self.devices[id] = nil
end

function R:markMissing(seen)
  for id, d in pairs(self.devices) do d.missing = (not seen[id]) or nil end
end

function R:componentsOf(devId)
  local out = {}
  local d = self.devices[devId]
  if d then for ckey in pairs(d.components) do out[#out + 1] = self.comps[ckey] end end
  table.sort(out, function(a, b) if a.kind ~= b.kind then return a.kind < b.kind end return a.channel < b.channel end)
  return out
end

-- ---- children -----------------------------------------------------------------------------
function R:bindChild(ckey, childId)
  local old = self.children[ckey]
  if old then self.childOf[old] = nil end
  self.children[ckey] = childId
  self.childOf[childId] = ckey
end
function R:unbindChild(childId)
  local ckey = self.childOf[childId]
  if ckey then self.children[ckey] = nil; self.childOf[childId] = nil end
  return ckey
end
function R:childFor(ckey) return self.children[ckey] end
function R:unassigned()
  local out = {}
  for ckey, c in pairs(self.comps) do
    if not self.children[ckey] and not c.gone and self.devices[c.devId] and self.devices[c.devId].supported then out[#out + 1] = c end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

-- ---- state --------------------------------------------------------------------------------
local function st(self, ckey)
  local s = self.states[ckey]
  if not s then s = {}; self.states[ckey] = s end
  return s
end

local function publish(self, ckey, s, confirmed)
  s.notified = U.copy(s.value)
  s.everNotified = true
  if self.hooks.onChanged then self.hooks.onChanged(ckey, s, confirmed) end
end

-- opts: { verify = bool, metaOnly = bool }
function R:applyRead(devId, norm, source, opts)
  opts = opts or {}
  local now = self.rt.clock.now()
  local d = self.devices[devId]
  if not d then return end
  if norm.online ~= nil and norm.online ~= d.online then
    d.online = norm.online
    if self.hooks.onOnline then self.hooks.onOnline(devId, norm.online) end
  end
  if opts.metaOnly then return end
  for _, c in ipairs(norm.components or {}) do
    local ckey = Parse.key(devId, c.kind, c.channel)
    if self.comps[ckey] then
      local newv = valueOf(c)
      local s = st(self, ckey)
      local held = s.hold and now < s.hold.untilMs
      if newv == nil then
        -- the read named the component but carried no state: keep what we know
      elseif held and not opts.verify and not eqv(newv, s.hold.value) then
        self.rt.log:debug("ignored stale %s read for %s during hold", source, ckey)
      else
        if opts.verify and s.hold and not eqv(newv, s.hold.value) and self.hooks.onDisagree then
          self.hooks.onDisagree(ckey, s.hold.value, newv)
        end
        s.hold = nil
        local wasPending = s.pending
        s.pending = nil
        s.value, s.source, s.at = newv, source, now
        if not s.everNotified or wasPending or not eqv(s.notified, newv) then
          publish(self, ckey, s, wasPending and true or false)
        end
      end
    end
  end
end

-- Apply the value a successful command should produce, and open a hold. Not forwarded to children.
function R:applyCommand(ckey, intent, holdMs)
  local c = self.comps[ckey]
  if not c then return end
  local s = st(self, ckey)
  local v
  if c.kind == "switch" then v = { on = intent.on and true or false }
  elseif c.kind == "light" then
    local level = intent.level
    if level ~= nil then v = { on = level > 0, level = level > 0 and level or (s.value and s.value.level) }
    else v = { on = intent.on and true or false, level = s.value and s.value.level } end
  end
  s.pending = true
  if v then
    s.value = v
    s.hold = { value = v, untilMs = self.rt.clock.now() + (holdMs or 2000) }
  end
end

-- The last confirmed-or-optimistic value (used to resolve a toggle into an absolute command).
function R:value(ckey) local s = self.states[ckey]; return s and s.value end

function R:clearState(devId)
  for ckey in pairs((self.devices[devId] or { components = {} }).components) do self.states[ckey] = nil end
end

-- ---- persistence --------------------------------------------------------------------------
-- Compact on purpose (see AddressBook:export). Components are "l0,s0,s1,c0"; children are
-- { deviceIndex, "s1", childId } so long keys are not repeated.
local LETTER = { light = "l", switch = "s", cover = "c", flood = "f", smoke = "k", gas = "g", contact = "i" }
local KIND = { l = "light", s = "switch", c = "cover", f = "flood", k = "smoke", g = "gas", i = "contact" }

function R:export()
  local devs, kids, index = {}, {}, {}
  for _, id in ipairs(self:deviceIds()) do
    local d = self.devices[id]
    local comps = {}
    for _, c in ipairs(self:componentsOf(id)) do comps[#comps + 1] = (LETTER[c.kind] or "?") .. c.channel end
    devs[#devs + 1] = { i = id, m = d.model, g = d.gen, u = (d.supported == false) and 0 or nil, x = d.missing or nil,
      c = table.concat(comps, ",") }
    index[id] = #devs
  end
  local keys = {}
  for ckey in pairs(self.children) do keys[#keys + 1] = ckey end
  table.sort(keys)
  for _, ckey in ipairs(keys) do
    local c = self.comps[ckey]
    if c and index[c.devId] then kids[#kids + 1] = { index[c.devId], (LETTER[c.kind] or "?") .. c.channel, self.children[ckey] } end
  end
  return { d = devs, k = kids }
end

function R:import(data)
  if type(data) ~= "table" then return end
  local ids = {}
  for _, e in ipairs(type(data.d) == "table" and data.d or {}) do
    if type(e) == "table" and type(e.i) == "string" then
      local comps = {}
      for kind, ch in tostring(e.c or ""):gmatch("(%a)(%d+)") do
        if KIND[kind] then comps[#comps + 1] = { kind = KIND[kind], channel = tonumber(ch) } end
      end
      self:upsert({ id = e.i, model = e.m, gen = e.g, supported = e.u ~= 0, components = comps })
      self.devices[e.i].missing = e.x
      ids[#ids + 1] = e.i
    else ids[#ids + 1] = false end
  end
  for _, k in ipairs(type(data.k) == "table" and data.k or {}) do
    local id = ids[tonumber(k[1]) or 0]
    local kind, ch = tostring(k[2] or ""):match("^(%a)(%d+)$")
    if id and KIND[kind] and tonumber(k[3]) then self:bindChild(id .. "|" .. KIND[kind] .. "|" .. ch, tonumber(k[3])) end
  end
end

return R
