local function shell_quote(value)
  value = tostring(value)
  if value:find("%z") then
    error("cannot quote path with NUL byte")
  end
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function is_absolute(path)
  path = tostring(path or "")
  return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

local function normalize(path)
  path = tostring(path or ""):gsub("\\", "/")
  local prefix = ""
  if path:sub(1, 1) == "/" then
    prefix = "/"
    path = path:sub(2)
  elseif path:match("^%a:/") then
    prefix = path:sub(1, 3)
    path = path:sub(4)
  end
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 then
        parts[#parts] = nil
      elseif prefix == "" then
        parts[#parts + 1] = part
      end
    elseif part ~= "." and part ~= "" then
      parts[#parts + 1] = part
    end
  end
  local joined = table.concat(parts, "/")
  if prefix == "" then
    return joined == "" and "." or joined
  end
  return joined == "" and prefix:gsub("/$", "") or (prefix .. joined)
end

local function current_dir()
  local pwd = os.getenv("PWD")
  if pwd and pwd ~= "" then
    return pwd
  end
  local handle = assert(io.popen("pwd", "r"))
  local output = handle:read("*l")
  handle:close()
  return output
end

local function dirname(path)
  path = normalize(path):gsub("/+$", "")
  return path:match("^(.*)/[^/]+$") or "."
end

local function script_path()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  if not is_absolute(source) then
    source = current_dir() .. "/" .. source
  end
  return normalize(source)
end

local test_dir = dirname(script_path())
local repo_root = dirname(test_dir)
_G.MUTATE4LUA_TEST_ROOT = repo_root

package.path = table.concat({
  repo_root .. "/lib/?.lua",
  repo_root .. "/lib/?/init.lua",
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
local spec_dir = repo_root .. "/test/spec"
for file in io.popen("find " .. shell_quote(spec_dir) .. " -type f -name '*_spec.lua' | sort", "r"):lines() do
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
