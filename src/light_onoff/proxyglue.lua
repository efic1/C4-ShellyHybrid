-- Light V2 proxy glue for on/off loads (a Shelly relay channel presented as a light). Same contract as light.proxyglue:
-- official-sample commands and feedback, brightness reported as 0 or 100.
local ids = require("common.ids")

local G = { kind = "light_onoff", component = "switch" }
local B = ids.BINDING

local function publish(child, level)
  local mode = child.env.prop("Feedback Notification")
  if mode ~= "Light Level" then child.env.notify(B, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level }) end
  if mode == "Light Level" or mode == "Both" then child.env.notify(B, "LIGHT_LEVEL", level) end
end

function G.apply(child, v, force)
  local level = v.on and 100 or 0
  if force then child.sent.level = nil end
  child:once("level", level, function() publish(child, level) end)
end

function G.online(child, online)
  child:once("online", tostring(online), function() child.env.notify(B, "ONLINE_CHANGED", { STATE = online }) end)
end

function G.optimistic(child, intent) G.apply(child, { on = intent.on }) end

function G.toIntent(child, cmd, p)
  if cmd == "SET_BRIGHTNESS_TARGET" then
    local target = require("common.protocol").brightnessTarget(p)
    if target then return { on = target > 0 } end
    local preset = tonumber(p.LIGHT_BRIGHTNESS_TARGET_PRESET_ID)     -- 1 On, 2 Off, 3 Slow On, 4 Slow Off
    if preset == 1 or preset == 3 then return { on = true } elseif preset == 2 or preset == 4 then return { on = false }
    elseif preset then return nil, "unsupported brightness preset " .. preset end
    return nil, "missing brightness target"
  elseif cmd == "SET_LEVEL" or cmd == "RAMP_TO_LEVEL" or cmd == "GROUP_SET_LEVEL" or cmd == "GROUP_RAMP_TO_LEVEL" then
    local target = tonumber(p.LEVEL)
    if not target then return nil, "missing brightness target" end
    return { on = target > 0 }
  elseif cmd == "ON" then return { on = true }
  elseif cmd == "OFF" then return { on = false }
  elseif cmd == "TOGGLE" then
    if not child.value then return nil, "state unknown, cannot toggle" end
    return { on = not child.value.on }
  elseif cmd == "BUTTON_ACTION" then
    if tostring(p.ACTION) ~= "2" then return nil end
    local id = tostring(p.BUTTON_ID)
    if id == "0" then return { on = true } elseif id == "1" then return { on = false }
    elseif id == "2" then return G.toIntent(child, "TOGGLE", p) end
    return nil
  end
  return nil
end

return G
