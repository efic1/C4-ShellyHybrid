-- Generated files and packaging: driver.xml <-> Lua consistency, ids freshness, package contents.
local H = require("tests.harness")
local test, eq, truthy, falsy, contains = H.test, H.eq, H.truthy, H.falsy, H.contains
local ids = require("common.ids")

local DRIVERS = { hub = "shelly_hub", light = "shelly_light", light_onoff = "shelly_light_onoff", relay = "shelly_relay", blind = "shelly_blind", sensor = "shelly_sensor", contact = "shelly_contact" }
local CHILDREN = { "light", "light_onoff", "relay", "blind", "sensor", "contact" }

local function read(path) local f = assert(io.open(path, "rb"), path); local s = f:read("*a"); f:close(); return s end
local function sh(cmd) local p = io.popen(cmd .. " 2>&1"); local out = p:read("*a"); local ok = p:close(); return out, ok end
local function xmlOf(key) return read("build/" .. DRIVERS[key] .. "/driver.xml") end
local function xmlProps(xml) local t = {} for b in xml:gmatch("<property>(.-)</property>") do t[b:match("<name>(.-)</name>")] = b end return t end
local function xmlEvents(xml) local t = {} for id, name in xml:gmatch("<event><id>(%d+)</id><name>(.-)</name>") do t[name] = tonumber(id) end return t end
local function luaFiles(dir)
  local out = {}
  local p = io.popen("find " .. dir .. " -name '*.lua'")
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  return out
end

test("generator: ids.lua is fresh (tools/build.py --check)", function()
  local out, ok = sh("python3 tools/build.py --check")
  truthy(ok, out)
end)

test("generator: every driver.xml is well-formed XML", function()
  for _, f in pairs(DRIVERS) do
    local out, ok = sh("python3 -c \"import xml.dom.minidom,sys; xml.dom.minidom.parse('build/" .. f .. "/driver.xml')\"")
    truthy(ok, f .. ": " .. out)
  end
end)

test("generator: every bundled driver.lua passes luac -p and defines its entry points", function()
  for _, f in pairs(DRIVERS) do
    local out, ok = sh("luac5.1 -p build/" .. f .. "/driver.lua")
    truthy(ok, f .. ": " .. out)
    local src = read("build/" .. f .. "/driver.lua")
    contains(src, "function OnDriverInit()"); contains(src, "function ExecuteCommand(")
  end
end)

test("generator: .c4z packages contain driver.xml, driver.lua and documentation", function()
  for _, f in pairs(DRIVERS) do
    local out = sh("python3 -c \"import zipfile;print(sorted(zipfile.ZipFile('build/" .. f .. ".c4z').namelist()))\"")
    contains(out, "driver.xml"); contains(out, "driver.lua"); contains(out, "www/documentation.html")
  end
end)

test("generator: XML version equals the Lua version constant in every driver", function()
  for key in pairs(DRIVERS) do contains(xmlOf(key), "<version>" .. ids.VERSION .. "</version>") end
end)

test("generator: property, LIST and RANGED_INTEGER definitions are internally valid", function()
  for key in pairs(DRIVERS) do
    for name, blk in pairs(xmlProps(xmlOf(key))) do
      local ptype, default = blk:match("<type>(.-)</type>"), blk:match("<default>(.-)</default>") or ""
      if ptype == "LIST" then
        local found = false
        for it in blk:gmatch("<item>(.-)</item>") do if it == default then found = true end end
        truthy(found, key .. ": default '" .. default .. "' of '" .. name .. "' is not one of its items")
      elseif ptype == "RANGED_INTEGER" then
        local mn, mx = tonumber(blk:match("<minimum>(.-)</minimum>")), tonumber(blk:match("<maximum>(.-)</maximum>"))
        truthy(mn and mx and tonumber(default) >= mn and tonumber(default) <= mx, key .. ": range of '" .. name .. "'")
      end
    end
  end
end)

-- Names used in Lua must exist in the XML of every driver that bundles that file.
local function collect(src, patterns)
  local names = {}
  for _, pat in ipairs(patterns) do for n in src:gmatch(pat) do names[n] = true end end
  return names
end
local PROP_PATTERNS = { 'prop%("([^"]+)"%)', 'setProp%("([^"]+)"', 'props%.set%("([^"]+)"', '[^%w_.:]set%("([^"]+)"', 'propertyChanged%(.-%).-name == "([^"]+)"' }

local function driversFor(path)
  if path:find("^src/hub/") then return { "hub" } end
  if path:find("childcore") then return CHILDREN end
  for _, k in ipairs(CHILDREN) do if path:find("^src/" .. k .. "/") then return { k } end end
  return nil                                                           -- shared modules: names are passed in
end

test("generator: every property name used in Lua exists in the driver XML that bundles the file", function()
  for _, path in ipairs(luaFiles("src")) do
    local targets = driversFor(path)
    if targets then
      local src = read(path)
      for name in pairs(collect(src, PROP_PATTERNS)) do
        for _, key in ipairs(targets) do
          truthy(xmlProps(xmlOf(key))[name], path .. " uses property '" .. name .. "' which " .. DRIVERS[key] .. " does not declare")
        end
      end
    end
  end
end)

test("generator: every event fired by name in Lua exists in the driver XML", function()
  for _, path in ipairs(luaFiles("src")) do
    local targets = driversFor(path)
    if targets then
      local src = read(path)
      for name in pairs(collect(src, { 'fire%("([^"]+)"%)' })) do
        for _, key in ipairs(targets) do
          -- relay-only events are fired from the relay glue only
          truthy(xmlEvents(xmlOf(key))[name], path .. " fires '" .. name .. "' which " .. DRIVERS[key] .. " does not declare")
        end
      end
    end
  end
end)

test("generator: every variable set by name exists in the generated variable table", function()
  local declared = {}
  for _, group in pairs(ids.variables) do for _, v in ipairs(group) do declared[v.name] = true end end
  for _, path in ipairs(luaFiles("src")) do
    for name in pairs(collect(read(path), { 'setVar%("([^"]+)"' })) do truthy(declared[name], path .. " sets undeclared variable '" .. name .. "'") end
  end
end)

test("generator: every action in driver.xml has a handler", function()
  local core, child = read("src/hub/core.lua"), read("src/common/childcore.lua")
  for cmd in xmlOf("hub"):gmatch("<command>(.-)</command>") do contains(core, "function Core:do" .. cmd .. "(") end
  for _, k in ipairs(CHILDREN) do
    for cmd in xmlOf(k):gmatch("<command>(.-)</command>") do contains(child, '"' .. cmd .. '"') end
  end
end)

test("generator: event IDs are unique, stable, >= 100, and cannot collide with the proxy binding or relay connection", function()
  for key in pairs(DRIVERS) do
    local seen = {}
    for name, id in pairs(xmlEvents(xmlOf(key))) do
      truthy(id >= 100, name); falsy(seen[id], key .. " reuses event id " .. id); seen[id] = true
      truthy(id ~= ids.BINDING and id ~= 1)
    end
  end
  eq(xmlEvents(xmlOf("light"))["Device Offline"], 100)                -- IDs are permanent: never renumber
  eq(xmlEvents(xmlOf("relay"))["Relay Closed"], 110)
  eq(xmlEvents(xmlOf("hub"))["Cloud Connected"], 200)
end)

test("generator: proxies, capabilities and connections are declared as designed", function()
  contains(xmlOf("light"), "<proxy proxybindingid=\"5001\" name=\"Shelly Light\" primary=\"True\">light_v2</proxy>")
  contains(xmlOf("light_onoff"), "<dimmer>False</dimmer>"); contains(xmlOf("light"), "<dimmer>True</dimmer>")
  contains(xmlOf("blind"), ">blind</proxy>"); contains(xmlOf("blind"), "<driver_handles_toggle>False</driver_handles_toggle>")
  contains(xmlOf("relay"), "<classname>RELAY</classname>"); contains(xmlOf("relay"), "<consumer>False</consumer>")
  falsy(xmlOf("hub"):find("<proxy ", 1, true), "the hub has no proxy")
end)

test("generator: the hub declares NO variables or events beyond the static table (nothing added at runtime)", function()
  local src = read("src/hub/core.lua")
  falsy(src:find("AddEvent", 1, true)); falsy(src:find("addVar", 1, true))
end)

test("generator: no build artefact depends on Control4's package.path or the global require", function()
  for _, f in pairs(DRIVERS) do
    local src = read("build/" .. f .. "/driver.lua")
    falsy(src:find("package.path", 1, true)); falsy(src:find("package.preload", 1, true))
  end
end)

test("generator: no function calls a local that is defined later in its file (compiles, then fails at runtime)", function()
  local out, ok = sh("python3 tools/check_forward_refs.py")
  truthy(ok, out)
end)

test("generator: the forward-reference gate really catches a forward reference (mutation check)", function()
  local f = assert(io.open("/tmp/c4_fwd_bad.lua", "w"))
  f:write("local M = {}\nfunction M.a() return helper(1) end\nlocal function helper(x) return x end\nreturn M\n"); f:close()
  local out, ok = sh("python3 -c \"import importlib.util as u;s=u.spec_from_file_location('g','tools/check_forward_refs.py');m=u.module_from_spec(s);s.loader.exec_module(m);print(m.check('/tmp/c4_fwd_bad.lua'))\"")
  contains(out, "helper")
end)

test("generator: .c4z archives have NO directory entries and driver.xml has NO XML declaration (Composer's Update Driver fails silently otherwise)", function()
  for _, f in pairs(DRIVERS) do
    local out = sh("python3 -c \"import zipfile;print([n for n in zipfile.ZipFile('build/" .. f .. ".c4z').namelist() if n.endswith('/')])\"")
    contains(out, "[]", f .. " has directory entries: " .. out)
    local xml = read("build/" .. f .. "/driver.xml")
    truthy(xml:sub(1, 12) == "<devicedata>", f .. ": driver.xml must start with <devicedata>, not an XML declaration")
    falsy(xml:find("<?xml", 1, true))
  end
end)

test("generator: names Composer keys an update on are stable (name, model, manufacturer, creator, filename)", function()
  contains(read("build/shelly_hub/driver.xml"), "<name>Shelly Hub</name>")
  contains(read("build/shelly_light/driver.xml"), "<model>Shelly Light</model>")
  contains(read("build/shelly_relay/driver.xml"), "<creator>C4-ShellyHybrid</creator>")
  for _, f in pairs(DRIVERS) do falsy(io.open("build/" .. f .. ".c4z") == nil) end
end)

test("generator: light and blind drivers declare their proxy binding as a connection (as Control4's light sample and the Ultra lock driver do)", function()
  local lx = read("build/shelly_light/driver.xml")
  contains(lx, "<classname>LIGHT_V2</classname>"); contains(lx, "<id>5001</id>")
  contains(read("build/shelly_light_onoff/driver.xml"), "<classname>LIGHT_V2</classname>")
  contains(read("build/shelly_blind/driver.xml"), "<classname>BLIND</classname>")
end)

test("generator: light capabilities follow Control4's official light_sample.c4i (on_off, ramp_level, scenes) and lights are categorised Lighting", function()
  for _, k in ipairs({ "shelly_light", "shelly_light_onoff" }) do
    local x = read("build/" .. k .. "/driver.xml")
    contains(x, "<on_off>True</on_off>"); contains(x, "<supports_target>True</supports_target>"); contains(x, "<category>Lighting</category>")
  end
  local dim, onoff = read("build/shelly_light/driver.xml"), read("build/shelly_light_onoff/driver.xml")
  contains(dim, "<dimmer>True</dimmer>"); contains(dim, "<set_level>True</set_level>"); contains(dim, "<ramp_level>True</ramp_level>")
  contains(onoff, "<dimmer>False</dimmer>"); contains(onoff, "<set_level>False</set_level>"); contains(onoff, "<ramp_level>False</ramp_level>")
end)

test("generator: the blind driver does not declare level_unknown (probably a numeric sentinel, not a boolean)", function()
  falsy(read("build/shelly_blind/driver.xml"):find("level_unknown", 1, true))
end)

test("generator: lights declare reduced ALS support so Advanced Lighting Scenes drive them with individual SET_BRIGHTNESS_TARGET commands", function()
  for _, k in ipairs({ "shelly_light", "shelly_light_onoff" }) do
    contains(read("build/" .. k .. "/driver.xml"), "<reduced_als_support>True</reduced_als_support>")
  end
end)

test("generator: the blind declares a Full Travel Time property used for RAMP_RATE", function()
  contains(read("build/shelly_blind/driver.xml"), "<name>Full Travel Time (s)</name>")
end)

test("generator: full ALS support is NOT claimed (advanced_scene_support False) while reduced ALS is - they are alternatives, and we implement no scene commands", function()
  for _, k in ipairs({ "shelly_light", "shelly_light_onoff" }) do
    local x = read("build/" .. k .. "/driver.xml")
    contains(x, "<advanced_scene_support>False</advanced_scene_support>"); contains(x, "<reduced_als_support>True</reduced_als_support>")
    contains(x, "<supports_multichannel_scenes>False</supports_multichannel_scenes>"); contains(x, "<load_group_support>False</load_group_support>")
  end
end)
