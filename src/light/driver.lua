-- Entry points for the Control4 Director. All behaviour lives in common.childcore and light.proxyglue.
local Runtime = require("common.runtime")
local Child = require("common.childcore")
local Glue = require("light.proxyglue")

local rt = Runtime.build(C4, _G, { name = "shelly-light" })
local env = Runtime.env(C4, _G, rt)
local child = Child.new(rt, env, Glue)

function OnDriverInit() child:init() end
function OnDriverLateInit() child:lateInit() end
function OnDriverDestroyed() child:destroy() end
function OnPropertyChanged(name) child:propertyChanged(name) end
-- [Unverified] parameter order: OnBindingChanged(idBinding, class, bIsBound, otherDeviceId, otherBindingId)
function OnBindingChanged(idBinding, strClass, bIsBound) child:bindingChanged(idBinding, bIsBound) end
function ExecuteCommand(cmd, params) child:executeCommand(cmd, params or {}) end
function ReceivedFromProxy(binding, cmd, params) child:fromProxy(binding, cmd, params) end
