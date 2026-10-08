-- Levelled logger with secret redaction and a small in-memory activity ring.
-- Performance: a call below the active level returns before touching its varargs,
-- redaction runs only on lines that will actually be emitted, and the ring holds
-- at most `ringMax` short strings.
local U = require("common.util")

local Log = {}
Log.__index = Log
Log.LEVELS = { Error = 1, Warning = 2, Info = 3, Debug = 4 }

function Log.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Log)
  self.name = opts.name or "shelly"
  self.level = Log.LEVELS[opts.level or "Info"] or 3
  self.sink = opts.sink or function(line) print(line) end
  self.clock = opts.clock or function() return 0 end
  self.secrets = {}          -- kind -> { plain, pat }
  self.ring, self.ringMax, self.ringN = {}, opts.ringMax or 25, 0
  self.onRecord = opts.onRecord
  self.errors, self.warnings = 0, 0
  return self
end

function Log:setLevel(name)
  self.level = Log.LEVELS[name] or self.level
end

function Log:isDebug() return self.level >= 4 end
function Log:levelName()
  for k, v in pairs(Log.LEVELS) do if v == self.level then return k end end
end

-- Register (or replace, or clear with nil) a secret by kind so it is scrubbed from all output.
function Log:setSecret(kind, value)
  if type(value) == "string" and #value >= 4 then
    self.secrets[kind] = { plain = value, pat = U.escape_pattern(value) }
  else
    self.secrets[kind] = nil
  end
end

function Log:redact(s)
  if type(s) ~= "string" then s = tostring(s) end
  for _, sec in pairs(self.secrets) do s = s:gsub(sec.pat, "******") end
  s = s:gsub("auth_key=[^&%s\"']+", "auth_key=******")
  s = s:gsub("(response=\")[^\"]*\"", "%1******\"")
  s = s:gsub("([Aa]uthorization:%s*)[^\r\n]+", "%1******")
  return s
end

local TAGS = { "ERROR", "WARN", "INFO", "DEBUG" }

local function emit(self, lvl, fmt, ...)
  local msg
  if select("#", ...) == 0 then
    msg = tostring(fmt)
  else
    local ok, r = pcall(string.format, fmt, ...)
    msg = ok and r or (tostring(fmt) .. " [format error]")
  end
  msg = self:redact(msg)
  self.sink("[" .. self.name .. "] " .. TAGS[lvl] .. ": " .. msg)
  if lvl == 1 then self.errors = self.errors + 1 elseif lvl == 2 then self.warnings = self.warnings + 1 end
  if lvl <= 3 then
    self.ringN = self.ringN + 1
    self.ring[(self.ringN - 1) % self.ringMax + 1] = { t = self.clock(), m = msg }
    if self.onRecord then self.onRecord() end
  end
end

function Log:error(fmt, ...) if self.level >= 1 then emit(self, 1, fmt, ...) end end
function Log:warn(fmt, ...)  if self.level >= 2 then emit(self, 2, fmt, ...) end end
function Log:info(fmt, ...)  if self.level >= 3 then emit(self, 3, fmt, ...) end end
function Log:debug(fmt, ...) if self.level >= 4 then emit(self, 4, fmt, ...) end end

-- Multi-line report: goes to the sink only, never into the activity ring.
function Log:block(lines)
  for i = 1, #lines do self.sink(self:redact(lines[i])) end
end

-- Newest first, at most n entries.
function Log:recent(n)
  local out = {}
  local total = math.min(self.ringN, self.ringMax)
  n = math.min(n or total, total)
  for i = 0, n - 1 do
    local e = self.ring[(self.ringN - 1 - i) % self.ringMax + 1]
    out[#out + 1] = U.clock_str(e.t) .. " " .. e.m
  end
  return out
end

function Log:recentText(n, maxChars)
  local text = table.concat(self:recent(n), " | ")
  maxChars = maxChars or 500
  if #text > maxChars then text = text:sub(1, maxChars - 3) .. "..." end
  return text
end

return Log
