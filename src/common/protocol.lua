-- Hub <-> child wire protocol. All values travel as strings (Control4 command parameters);
-- structured payloads are JSON in a single parameter. Names come from the generated ids.lua.
local ids = require("common.ids")

local P = {}
P.M = ids.protocol

function P.flag(v) return v and "1" or "0" end
function P.triState(v) if v == nil then return "" end return v and "1" or "0" end
function P.fromTriState(s) if s == "1" then return true elseif s == "0" then return false end return nil end

-- Which registry component kind each child driver binds to.
P.COMPONENT_OF = { light = "light", light_onoff = "switch", relay = "switch", blind = "cover", contact = "contact" }
-- A light child may also bind to a switch-type light? No: dimmable lights bind to light:N only.

-- "Test Cloud Connection", "TEST_CLOUD_CONNECTION" and "TestCloud" all identify one action.
-- SET_BRIGHTNESS_TARGET carries a level under one of several names: the documented LIGHT_BRIGHTNESS_TARGET_PERCENT / _LEVEL, then the
-- spellings seen in third-party captures. Returns a number or nil. (The On/Off tiles may instead carry only LIGHT_BRIGHTNESS_TARGET_PRESET_ID.)
function P.brightnessTarget(p)
  p = p or {}
  return tonumber(p.LIGHT_BRIGHTNESS_TARGET_PERCENT) or tonumber(p.LIGHT_BRIGHTNESS_TARGET_LEVEL)
    or tonumber(p.LIGHT_BRIGHTNESS_TARGET) or tonumber(p.PERCENT) or tonumber(p.LEVEL)
end

local function actionKey(s) return (tostring(s or ""):upper():gsub("[^%w]+", "_")) end

function P.resolveAction(list, raw)
  if raw == nil then return nil end
  local want = actionKey(raw)
  for _, a in ipairs(list or {}) do
    if raw == a.cmd or raw == a.label or want == actionKey(a.label) or want == actionKey(a.cmd) then return a.cmd end
  end
  return nil
end

function P.compatible(childKind, componentKind)
  local want = P.COMPONENT_OF[childKind]
  if want == componentKind then return true end
  if childKind == "sensor" then return componentKind == "flood" or componentKind == "smoke" or componentKind == "gas" end   -- component chosen per child
  return childKind == "light_onoff" and componentKind == "light"      -- on/off presentation of a dimmer channel
end

return P
