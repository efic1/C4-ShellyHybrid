-- Entry points for the Control4 Director. All behaviour lives in hub.core.
local Runtime = require("common.runtime")
local Core = require("hub.core")

local rt = Runtime.build(C4, _G, { name = "shelly-hub" })
local env = Runtime.env(C4, _G, rt)
local core = Core.new(rt, env)

function OnDriverInit() core:init() end
function OnDriverLateInit() core:lateInit() end
function OnDriverDestroyed() core:destroy() end
function OnPropertyChanged(name) core:propertyChanged(name) end

function ExecuteCommand(cmd, params)
  params = params or {}
  if cmd == "LUA_ACTION" then core:action(params.ACTION) else core:executeCommand(cmd, params) end
end
