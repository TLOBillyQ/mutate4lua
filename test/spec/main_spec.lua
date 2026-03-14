local main = require("mutate4lua.cli")
local mutate4lua = require("mutate4lua")
local manifest = require("mutate4lua.legacy.manifest")
local scanner = require("mutate4lua.legacy.scanner")
local lexer = require("mutate4lua.legacy.lexer")
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
local function write_passing_project(root)
  write(util.join_path(root, "src/demo/flag.lua"), [[
local M = {}
function M.enabled()
  return true
end
return M
]])
  write(util.join_path(root, "test/flag_test.lua"), [[
local flag = dofile("src/demo/flag.lua")
assert(flag.enabled() == true)
]])
end
test("scanner discovers operators and skips comments", function()
  local source = [[
local value = 0 -- true == false
return true and call()
]]
  local analysis = scanner.analyze("/tmp/sample.lua", "sample.lua", source)
  local descriptions = {}
  for _, site in ipairs(analysis.sites) do
    descriptions[#descriptions + 1] = site.description
  end
  assert_contains(table.concat(descriptions, "\n"), "replace 0 with 1")
  assert_contains(table.concat(descriptions, "\n"), "replace true with false")
  assert_contains(table.concat(descriptions, "\n"), "replace and with or")
  assert_contains(table.concat(descriptions, "\n"), "replace call() with nil")
  assert_not_contains(table.concat(descriptions, "\n"), "replace == with ~=")
end)

test("lexer counts newline after single-line comments once", function()
  local tokens = lexer.tokenize("local a = true -- comment\nlocal b = false\n")
  assert_equal(1, tokens[1].line)
  assert_equal(2, tokens[5].line)
  assert_equal("local", tokens[5].value)
end)

test("lexer parses hex, binary, and exponent numbers", function()
  local tokens = lexer.tokenize("local a=0xFF local b=0b1010 local c=1.5e-3\n")
  local numbers = {}
  for _, token in ipairs(tokens) do
    if token.type == "number" then
      numbers[#numbers + 1] = token.value
    end
  end
  assert_equal("0xFF", numbers[1])
  assert_equal("0b1010", numbers[2])
  assert_equal("1.5e-3", numbers[3])
end)
test("manifest roundtrip strips footer", function()
  local path = util.tmp_path(".lua")
  write(path, "return true\n")
  manifest.write(path, "return true\n", {
    version = 1,
    project_hash = "abc",
    scopes = {
      {id = "chunk:file", kind = "chunk", start_line = 1, end_line = 1, semantic_hash = "xyz"},
    },
  })
  local loaded = manifest.read(path)
  assert_equal("abc", loaded.project_hash)
  assert_equal("chunk:file", loaded.scopes[1].id)
  local stripped = manifest.strip(assert(util.read_file(path)))
  assert_equal("return true\n", stripped)
end)
test("public package exposes run and usage from lua layout", function()
  assert_equal("function", type(mutate4lua.run))
  assert_equal("function", type(mutate4lua.usage))
  assert_contains(mutate4lua.usage(), "mutate4lua <file.lua>")
end)
test("mutates a real lua project", function()
  local root = temp_dir()
  write_passing_project(root)
  local out = buffer()
  local err = buffer()
  local exit = main.run({"src/demo/flag.lua"}, root, out, err)
  assert_equal(0, exit)
  assert_contains(out.text(), "KILLED src/demo/flag.lua:3 replace true with false")
  assert_contains(out.text(), "Summary: 1 killed, 0 survived, 1 total.")
  assert_equal("", err.text())
end)
test("fails fast when baseline tests are red", function()
  local root = temp_dir()
  write_passing_project(root)
  write(util.join_path(root, "test/flag_test.lua"), [[
local flag = dofile("src/demo/flag.lua")
assert(flag.enabled() == false)
]])
  local out = buffer()
  local err = buffer()
  local exit = main.run({"src/demo/flag.lua"}, root, out, err)
  assert_equal(2, exit)
  assert_contains(err.text(), "Baseline tests failed.")
end)
test("updates manifest without running tests", function()
  local root = temp_dir()
  write_passing_project(root)
  write(util.join_path(root, "test/flag_test.lua"), [[
assert(false)
]])
  local out = buffer()
  local err = buffer()
  local exit = main.run({"src/demo/flag.lua", "--update-manifest"}, root, out, err)
  assert_equal(0, exit)
  assert_contains(out.text(), "Updated manifest for src/demo/flag.lua")
  assert_equal("", err.text())
  assert_contains(assert(util.read_file(util.join_path(root, "src/demo/flag.lua"))), "mutate4lua-manifest")
end)
test("scan marks changed scopes when manifest differs", function()
  local root = temp_dir()
  write_passing_project(root)
  local first_out = buffer()
  local first_err = buffer()
  assert_equal(0, main.run({"src/demo/flag.lua", "--update-manifest"}, root, first_out, first_err))
  local path = util.join_path(root, "src/demo/flag.lua")
  local current = assert(util.read_file(path))
  current = current:gsub("return true", "return false")
  write(path, current)
  local out = buffer()
  local err = buffer()
  local exit = main.run({"src/demo/flag.lua", "--scan"}, root, out, err)
  assert_equal(0, exit)
  assert_contains(out.text(), "* src/demo/flag.lua:3 replace false with true")
  assert_contains(out.text(), "* indicates a scope that differs from the embedded manifest.")
end)
