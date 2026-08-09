local lu = require("luaunit")
local manifest = require("mutate4lua.internal.manifest")
local attribution = require("mutate4lua.internal.attribution")
local engine = require("mutate4lua.engine")
local util = require("mutate4lua.util")

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

local function read_file(path)
  local f = io.open(path, "rb")
  if f == nil then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

local function null_buffer()
  return {write = function() end}
end

local function capture_buffer(sink)
  return {write = function(_, ...)
    for _, piece in ipairs({...}) do sink[#sink + 1] = tostring(piece) end
  end}
end

-- luaunit's assertStrMatches anchors the pattern (full match); this helper
-- keeps the old substring-match semantics. Lua patterns' "." matches newlines.
local function assertMatches(pat, str)
  lu.assertStrMatches(str, ".*" .. pat .. ".*")
end

local function make_shell(returns)
  local n = 0
  local self = {commands = {}}
  function self.fn(cmd, _cwd, _timeout)
    n = n + 1
    self.commands[n] = cmd
    local r = returns[n] or {ok = true}
    return {
      ok = r.ok,
      code = r.code or (r.ok and 0 or 1),
      output = r.output or "",
      elapsed = r.elapsed or 0,
    }
  end
  function self.count() return n end
  return self
end

TestEngine = {}

function TestEngine:setUp()
  self.dir = tmp_dir()
  self.target_rel = "m.lua"
  self.target_abs = util.join_path(self.dir, self.target_rel)
end

function TestEngine:tearDown()
  rm_rf(self.dir)
end

function TestEngine:null_env()
  return {cwd = self.dir, stdout = null_buffer(), stderr = null_buffer()}
end

-- update_manifest

function TestEngine:testUpdateManifestWritesV4FooterWithoutRunningTests()
  write_file(self.target_abs, "return true\n")
  local out = {}
  local code = engine.update_manifest({target = self.target_rel}, {
    cwd = self.dir, stdout = capture_buffer(out), stderr = null_buffer(),
  })
  lu.assertEquals(code, 0)
  assertMatches("manifest updated: m%.lua", table.concat(out))
  local data = manifest.read(self.target_abs)
  lu.assertNotNil(data)
  lu.assertEquals(data.version, 4)
  for _, scope in ipairs(data.scopes) do
    lu.assertNil(scope.last_mutated_at)
    lu.assertNil(scope.last_mutation_status)
  end
end

function TestEngine:testUpdateManifestSucceedsEvenWhenTargetTestSuiteWouldFail()
  write_file(self.target_abs, "return true\n")
  local code = engine.update_manifest({target = self.target_rel}, self:null_env())
  lu.assertEquals(code, 0)
end

-- mutate write gating

function TestEngine:testWritesV4FooterWhenAllMutantsKilledAndLinesUnset()
  write_file(self.target_abs, "return 1 == 2\n")
  local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  engine.mutate({target = self.target_rel, test_command = "true", max_workers = 1}, env)
  local data = manifest.read(self.target_abs)
  lu.assertNotNil(data)
  lu.assertEquals(data.version, 4)
end

function TestEngine:testDoesNotWriteFooterWhenMutantSurvives()
  write_file(self.target_abs, "return 1 == 2\n")
  local shell = make_shell({{ok = true}, {ok = true}})
  local env = self:null_env()
  env.run_shell = shell.fn
  engine.mutate({target = self.target_rel, test_command = "true", max_workers = 1}, env)
  lu.assertNil(manifest.read(self.target_abs))
end

function TestEngine:testSuppressesFooterWhenLinesIsUsed()
  write_file(self.target_abs, "return 1 == 2\n")
  local shell = make_shell({{ok = true}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  engine.mutate({
    target = self.target_rel,
    test_command = "true",
    line_set = {[1] = true},
    max_workers = 1,
  }, env)
  lu.assertNil(manifest.read(self.target_abs))
end

-- exit codes

function TestEngine:testReturns2WhenBaselineFails()
  write_file(self.target_abs, "return 1 == 2\n")
  local shell = make_shell({{ok = false, code = 1}})
  local env = self:null_env()
  env.run_shell = shell.fn
  local code = engine.mutate({target = self.target_rel, test_command = "false", max_workers = 1}, env)
  lu.assertEquals(code, 2)
end

function TestEngine:testReturns3WhenMutantSurvives()
  write_file(self.target_abs, "return 1 == 2\n")
  local shell = make_shell({{ok = true}, {ok = true}})
  local env = self:null_env()
  env.run_shell = shell.fn
  local code = engine.mutate({target = self.target_rel, test_command = "true", max_workers = 1}, env)
  lu.assertEquals(code, 3)
end

function TestEngine:testReturns0WhenEveryMutantKilled()
  write_file(self.target_abs, "return 1 == 2\n")
  local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  local code = engine.mutate({target = self.target_rel, test_command = "true", max_workers = 1}, env)
  lu.assertEquals(code, 0)
end

-- differential selection

function TestEngine:rewrite_preserving_footer(transform)
  local content = assert(read_file(self.target_abs))
  local stripped = manifest.strip(content)
  local new_stripped = transform(stripped)
  if not new_stripped:match("\n$") then
    new_stripped = new_stripped .. "\n"
  end
  local footer = content:sub(#stripped + 1)
  write_file(self.target_abs, new_stripped .. footer)
end

function TestEngine:testRunsNoSitesAndNoBaselineWhenManifestUnchanged()
  write_file(self.target_abs, "local function f() return 1 == 2 end\nreturn f\n")
  engine.update_manifest({target = self.target_rel}, self:null_env())
  self:rewrite_preserving_footer(function(s) return s end)
  local shell = make_shell({})
  local env = self:null_env()
  env.run_shell = shell.fn
  local code = engine.mutate({target = self.target_rel, test_command = "true", max_workers = 1}, env)
  lu.assertEquals(code, 0)
  lu.assertEquals(shell.count(), 0)
end

function TestEngine:testSelectsAllCoveredSitesWhenNoManifestExists()
  write_file(self.target_abs, "return 1 == 2\n")
  local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  engine.mutate({target = self.target_rel, test_command = "true", max_workers = 1}, env)
  lu.assertTrue(shell.count() >= 2, "expected baseline + at least one mutant")
end

function TestEngine:testSelectsOnlySitesInChangedScopesWhenModuleHashChanges()
  write_file(self.target_abs, "local function f() return 1 == 2 end\nlocal function g() return 3 == 4 end\nreturn f\n")
  engine.update_manifest({target = self.target_rel}, self:null_env())
  self:rewrite_preserving_footer(function(s)
    return s:gsub("return 1 == 2", "return 2 ~= 3")
  end)
  local shell = make_shell({{ok = true}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  engine.mutate({target = self.target_rel, test_command = "true", max_workers = 1}, env)
  -- f is changed (now one site); g is unchanged. Baseline + 1 mutant ran.
  lu.assertEquals(shell.count(), 2)
end

function TestEngine:testTreatsStaleV3ManifestAsInvalidAndRescansAllSites()
  write_file(self.target_abs, "return 1 == 2\n")
  engine.update_manifest({target = self.target_rel}, self:null_env())
  -- downgrade the freshly-written footer's format version (4 -> 3), the
  -- pre-AST-hash format: it must NOT be trusted, even though its hashes
  -- were computed by the current algorithm and would otherwise compare equal.
  local content = assert(read_file(self.target_abs))
  local stripped = manifest.strip(content)
  local footer = content:sub(#stripped + 1):gsub("version=4", "version=3")
  write_file(self.target_abs, stripped .. footer)
  local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  engine.mutate({target = self.target_rel, test_command = "true", max_workers = 1}, env)
  -- a trusted v3 footer would suppress differential selection (0 runs);
  -- invalidation forces baseline + both mutants (3 runs)
  lu.assertEquals(shell.count(), 3)
end

function TestEngine:testMutateAllBypassesManifestFilter()
  write_file(self.target_abs, "return 1 == 2\n")
  engine.update_manifest({target = self.target_rel}, self:null_env())
  local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  engine.mutate({target = self.target_rel, test_command = "true", mutate_all = true, max_workers = 1}, env)
  lu.assertTrue(shell.count() >= 2)
end

function TestEngine:testSinceLastRunRestrictsToChangedScopesEvenWhenModuleHashUnchanged()
  write_file(self.target_abs, "local function f() return 1 == 2 end\nreturn f\n")
  engine.update_manifest({target = self.target_rel}, self:null_env())
  self:rewrite_preserving_footer(function(s) return s end)
  local shell = make_shell({})
  local env = self:null_env()
  env.run_shell = shell.fn
  local code = engine.mutate({target = self.target_rel, test_command = "true", since_last_run = true, max_workers = 1}, env)
  lu.assertEquals(code, 0)
  lu.assertEquals(shell.count(), 0)
end

-- coverage handling

local function make_luacov_report(target_rel, hits)
  -- hits is an array indexed by source line: true/numeric = covered,
  -- false = uncovered executable, nil = non-executable.
  local lines = {
    "==============================================================================",
    target_rel,
    "==============================================================================",
  }
  for i = 1, #hits do
    local kind = hits[i]
    if kind == nil then
      lines[#lines + 1] = "        -- non-executable"
    elseif kind == false then
      lines[#lines + 1] = "  *0    print(" .. i .. ")"
    else
      lines[#lines + 1] = string.format("%6d    print(%d)", (tonumber(kind) or 1), i)
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

function TestEngine:testWarnsAndTreatsAllSitesCoveredWhenTestCommandUsed()
  write_file(self.target_abs, "return 1 == 2\n")
  local err = {}
  local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  env.stderr = capture_buffer(err)
  engine.mutate({target = self.target_rel, test_command = "true", max_workers = 1}, env)
  assertMatches("test%-command disables coverage filtering", table.concat(err))
end

-- Coverage filtering now comes from the attribution matrix (#21), not
-- luacov.report.out. Seed a fresh matrix under .mutate4lua/attribution/ so the
-- engine path exercises the matrix-derived filter without a real suite.
local function seed_attribution_matrix(dir, target_rel, stripped, covered_lines)
  local test_dir = util.join_path(dir, "tests")
  util.mkdir_p(test_dir)
  local test_path = util.join_path(test_dir, "test_seed.lua")
  write_file(test_path, "return {}\n")
  local suite_hash = assert(attribution.suite_hash(dir, {test_path}))
  local target_hash = attribution.target_hash(stripped)
  local matrix = {
    version = attribution.CURRENT_MATRIX_VERSION,
    target = target_rel,
    suite_hash = suite_hash,
    target_hash = target_hash,
    load_lines_known = true,
    load_lines = {},
    failing_files = {},
    files = {["tests/test_seed.lua"] = covered_lines},
  }
  assert(attribution.save(dir, target_rel, matrix))
end

function TestEngine:testFiltersUncoveredSitesUsingAttributionMatrix()
  write_file(self.target_abs, "local x = 1\nlocal y = 2\nreturn x == y\n")
  -- Mutation site is on line 3 (the == comparison); mark no lines covered.
  seed_attribution_matrix(self.dir, self.target_rel, "local x = 1\nlocal y = 2\nreturn x == y\n", {})
  local shell = make_shell({{ok = true}})
  local out = {}
  local env = self:null_env()
  env.run_shell = shell.fn
  env.stdout = capture_buffer(out)
  local code = engine.mutate({target = self.target_rel, max_workers = 1}, env)
  lu.assertEquals(code, 0)
  local output = table.concat(out)
  assertMatches("no covered mutation sites", output)
  assertMatches("uncovered mutation sites: ", output)
end

function TestEngine:testReuseCoverageNotesMatrixPathAndIgnoresLuacovReport()
  write_file(self.target_abs, "return 1 == 2\n")
  write_file(util.join_path(self.dir, "luacov.report.out"), make_luacov_report(self.target_rel, {false}))
  local err = {}
  local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  env.stderr = capture_buffer(err)
  env.run_resident = function(spec)
    local results = {}
    for i = 1, spec.job_count do results[i] = {ok = false, code = 1, elapsed = 0} end
    return results
  end
  engine.mutate({target = self.target_rel, reuse_coverage = true, max_workers = 1}, env)
  assertMatches("%-%-reuse%-coverage now uses the attribution matrix", table.concat(err))
end

function TestEngine:testSucceedsWhenAllDiscoveredSitesAreUncoveredByMatrix()
  write_file(self.target_abs, "local y = 2\nreturn y == 3\n")
  -- The mutation site is on line 2 (the == comparison); leave it uncovered.
  seed_attribution_matrix(self.dir, self.target_rel, "local y = 2\nreturn y == 3\n", {})
  local shell = make_shell({{ok = true}})
  local env = self:null_env()
  env.run_shell = shell.fn
  local code = engine.mutate({target = self.target_rel, max_workers = 1}, env)
  lu.assertEquals(code, 0)
end

-- diagnostics block

function TestEngine:testPrintsPreWorkerDiagnosticsBlock()
  write_file(self.target_abs, "return 1 == 2\n")
  local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
  local out = {}
  local env = self:null_env()
  env.run_shell = shell.fn
  env.stdout = capture_buffer(out)
  engine.mutate({target = self.target_rel, test_command = "true", max_workers = 1}, env)
  local output = table.concat(out)
  assertMatches("total mutation sites:", output)
  assertMatches("covered mutation sites:", output)
  assertMatches("uncovered mutation sites:", output)
  assertMatches("changed mutation sites:", output)
  assertMatches("suppressed equivalent sites:", output)
  assertMatches("manifest exists:", output)
  assertMatches("module hash changed:", output)
  assertMatches("differential surface area:", output)
  assertMatches("manifest%-violating surface area:", output)
end

-- mutation warning

function TestEngine:testWarnsWhenSelectedCountExceedsThreshold()
  write_file(self.target_abs, "return 1 == 2\n")
  local err = {}
  local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  env.stderr = capture_buffer(err)
  engine.mutate({target = self.target_rel, test_command = "true", mutation_warning = 0, max_workers = 1}, env)
  assertMatches("warning:.*mutations exceed threshold 0", table.concat(err))
end

-- scan

function TestEngine:testScanMarksSitesWhoseScopesDifferFromManifest()
  write_file(self.target_abs, "local function f() return 1 == 2 end\nreturn f\n")
  engine.update_manifest({target = self.target_rel}, self:null_env())
  local content = read_file(self.target_abs)
  local stripped = manifest.strip(content)
  local modified = stripped:gsub("return 1 == 2", "return 2 ~= 3")
  local footer = content:sub(#stripped + 1)
  write_file(self.target_abs, modified .. footer)
  local out = {}
  local code = engine.scan({target = self.target_rel}, {cwd = self.dir, stdout = capture_buffer(out), stderr = null_buffer()})
  lu.assertEquals(code, 0)
  local output = table.concat(out)
  lu.assertStrMatches(output, "file: m%.lua.*")
  assertMatches("sites: %d+", output)
  assertMatches("suppressed equivalent sites: %d+", output)
  assertMatches("%* L%d+", output)
end

-- parallel path

local multi_site_body = "return (1 == 2) and (3 ~= 4)\n"

function TestEngine:parallel_env(make_results)
  return {
    cwd = self.dir,
    stdout = null_buffer(),
    stderr = null_buffer(),
    run_shell = make_shell({{ok = true}}).fn,
    create_workspaces = function(_, count)
      local list = {}
      for i = 1, count do list[i] = util.join_path(self.dir, "ws_" .. i) end
      return list
    end,
    run_parallel = function(spec)
      local results = {}
      for i = 1, spec.job_count do
        results[i] = make_results(i)
      end
      return results
    end,
  }
end

local function killed() return {ok = false, code = 1, output = "", elapsed = 0, timed_out = false} end

function TestEngine:testRoutesMutantsThroughRunParallelWhenMaxWorkersAbove1()
  write_file(self.target_abs, multi_site_body)
  local captured
  local env = self:parallel_env(function() return killed() end)
  local base_run_parallel = env.run_parallel
  env.run_parallel = function(spec)
    captured = spec
    return base_run_parallel(spec)
  end
  engine.mutate({
    target = self.target_rel, test_command = "true",
    mutate_all = true, max_workers = 4,
  }, env)
  lu.assertNotNil(captured, "parallel runner was not used")
  lu.assertTrue(captured.job_count >= 2, "expected multiple mutation sites")
  lu.assertTrue(captured.worker_count >= 2, "expected more than one worker")
end

function TestEngine:testDoesNotForwardPollInterval()
  write_file(self.target_abs, multi_site_body)
  local captured
  local env = self:parallel_env(function() return killed() end)
  env.run_parallel = function(spec)
    captured = spec
    local results = {}
    for i = 1, spec.job_count do
      results[i] = killed()
    end
    return results
  end
  engine.mutate({
    target = self.target_rel, test_command = "true",
    mutate_all = true, max_workers = 4,
  }, env)
  lu.assertNil(captured.poll_interval)
end

function TestEngine:testWritesV4FooterWhenEveryParallelMutantKilled()
  write_file(self.target_abs, multi_site_body)
  engine.mutate({
    target = self.target_rel, test_command = "true",
    mutate_all = true, max_workers = 4,
  }, self:parallel_env(function() return killed() end))
  local data = manifest.read(self.target_abs)
  lu.assertNotNil(data)
  lu.assertEquals(data.version, 4)
end

-- built-in runner resolution (ADR-0005): without --test-command the engine
-- invokes the runner shipped next to engine.lua; no driver script is needed.

function TestEngine:testDefaultBaselineInvokesBuiltinRunnerWithoutCoverage()
  -- #21: baseline is suite-health only; coverage comes from the matrix.
  write_file(self.target_abs, "return 1 == 2\n")
  local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  env.run_resident = function(spec)
    local results = {}
    for i = 1, spec.job_count do
      results[i] = killed()
    end
    return results
  end
  engine.mutate({target = self.target_rel, max_workers = 1}, env)
  local baseline = shell.commands[1]
  lu.assertNotNil(baseline)
  assertMatches("src/runner%.lua", baseline)
  assertMatches("%-%-no%-coverage", baseline)
end

function TestEngine:testMutateAllBaselineInvokesBuiltinRunnerWithoutCoverage()
  write_file(self.target_abs, "return 1 == 2\n")
  local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  env.run_resident = function(spec)
    local results = {}
    for i = 1, spec.job_count do
      results[i] = killed()
    end
    return results
  end
  engine.mutate({target = self.target_rel, mutate_all = true, max_workers = 1}, env)
  local baseline = shell.commands[1]
  assertMatches("src/runner%.lua", baseline)
  assertMatches("%-%-no%-coverage", baseline)
end

-- resident routing (ADR-0007): without --test-command the mutant loop runs
-- through the resident worker pool; --test-command keeps the fresh-process
-- paths.

function TestEngine:testRoutesMutantsThroughRunResidentWhenNoTestCommand()
  write_file(self.target_abs, multi_site_body)
  local captured
  local env = self:null_env()
  env.run_shell = make_shell({{ok = true}}).fn
  env.run_resident = function(spec)
    captured = spec
    local results = {}
    for i = 1, spec.job_count do
      results[i] = killed()
    end
    return results
  end
  local code = engine.mutate({
    target = self.target_rel, mutate_all = true, max_workers = 1,
  }, env)
  lu.assertEquals(code, 0)
  lu.assertNotNil(captured, "resident pool was not used")
  lu.assertTrue(captured.job_count >= 2, "expected multiple mutation sites")
  lu.assertEquals(captured.worker_count, 1)
  lu.assertNotNil(captured.runner_path)
  assertMatches("src/runner%.lua", captured.runner_path)
  lu.assertEquals(captured.params(1).fail_fast, true)
end

-- test subsetting (map #1, #13): the per-mutant prune set rides the resident
-- request's `files` field; an unattributable line falls back to the full suite.

-- Seeds a fresh attribution matrix cache for the target so engine.mutate finds
-- it instead of building one (the build needs a real luacov pass).
function TestEngine:seed_matrix(rows, extra)
  util.mkdir_p(util.join_path(self.dir, "tests"))
  write_file(util.join_path(self.dir, "tests", "test_seed.lua"), "return {}\n")
  local target_source = read_file(self.target_abs)
  local matrix = {
    version = attribution.CURRENT_MATRIX_VERSION,
    target = self.target_rel,
    suite_hash = assert(attribution.suite_hash(self.dir)),
    target_hash = attribution.target_hash(manifest.strip(target_source)),
    load_lines_known = true,
    load_lines = {},
    failing_files = {},
    files = rows,
  }
  for key, value in pairs(extra or {}) do matrix[key] = value end
  assert(attribution.save(self.dir, self.target_rel, matrix))
  return matrix
end

function TestEngine:resident_capture_env()
  local env = self:null_env()
  env.run_shell = make_shell({{ok = true}}).fn
  env.captured = nil
  env.run_resident = function(spec)
    env.captured = spec
    local results = {}
    for i = 1, spec.job_count do
      results[i] = killed()
    end
    return results
  end
  return env
end

function TestEngine:testPruneSetOfCoveringTestsRidesTheResidentRequest()
  write_file(self.target_abs, "return 1 == 2\n")
  self:seed_matrix({["tests/test_seed.lua"] = {1}})
  local env = self:resident_capture_env()
  engine.mutate({target = self.target_rel, mutate_all = true, max_workers = 1}, env)
  lu.assertNotNil(env.captured, "resident pool was not used")
  lu.assertEquals(env.captured.params(1).files, {"tests/test_seed.lua"})
end

function TestEngine:testUnattributableLineFallsBackToTheFullSuite()
  -- nil files means "no prune set": the runner discovers the whole suite.
  write_file(self.target_abs, "return 1 == 2\n")
  self:seed_matrix({["tests/test_seed.lua"] = {99}})
  local env = self:resident_capture_env()
  engine.mutate({target = self.target_rel, mutate_all = true, max_workers = 1}, env)
  lu.assertNil(env.captured.params(1).files)
end

function TestEngine:testLoadTimeLineFallsBackEvenThoughAFileCoveredIt()
  write_file(self.target_abs, "return 1 == 2\n")
  self:seed_matrix({["tests/test_seed.lua"] = {1}}, {load_lines = {1}})
  local env = self:resident_capture_env()
  engine.mutate({target = self.target_rel, mutate_all = true, max_workers = 1}, env)
  lu.assertNil(env.captured.params(1).files)
end

function TestEngine:testStaleMatrixIsIgnoredSoEveryMutantRunsTheFullSuite()
  -- A stale cache must never prune: the freshness key is the guard, and an
  -- unusable matrix degrades to pre-subsetting behaviour.
  write_file(self.target_abs, "return 1 == 2\n")
  self:seed_matrix({["tests/test_seed.lua"] = {1}}, {suite_hash = "stale"})
  local env = self:resident_capture_env()
  -- The rebuild attempt runs through run_shell (stubbed ok, writes no matrix),
  -- so the engine ends up without an index.
  engine.mutate({target = self.target_rel, mutate_all = true, max_workers = 1}, env)
  lu.assertNil(env.captured.params(1).files)
end

function TestEngine:testReportsFallbackRateForMatrixQuality()
  write_file(self.target_abs, multi_site_body)
  self:seed_matrix({["tests/test_seed.lua"] = {1}})
  local out = {}
  local env = self:resident_capture_env()
  env.stdout = capture_buffer(out)
  engine.mutate({target = self.target_rel, mutate_all = true, max_workers = 1}, env)
  assertMatches("test subsetting: %d+/%d+ sites pruned, %d+ full%-suite fallback", table.concat(out))
end

function TestEngine:testTestCommandPathNeverPrunes()
  -- --test-command owns its own test selection and has no runner to build a
  -- matrix with, so subsetting stays off there.
  write_file(self.target_abs, "return 1 == 2\n")
  self:seed_matrix({["tests/test_seed.lua"] = {1}})
  local out = {}
  local shell = make_shell({{ok = true}, {ok = false}})
  local env = self:null_env()
  env.stdout = capture_buffer(out)
  env.run_shell = shell.fn
  engine.mutate({
    target = self.target_rel, test_command = "true",
    mutate_all = true, max_workers = 1,
  }, env)
  lu.assertNotNil(shell.commands[2])
  lu.assertEquals(shell.commands[2], "true")
  lu.assertNotStrContains(table.concat(out), "test subsetting")
end

function TestEngine:testResidentPoolGetsOneWorkspacePerWorker()
  write_file(self.target_abs, multi_site_body)
  local captured
  local env = self:null_env()
  env.run_shell = make_shell({{ok = true}}).fn
  env.create_workspaces = function(_, count)
    local list = {}
    for i = 1, count do list[i] = util.join_path(self.dir, "ws_" .. i) end
    return list
  end
  env.run_resident = function(spec)
    captured = spec
    local results = {}
    for i = 1, spec.job_count do
      results[i] = killed()
    end
    return results
  end
  engine.mutate({
    target = self.target_rel, mutate_all = true, max_workers = 4,
  }, env)
  lu.assertNotNil(captured)
  lu.assertTrue(captured.worker_count >= 2, "expected more than one worker")
  lu.assertEquals(#captured.workspaces, captured.worker_count)
end

return TestEngine
