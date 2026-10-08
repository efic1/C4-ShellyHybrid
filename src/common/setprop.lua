-- SetProp(name, value): write a Composer property only when it changed.
-- Every C4:UpdateProperty is a round trip to Director and forces Composer to redraw.
local M = {}

function M.new(update)
  local shadow, writes = {}, 0
  local self = {}
  function self.set(name, value)
    value = tostring(value)
    if shadow[name] == value then return false end
    shadow[name] = value
    writes = writes + 1
    update(name, value)
    return true
  end
  function self.forget(name) shadow[name] = nil end      -- force the next write
  function self.writes() return writes end
  function self.get(name) return shadow[name] end
  return self
end

return M
