-- Small pure helpers. No Control4 calls, no allocation in hot paths beyond what is noted.
local U = {}

function U.copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end

function U.deepcopy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = U.deepcopy(v) end
  return o
end

-- Equality of two flat tables (values compared with ==). nil-safe.
function U.flat_eq(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if b[k] ~= v then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

function U.sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

function U.clamp(n, lo, hi)
  if n < lo then return lo elseif n > hi then return hi end
  return n
end

function U.round(n) return math.floor(n + 0.5) end

function U.trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end

function U.normalize_mac(s)
  if type(s) ~= "string" then return nil end
  local m = s:gsub("[^%x]", ""):upper()
  if #m ~= 12 then return nil end
  return m
end

function U.is_ipv4(s)
  if type(s) ~= "string" then return false end
  local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return false end
  for _, p in ipairs({ a, b, c, d }) do if tonumber(p) > 255 then return false end end
  return a ~= "0" and s ~= "0.0.0.0"
end

function U.escape_pattern(s) return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")) end

function U.split(s, sep)
  local out, pat = {}, "([^" .. sep .. "]*)"
  for piece in (s .. sep):gmatch(pat .. sep) do out[#out + 1] = piece end
  return out
end

-- Device IDs come from the cloud as hex; normalise to lower-case without separators.
function U.norm_id(id)
  if id == nil then return nil end
  return (tostring(id):lower():gsub("[^%w]", ""))
end

function U.clock_str(ms)
  return os.date("%H:%M:%S", math.floor((ms or 0) / 1000))
end

return U
