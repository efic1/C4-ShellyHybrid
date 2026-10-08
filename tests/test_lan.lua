local H = require("tests.harness")
local F = require("tests.fakes")
local Sim = require("tests.lan_sim")
local Auth = require("hub.transport.lan_auth")
local Lan = require("hub.transport.lan")
local test, eq, truthy, falsy, contains, not_contains = H.test, H.eq, H.truthy, H.falsy, H.contains, H.not_contains

local function setup(simOpts, password)
  local rt = F.new()
  local sim = Sim.new(rt, simOpts)
  local auth = Auth.new(rt)
  local lan = Lan.new(rt, auth)
  lan.passwordFor = function() return password end
  local d = { id = "b48a0a1cd978", address = sim.addr }
  return rt, sim, lan, d, auth
end
local function run(rt, fn) local o, r; fn(function(a, b) o, r = a, b end); rt.advance(5000); return o, r end

test("lan: probe (plain HTTP) learns scheme, identity and that auth is off", function()
  local rt, sim, lan, d = setup()
  local out, info = run(rt, function(cb) lan:probe(d, cb) end)
  truthy(out.ok); eq(info.scheme, "http"); eq(info.identity.mac, "B48A0A1CD978"); eq(info.authRequired, false)
  eq(d.scheme, "http"); eq(d.authRequired, false)
  eq(rt.http.log[1].spec.headers.Authorization, nil, "probe never carries credentials")
end)

test("lan: probe follows an http->https redirect on the same host and remembers https", function()
  local rt, sim, lan, d = setup({ mode = "redirect" })
  local out, info = run(rt, function(cb) lan:probe(d, cb) end)
  truthy(out.ok); eq(info.scheme, "https"); eq(d.scheme, "https")
end)

test("lan: probe falls back to https when plain HTTP is refused", function()
  local rt, sim, lan, d = setup({ mode = "https-only" })
  local out, info = run(rt, function(cb) lan:probe(d, cb) end)
  truthy(out.ok); eq(info.scheme, "https")
end)

test("lan: a redirect to another host is refused, never followed", function()
  local rt = F.new()
  rt.http.on("://192.168.1.40", function() return F.resp(302, "", { location = "https://evil.example.com/shelly" }) end)
  local lan = Lan.new(rt, Auth.new(rt))
  local out = run(rt, function(cb) lan:probe({ id = "x", address = "192.168.1.40" }, cb) end)
  falsy(out.ok); eq(out.class, "UNREACHABLE")
  for _, r in ipairs(rt.http.log) do not_contains(r.url, "evil.example.com") end
end)

test("lan: a Gen1 device at the address is rejected as unsupported", function()
  local rt, sim, lan, d = setup({ gen = 1 })
  local out = run(rt, function(cb) lan:probe(d, cb) end)
  falsy(out.ok); eq(out.class, "CONFIG")
end)

test("lan: probe of a dead address is UNREACHABLE", function()
  local rt, sim, lan, d = setup({ mode = "dead" })
  local out = run(rt, function(cb) lan:probe(d, cb) end)
  eq(out.class, "UNREACHABLE")
end)

test("lan: control is POST /rpc/<Method> with a JSON body and NO query string", function()
  local rt, sim, lan, d = setup()
  local out = run(rt, function(cb) lan:set(d, "switch", 0, { on = true }, cb) end)
  truthy(out.ok)
  local req = rt.http.log[1]
  eq(req.method, "POST"); eq(req.url, "http://192.168.1.40/rpc/Switch.Set")
  eq(rt.json.decode(req.body), { id = 0, on = true })
  eq(req.spec.timeout, 3); eq(req.spec.verify, false, "LAN TLS verification defaults to off")
end)

test("lan: intent mapping for switch, light and cover (absolute commands only)", function()
  local rt, sim, lan, d = setup()
  local function last() return sim.calls[#sim.calls] end
  run(rt, function(cb) lan:set(d, "light", 1, { level = 0 }, cb) end)
  eq(last(), { method = "Light.Set", params = { id = 1, on = false } })
  run(rt, function(cb) lan:set(d, "light", 0, { level = 42.6 }, cb) end)
  eq(last(), { method = "Light.Set", params = { id = 0, on = true, brightness = 43 } })
  run(rt, function(cb) lan:set(d, "cover", 0, { position = 130 }, cb) end)
  eq(last(), { method = "Cover.GoToPosition", params = { id = 0, pos = 100 } })
  for _, m in ipairs({ "open", "close", "stop" }) do
    run(rt, function(cb) lan:set(d, "cover", 0, { cover = m }, cb) end)
    eq(last().method, "Cover." .. m:sub(1, 1):upper() .. m:sub(2))
  end
  run(rt, function(cb) lan:set(d, "switch", 0, { on = true, toggle_after = 2 }, cb) end)
  eq(last().params, { id = 0, on = true, toggle_after = 2 })
  for _, c in ipairs(sim.calls) do
    not_contains(c.method, "Toggle")
    falsy(c.params.rel, "no relative moves")
  end
end)

test("lan: status returns a normalised device and no address (the LAN address is authoritative)", function()
  local rt, sim, lan, d = setup()
  local out, dev = run(rt, function(cb) lan:status(d, cb) end)
  truthy(out.ok); eq(dev.identity.mac, "B48A0A1CD978"); eq(dev.address, nil); eq(#dev.components, 3)
end)

test("lan: authenticated device: challenge is answered once, then the nonce is reused (no extra round trip)", function()
  local rt, sim, lan, d, auth = setup({ password = "s3cret-pass" }, "s3cret-pass")
  local o1 = run(rt, function(cb) lan:set(d, "switch", 0, { on = true }, cb) end)
  truthy(o1.ok, o1.reason)
  eq(#rt.http.log, 2, "unauthenticated request + credentialed retry")
  local o2 = run(rt, function(cb) lan:set(d, "switch", 0, { on = false }, cb) end)
  truthy(o2.ok); eq(#rt.http.log, 3, "second command needs no challenge round trip")
  eq(sim.rejected, 0); eq(sim.challenges, 1)
end)

test("lan: WRONG password: exactly one credentialed attempt, then a stop; later calls send NO credentials", function()
  local rt, sim, lan, d, auth = setup({ password = "right-pass" }, "wrong-pass")
  local out = run(rt, function(cb) lan:set(d, "switch", 0, { on = true }, cb) end)
  eq(out.class, "AUTH"); truthy(out.rejected)
  eq(auth:credentialedRequests(d.id), 1)
  for i = 1, 5 do run(rt, function(cb) lan:status(d, cb) end) end
  eq(auth:credentialedRequests(d.id), 1, "no further credentialed request is ever sent to a device we were refused by")
  eq(sim.rejected, 1)
end)

test("lan: no password configured for a protected device is AUTH/needsPassword, nothing credentialed sent", function()
  local rt, sim, lan, d, auth = setup({ password = "right-pass" }, nil)
  local out = run(rt, function(cb) lan:set(d, "switch", 0, { on = true }, cb) end)
  eq(out.class, "AUTH"); truthy(out.needsPassword); eq(auth:credentialedRequests(d.id), 0)
end)

test("lan: a stale nonce after a known-good password gets ONE fresh-nonce retry and is not a lockout", function()
  local rt, sim, lan, d, auth = setup({ password = "good-pass" }, "good-pass")
  truthy(run(rt, function(cb) lan:set(d, "switch", 0, { on = true }, cb) end).ok)
  sim:rotateNonce()                                        -- device restarted / nonce expired
  local out = run(rt, function(cb) lan:set(d, "switch", 0, { on = false }, cb) end)
  truthy(out.ok, out.reason)
  falsy(auth:isStopped(d.id, "good-pass"))
  eq(sim.rejected, 0)
end)

test("lan: after a password change lifts a stop, authentication works again", function()
  local rt, sim, lan, d, auth = setup({ password = "right-pass" }, "wrong-pass")
  run(rt, function(cb) lan:set(d, "switch", 0, { on = true }, cb) end)
  lan.passwordFor = function() return "right-pass" end
  local out = run(rt, function(cb) lan:set(d, "switch", 0, { on = true }, cb) end)
  truthy(out.ok, out.reason)
end)

test("lan: device-level errors are DEVICE (answered), network failures are UNREACHABLE", function()
  local rt, sim, lan, d = setup()
  sim.errorFor["Switch.Set"] = { code = -105, message = "Argument 'id', value 7 not found" }
  local out = run(rt, function(cb) lan:set(d, "switch", 7, { on = true }, cb) end)
  eq(out.class, "DEVICE"); contains(out.reason, "not found")
  sim.mode = "dead"
  eq(run(rt, function(cb) lan:set(d, "switch", 0, { on = true }, cb) end).class, "UNREACHABLE")
  local rt2 = F.new()
  rt2.http.on("192.168", function() return F.resp(503, "") end)
  local lan2 = Lan.new(rt2, Auth.new(rt2))
  eq(run(rt2, function(cb) lan2:set({ id = "x", address = "192.168.1.9" }, "switch", 0, { on = true }, cb) end).class, "UNREACHABLE")
end)

test("lan: a device without an address is UNREACHABLE without any request", function()
  local rt = F.new()
  local lan = Lan.new(rt, Auth.new(rt))
  local out = run(rt, function(cb) lan:set({ id = "x" }, "switch", 0, { on = true }, cb) end)
  eq(out.class, "UNREACHABLE"); eq(#rt.http.log, 0)
end)

test("lan: identity comparison: mac first, then id suffix, otherwise unknown", function()
  eq(Lan.sameIdentity({ mac = "AA" }, { mac = "AA" }), true)
  eq(Lan.sameIdentity({ mac = "AA" }, { mac = "BB" }), false)
  eq(Lan.sameIdentity({ id = "shellyplus1pm-b48a0a1cd978" }, { id = "b48a0a1cd978" }), true)
  eq(Lan.sameIdentity({ id = "shellyplus1pm-b48a0a1cd978" }, { id = "shellypro2-aaaaaaaaaaaa" }), false)
    eq(Lan.sameIdentity({ id = "b48a0a1cd978" }, { mac = "B48A0A1CD978" }), true, "cloud id vs LAN mac")
  eq(Lan.sameIdentity({ id = "b48a0a1cd978" }, { mac = "AABBCCDDEEFF" }), false)
  eq(Lan.sameIdentity({}, { mac = "AA" }), nil)
  eq(Lan.sameIdentity(nil, { mac = "AA" }), nil)
end)

test("lan: the device password never reaches the log", function()
  local rt, sim, lan, d = setup({ password = "very-secret-pw" }, "very-secret-pw")
  rt.log:setSecret("devPass", "very-secret-pw")
  run(rt, function(cb) lan:set(d, "switch", 0, { on = true }, cb) end)
  for _, r in ipairs(rt.http.log) do
    rt.log:debug("request %s auth=%s", r.url, tostring(r.headers and r.headers.Authorization))
  end
  not_contains(rt.output(), "very-secret-pw")
  contains(rt.output(), 'response="******"')       -- the digest value itself is masked
  local real = rt.http.log[#rt.http.log].headers.Authorization:match('response="(%x+)"')
  truthy(real, "a credentialed request was made")
  not_contains(rt.output(), real)
end)

test("lan: Cover.* and Light.Set answer with the JSON literal null on success (per the Shelly docs) and that is success", function()
  local rt, sim, lan, d = setup()
  for _, it in ipairs({ { "cover", 0, { cover = "open" } }, { "cover", 0, { cover = "stop" } }, { "cover", 0, { position = 40 } },
                        { "light", 0, { level = 60 } }, { "light", 0, { on = false } } }) do
    local out = run(rt, function(cb) lan:set(d, it[1], it[2], it[3], cb) end)
    truthy(out.ok, it[1] .. " " .. H.show(it[3]))
  end
end)

test("lan: a 200 that is not JSON (captive portal, proxy page) is NOT a successful command", function()
  local rt, sim, lan, d = setup()
  rt.http.on(function(spec) return spec.url:find("192.168.1.40", 1, true) end, function() return F.resp(200, "<html>sign in</html>") end)
  local out = run(rt, function(cb) lan:set(d, "switch", 0, { on = true }, cb) end)
  falsy(out.ok); eq(out.class, "UNREACHABLE")
end)

test("lan: HTTP 429 (firmware 2.0 throttling) is a transient UNREACHABLE, never a DEVICE error", function()
  local rt, sim, lan, d = setup({ throttle = true })
  local out = run(rt, function(cb) lan:set(d, "switch", 0, { on = true }, cb) end)
  falsy(out.ok); eq(out.class, "UNREACHABLE"); contains(out.reason, "429")
end)

test("lan: the digest realm is the device id - a DIFFERENT device is never given credentials", function()
  local rt, sim, lan, d = setup({ password = "right", mac = "AABBCCDDEEFF" }, "right")
  d.identity = { mac = "B48A0A1CD978" }                         -- we expect a different device at this address
  local out = run(rt, function(cb) lan:call(d, "Shelly.GetStatus", {}, cb) end)
  falsy(out.ok); eq(out.class, "UNREACHABLE"); truthy(out.identityMismatch)
  eq(sim.rejected, 0, "no login attempt reached the stranger")
  for _, r in ipairs(rt.http.log) do eq(r.spec.headers and r.spec.headers.Authorization, nil) end
end)

test("lan: the realm check passes for the right device (mac in the realm)", function()
  local rt, sim, lan, d = setup({ password = "right" }, "right")
  d.identity = { mac = "B48A0A1CD978" }
  truthy((run(rt, function(cb) lan:call(d, "Shelly.GetStatus", {}, cb) end)).ok)
end)

test("lan: Enhanced Security (port 80 redirects to HTTPS, enhanced_security=true) is learned by the probe", function()
  local rt, sim, lan, d = setup({ enhanced = true })
  local out, info = run(rt, function(cb) lan:probe(d, cb) end)
  truthy(out.ok); eq(d.scheme, "https"); eq(info.scheme, "https")
  local before = rt.http.count("http://")
  truthy(run(rt, function(cb) lan:set(d, "switch", 0, { on = true }, cb) end).ok)
  eq(rt.http.count("http://"), before, "later commands go straight to HTTPS")
end)

test("lan: a light's RATE becomes Light.Set transition_duration in seconds; below the device's 0.5 s minimum it is left out", function()
  local rt, sim, lan, d = setup()
  local function last() return sim.calls[#sim.calls].params end
  run(rt, function(cb) lan:set(d, "light", 0, { level = 60, rate = 2500 }, cb) end)
  eq(last().brightness, 60); eq(last().transition_duration, 2.5)
  run(rt, function(cb) lan:set(d, "light", 0, { level = 0, rate = 8000 }, cb) end)
  eq(last().on, false); eq(last().transition_duration, 8)
  run(rt, function(cb) lan:set(d, "light", 0, { level = 30, rate = 200 }, cb) end)
  eq(last().transition_duration, nil)
  run(rt, function(cb) lan:set(d, "light", 0, { level = 30 }, cb) end)
  eq(last().transition_duration, nil)
  run(rt, function(cb) lan:set(d, "light", 0, { level = 30, rate = 99999999 }, cb) end)
  eq(last().transition_duration, 10800)
end)
