-- Alarm sensor glue (Shelly Flood Gen4 / Flood SHWT-1 water leak, Shelly Plus Smoke / Smoke SHSM-01, Gas SHGS-1): a CONTACT_SENSOR provider (connection 1) that a security
-- panel zone or any contact-consuming device can be bound to.
--
--   * STATE_CLOSED / STATE_OPENED report the state on the first report (and on every replay); CLOSED / OPENED signal a real change - the
--     same contact semantics as the relay (found on hardware in efic1/C4-SwitchBotUltra). Which contact state means "alarm" is the
--     "Alarm Contact State" property (default Closed, like a dry contact that closes on alarm).
--   * Events Alarm Started / Alarm Cleared fire on changes only, never on the first report after a reload; variables Alarm and Muted follow.
--   * READ-ONLY: this driver never mutes or silences an alarm (a remote mute could leave residents unaware), so it accepts no commands.
--   * Battery devices sleep for hours and are unreachable by design: Device Offline waits 25 hours and LAN/cloud route changes raise no
--     Fallback / Restored events. The state shown is the device's LAST REPORT, obtained through the cloud (about once a minute) or the
--     LAN while the device is awake. This is NOT a safety-grade alarm path.
local ids = require("common.ids")

-- Battery sensors (flood, smoke) sleep for hours; a mains-powered gas detector must be reachable, so a silent one is reported after 10 minutes.
local function offlineDebounce(child) return child.component == "gas" and 10 * 60 * 1000 or 25 * 3600 * 1000 end
local G = { kind = "sensor", component = nil, componentProp = "Sensor Component", varSet = "sensor", offlineDebounceMs = offlineDebounce, routeEvents = false }
local B = 1

local function closedOnAlarm(child) return child.env.prop("Alarm Contact State") ~= "Open" end

function G.apply(child, v, force)
  -- Variables follow every report, even one whose alarm is unknown (that is how a gas detector's fault becomes visible).
  if v.alarm ~= nil then child.lastAlarm = v.alarm and true or false end
  local known = child.lastAlarm
  if v.state ~= nil then child:once("sstate", v.state, function() child.env.setVar("Sensor State", v.state) end) end   -- gas: normal | warmup | fault | unknown
  if v.battery ~= nil then
    child:once("battery", tostring(v.battery), function() child.env.setVar("Battery Level", tostring(v.battery)) end)
  end
  -- gas: none | mild | heavy | test | unknown; flood and smoke: alarm | none
  local level = v.level or (known ~= nil and (known and "alarm" or "none")) or "unknown"
  child:once("level", level, function() child.env.setVar("Alarm Level", level) end)
  child:once("mute", tostring(v.mute and true or false), function() child.env.setVar("Muted", v.mute and "1" or "0") end)
  -- The contact only ever reflects a KNOWN alarm; an unknown one leaves it exactly as it was.
  if known == nil then return end
  local alarm = known
  if force then child.sent.alarm = nil end
  local first = child.sent.alarm == nil
  child:once("alarm", alarm and "A" or "N", function()
    local closed = (alarm == closedOnAlarm(child))
    if first then child.env.notify(B, closed and "STATE_CLOSED" or "STATE_OPENED", {})
    else child.env.notify(B, closed and "CLOSED" or "OPENED", {}) end
    child.env.setVar("Alarm", alarm and "1" or "0")
    if not first then child:fire(alarm and "Alarm Started" or "Alarm Cleared") end
  end)
end

function G.propertyChanged(child, name)
  if name == "Alarm Contact State" and child.value then child.sent.alarm = nil; G.apply(child, child.value) end
end

function G.toIntent() return nil end            -- read-only

return G
