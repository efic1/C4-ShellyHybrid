-- Runs every test file. Usage: lua5.1 tests/run_all.lua   (from the repo root)
package.path = "./src/?.lua;./?.lua;" .. package.path
local files = {
  "tests.test_common", "tests.test_persist", "tests.test_sched", "tests.test_cloudqueue",
  "tests.test_cloud", "tests.test_auth", "tests.test_lan", "tests.test_dispatch",
  "tests.test_addressbook", "tests.test_registry", "tests.test_router", "tests.test_feeds",
  "tests.test_hub", "tests.test_children", "tests.test_gen1", "tests.test_contact", "tests.test_alarms", "tests.test_router_paths", "tests.test_edges", "tests.test_variable_order", "tests.test_regressions", "tests.test_generator",
}
local COVER = os.getenv("COVER") and require("tests.cover")
if COVER then COVER.start() end
local H = require("tests.harness")
local failed, ran = 0, 0
for _, f in ipairs(files) do
  local path = f:gsub("%.", "/") .. ".lua"
  local fh = io.open(path, "r")
  if fh then
    fh:close()
    require(f)
    failed = failed + H.run(f:gsub("^tests%.", ""))
    ran = ran + 1
  end
end
if COVER then COVER.report(tonumber(os.getenv("COVER_MIN") or 0)) end
io.write(string.format("\n%d files, %s\n", ran, failed == 0 and "ALL PASSED" or (failed .. " FAILED")))
os.exit(failed == 0 and 0 or 1)
