local lu = require("luaunit")
local cli = require("mutate4lua.cli")

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

-- luaunit's assertStrMatches anchors the pattern (full match); this helper
-- keeps the old substring-match semantics. Lua patterns' "." matches newlines.
local function assertMatches(pat, str)
  lu.assertStrMatches(str, ".*" .. pat .. ".*")
end

TestCli = {}

-- defaults

function TestCli:testDefaultsTimeoutFactorTo10()
  local capture = {}
  cli.run({ "target.lua", "--mutate-all" }, stub_engine_env(capture))
  lu.assertEquals(capture.options.timeout_factor, 10)
end

function TestCli:testDefaultsMutationWarningTo50()
  local capture = {}
  cli.run({ "target.lua", "--mutate-all" }, stub_engine_env(capture))
  lu.assertEquals(capture.options.mutation_warning, 50)
end

function TestCli:testLeavesMaxWorkersUnsetSoEngineComputesDefault()
  local capture = {}
  cli.run({ "target.lua", "--mutate-all" }, stub_engine_env(capture))
  lu.assertNil(capture.options.max_workers)
end

-- option parsing

function TestCli:testParsesSinceLastRun()
  local capture = {}
  cli.run({ "target.lua", "--since-last-run" }, stub_engine_env(capture))
  lu.assertTrue(capture.options.since_last_run)
end

function TestCli:testParsesReuseCoverage()
  local capture = {}
  cli.run({ "target.lua", "--reuse-coverage" }, stub_engine_env(capture))
  lu.assertTrue(capture.options.reuse_coverage)
end

function TestCli:testParsesTimeoutFactor()
  local capture = {}
  cli.run({ "target.lua", "--timeout-factor", "7" }, stub_engine_env(capture))
  lu.assertEquals(capture.options.timeout_factor, 7)
end

function TestCli:testParsesMutationWarning()
  local capture = {}
  cli.run({ "target.lua", "--mutation-warning", "12" }, stub_engine_env(capture))
  lu.assertEquals(capture.options.mutation_warning, 12)
end

function TestCli:testParsesLinesIntoLineSet()
  local capture = {}
  cli.run({ "target.lua", "--lines", "1,3,5" }, stub_engine_env(capture))
  lu.assertTrue(capture.options.line_set[1])
  lu.assertTrue(capture.options.line_set[3])
  lu.assertTrue(capture.options.line_set[5])
  lu.assertNil(capture.options.line_set[2])
end

-- conflict rules

local function expect_conflict(args)
  local err = {}
  local code = cli.run(args, {
    stdout = null_buffer(),
    stderr = capture_buffer(err),
    engine = stub_engine_env({}).engine,
  })
  lu.assertEquals(code, 1)
  assertMatches("error:", table.concat(err))
end

function TestCli:testRejectsScanWithSinceLastRun()
  expect_conflict({ "m.lua", "--scan", "--since-last-run" })
end

function TestCli:testRejectsScanWithMutateAll()
  expect_conflict({ "m.lua", "--scan", "--mutate-all" })
end

function TestCli:testRejectsScanWithUpdateManifest()
  expect_conflict({ "m.lua", "--scan", "--update-manifest" })
end

function TestCli:testRejectsScanWithReuseCoverage()
  expect_conflict({ "m.lua", "--scan", "--reuse-coverage" })
end

function TestCli:testRejectsLinesWithSinceLastRun()
  expect_conflict({ "m.lua", "--lines", "1", "--since-last-run" })
end

function TestCli:testRejectsLinesWithMutateAll()
  expect_conflict({ "m.lua", "--lines", "1", "--mutate-all" })
end

function TestCli:testRejectsLinesWithUpdateManifest()
  expect_conflict({ "m.lua", "--lines", "1", "--update-manifest" })
end

function TestCli:testRejectsSinceLastRunWithMutateAll()
  expect_conflict({ "m.lua", "--since-last-run", "--mutate-all" })
end

function TestCli:testRejectsUpdateManifestWithSinceLastRun()
  expect_conflict({ "m.lua", "--update-manifest", "--since-last-run" })
end

function TestCli:testRejectsUpdateManifestWithMutateAll()
  expect_conflict({ "m.lua", "--update-manifest", "--mutate-all" })
end

function TestCli:testRejectsUpdateManifestWithReuseCoverage()
  expect_conflict({ "m.lua", "--update-manifest", "--reuse-coverage" })
end

-- removed options

local function expect_unknown(args)
  local err = {}
  local code = cli.run(args, {
    stdout = null_buffer(),
    stderr = capture_buffer(err),
    engine = stub_engine_env({}).engine,
  })
  lu.assertEquals(code, 1)
  assertMatches("unknown option", table.concat(err))
end

function TestCli:testRejectsLane()
  expect_unknown({ "m.lua", "--lane", "behavior" })
end

function TestCli:testRejectsRunner()
  expect_unknown({ "m.lua", "--runner", "busted" })
end

function TestCli:testRejectsDryRun()
  expect_unknown({ "m.lua", "--dry-run" })
end

function TestCli:testRejectsPollInterval()
  expect_unknown({ "m.lua", "--poll-interval", "0.1" })
end

function TestCli:testRejectsJson()
  expect_unknown({ "m.lua", "--json" })
end

function TestCli:testRejectsMigrateManifest()
  expect_unknown({ "m.lua", "--migrate-manifest" })
end

function TestCli:testRejectsIndexSuites()
  expect_unknown({ "--index-suites" })
end

-- ADR-0005: the env.default_driver hook is gone; runs always go through the
-- built-in runner (or --test-command), so options no longer carry a driver.

function TestCli:testIgnoresLegacyEnvDefaultDriver()
  local capture = {}
  local env = stub_engine_env(capture)
  env.default_driver = "tools/mutate_driver.lua"
  cli.run({ "target.lua", "--mutate-all" }, env)
  lu.assertNil(capture.options.driver_script)
end

-- subcommand routing

function TestCli:testRoutesScanToEngineScan()
  local capture = {}
  cli.run({ "m.lua", "--scan" }, stub_engine_env(capture))
  lu.assertEquals(capture.options.subcommand, "scan")
end

function TestCli:testRoutesUpdateManifestToEngineUpdateManifest()
  local capture = {}
  cli.run({ "m.lua", "--update-manifest" }, stub_engine_env(capture))
  lu.assertEquals(capture.options.subcommand, "update-manifest")
end

function TestCli:testRoutesDefaultToEngineMutate()
  local capture = {}
  cli.run({ "m.lua" }, stub_engine_env(capture))
  lu.assertEquals(capture.options.subcommand, "mutate")
end

return TestCli
