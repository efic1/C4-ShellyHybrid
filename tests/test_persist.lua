local H = require("tests.harness")
local F = require("tests.fakes")
local Persist = require("common.persist")
local test, eq, truthy, falsy, contains = H.test, H.eq, H.truthy, H.falsy, H.contains

test("persist: base64 round-trips arbitrary bytes", function()
  for _, s in ipairs({ "", "a", "ab", "abc", "abcd", "\0\1\2\255\254", string.rep("xyz", 1000) }) do
    eq(Persist.b64dec(Persist.b64enc(s)), s)
  end
end)

test("persist: write then read returns the exact text, split into parts of at most 600 chars", function()
  local rt = F.new()
  local p = Persist.new(rt)
  local big = string.rep('{"a":"héllo\\n","b":[1,2,3]}', 200)
  p:write("k", big)
  eq(p:read("k"), big)
  local n = tonumber(rt.committed.k:match("^SHBLOB1:(%d+):"))
  truthy(n > 1)
  for i = 1, n do truthy(#rt.committed["k.part" .. i] <= 600 + 6) end
end)

test("persist: header is written last (a crash mid-write cannot yield a valid but wrong blob)", function()
  local rt = F.new()
  local order = {}
  local set = rt.store.set
  rt.store.set = function(k, v) order[#order + 1] = k; set(k, v) end
  Persist.new(rt):write("k", string.rep("x", 2000))
  eq(order[#order], "k")
end)

test("persist: corrupted part or header is rejected, never returned as data", function()
  local rt = F.new()
  local p = Persist.new(rt)
  p:write("k", "hello world")
  rt.committed["k.part1"] = "SHB64:AAAA"
  local s, why = p:read("k")
  eq(s, nil); truthy(why)
  eq(p:read("missing"), nil)
  rt.committed.k = "garbage"
  eq(select(2, p:read("k")), "bad header")
end)

test("persist: shrinking a value removes the stale trailing parts", function()
  local rt = F.new()
  local p = Persist.new(rt)
  p:write("k", string.rep("y", 3000))
  truthy(rt.committed["k.part3"])
  p:write("k", "tiny")
  eq(rt.committed["k.part3"], nil)
  eq(p:read("k"), "tiny")
end)

test("persist: a store that becomes readable late is verified on the timers, not trusted immediately", function()
  local rt = F.new({ storeDelay = 3000 })
  local p = Persist.new(rt)
  p:write("k", "delayed value")
  eq(p:read("k"), nil, "not readable straight after the write on this controller")
  eq(p:pendingVerifications(), 1)
  rt.advance(6000)
  eq(p:read("k"), "delayed value")
  eq(p:pendingVerifications(), 0)
  eq(#rt.errors, 0)
end)

test("persist: a write that never becomes readable is reported with the first differing position", function()
  local rt = F.new()
  local p = Persist.new(rt)
  p:write("k", "abcdef")
  rt.store.get = function(k) return nil end
  rt.advance(200000)
  contains(rt.output(), "failed verification")
end)

test("persist: tables round-trip through JSON", function()
  local rt = F.new()
  local p = Persist.new(rt)
  p:writeTable("t", { a = 1, b = { "x", "y" }, c = true })
  eq(p:readTable("t"), { a = 1, b = { "x", "y" }, c = true })
end)
