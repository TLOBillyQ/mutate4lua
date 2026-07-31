local lu = require("luaunit")
local manifest = require("mutate4lua.internal.manifest")
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

function TestEngine:testReusesExistingLuacovReportWithReuseCoverage()
  write_file(self.target_abs, "local x = 1\nlocal y = 2\nreturn x == y\n")
  -- Line 1 has the only mutation site in this file; mark it uncovered.
  write_file(util.join_path(self.dir, "luacov.report.out"), make_luacov_report(self.target_rel, {false, false, false}))
  local shell = make_shell({{ok = true}})
  local out = {}
  local env = self:null_env()
  env.run_shell = shell.fn
  env.stdout = capture_buffer(out)
  local code = engine.mutate({target = self.target_rel, reuse_coverage = true, max_workers = 1}, env)
  lu.assertEquals(code, 0)
  local output = table.concat(out)
  assertMatches("no covered mutation sites", output)
  assertMatches("uncovered mutation sites: ", output)
end

function TestEngine:testWarnsAndContinuesWithoutFilteringWhenReuseCoverageHasNoReport()
  write_file(self.target_abs, "return 1 == 2\n")
  local err = {}
  local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  env.stderr = capture_buffer(err)
  engine.mutate({target = self.target_rel, reuse_coverage = true, max_workers = 1}, env)
  assertMatches("reuse%-coverage requested but", table.concat(err))
end

function TestEngine:testSucceedsWhenAllDiscoveredSitesAreUncovered()
  write_file(self.target_abs, "local y = 2\nreturn y == 3\n")
  -- The mutation site is on line 2 (the == comparison).
  write_file(util.join_path(self.dir, "luacov.report.out"), make_luacov_report(self.target_rel, {nil, false}))
  local shell = make_shell({{ok = true}})
  local env = self:null_env()
  env.run_shell = shell.fn
  local code = engine.mutate({target = self.target_rel, reuse_coverage = true, max_workers = 1}, env)
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

function TestEngine:testDefaultBaselineInvokesBuiltinRunnerWithCoverageReport()
  write_file(self.target_abs, "return 1 == 2\n")
  local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  engine.mutate({target = self.target_rel, max_workers = 1}, env)
  local baseline = shell.commands[1]
  lu.assertNotNil(baseline)
  assertMatches("mutate4lua/runner%.lua", baseline)
  assertMatches("%-%-coverage%-report", baseline)
  local mutant = shell.commands[2]
  assertMatches("%-%-no%-coverage", mutant)
  assertMatches("%-%-fail%-fast", mutant)
end

function TestEngine:testMutateAllBaselineInvokesBuiltinRunnerWithoutCoverage()
  write_file(self.target_abs, "return 1 == 2\n")
  local shell = make_shell({{ok = true}, {ok = false}, {ok = false}})
  local env = self:null_env()
  env.run_shell = shell.fn
  engine.mutate({target = self.target_rel, mutate_all = true, max_workers = 1}, env)
  local baseline = shell.commands[1]
  assertMatches("mutate4lua/runner%.lua", baseline)
  assertMatches("%-%-no%-coverage", baseline)
end

return TestEngine
