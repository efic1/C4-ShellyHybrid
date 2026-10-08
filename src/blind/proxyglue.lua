-- Blind proxy glue, following the Blind Protocol Notifications in Control4's Proxy & Protocol guide.
--
-- Two level schemes (SET_HAS_LEVEL):
--   * level mode (calibrated, position known): open = 100, closed = 0, any position in between (discrete control);
--   * no-level mode (uncalibrated, or a calibrated cover that lost its position): the guide's convention for blinds without
--     feedback - open = 0, closed = 2 (2 because the blind can stop, and 1 means "unknown state"), a UI then only ever sends the
--     open and closed values, and STOPPED with LEVEL 1 reports an unknown position.
-- MOVING is sent ONCE per movement with LEVEL_TARGET, RAMP_RATE (estimated from the Full Travel Time property) and LEVEL = where the
-- blind started from (the last STOPPED level, or the current level if it was interrupted); progress reports send nothing, and STOPPED
-- (with the final LEVEL) ends the movement. Parameter names with spaces in the guide are written with underscores here (inferred,
-- as LEVEL_TARGET is for the command); the parameters of SET_HAS_LEVEL are all optional in the guide.
local U = require("common.util")
local ids = require("common.ids")

local G = { kind = "blind", component = "cover" }
local B = ids.BINDING

local NOLEVEL = { open = 0, closed = 2, unknown = 1 }

local function hasLevel(v) return v.calibrated ~= false and v.position ~= nil end
G.hasLevel = hasLevel

local function travelMs(child, from, target, graded)
  local secs = tonumber(child.env.prop("Full Travel Time (s)")) or 20
  local frac = 1
  if graded and from ~= nil and target ~= nil then frac = math.abs(target - from) / 100 end
  return math.max(500, math.floor(secs * 1000 * frac))
end

-- SET_CAN_STOP {CAN_STOP = bool}: the parameter name is confirmed by a working blind driver (bphillips09/Control4-HA-Blinds). Sent at
-- start-up and on every replay, in addition to the static <can_stop> capability. SET_TYPE / SET_MOVEMENT are deliberately never sent:
-- each would disable the dealer's pull-down.
function G.lateInit(child)
  child.env.notify(B, "SET_CAN_STOP", { CAN_STOP = true })
end

function G.apply(child, v, force)
  if force then child.sent.cover = nil; child.sent.mode = nil end
  local graded = hasLevel(v)
  child:once("mode", graded and "level" or "nolevel", function()
    if graded then
      child.env.notify(B, "SET_HAS_LEVEL", { HAS_LEVEL = true, LEVEL_OPEN = 100, LEVEL_CLOSED = 0, LEVEL_DISCRETE_CONTROL = true })
    else
      child.env.notify(B, "SET_HAS_LEVEL", { HAS_LEVEL = false, LEVEL_OPEN = NOLEVEL.open, LEVEL_CLOSED = NOLEVEL.closed, LEVEL_DISCRETE_CONTROL = false })
    end
  end)
  local st = v.state
  local function current()
    if graded then return v.position end
    if st == "open" then return NOLEVEL.open elseif st == "closed" then return NOLEVEL.closed end
    return NOLEVEL.unknown
  end
  if st == "opening" or st == "closing" then
    local target
    if graded then target = v.target or (st == "opening" and 100 or 0)
    else target = (st == "opening") and NOLEVEL.open or NOLEVEL.closed end
    child:once("cover", "M:" .. st .. ":" .. tostring(target), function()
      -- a fresh movement starts where the last one stopped; a reversal/interruption starts where the blind is NOW
      local from
      if child.moving then from = current() else from = child.lastStopped or current() end
      child.moving = true
      child.env.notify(B, "MOVING", { LEVEL_TARGET = target, RAMP_RATE = travelMs(child, from, target, graded), LEVEL = from })
    end)
  else
    local level = current()
    child:once("cover", "S:" .. tostring(level), function()
      child.moving, child.lastStopped = false, level
      child.env.notify(B, "STOPPED", { LEVEL = level })
    end)
  end
end

function G.online(child, online)
  child:once("online", tostring(online), function() child.env.notify(B, "ONLINE_CHANGED", { STATE = online }) end)
end

-- No optimistic MOVING: the verification read that follows every command reports the movement (with the real target) within ~0.5 s,
-- and a failed command needs no snap-back because nothing was announced.

function G.toIntent(child, cmd, p)
  local v = child.value
  if cmd == "SET_LEVEL_TARGET" then
    local target = tonumber(p.LEVEL_TARGET)
    if not target then return nil, "missing level target" end
    if v and not hasLevel(v) then
      target = U.round(target)
      if target == NOLEVEL.open then return { cover = "open" }
      elseif target == NOLEVEL.closed then return { cover = "close" } end
      if v.calibrated == false then return nil, "cover is not calibrated: only fully open or fully closed is possible" end
      -- calibrated but the device lost its position (power cut): GoToPosition would fail with -109
      return nil, "cover position is unknown: fully open or close it once to re-reference it"
    end
    return { position = U.clamp(U.round(target), 0, 100) }
  elseif cmd == "OPEN" or cmd == "UP" then return { cover = "open" }      -- UP / DOWN: what the blind proxy sends for its open/close buttons,
  elseif cmd == "CLOSE" or cmd == "DOWN" then return { cover = "close" }  -- and instead of SET_LEVEL_TARGET when HAS_LEVEL is false
  elseif cmd == "STOP" then return { cover = "stop" }
  elseif cmd == "TOGGLE" then
    if not v then return nil, "state unknown, cannot toggle" end
    if v.state == "opening" or v.state == "closing" then return { cover = "stop" } end
    if v.state == "open" then return { cover = "close" } end
    if v.state == "closed" then return { cover = "open" } end
    return nil, "cover position unknown, cannot toggle"
  end
  return nil
end

return G
