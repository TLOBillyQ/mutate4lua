local mutate4lua = require("mutate4lua")
local util = require("mutate4lua.util")

local function temp_dir()
  local path = util.tmp_path(".dir")
  util.remove(path)
  util.mkdir_p(path)
  return path
end

local function write(path, content)
  util.mkdir_p(util.parent_dir(path))
  assert(util.write_file(path, content))
end

test("absolute and relative path helpers no longer rely on python", function()
  local root = temp_dir()
  local nested = util.join_path(root, "alpha", "beta", "file.lua")
  write(nested, "return true\n")

  local absolute = util.absolute_path(util.join_path(root, "alpha", ".", "beta", "..", "beta", "file.lua"))
  local relative = util.relative_path(root, absolute)

  assert_equal(util.normalize_relative_path(nested), util.normalize_relative_path(absolute))
  assert_equal("alpha/beta/file.lua", relative)
end)

test("default max workers returns a positive integer without python", function()
  local workers = util.default_max_workers()
  assert_equal(true, type(workers) == "number")
  assert_equal(true, workers >= 1)
  assert_equal(workers, math.floor(workers))
end)

test("engine resolution prefers explicit environment path", function()
  local root = temp_dir()
  local custom = util.join_path(root, "bin", "custom-engine")
  write(custom, "#!/bin/sh\nexit 0\n")
  assert(util.command_succeeds("chmod +x " .. util.shell_quote(custom)))
  local resolved = assert(mutate4lua.resolve_engine({binary_path = custom}))
  assert_equal(util.absolute_path(custom), resolved)
end)

test("bin wrapper works without python helper file", function()
  local repo_root = util.absolute_path(".")
  local helper_path = util.join_path(repo_root, "tools", "process_helper.py")
  local fake_root = temp_dir()
  local fake_engine = util.join_path(fake_root, "engine.sh")
  write(fake_engine, "#!/bin/sh\nprintf 'WRAPPER %s\\n' \"$*\"\n")
  assert(util.command_succeeds("chmod +x " .. util.shell_quote(fake_engine)))
  assert_equal(false, util.is_file(helper_path))

  local command = table.concat({
    "cd", util.shell_quote(repo_root), "&&",
    "MUTATE4LUA_ENGINE_BIN=" .. util.shell_quote(fake_engine),
    "lua", util.shell_quote("bin/mutate4lua"), "help",
  }, " ")
  local output = assert(util.capture(command))
  assert_contains(output, "WRAPPER help")
end)
