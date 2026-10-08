-- Relay provider glue. The child exposes a RELAY connection (id 1). A Control4 relay-consuming
-- device is bound to it by the installer; commands arrive as OPEN / CLOSE / TOGGLE / TRIGGER and
-- state goes back as OPENED / CLOSED (+ STATE_OPENED / STATE_CLOSED for the initial report).
-- Closed = output ON.  [Unverified] how commands are delivered for a non-proxy connection (M3).
local ids = require("common.ids")

local G = { kind = "relay", component = "switch", varSet = "relay" }
local B = 1

-- STATE_CLOSED / STATE_OPENED report the current state WITHOUT signalling a transition; CLOSED / OPENED signal a real change and
-- drive programming. So: state only on the first report (or a replay), the transition only on a change, nothing when unchanged.
-- (Found on hardware in efic1/C4-SwitchBotUltra: sending both on every report re-announced a transition each poll.)
function G.apply(child, v, force)
  local closed = v.on and true or false
  if force then child.sent.relay = nil end
  local first = child.sent.relay == nil
  child:once("relay", closed and "C" or "O", function()
    if first then child.env.notify(B, closed and "STATE_CLOSED" or "STATE_OPENED", {})
    else child.env.notify(B, closed and "CLOSED" or "OPENED", {}) end
    child.env.setVar("Relay State", closed and "Closed" or "Open")
    if not first then child:fire(closed and "Relay Closed" or "Relay Opened") end
  end)
end

function G.optimistic(child, intent) if not intent.toggle_after then G.apply(child, { on = intent.on }) end end

function G.toIntent(child, cmd, p)
  if cmd == "CLOSE" then return { on = true }
  elseif cmd == "OPEN" then return { on = false }
  elseif cmd == "TOGGLE" then
    if not child.value then return nil, "state unknown, cannot toggle" end
    return { on = not child.value.on }
  elseif cmd == "TRIGGER" then
    local ms = tonumber(child.env.prop("Trigger Pulse (ms)")) or 1000
    return { on = true, toggle_after = ms / 1000 }
  end
  return nil
end

return G
