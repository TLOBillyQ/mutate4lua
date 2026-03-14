package.path = table.concat({
  "src/?.lua",
  "src/?/init.lua",
  package.path,
}, ";")
local tests = {}
function test(name, fn)
  tests[#tests + 1] = {name = name, fn = fn}
end
function assert_equal(expected, actual)
  if expected ~= actual then
    error(string.format("expected %s but got %s", tostring(expected), tostring(actual)), 2)
  end
end
function assert_contains(haystack, needle)
  if not haystack:find(needle, 1, true) then
    error(string.format("expected to find %q in %q", needle, haystack), 2)
  end
end
function assert_not_contains(haystack, needle)
  if haystack:find(needle, 1, true) then
    error(string.format("expected not to find %q in %q", needle, haystack), 2)
  end
end
for file in io.popen("find test/spec -type f -name '*_spec.lua' | sort", "r"):lines() do
  dofile(file)
end
local passed = 0
for _, entry in ipairs(tests) do
  local ok, err = xpcall(entry.fn, debug.traceback)
  if ok then
    io.stdout:write("PASS ", entry.name, "\n")
    passed = passed + 1
  else
    io.stderr:write("FAIL ", entry.name, "\n", err, "\n")
  end
end
if passed ~= #tests then
  io.stderr:write(string.format("%d/%d tests passed\n", passed, #tests))
  os.exit(1)
end
io.stdout:write(string.format("%d/%d tests passed\n", passed, #tests))
