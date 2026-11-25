-- Variable order lock. Composer programming refers to variables by the order/IDs Director assigns when a driver creates them
-- (C4:AddVariable), so an inserted, removed or reordered variable silently re-points existing programming.
-- RULE: variables are APPEND-ONLY. To add one, add it at the END of its list in tools/spec.py; never insert, rename, remove or reorder.
-- This test pins today's order. It passes when new variables are appended and fails (naming the position) on any other change.
local H = require("tests.harness")
local Director = require("tests.director")
local ids = require("common.ids")
local test, eq, truthy = H.test, H.eq, H.truthy

-- The pinned order. Appending to a group needs no change here; to pin a newly added variable, append it below as well.
local PINNED = {
  child   = { "Device Online", "Route" },
  relay   = { "Relay State" },
  contact = { "Contact State", "Battery Level" },
  sensor  = { "Alarm", "Muted", "Alarm Level", "Battery Level", "Sensor State" },
  hub     = { "Alarm Active", "Active Alarm Count", "Alarm Type", "Alarm Source", "Alarm Source ID", "Alarm Device ID",
              "Alarm Message", "Alarm Time", "Active Alarms" },
}
local PINNED_TYPES = {
  ["Device Online"] = "BOOL", ["Alarm Active"] = "BOOL", ["Alarm"] = "BOOL", ["Muted"] = "BOOL",
  ["Active Alarm Count"] = "NUMBER", ["Alarm Device ID"] = "NUMBER", ["Battery Level"] = "NUMBER",
}

local function names(list) local o = {}; for i, v in ipairs(list) do o[i] = v.name end; return o end

-- first difference between the pinned list and the current one, as a readable message (nil = pinned list is an unchanged prefix)
local function drift(pinned, current)
  for i, want in ipairs(pinned) do
    if current[i] ~= want then
      return string.format("position %d is %q, expected %q (pinned order: %s)", i, tostring(current[i]), want, table.concat(pinned, ", "))
    end
  end
  return nil
end

test("variable order: every variable group keeps its pinned order (append-only)", function()
  for group, pinned in pairs(PINNED) do
    local current = ids.variables[group]
    truthy(current, "group " .. group .. " still exists")
    local why = drift(pinned, names(current))
    if why then error("variables '" .. group .. "' were reordered, renamed or removed: " .. why .. ". Add new variables at the END only.", 0) end
  end
  for group in pairs(ids.variables) do truthy(PINNED[group], "new variable group '" .. group .. "' must be pinned in tests/test_variable_order.lua") end
end)

test("variable order: pinned variables keep their types", function()
  for _, list in pairs(ids.variables) do
    for _, v in ipairs(list) do
      local want = PINNED_TYPES[v.name]
      if want then eq(v.type, want, "type of " .. v.name) end
    end
  end
end)

test("variable order: no variable is declared twice within one driver", function()
  local function check(label, groups)
    local seen = {}
    for _, g in ipairs(groups) do
      for _, v in ipairs(ids.variables[g]) do
        truthy(not seen[v.name], label .. " declares '" .. v.name .. "' twice")
        seen[v.name] = true
      end
    end
  end
  check("hub", { "hub" })
  check("relay", { "child", "relay" }); check("contact", { "child", "contact" }); check("sensor", { "child", "sensor" })
  check("light", { "child" })
end)

-- What each shipped driver really creates, in creation order, from the built bundles.
local EXPECT = {
  shelly_hub         = { "hub" },
  shelly_light       = { "child" },
  shelly_light_onoff = { "child" },
  shelly_blind       = { "child" },
  shelly_relay       = { "child", "relay" },
  shelly_contact     = { "child", "contact" },
  shelly_sensor      = { "child", "sensor" },
}

test("variable order: each built driver creates its variables in the pinned order", function()
  for file, groups in pairs(EXPECT) do
    local dir = Director.new({ latency = 10 })
    local inst = dir:load(file, {})
    dir:advance(5000)
    local want = {}
    for _, g in ipairs(groups) do for _, n in ipairs(PINNED[g]) do want[#want + 1] = n end end
    local why = drift(want, inst.varOrder)
    if why then error(file .. " creates its variables in a different order: " .. why, 0) end
    -- appended variables must come after every pinned one, as ids.lua lists them
    local full = {}
    for _, g in ipairs(groups) do for _, n in ipairs(names(ids.variables[g])) do full[#full + 1] = n end end
    eq(table.concat(inst.varOrder, "|"), table.concat(full, "|"), file .. " creation order matches ids.lua")
  end
end)

test("variable order: the checker really catches an inserted, swapped or removed variable", function()
  local cur = names(ids.variables.sensor)
  eq(drift(PINNED.sensor, cur), nil)
  local inserted = { "Alarm", "New One", "Muted", "Alarm Level", "Battery Level", "Sensor State" }
  truthy(drift(PINNED.sensor, inserted), "insertion in the middle is detected")
  local swapped = { "Muted", "Alarm", "Alarm Level", "Battery Level", "Sensor State" }
  truthy(drift(PINNED.sensor, swapped), "swap is detected")
  local removed = { "Alarm", "Muted", "Alarm Level", "Battery Level" }
  truthy(drift(PINNED.sensor, removed), "removal is detected")
  local appended = { "Alarm", "Muted", "Alarm Level", "Battery Level", "Sensor State", "Brand New" }
  eq(drift(PINNED.sensor, appended), nil)                           -- appending is allowed
end)
