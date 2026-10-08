-- Normalises Shelly Gen2+ status payloads (cloud v2, cloud all_status, LAN Shelly.GetStatus)
-- into transport-independent records. All field names below are [Unverified] until captured
-- from real devices in milestone M0 (see docs/SPEC.md); this file is the ONLY place they appear.
--
-- An empty/missing field becomes nil ("unknown"), never a guessed default.
local U = require("common.util")
local P = {}

local IGNORED = { script = true, ws = true, cloud = true, mqtt = true, wifi = true, eth = true, sys = true,
  ble = true, bthome = true, ts = true, knx = true, matter = true, zigbee = true, wd = true }

function P.is_gen2plus(gen)
  if gen == nil then return true end                       -- LAN reads carry no gen; probe already vetted it
  local g = tostring(gen):upper():gsub("^G", "")
  local n = tonumber(g)
  return n ~= nil and n >= 2
end

-- "G1" / "G2" / 2 / nil -> 1 / 2 / 2 / nil ("GBLE", "V1" ... -> nil)
function P.genNumber(gen)
  if gen == nil then return nil end
  local n = tonumber((tostring(gen):upper():gsub("^G", "")))
  return n
end

-- Gen1 models whose relays[] this driver controls (relay API identical across the family; only the Shelly 1 is verified).
-- Others with relays[] (2.5 in roller mode, Uni, EM ...) are NOT assumed safe: a roller motor must never be driven as two lights.
local GEN1_RELAY_MODELS = { ["SHSW-1"] = true }
-- Gen1 alarm sensors by model: the component exists even while its value is unknown (a faulted sensor reports null).
local GEN1_DOORWINDOW_MODELS = { ["SHDW-1"] = true, ["SHDW-2"] = true }
local GEN1_SENSOR_MODELS = { ["SHWT-1"] = "flood", ["SHSM-01"] = "smoke", ["SHGS-1"] = "gas" }

-- Gen1 status is flat: relays[], and top-level flood / smoke / gas_sensor for the battery and gas sensors.
function P.components_gen1(status, code)
  local comps, unsupported = {}, {}
  if type(status) ~= "table" then return comps, unsupported end
  if (code == nil or GEN1_RELAY_MODELS[code]) and type(status.relays) == "table" then
    for i, r in ipairs(status.relays) do
      if type(r) == "table" then comps[#comps + 1] = { kind = "switch", channel = i - 1, on = r.ison } end
    end
  end
  if (code == nil or GEN1_RELAY_MODELS[code]) and type(status.inputs) == "table" then
    for i, inp in ipairs(status.inputs) do
      if type(inp) == "table" and (inp.input == 0 or inp.input == 1) then
        comps[#comps + 1] = { kind = "contact", channel = i - 1, closed = (inp.input == 1), optional = true }
      end
    end
  end
  -- Door/Window 1/2 (battery): sensor.state = "open" | "close" (+ is_valid at both levels), bat.value, accel/lux ignored.
  if GEN1_DOORWINDOW_MODELS[code] or (code == nil and type(status.sensor) == "table" and type(status.sensor.state) == "string") then
    local s = type(status.sensor) == "table" and status.sensor or {}
    local ok = status.is_valid ~= false and s.is_valid ~= false
    local c = { kind = "contact", channel = 0, battery = type(status.bat) == "table" and tonumber(status.bat.value) or nil }
    if ok and (s.state == "open" or s.state == "close") then c.closed = (s.state == "close") end
    comps[#comps + 1] = c
  end
  -- Battery sensors report `null` on a fault since firmware 1.12.1; a packet is valid only with is_valid true and sensor_error 0. An
  -- invalid read is "unknown" (alarm = nil): the component stays, but nothing is concluded from it - never a stale or guessed alarm.
  local valid = status.is_valid ~= false and (status.sensor_error == nil or status.sensor_error == 0)
  local sensorKind = GEN1_SENSOR_MODELS[code]
  local function boolOf(raw) if valid and type(raw) == "boolean" then return raw end return nil end
  local battery = type(status.bat) == "table" and tonumber(status.bat.value) or nil          -- estimated remaining capacity, 0..100 %
  if sensorKind == "flood" or (sensorKind == nil and type(status.flood) == "boolean") then
    comps[#comps + 1] = { kind = "flood", channel = 0, alarm = boolOf(status.flood), mute = false, battery = battery }
  end
  if sensorKind == "smoke" or (sensorKind == nil and type(status.smoke) == "boolean") then
    comps[#comps + 1] = { kind = "smoke", channel = 0, alarm = boolOf(status.smoke), mute = false, battery = battery }
  end
  -- Gas: alarm_state = unknown | none | mild | heavy | test; sensor_state = unknown | warmup | normal | fault (documented).
  --   mild / heavy are ALWAYS an alarm; "none" / "test" (the self-test result) assert "no alarm" only from a sensor that reports normal
  --   operation (a missing sensor_state, on older firmware, is trusted); anything else - alarm_state unknown, or a warming-up / faulted /
  --   unknown sensor - is "unknown" (alarm = nil): never an all-clear. The state is exposed so a fault can be acted on.
  local gs = type(status.gas_sensor) == "table" and status.gas_sensor or nil
  if sensorKind == "gas" or gs then
    local c = { kind = "gas", channel = 0 }
    local st = gs and gs.alarm_state
    local sensorState = gs and type(gs.sensor_state) == "string" and gs.sensor_state or nil
    if type(st) == "string" then
      c.level = st
      if st == "mild" or st == "heavy" then c.alarm = true
      elseif (st == "none" or st == "test") and (sensorState == nil or sensorState == "normal") then c.alarm = false end
    end
    c.state = sensorState
    comps[#comps + 1] = c
  end
  return comps, unsupported
end

function P.components(status)
  local comps, unsupported = {}, {}
  if type(status) ~= "table" then return comps, unsupported end
  -- sorted keys: component order must not depend on Lua's hash order (it decides Auto-Setup order and what a list shows)
  local keys = {}
  for key in pairs(status) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local v = status[key]
    local kind, ch = key:match("^(%a+):(%d+)$")
    if kind and type(v) == "table" and not IGNORED[kind] then
      ch = tonumber(ch)
      if kind == "switch" then
        comps[#comps + 1] = { kind = "switch", channel = ch, on = v.output }
      elseif kind == "light" then
        -- During a transition the status shows the CURRENT (moving) level; the value the device is heading to
        -- is transition.target. Believing the moving value would report a false disagreement after every command.
        local on, level = v.output, v.brightness
        local target = type(v.transition) == "table" and v.transition.target
        if type(target) == "table" then
          if target.output ~= nil then on = target.output end
          if target.brightness ~= nil then level = target.brightness end
        end
        local uncal = false
        if type(v.flags) == "table" then for _, f in ipairs(v.flags) do if f == "uncalibrated" then uncal = true end end end
        comps[#comps + 1] = { kind = "light", channel = ch, on = on, level = level, uncalibrated = uncal or nil }
      elseif kind == "flood" or kind == "smoke" then
        -- Alarm sensors (Flood Gen4, Plus Smoke): { alarm, mute }. Read-only: mute is deliberately not exposed (see docs).
        comps[#comps + 1] = { kind = kind, channel = ch, alarm = v.alarm, mute = v.mute }
      elseif kind == "input" then
        -- A digital input of type `switch` reports a boolean state (a reed switch, a limit switch, a wall switch); a `button` input is
        -- stateless (state null). OPTIONAL: most inputs are wall switches, so a contact driver is only created for the ones the installer lists.
        if type(v.state) == "boolean" then comps[#comps + 1] = { kind = "contact", channel = ch, closed = v.state, optional = true } end
      elseif kind == "cover" then
        -- pos_control is the calibration flag; current_pos can be null on a CALIBRATED cover (position lost after
        -- a power cut) and is absent on an uncalibrated one.
        local calibrated
        if v.pos_control ~= nil then calibrated = v.pos_control and true or false else calibrated = v.current_pos ~= nil end
        comps[#comps + 1] = { kind = "cover", channel = ch, state = v.state, position = v.current_pos, calibrated = calibrated, target = v.target_pos }
      else
        unsupported[#unsupported + 1] = key
      end
    end
  end
  table.sort(comps, function(a, b)
    if a.kind ~= b.kind then return a.kind < b.kind end
    return a.channel < b.channel
  end)
  table.sort(unsupported)
  return comps, unsupported
end

function P.identity(status, fallbackId)
  local mac = status and ((status.sys and U.normalize_mac(status.sys.mac)) or U.normalize_mac(status.mac))   -- Gen2: sys.mac, Gen1: mac
  local id = status and status.id
  return { id = U.norm_id(id or fallbackId), mac = mac }
end

-- Prefer the wired address when there is one.
function P.address(status)
  if type(status) ~= "table" then return nil end
  local eth = status.eth and status.eth.ip
  if U.is_ipv4(eth) then return eth, "eth" end
  local wifi = status.wifi and status.wifi.sta_ip
  if U.is_ipv4(wifi) then return wifi, "wifi" end
  local g1 = status.wifi_sta and status.wifi_sta.ip                  -- Gen1
  if U.is_ipv4(g1) then return g1, "wifi" end
  return nil
end

-- meta: { id, online, gen, code }
function P.device(meta, status)
  local gen1 = P.genNumber(meta.gen) == 1
  local comps, unsupported
  if gen1 then comps, unsupported = P.components_gen1(status, meta.code) else comps, unsupported = P.components(status) end
  local addr = P.address(status)
  local ident = P.identity(status, meta.id)
  if not ident.id then ident.id = U.norm_id(meta.id) end
  return {
    id = U.norm_id(meta.id), online = meta.online, gen = meta.gen, model = meta.code,
    components = comps, unsupported = unsupported, identity = ident, address = addr,
    supported = gen1 and #comps > 0 or (not gen1 and P.is_gen2plus(meta.gen)),
  }
end

-- POST /v2/devices/api/get  ->  list of { id, type, code, gen, online, status }
function P.from_v2(list)
  local out = {}
  if type(list) ~= "table" then return out end
  for _, e in ipairs(list) do
    if type(e) == "table" and e.id then
      out[#out + 1] = P.device({ id = e.id, online = (e.online == 1 or e.online == true) and true or (e.online == nil and nil or false),
        gen = e.gen, code = e.code }, e.status or {})
    end
  end
  return out
end

-- POST /device/all_status  ->  data.devices_status[<key>] = { ...status, _dev_info = { id, gen, code, online } }
function P.from_all_status(data)
  local out = {}
  local map = data and data.devices_status
  if type(map) ~= "table" then return out end
  for _, st in pairs(map) do
    local info = type(st) == "table" and st._dev_info
    if info and info.id and type(info.id) == "string" then
      local online = info.online
      if online == 1 then online = true elseif online == 0 then online = false end       -- documented as boolean; be lenient
      out[#out + 1] = P.device({ id = info.id, online = online, gen = info.gen, code = info.code }, st)
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- Component key used everywhere: "<deviceId>|<kind>|<channel>"
function P.key(id, kind, channel) return id .. "|" .. kind .. "|" .. channel end

return P
