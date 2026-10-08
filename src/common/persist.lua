-- Blob persistence, with delayed read-back verification.
-- Lessons carried over from C4-PimaForce (see docs/ARCHITECTURE.md "Persistence"):
--   * store text as base64 in parts <= 600 chars so no escape processing, charset
--     conversion or JSON decoding can alter it;
--   * write the header LAST, and describe part count, length and checksum in it;
--   * a value is not readable immediately after PersistSetValue on a real controller,
--     so verification runs later on timers instead of trusting the write.
local Persist = {}
Persist.__index = Persist

local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local REV = {}
for i = 1, #ALPHA do REV[ALPHA:byte(i)] = i - 1 end
local PART = 600

local function b64enc(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1, c2 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64
    local c3, c4 = math.floor(n / 64) % 64, n % 64
    out[#out + 1] = ALPHA:sub(c1 + 1, c1 + 1) .. ALPHA:sub(c2 + 1, c2 + 1)
      .. (b and ALPHA:sub(c3 + 1, c3 + 1) or "=") .. (c and ALPHA:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end

local function b64dec(s)
  local out = {}
  s = s:gsub("[^%w%+/=]", "")
  for i = 1, #s, 4 do
    local a, b, c, d = s:byte(i, i + 3)
    local n = (REV[a] or 0) * 262144 + (REV[b] or 0) * 4096 + (REV[c] or 0) * 64 + (REV[d] or 0)
    local x, y, z = math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
    if c == 61 then out[#out + 1] = string.char(x)
    elseif d == 61 then out[#out + 1] = string.char(x, y)
    else out[#out + 1] = string.char(x, y, z) end
  end
  return table.concat(out)
end

local function adler(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

Persist.b64enc, Persist.b64dec, Persist.adler = b64enc, b64dec, adler

-- rt: store{get,set,delete?}, sched, log, json
function Persist.new(rt)
  return setmetatable({ rt = rt, expected = {}, parts = {}, verifyIds = {} }, Persist)
end

function Persist:write(key, str)
  local store, enc = self.rt.store, b64enc(str)
  local n = math.max(1, math.ceil(#enc / PART))
  for i = 1, n do store.set(key .. ".part" .. i, "SHB64:" .. enc:sub((i - 1) * PART + 1, i * PART)) end
  local old = self.parts[key] or 0
  for i = n + 1, old do (store.delete or function(k) store.set(k, "") end)(key .. ".part" .. i) end
  self.parts[key] = n
  store.set(key, string.format("SHBLOB1:%d:%d:%d", n, #str, adler(str)))
  self.expected[key] = str
  self:scheduleVerify(key, 1)
end

function Persist:read(key)
  local head = self.rt.store.get(key)
  if type(head) ~= "string" then return nil, "no header" end
  local n, len, sum = head:match("^SHBLOB1:(%d+):(%d+):(%d+)$")
  if not n then return nil, "bad header" end
  n, len, sum = tonumber(n), tonumber(len), tonumber(sum)
  local parts = {}
  for i = 1, n do
    local p = self.rt.store.get(key .. ".part" .. i)
    if type(p) ~= "string" or p:sub(1, 6) ~= "SHB64:" then return nil, "missing part " .. i end
    parts[i] = p:sub(7)
  end
  local str = b64dec(table.concat(parts))
  if #str ~= len then return nil, "length mismatch" end
  if adler(str) ~= sum then return nil, "checksum mismatch" end
  self.parts[key] = n
  return str
end

local DELAYS = { 5000, 30000, 120000 }

function Persist:scheduleVerify(key, attempt)
  local sched = self.rt.sched
  sched:cancel(self.verifyIds[key])
  self.verifyIds[key] = sched:after(DELAYS[attempt], function()
    local want = self.expected[key]
    local got, why = self:read(key)
    if got == want then
      self.expected[key] = nil
      self.rt.log:debug("persist %s verified", key)
    elseif attempt < #DELAYS then
      self:scheduleVerify(key, attempt + 1)
    else
      local pos = 0
      if got and want then
        pos = 1
        while pos <= #want and got:byte(pos) == want:byte(pos) do pos = pos + 1 end
      end
      self.rt.log:error("persist %s failed verification (%s, first difference at %d)", key, tostring(why), pos)
    end
  end)
end

function Persist:writeTable(key, tbl) self:write(key, self.rt.json.encode(tbl)) end
function Persist:readTable(key)
  local s, err = self:read(key)
  if not s then return nil, err end
  return self.rt.json.decode(s)
end

function Persist:pendingVerifications()
  local n = 0
  for _ in pairs(self.expected) do n = n + 1 end
  return n
end

return Persist
