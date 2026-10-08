-- Small pure-Lua JSON codec used by the test fakes (stands in for C4:JsonEncode/JsonDecode).
-- null decodes to nil (like C4:JsonDecode without decodeNull). Keys are sorted on encode
-- so output is deterministic.
local J = {}
local esc = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function estr(s)
  return '"' .. s:gsub('[%c"\\]', function(c) return esc[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end
local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    n = n + 1
  end
  return n == #t
end
function J.encode(v)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number" then
    if v % 1 == 0 and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.14g", v)
  elseif t == "string" then return estr(v)
  elseif t == "table" then
    if next(v) == nil then return "{}" end
    if is_array(v) then
      local o = {}
      for i = 1, #v do o[i] = J.encode(v[i]) end
      return "[" .. table.concat(o, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local o = {}
    for _, k in ipairs(keys) do
      local val = v[k]
      if val == nil then val = v[tonumber(k)] end
      o[#o + 1] = estr(k) .. ":" .. J.encode(val)
    end
    return "{" .. table.concat(o, ",") .. "}"
  end
  error("cannot encode " .. t)
end

local function skip(s, i) return s:find("[^ \t\r\n]", i) or #s + 1 end
local parse_value
local function parse_string(s, i)
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == "" then error("unterminated string") end
    if c == '"' then return table.concat(out), j + 1 end
    if c == "\\" then
      local n = s:sub(j + 1, j + 1)
      local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
      if n == "u" then
        local code = tonumber(s:sub(j + 2, j + 5), 16)
        out[#out + 1] = code < 128 and string.char(code) or "?"
        j = j + 6
      else out[#out + 1] = map[n] or n; j = j + 2 end
    else out[#out + 1] = c; j = j + 1 end
  end
end
function parse_value(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return t, i + 1 end
    while true do
      i = skip(s, i)
      local k; k, i = parse_string(s, i)
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then error("expected : at " .. i) end
      local v; v, i = parse_value(s, i + 1)
      t[k] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "}" then return t, i + 1 end
      if d ~= "," then error("expected , or } at " .. i) end
      i = i + 1
    end
  elseif c == "[" then
    local t, n = {}, 0
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return t, i + 1 end
    while true do
      local v; v, i = parse_value(s, i)
      n = n + 1; t[n] = v
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "]" then return t, i + 1 end
      if d ~= "," then error("expected , or ] at " .. i) end
      i = i + 1
    end
  elseif c == '"' then return parse_string(s, i)
  elseif s:sub(i, i + 3) == "true" then return true, i + 4
  elseif s:sub(i, i + 4) == "false" then return false, i + 5
  elseif s:sub(i, i + 3) == "null" then return nil, i + 4
  else
    local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
    if not num or num == "" then error("bad json at " .. i) end
    return tonumber(num), i + #num
  end
end
function J.decode(s)
  if type(s) ~= "string" then return nil, "not a string" end
  local ok, v = pcall(function() local val = parse_value(s, 1); return val end)
  if not ok then return nil, tostring(v) end
  return v
end
return J
