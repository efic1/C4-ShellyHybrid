-- Minimal test harness (Lua 5.1, no dependencies).
local H = { tests = {}, current = nil }

function H.test(name, fn) H.tests[#H.tests + 1] = { name = name, fn = fn } end

local function show(v, depth)
  depth = depth or 0
  if type(v) == "table" then
    if depth > 3 then return "{...}" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. show(v[k], depth + 1) end
    return "{" .. table.concat(out, ", ") .. "}"
  end
  return type(v) == "string" and string.format("%q", v) or tostring(v)
end
H.show = show

local function deep_eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
H.deep_eq = deep_eq

function H.eq(actual, expected, msg)
  if not deep_eq(actual, expected) then
    error((msg and (msg .. ": ") or "") .. "expected " .. show(expected) .. " got " .. show(actual), 2)
  end
end
function H.truthy(v, msg) if not v then error(msg or "expected truthy, got " .. show(v), 2) end end
function H.falsy(v, msg) if v then error(msg or "expected falsy, got " .. show(v), 2) end end
function H.contains(hay, needle, msg)
  if type(hay) ~= "string" or not hay:find(needle, 1, true) then
    error((msg or "expected string to contain") .. ": " .. show(needle) .. " in " .. show(hay), 2)
  end
end
function H.not_contains(hay, needle, msg)
  if type(hay) == "string" and hay:find(needle, 1, true) then
    error((msg or "expected string NOT to contain") .. ": " .. show(needle), 2)
  end
end
function H.near(a, b, tol, msg)
  if math.abs(a - b) > (tol or 1e-6) then error((msg or "near") .. ": " .. tostring(a) .. " vs " .. tostring(b), 2) end
end

function H.run(title)
  local pass, fail = 0, 0
  for _, t in ipairs(H.tests) do
    local ok, err = xpcall(t.fn, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
    if ok then pass = pass + 1 else
      fail = fail + 1
      io.write("  FAIL  ", t.name, "\n        ", (tostring(err):gsub("\n", "\n        ")), "\n")
    end
  end
  io.write(string.format("%-28s %3d passed, %d failed\n", title or "tests", pass, fail))
  H.tests = {}
  return fail
end
return H
