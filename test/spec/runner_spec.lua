local main = require("mutate4lua.main")
local runner = require("mutate4lua.runner")
local util = require("mutate4lua.util")

local function buffer()
  local pieces = {}
  return {
    write = function(_, text)
      pieces[#pieces + 1] = text
    end,
    text = function()
      return table.concat(pieces)
    end,
  }
end

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

test("runner normalizes coverage paths", function()
  local path = util.tmp_path(".coverage")
  write(path, "./src/demo/flag.lua:3\n.\\src\\demo\\flag.lua:4\nsrc/demo/flag.lua:5\n")
  local coverage = runner.read_coverage(path)
  assert_equal(true, coverage["src/demo/flag.lua:3"])
  assert_equal(true, coverage["src/demo/flag.lua:4"])
  assert_equal(true, coverage["src/demo/flag.lua:5"])
end)

test("baseline coverage cache skips rerunning unchanged baseline", function()
  local root = temp_dir()
  local target = util.join_path(root, "src/demo/plain.lua")
  local counter = util.join_path(root, "counter.txt")
  write(target, [[
local M = {}
function M.value(input)
  return input
end
return M
]])
  write(util.join_path(root, "test/plain_test.lua"), string.format([[
local path = %q
local handle = io.open(path, "r")
local count = 0
if handle then
  count = tonumber(handle:read("*a")) or 0
  handle:close()
end
handle = assert(io.open(path, "w"))
handle:write(tostring(count + 1))
handle:close()
local module = dofile("src/demo/plain.lua")
assert(module.value("ok") == "ok")
]], counter))

  local out = buffer()
  local err = buffer()
  assert_equal(0, main.run({"src/demo/plain.lua"}, root, out, err))
  assert_equal("1", util.trim(assert(util.read_file(counter))))

  out = buffer()
  err = buffer()
  assert_equal(0, main.run({"src/demo/plain.lua"}, root, out, err))
  assert_equal("1", util.trim(assert(util.read_file(counter))))
end)
