-- Light V2 proxy glue (dimmable), following Control4's Proxy & Protocol guide and light_sample.c4i:
--   commands  : SET_BRIGHTNESS_TARGET with LIGHT_BRIGHTNESS_TARGET_PERCENT (0..100) | _LEVEL (min..max, 0..100 here) |
--               _PRESET_ID (1 On, 2 Off, 3 Slow On, 4 Slow Off) and an optional RATE in ms (-1 = unspecified); plus the deprecated
--               SET_LEVEL / RAMP_TO_LEVEL {LEVEL}, ON / OFF / TOGGLE and BUTTON_ACTION {BUTTON_ID, ACTION} that the sample handles;
--   feedback  : LIGHT_BRIGHTNESS_CHANGED {LIGHT_BRIGHTNESS_CURRENT = raw level} - the guide says dimmers should use only this (and
--               CHANGING) and no longer the level notify. The sample's legacy LIGHT_LEVEL <level> stays selectable through the
--               "Feedback Notification" property as a fallback.
-- Toggles are resolved from known state and sent as absolute values.
local U = require("common.util")
local ids = require("common.ids")

local G = { kind = "light", component = "light" }
local B = ids.BINDING

local function levelOf(v)
  if not v.on then return 0 end
  return v.level or 100
end
G.levelOf = levelOf

local function publish(child, level)
  local mode = child.env.prop("Feedback Notification")
  if mode ~= "Light Level" then child.env.notify(B, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level }) end
  if mode == "Light Level" or mode == "Both" then child.env.notify(B, "LIGHT_LEVEL", level) end
end
G.publish = publish

function G.apply(child, v, force)
  local level = levelOf(v)
  if force then child.sent.level = nil end
  child:once("level", level, function() publish(child, level) end)
end

function G.online(child, online)
  child:once("online", tostring(online), function() child.env.notify(B, "ONLINE_CHANGED", { STATE = online }) end)
end

function G.optimistic(child, intent)
  local level = intent.level
  if level == nil then level = intent.on and (child.value and child.value.level or 100) or 0 end
  G.apply(child, { on = level > 0, level = level > 0 and level or nil })
end

-- RATE / TIME: milliseconds for the transition; absent, 0 or -1 (the guide: -1 means "not specified") = the device's own transition.
local function rateOf(p)
  local r = tonumber(p and (p.RATE or p.TIME))
  if r and r > 0 then return math.floor(r) end
  return nil
end

local function levelIntent(child, target, rate)
  target = U.clamp(U.round(target), 0, 100)
  if child.value and child.value.uncalibrated then
    -- the device refuses brightness on an uncalibrated dimmer channel (error -109): only on/off is possible
    if target <= 0 then return { on = false } end
    if target >= 100 then return { on = true } end
    return nil, "dimmer is not calibrated: only fully on or off is possible (calibrate it in the Shelly app)"
  end
  return { level = target, rate = rate }
end

local function onIntent(child, rate)
  local lvl = child.value and child.value.level
  if child.value and child.value.uncalibrated then return { on = true } end
  return { level = lvl or 100, rate = rate }
end

local Proto = require("common.protocol")
local targetOf = Proto.brightnessTarget
G.targetOf = targetOf

function G.toIntent(child, cmd, p)
  if cmd == "SET_BRIGHTNESS_TARGET" then
    local target = targetOf(p)
    if target then return levelIntent(child, target, rateOf(p)) end
    -- The On / Off tiles may arrive as static presets with no level: 1 On, 2 Off, 3 Slow On, 4 Slow Off.
    local preset = tonumber(p.LIGHT_BRIGHTNESS_TARGET_PRESET_ID)
    if preset == 1 or preset == 3 then return onIntent(child, rateOf(p))
    elseif preset == 2 or preset == 4 then return levelIntent(child, 0, rateOf(p))
    elseif preset then return nil, "unsupported brightness preset " .. preset end
    return nil, "missing brightness target"
  elseif cmd == "SET_LEVEL" or cmd == "RAMP_TO_LEVEL" or cmd == "GROUP_SET_LEVEL" or cmd == "GROUP_RAMP_TO_LEVEL" then
    local target = tonumber(p.LEVEL)
    if not target then return nil, "missing level" end
    return levelIntent(child, target, rateOf(p))
  elseif cmd == "ON" then return onIntent(child)
  elseif cmd == "OFF" then return levelIntent(child, 0)
  elseif cmd == "TOGGLE" then
    if not child.value then return nil, "state unknown, cannot toggle" end
    if levelOf(child.value) > 0 then return levelIntent(child, 0) end
    return onIntent(child)
  elseif cmd == "BUTTON_ACTION" then
    -- BUTTON_ID 0 = top (on), 1 = bottom (off), 2 = toggle; ACTION 0 = long release, 1 = press, 2 = release. Act on release only.
    if tostring(p.ACTION) ~= "2" then return nil end
    local id = tostring(p.BUTTON_ID)
    if id == "0" then return onIntent(child)
    elseif id == "1" then return levelIntent(child, 0)
    elseif id == "2" then return G.toIntent(child, "TOGGLE", p) end
    return nil
  end
  return nil
end

return G
