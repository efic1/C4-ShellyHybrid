-- Line coverage for the bundled drivers (no external dependency). Usage:  COVER=1 lua5.1 tests/run_all.lua   (or: lua5.1 tests/cover.lua)
-- Hits are recorded per bundle line with debug.sethook, then mapped back to src/ modules through the __src["module"] markers.
-- Executable lines come from `luac5.1 -l -p`. Output: per-module table, and uncovered lines in tests/.cover/<module>.txt.
local C = { hits = {} }

local function bundleFiles()
  local list = {}
  local p = io.popen("ls build/*/driver.lua 2>/dev/null")
  for line in p:lines() do list[#list + 1] = line end
  p:close()
  return list
end

function C.start()
  local hits = C.hits
  local hook = function(_, line)
    local info = debug.getinfo(2, "S")
    local src = info and info.source
    if src and (src:sub(1, 7) == "@build/" or src:sub(1, 7) == "@./src/") then
      local t = hits[src]
      if not t then t = {}; hits[src] = t end
      t[line] = true
    end
  end
  C.hook = hook
  debug.sethook(hook, "l")
  -- coroutines get their own hook
  local create = coroutine.create
  coroutine.create = function(f) local co = create(f); debug.sethook(co, hook, "l"); return co end
end

local function executableLines(path)
  local set = {}
  local p = io.popen("luac5.1 -l -p " .. path .. " 2>/dev/null")
  for l in p:lines() do
    local n = l:match("^%s*%d+%s+%[(%d+)%]")
    if n then set[tonumber(n)] = true end
  end
  p:close()
  return set
end

function C.report(minShow)
  debug.sethook()
  os.execute("mkdir -p tests/.cover")
  local mods = {}                                    -- module -> { key = { [srcLine] = { text, hit } } }
  local function rec(name) local r = mods[name]; if not r then r = { key = {} }; mods[name] = r end; return r end
  local p = io.popen("find src -name '*.lua' | sort")
  local srcFiles = {}
  for l in p:lines() do srcFiles[#srcFiles + 1] = l end
  p:close()
  for _, path in ipairs(srcFiles) do
    local name = path:gsub("^src/", ""):gsub("%.lua$", ""):gsub("/", ".")
    if name ~= "common.ids" and not name:match("%.driver$") then                      -- generated
      local lines = {}
      local f = io.open(path)
      for l in f:lines() do lines[#lines + 1] = l end
      f:close()
      local r = rec(name)
      local hit = C.hits["@./" .. path] or {}
      for n in pairs(executableLines(path)) do
        if lines[n] and lines[n]:match("%S") and not lines[n]:match("^%s*end[%s%),]*$") then
          r.key[n] = { text = lines[n], hit = hit[n] and true or false }
        end
      end
    end
  end
  -- bundle hits count for the same source line (the real drivers run the same code)
  for _, path in ipairs(bundleFiles()) do
    local lines, markers = {}, {}
    local f = io.open(path)
    for l in f:lines() do lines[#lines + 1] = l end
    f:close()
    for i, l in ipairs(lines) do
      local m = l:match('^__src%["([^"]+)"%] = function')
      if m then markers[#markers + 1] = { name = m, at = i } end
    end
    for n in pairs(C.hits["@" .. path] or {}) do
      local mk
      for _, m in ipairs(markers) do if m.at < n then mk = m else break end end
      local r = mk and mods[mk.name]
      local k = r and r.key[n - mk.at]
      if k then k.hit = true end
    end
  end
  local names = {}
  for n in pairs(mods) do names[#names + 1] = n end
  table.sort(names)
  local tE, tH = 0, 0
  local rows = {}
  for _, n in ipairs(names) do
    local e, h, miss = 0, 0, {}
    for ln, k in pairs(mods[n].key) do
      e = e + 1
      if k.hit then h = h + 1 else miss[#miss + 1] = { ln, k.text } end
    end
    table.sort(miss, function(a, b) return a[1] < b[1] end)
    tE, tH = tE + e, tH + h
    rows[#rows + 1] = { n, e, h }
    local out = io.open("tests/.cover/" .. n .. ".txt", "w")
    for _, m in ipairs(miss) do out:write(string.format("%4d  %s\n", m[1], m[2])) end
    out:close()
  end
  table.sort(rows, function(a, b) return (a[2] - a[3]) > (b[2] - b[3]) end)
  io.write(string.format("\n%-34s %6s %6s %6s\n", "module", "lines", "hit", "cover"))
  for _, r in ipairs(rows) do
    if r[2] - r[3] >= (minShow or 0) then io.write(string.format("%-34s %6d %6d %5.1f%%\n", r[1], r[2], r[3], r[2] == 0 and 100 or 100 * r[3] / r[2])) end
  end
  io.write(string.format("%-34s %6d %6d %5.1f%%\n", "TOTAL", tE, tH, 100 * tH / tE))
end

return C
