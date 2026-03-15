local mutate4lua = require("mutate4lua")
local manifest = require("mutate4lua.internal.manifest")
local scanner = require("mutate4lua.internal.scanner")
local lexer = require("mutate4lua.internal.lexer")
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

test("public package exposes thin wrapper surface", function()
  local keys = {}
  for key in pairs(mutate4lua) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  assert_equal("function", type(mutate4lua.run))
  assert_equal("function", type(mutate4lua.usage))
  assert_equal("function", type(mutate4lua.resolve_engine))
  assert_equal("resolve_engine,run,usage", table.concat(keys, ","))
  assert_contains(mutate4lua.usage(), "mutate4lua <file.lua>")
end)

test("public run delegates directly to the configured engine binary", function()
  local root = temp_dir()
  local fake_engine = util.join_path(root, "fake-engine.sh")
  write(fake_engine, "#!/bin/sh\nprintf 'ENGINE %s\\n' \"$*\"\n")
  assert(util.command_succeeds("chmod +x " .. util.shell_quote(fake_engine)))

  local out = buffer()
  local err = buffer()
  local exit = mutate4lua.run({"help"}, util.absolute_path("."), out, err, {binary_path = fake_engine})
  assert_equal(0, exit)
  assert_contains(out:text(), "ENGINE help")
  assert_equal("", err:text())
end)
