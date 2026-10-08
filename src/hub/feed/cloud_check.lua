-- Cloud feed: a SLOW health/address cycle for every device, a faster cycle only for devices whose
-- route is Cloud, and on-demand address refreshes when a device drops off the LAN.
-- Traffic is Background priority through the rate-gated queue, ten devices per request.
local Feed = {}
Feed.__index = Feed

function Feed.new(rt, deps)
  local self = setmetatable({}, Feed)
  self.rt = rt
  for k, v in pairs(deps) do self[k] = v end       -- cloud, registry, ab, router, hooks
  self.hooks = deps.hooks or {}
  self.slowId, self.fastId, self.refreshId = nil, nil, nil
  self.pendingRefresh = {}
  return self
end

function Feed:start()
  self:stop()
  local slow = (self.rt.cfg.cloudCheckS or 300) * 1000
  self.slowId = self.rt.sched:every(slow, function() self:checkAll() end)
  self.fastId = self.rt.sched:every(60000, function() self:checkCloudRoute() end)
end
function Feed:stop()
  for _, k in ipairs({ "slowId", "fastId", "refreshId" }) do
    if self[k] then self.rt.sched:cancel(self[k]); self[k] = nil end
  end
end

local function batches(ids)
  local out, cur = {}, {}
  for _, id in ipairs(ids) do
    cur[#cur + 1] = id
    if #cur == 10 then out[#out + 1] = cur; cur = {} end
  end
  if #cur > 0 then out[#out + 1] = cur end
  return out
end

-- Fold a cloud read into the address book and registry.
function Feed:ingest(devs, prio)
  for _, norm in ipairs(devs) do
    if norm.supported == false then
      self.registry:upsert(norm, "cloud")                -- remembered so List Devices can say why it is skipped
      self.rt.log:info("device %s (%s) has no supported components; skipped", norm.id, tostring(norm.model or "unknown model"))
    else
    local d = self.ab:ensure(norm.id)
    self.ab:setGen(norm.id, require("hub.transport.parse").genNumber(norm.gen), norm.model)
    self.ab:setCloudOnline(norm.id, norm.online)
    if norm.identity and (norm.identity.mac or norm.identity.id) and not d.identity then self.ab:setIdentity(norm.id, norm.identity) end
    if norm.address then self.ab:setAddress(norm.id, norm.address, "cloud") end
    -- cloud state is used until the LAN is CONFIRMED working (Up/Degraded); Probing/Down/NoAddress take it from the cloud
    local lan = d.lan
    local viaCloud = not (lan == "Up" or lan == "Degraded")
    local structural = self.registry:upsert(norm, "cloud")
    self.registry:applyRead(norm.id, norm, "cloud", { metaOnly = not viaCloud, verify = prio == "verify" })
    if structural and self.hooks.onStructure then self.hooks.onStructure(norm.id) end
    if self.hooks.onRoute then self.hooks.onRoute(norm.id) end
    end
  end
end

function Feed:read(ids, prio, cb)
  for _, batch in ipairs(batches(ids)) do
    self.cloud:read(batch, prio, function(out, devs)
      if out.ok then self:ingest(devs or {}, prio) elseif self.hooks.onCloudError then self.hooks.onCloudError(out) end
      if cb then cb(out) end
    end)
  end
end

function Feed:checkAll() if self.cloud:isUsable() then self:read(self.registry:deviceIds(), "background") end end

function Feed:checkCloudRoute()
  if not self.cloud:isUsable() then return end
  local ids = {}
  for _, id in ipairs(self.registry:deviceIds()) do
    if not self.ab:lanUsable(id) then ids[#ids + 1] = id end
  end
  if #ids > 0 then self:read(ids, "background") end
end

-- A device left the LAN: ask the cloud where it is now. Coalesced into one request.
function Feed:requestRefresh(id)
  self.pendingRefresh[id] = true
  if self.refreshId then return end
  self.refreshId = self.rt.sched:after(300, function()
    self.refreshId = nil
    local ids = {}
    for k in pairs(self.pendingRefresh) do ids[#ids + 1] = k end
    table.sort(ids)
    self.pendingRefresh = {}
    if self.cloud:isUsable() and #ids > 0 then self:read(ids, "verify") end
  end)
end

return Feed
