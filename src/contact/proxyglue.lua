-- Contact sensor glue: a CONTACT_SENSOR provider (connection 1) fed by either
--   * a device's digital input terminal (Gen2 input:N of type switch; Gen1 Shelly 1 inputs[]) - e.g. a reed switch on a garage door, or
--   * a Shelly Door/Window 1/2 (Gen1, battery).
-- Closed = circuit closed (a reed switch with its magnet beside it). "Invert Contact" flips that for the Control4 side without touching the
-- Shelly's own configuration. Contact semantics as everywhere here: STATE_ on the first report and on every replay, CLOSED / OPENED only for
-- real changes; Contact Opened / Contact Closed events on changes only, never on the first report after a reload. Read-only.
-- A device that reports a battery level is a sleepy Door/Window: Device Offline then waits 25 hours; a mains-powered input waits 60 s.
local G = { kind = "contact", component = "contact", varSet = "contact", routeEvents = false }
local B = 1

G.offlineDebounceMs = function(child)
  if child.value and child.value.battery ~= nil then return 25 * 3600 * 1000 end
  return nil                                       -- the default (60 s)
end

local function inverted(child) return child.env.prop("Invert Contact") == "Yes" end

function G.apply(child, v, force)
  if v.closed ~= nil then child.lastClosed = v.closed and true or false end
  if v.battery ~= nil then
    child:once("battery", tostring(v.battery), function() child.env.setVar("Battery Level", tostring(v.battery)) end)
  end
  if child.lastClosed == nil then return end                    -- unknown (e.g. a Door/Window self-check fault): leave the contact as it was
  local closed = child.lastClosed
  if inverted(child) then closed = not closed end
  if force then child.sent.contact = nil end
  local first = child.sent.contact == nil
  child:once("contact", closed and "C" or "O", function()
    if first then child.env.notify(B, closed and "STATE_CLOSED" or "STATE_OPENED", {})
    else child.env.notify(B, closed and "CLOSED" or "OPENED", {}) end
    child.env.setVar("Contact State", closed and "Closed" or "Open")
    if not first then child:fire(closed and "Contact Closed" or "Contact Opened") end
  end)
end

function G.propertyChanged(child, name)
  if name == "Invert Contact" and child.value then child.sent.contact = nil; G.apply(child, child.value) end
end

function G.toIntent() return nil end            -- read-only

return G
