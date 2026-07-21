local cli = require("mutate4lua.cli")
local util = require("mutate4lua.util")

local function null_buffer()
  return { write = function() end }
end

local function capture_buffer(sink)
  return { write = function(_, ...)
    for _, piece in ipairs({...}) do sink[#sink + 1] = tostring(piece) end
  end }
end

local function tmp_dir()
  local base = os.tmpname()
  os.remove(base)
  util.mkdir_p(base)
  return base
end

local function rm_rf(path)
  os.execute("rm -rf " .. string.format("%q", path))
end

local function write_file(path, content)
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

local function stub_env(capture)
  return {
    stdout = null_buffer(),
    stderr = null_buffer(),
    engine = {
      mutate = function(options)
        capture.options = options
        return 0
      end,
    },
  }
end

describe("cli --poll-interval", function()
  it("parses --poll-interval into the mutate options", function()
    local capture = {}
    cli.run({ "target.lua", "--mutate-all", "--poll-interval", "0.05" }, stub_env(capture))
    assert.are.equal(0.05, capture.options.poll_interval)
  end)

  it("leaves poll_interval unset when the flag is absent", function()
    local capture = {}
    cli.run({ "target.lua", "--mutate-all" }, stub_env(capture))
    assert.is_nil(capture.options.poll_interval)
  end)
end)


describe("cli driver resolution", function()
  it("passes env.default_driver through as the driver script", function()
    local capture = {}
    local env = stub_env(capture)
    env.default_driver = "tools/mutate_driver.lua"
    cli.run({ "target.lua", "--mutate-all" }, env)
    assert.are.equal("tools/mutate_driver.lua", capture.options.driver_script)
  end)

  it("passes env.busted_driver through for the busted runner", function()
    local capture = {}
    local env = stub_env(capture)
    env.busted_driver = "tools/busted_driver.lua"
    cli.run({ "target.lua", "--runner", "busted" }, env)
    assert.are.equal("tools/busted_driver.lua", capture.options.driver_script)
  end)

  it("leaves driver_script nil when the host provides no driver", function()
    -- The library ships no default driver path; the engine reports a clear
    -- error where a driver is actually needed.
    local capture = {}
    cli.run({ "target.lua", "--mutate-all" }, stub_env(capture))
    assert.is_nil(capture.options.driver_script)
  end)
end)

describe("cli missing driver", function()
  local dir
  before_each(function()
    dir = tmp_dir()
    write_file(util.join_path(dir, "m.lua"), "return true\n")
  end)
  after_each(function() rm_rf(dir) end)

  it("errors clearly for the harness runner without env.default_driver", function()
    local err = {}
    local code = cli.run({ "m.lua" }, {
      cwd = dir,
      stdout = null_buffer(),
      stderr = capture_buffer(err),
    })
    assert.are.equal(1, code)
    assert.matches("driver script required", table.concat(err))
  end)

  it("errors clearly for the busted runner without env.busted_driver", function()
    local err = {}
    local code = cli.run({ "m.lua", "--runner", "busted" }, {
      cwd = dir,
      stdout = null_buffer(),
      stderr = capture_buffer(err),
    })
    assert.are.equal(1, code)
    assert.matches("driver script required", table.concat(err))
  end)
end)

describe("cli --migrate-manifest", function()
  local dir
  before_each(function()
    dir = tmp_dir()
    write_file(util.join_path(dir, "m.lua"), "return true\n")
  end)
  after_each(function() rm_rf(dir) end)

  it("routes the subcommand to the engine", function()
    local capture = {}
    local env = {
      stdout = null_buffer(),
      stderr = null_buffer(),
      engine = {
        migrate_manifest = function(options)
          capture.options = options
          return 0
        end,
      },
    }
    cli.run({ "m.lua", "--migrate-manifest" }, env)
    assert.are.equal("migrate-manifest", capture.options.subcommand)
  end)

  it("rejects --dry-run combined with --migrate-manifest", function()
    local err = {}
    local code = cli.run({ "m.lua", "--migrate-manifest", "--dry-run" }, {
      cwd = dir,
      stdout = null_buffer(),
      stderr = capture_buffer(err),
      engine = stub_env({}).engine,
    })
    assert.are.equal(1, code)
    assert.matches("%-%-dry%-run cannot be combined with %-%-migrate%-manifest", table.concat(err))
  end)
end)
