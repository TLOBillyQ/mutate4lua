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

local function stub_engine_env(capture)
  return {
    stdout = null_buffer(),
    stderr = null_buffer(),
    engine = {
      mutate = function(options)
        capture.options = options
        return 0
      end,
      scan = function(options)
        capture.options = options
        return 0
      end,
      update_manifest = function(options)
        capture.options = options
        return 0
      end,
    },
  }
end

describe("cli defaults", function()
  it("defaults timeout-factor to 10", function()
    local capture = {}
    cli.run({ "target.lua", "--mutate-all" }, stub_engine_env(capture))
    assert.are.equal(10, capture.options.timeout_factor)
  end)

  it("defaults mutation-warning to 50", function()
    local capture = {}
    cli.run({ "target.lua", "--mutate-all" }, stub_engine_env(capture))
    assert.are.equal(50, capture.options.mutation_warning)
  end)

  it("leaves max-workers unset so the engine computes the default", function()
    local capture = {}
    cli.run({ "target.lua", "--mutate-all" }, stub_engine_env(capture))
    assert.is_nil(capture.options.max_workers)
  end)
end)

describe("cli option parsing", function()
  it("parses --since-last-run", function()
    local capture = {}
    cli.run({ "target.lua", "--since-last-run" }, stub_engine_env(capture))
    assert.is_true(capture.options.since_last_run)
  end)

  it("parses --reuse-coverage", function()
    local capture = {}
    cli.run({ "target.lua", "--reuse-coverage" }, stub_engine_env(capture))
    assert.is_true(capture.options.reuse_coverage)
  end)

  it("parses --timeout-factor", function()
    local capture = {}
    cli.run({ "target.lua", "--timeout-factor", "7" }, stub_engine_env(capture))
    assert.are.equal(7, capture.options.timeout_factor)
  end)

  it("parses --mutation-warning", function()
    local capture = {}
    cli.run({ "target.lua", "--mutation-warning", "12" }, stub_engine_env(capture))
    assert.are.equal(12, capture.options.mutation_warning)
  end)

  it("parses --lines into a line set", function()
    local capture = {}
    cli.run({ "target.lua", "--lines", "1,3,5" }, stub_engine_env(capture))
    assert.is_true(capture.options.line_set[1])
    assert.is_true(capture.options.line_set[3])
    assert.is_true(capture.options.line_set[5])
    assert.is_nil(capture.options.line_set[2])
  end)
end)

describe("cli conflict rules", function()
  local function expect_conflict(args)
    local err = {}
    local code = cli.run(args, {
      stdout = null_buffer(),
      stderr = capture_buffer(err),
      engine = stub_engine_env({}).engine,
    })
    assert.are.equal(1, code)
    assert.matches("error:", table.concat(err))
  end

  it("rejects --scan with --since-last-run", function()
    expect_conflict({ "m.lua", "--scan", "--since-last-run" })
  end)

  it("rejects --scan with --mutate-all", function()
    expect_conflict({ "m.lua", "--scan", "--mutate-all" })
  end)

  it("rejects --scan with --update-manifest", function()
    expect_conflict({ "m.lua", "--scan", "--update-manifest" })
  end)

  it("rejects --scan with --reuse-coverage", function()
    expect_conflict({ "m.lua", "--scan", "--reuse-coverage" })
  end)

  it("rejects --lines with --since-last-run", function()
    expect_conflict({ "m.lua", "--lines", "1", "--since-last-run" })
  end)

  it("rejects --lines with --mutate-all", function()
    expect_conflict({ "m.lua", "--lines", "1", "--mutate-all" })
  end)

  it("rejects --lines with --update-manifest", function()
    expect_conflict({ "m.lua", "--lines", "1", "--update-manifest" })
  end)

  it("rejects --since-last-run with --mutate-all", function()
    expect_conflict({ "m.lua", "--since-last-run", "--mutate-all" })
  end)

  it("rejects --update-manifest with --since-last-run", function()
    expect_conflict({ "m.lua", "--update-manifest", "--since-last-run" })
  end)

  it("rejects --update-manifest with --mutate-all", function()
    expect_conflict({ "m.lua", "--update-manifest", "--mutate-all" })
  end)

  it("rejects --update-manifest with --reuse-coverage", function()
    expect_conflict({ "m.lua", "--update-manifest", "--reuse-coverage" })
  end)
end)

describe("cli removed options", function()
  local function expect_unknown(args)
    local err = {}
    local code = cli.run(args, {
      stdout = null_buffer(),
      stderr = capture_buffer(err),
      engine = stub_engine_env({}).engine,
    })
    assert.are.equal(1, code)
    assert.matches("unknown option", table.concat(err))
  end

  it("rejects --lane", function()
    expect_unknown({ "m.lua", "--lane", "behavior" })
  end)

  it("rejects --runner", function()
    expect_unknown({ "m.lua", "--runner", "busted" })
  end)

  it("rejects --dry-run", function()
    expect_unknown({ "m.lua", "--dry-run" })
  end)

  it("rejects --poll-interval", function()
    expect_unknown({ "m.lua", "--poll-interval", "0.1" })
  end)

  it("rejects --json", function()
    expect_unknown({ "m.lua", "--json" })
  end)

  it("rejects --migrate-manifest", function()
    expect_unknown({ "m.lua", "--migrate-manifest" })
  end)

  it("rejects --index-suites", function()
    expect_unknown({ "--index-suites" })
  end)
end)

describe("cli driver resolution", function()
  it("passes env.default_driver through as the driver script", function()
    local capture = {}
    local env = stub_engine_env(capture)
    env.default_driver = "tools/mutate_driver.lua"
    cli.run({ "target.lua", "--mutate-all" }, env)
    assert.are.equal("tools/mutate_driver.lua", capture.options.driver_script)
  end)

  it("leaves driver_script nil when the host provides no driver", function()
    local capture = {}
    cli.run({ "target.lua", "--mutate-all" }, stub_engine_env(capture))
    assert.is_nil(capture.options.driver_script)
  end)
end)

describe("cli subcommand routing", function()
  it("routes --scan to engine.scan", function()
    local capture = {}
    cli.run({ "m.lua", "--scan" }, stub_engine_env(capture))
    assert.are.equal("scan", capture.options.subcommand)
  end)

  it("routes --update-manifest to engine.update_manifest", function()
    local capture = {}
    cli.run({ "m.lua", "--update-manifest" }, stub_engine_env(capture))
    assert.are.equal("update-manifest", capture.options.subcommand)
  end)

  it("routes default to engine.mutate", function()
    local capture = {}
    cli.run({ "m.lua" }, stub_engine_env(capture))
    assert.are.equal("mutate", capture.options.subcommand)
  end)
end)
