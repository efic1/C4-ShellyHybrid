-- Full-hub-minus-Control4 test rig: real registry, address book, LAN/cloud transports, router and
-- feeds, wired to simulated devices and a simulated cloud. Records every event a child would see.
local F = require("tests.fakes")
local Sim = require("tests.lan_sim")
local U = require("common.util")
local Auth = require("hub.transport.lan_auth")
local Lan = require("hub.transport.lan")
local Cloud = require("hub.transport.cloud")
local Dispatch = require("hub.transport.lan_dispatch")
local Registry = require("hub.registry")
local AB = require("hub.addressbook")
local Router = require("hub.router")
local LanPoll = require("hub.feed.lan_poll")
local CloudCheck = require("hub.feed.cloud_check")
local Parse = require("hub.transport.parse")
local resp = F.resp

local Rig = {}

function Rig.new(opts)
  opts = opts or {}
  local r = setmetatable({ sims = {}, events = {}, cloudCalls = {}, devPass = opts.devPass }, { __index = Rig })
  local rt = F.new(opts)
  r.rt = rt
  rt.cfg.lanPollS = opts.lanPollS or 20
  rt.cfg.identityCheck = opts.identityCheck or "Standard"
  rt.cfg.cloudFallback = opts.cloudFallback ~= false
  rt.cfg.cloudCheckS = opts.cloudCheckS or 300

  r.cloud = Cloud.new(rt)
  if opts.cloud ~= false then r.cloud:configure("shelly-42-eu.shelly.cloud", "0123456789cloudkey") end
  r.auth = Auth.new(rt)
  r.lan = Lan.new(rt, r.auth)
  r.lan.passwordFor = function() return r.devPass end
  r.dispatch = Dispatch.new(rt)

  local function rec(kind, a, b, c) r.events[#r.events + 1] = { kind = kind, a = a, b = b, c = c } end
  r.registry = Registry.new(rt, {
    onChanged = function(ckey, s, confirmed) rec("changed", ckey, U.copy(s.value), confirmed) end,
    onOnline = function(id, online) rec("online", id, online) end,
    onDisagree = function(ckey, want, got) rec("disagree", ckey, want, got) end,
  })
  r.ab = AB.new(rt, {
    onTransition = function(id, from, to) rec("lan", id, from, to) end,
    onDown = function(id) r.cloudCheck:requestRefresh(id) end,
  })
  local hooks = {
    onUnverified = function(id) rec("unverified", id) end,
    onRouteEvent = function(id, what, why) rec("route", id, what, why) end,
    onNeedRefresh = function(id) r.cloudCheck:requestRefresh(id) end,
  }
  r.router = Router.new(rt, { registry = r.registry, ab = r.ab, lan = r.lan, auth = r.auth, dispatch = r.dispatch, cloud = r.cloud, hooks = hooks })
  r.lanPoll = LanPoll.new(rt, { ab = r.ab, registry = r.registry, lan = r.lan, dispatch = r.dispatch, router = r.router, hooks = hooks })
  r.cloudCheck = CloudCheck.new(rt, { cloud = r.cloud, registry = r.registry, ab = r.ab, router = r.router, hooks = { onRoute = function() end } })

  -- simulated cloud
  r.cloudSim = require("tests.cloud_sim").install(rt, r.sims)
  r.cloudCalls = r.cloudSim.calls

  return r
end

-- Add a simulated device, register its components, give it an address and bind children.
-- o.up = true starts it in LAN state Up with a fresh identity match; o.noAddress leaves it cloud-only.
function Rig:addDevice(id, simOpts, o)
  o = o or {}
  simOpts = simOpts or {}
  self.n = (self.n or 0) + 1
  simOpts.mac = simOpts.mac or string.format("AABBCC0000%02X", self.n)
  simOpts.addr = simOpts.addr or ("192.168.1." .. (40 + self.n))
  local sim = Sim.new(self.rt, simOpts)
  self.sims[id] = sim
  local st = U.deepcopy(sim.status); st.wifi = { sta_ip = sim.addr }
  local norm = Parse.device({ id = id, online = true, gen = "G2", code = "SNSW" }, st)
  self.registry:upsert(norm, "cloud")
  local d = self.ab:ensure(id)
  self.ab:setIdentity(id, { mac = sim.mac })
  if not o.noAddress then self.ab:setAddress(id, sim.addr, "cloud") end
  if o.up then self.ab:noteSuccess(id); self.ab:noteIdentityOk(id) end
  for _, c in ipairs(self.registry:componentsOf(id)) do
    self.childSeq = (self.childSeq or 1000) + 1
    self.registry:bindChild(c.key, self.childSeq)
  end
  return sim, d
end

function Rig:eventsOf(kind)
  local out = {}
  for _, e in ipairs(self.events) do if e.kind == kind then out[#out + 1] = e end end
  return out
end
function Rig:clearEvents() self.events = {} end
function Rig:lanCalls(id) return self.sims[id].calls end

return Rig
