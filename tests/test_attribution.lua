-- Attribution matrix (map #1, #12): the per-test-file "test file → covered
-- lines of the target" mapping test subsetting prunes with.
--
-- Two layers are covered here: the module's cache/freshness/lookup semantics
-- (pure, fast), and one real end-to-end build through the runner against a
-- fixture project (slow but the only thing that proves the luacov
-- runner.data snapshot mechanism actually attributes per file).
local lu = require("luaunit")
local attribution = require("mutate4lua.internal.attribution")
local util = require("mutate4lua.util")

local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local repo_root = test_file:match("^(.*)/tests/[^/]+$")
if repo_root == nil then
  local pipe = io.popen("pwd")
  repo_root = util.trim(pipe:read("*l"))
  pipe:close()
end
local runner_path = repo_root .. "/src/runner.lua"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function tmp_dir()
  local base = os.tmpname()
  os.remove(base)
  util.mkdir_p(base)
  return base
end

local function rm_rf(path)
  os.execute("rm -rf " .. shell_quote(path))
end

local function write_file(path, content)
  local parent = util.parent_dir(path)
  if parent and parent ~= "" then util.mkdir_p(parent) end
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

TestAttribution = {}

function TestAttribution:setUp()
  self.dir = tmp_dir()
end

function TestAttribution:tearDown()
  rm_rf(self.dir)
end

-- ---- cache path & freshness ----

function TestAttribution:testCachePathLivesUnderProjectRootNotWorkspace()
  local path = attribution.cache_path(self.dir, "src/foundation/number.lua")
  lu.assertEquals(path,
    util.join_path(self.dir, ".mutate4lua", "attribution", "src/foundation/number.lua.matrix"))
end

function TestAttribution:testSuiteHashCoversOnlyTestFiles()
  write_file(util.join_path(self.dir, "tests", "test_a.lua"), "return {}\n")
  write_file(util.join_path(self.dir, "src", "a.lua"), "return 1\n")
  local before = assert(attribution.suite_hash(self.dir))

  -- Editing source must NOT move the suite hash: a dev-loop change to
  -- unrelated src would otherwise evict the matrix on every run.
  write_file(util.join_path(self.dir, "src", "a.lua"), "return 2\n")
  lu.assertEquals(attribution.suite_hash(self.dir), before)

  -- Editing a test file must move it.
  write_file(util.join_path(self.dir, "tests", "test_a.lua"), "return {x = 1}\n")
  lu.assertNotEquals(attribution.suite_hash(self.dir), before)
end

function TestAttribution:testSuiteHashCoversAddedTestFile()
  write_file(util.join_path(self.dir, "tests", "test_a.lua"), "return {}\n")
  local before = assert(attribution.suite_hash(self.dir))
  write_file(util.join_path(self.dir, "tests", "test_b.lua"), "return {}\n")
  lu.assertNotEquals(attribution.suite_hash(self.dir), before)
end

function TestAttribution:testDiscoveryMatchesRunnerConvention()
  write_file(util.join_path(self.dir, "tests", "test_a.lua"), "return {}\n")
  write_file(util.join_path(self.dir, "tests", "helper.lua"), "return {}\n")
  write_file(util.join_path(self.dir, "tests", "fixtures", "test_ignored.lua"), "return {}\n")
  write_file(util.join_path(self.dir, "spec", "test_b.lua"), "return {}\n")
  write_file(util.join_path(self.dir, "src", "test_c.lua"), "return {}\n")

  local found = attribution.discover_test_files(self.dir)
  local names = {}
  for _, path in ipairs(found) do
    names[#names + 1] = util.relative_path(self.dir, path):gsub("\\", "/")
  end
  table.sort(names)
  lu.assertEquals(names, {"spec/test_b.lua", "tests/test_a.lua"})
end

function TestAttribution:testFreshnessRequiresBothHashes()
  local matrix = {
    version = attribution.CURRENT_MATRIX_VERSION,
    suite_hash = "s1", target_hash = "t1", files = {},
  }
  lu.assertTrue(attribution.is_fresh(matrix, "s1", "t1"))
  lu.assertFalse(attribution.is_fresh(matrix, "s2", "t1"), "changed suite must invalidate")
  lu.assertFalse(attribution.is_fresh(matrix, "s1", "t2"), "changed target must invalidate")
  lu.assertFalse(attribution.is_fresh(nil, "s1", "t1"))
end

function TestAttribution:testStaleVersionIsTreatedAsAbsent()
  local matrix = {version = 0, suite_hash = "s1", target_hash = "t1", files = {}}
  lu.assertFalse(attribution.is_fresh(matrix, "s1", "t1"))
  assert(attribution.save(self.dir, "src/a.lua", matrix))
  lu.assertNil(attribution.load(self.dir, "src/a.lua"), "an older format must not be trusted")
end

function TestAttribution:testSaveLoadRoundTrip()
  local matrix = {
    version = attribution.CURRENT_MATRIX_VERSION,
    target = "src/a.lua",
    suite_hash = "s1",
    target_hash = "t1",
    load_lines_known = true,
    load_lines = {1, 9},
    files = {["tests/test_a.lua"] = {4, 5}, ["tests/test_b.lua"] = {7}},
  }
  assert(attribution.save(self.dir, "src/a.lua", matrix))
  local loaded = assert(attribution.load(self.dir, "src/a.lua"))
  lu.assertTrue(attribution.is_fresh(loaded, "s1", "t1"))
  lu.assertEquals(loaded.files["tests/test_a.lua"], {4, 5})
  lu.assertEquals(loaded.load_lines, {1, 9})
  -- Regression: load_lines_known must survive the round trip. Dropping it made
  -- every cached matrix read back as "unknown", disabling pruning entirely.
  lu.assertTrue(loaded.load_lines_known)
end

function TestAttribution:testUnknownLoadLinesDisablePruningEntirely()
  -- Fail safe: if the builder could not determine the load-time lines, any
  -- line might be one, so nothing may be pruned.
  local index = attribution.index({
    load_lines_known = false,
    files = {["tests/test_a.lua"] = {4}},
    load_lines = {},
  })
  lu.assertNil(attribution.files_for_line(index, 4))
end

function TestAttribution:testEncodeIsDeterministic()
  local matrix = {
    version = attribution.CURRENT_MATRIX_VERSION, target = "src/a.lua",
    files = {["tests/test_z.lua"] = {2}, ["tests/test_a.lua"] = {1}},
  }
  lu.assertEquals(attribution.encode(matrix), attribution.encode(matrix))
  lu.assertStrContains(attribution.encode(matrix), "tests/test_a.lua")
end

function TestAttribution:testDecodeRejectsNonMatrix()
  lu.assertNil(attribution.decode(""))
  lu.assertNil(attribution.decode("return 5"))
  lu.assertNil(attribution.decode("this is not lua"))
  lu.assertNil(attribution.decode("return {}"), "a matrix without a files map is unusable")
end

function TestAttribution:testDecodeCannotReachGlobals()
  -- A cache file is data; loading it must not be able to touch the process.
  lu.assertNil(attribution.decode("return {files = os.exit and {} or {}}"))
end

-- ---- line lookup / empty-set fallback ----

function TestAttribution:testFilesForLineReturnsCoveringTests()
  local index = attribution.index({
    files = {["tests/test_a.lua"] = {4, 5}, ["tests/test_b.lua"] = {5}},
    load_lines = {},
  })
  lu.assertEquals(attribution.files_for_line(index, 4), {"tests/test_a.lua"})
  lu.assertEquals(attribution.files_for_line(index, 5), {"tests/test_a.lua", "tests/test_b.lua"})
end

function TestAttribution:testUncoveredLineHasNoPruneSet()
  -- nil means "no prune set" — the engine runs the full suite (空集回退).
  local index = attribution.index({files = {["tests/test_a.lua"] = {4}}, load_lines = {}})
  lu.assertNil(attribution.files_for_line(index, 99))
end

function TestAttribution:testLoadTimeLineFallsBackToFullSuite()
  -- The target module loads once per process, so per-file attribution cannot
  -- name the killers of a load-time line: it must fall back, not prune.
  local index = attribution.index({
    files = {["tests/test_a.lua"] = {2, 4}},
    load_lines = {2},
  })
  lu.assertNil(attribution.files_for_line(index, 2), "load-time line must not be pruned")
  lu.assertEquals(attribution.files_for_line(index, 4), {"tests/test_a.lua"})
end

-- ---- end-to-end build through the runner ----

-- A fixture project whose target has one function per test file, so correct
-- per-file attribution is observable: each test may only claim its own line.
-- A fixture where the target runs code while a *host module* loads: `helper`
-- calls calc.mul at its own load time, so that line executes once, during
-- whichever test file's require chain loads helper first.
local function build_load_phase_fixture(root)
  write_file(util.join_path(root, "src", "calc.lua"), table.concat({
    "local calc = {}",           -- 1 (load-time)
    "",                          -- 2
    "function calc.add(a, b)",   -- 3 (load-time)
    "  return a + b",            -- 4 (run phase, test_add)
    "end",                       -- 5
    "",                          -- 6
    "function calc.mul(a, b)",   -- 7 (load-time)
    "  return a * b",            -- 8 (executed while helper loads)
    "end",                       -- 9
    "",                          -- 10
    "return calc",               -- 11 (load-time)
  }, "\n") .. "\n")
  write_file(util.join_path(root, "src", "helper.lua"), table.concat({
    'local calc = require("calc")',
    "local SIX = calc.mul(2, 3)",
    "return {six = SIX}",
  }, "\n") .. "\n")
  -- Both test files use helper; only the first to load it executes calc line 8.
  for _, name in ipairs({"test_one", "test_two"}) do
    write_file(util.join_path(root, "tests", name .. ".lua"), table.concat({
      'local lu = require("luaunit")',
      'local calc = require("calc")',
      'local helper = require("helper")',
      "T" .. name .. " = {}",
      "function T" .. name .. ":testIt()",
      "  lu.assertEquals(helper.six, 6)",
      "  lu.assertEquals(calc.add(1, 2), 3)",
      "end",
      "return T" .. name,
    }, "\n") .. "\n")
  end
end

local function build_fixture(root)
  write_file(util.join_path(root, "src", "calc.lua"), table.concat({
    "local calc = {}",           -- 1 (load-time)
    "",                          -- 2
    "function calc.add(a, b)",   -- 3 (load-time)
    "  return a + b",            -- 4 (test_add only)
    "end",                       -- 5
    "",                          -- 6
    "function calc.sub(a, b)",   -- 7 (load-time)
    "  return a - b",            -- 8 (test_sub only)
    "end",                       -- 9
    "",                          -- 10
    "function calc.unused()",    -- 11 (load-time)
    "  return 0",                -- 12 (no test)
    "end",                       -- 13
    "",                          -- 14
    "return calc",               -- 15 (load-time)
  }, "\n") .. "\n")
  write_file(util.join_path(root, "tests", "test_add.lua"), table.concat({
    'local lu = require("luaunit")',
    'local calc = require("calc")',
    "TestAdd = {}",
    "function TestAdd:testAdd() lu.assertEquals(calc.add(1, 2), 3) end",
    "return TestAdd",
  }, "\n") .. "\n")
  write_file(util.join_path(root, "tests", "test_sub.lua"), table.concat({
    'local lu = require("luaunit")',
    'local calc = require("calc")',
    "TestSub = {}",
    "function TestSub:testSub() lu.assertEquals(calc.sub(5, 3), 2) end",
    "return TestSub",
  }, "\n") .. "\n")
end

local function run_build(root, matrix_path)
  local command = "cd " .. shell_quote(root)
    .. " && lua " .. shell_quote(runner_path)
    .. " --root . --attribution-matrix " .. shell_quote(matrix_path)
    .. " --attribution-target src/calc.lua --quiet"
    .. " > /dev/null 2>&1"
  return util.command_succeeds(command)
end

function TestAttribution:testRunnerBuildsPerFileAttribution()
  build_fixture(self.dir)
  local matrix_path = util.join_path(self.dir, "matrix.out")
  lu.assertTrue(run_build(self.dir, matrix_path), "attribution build must succeed")

  local matrix = assert(attribution.decode(assert(util.read_file(matrix_path))))
  lu.assertEquals(matrix.target, "src/calc.lua")

  local index = attribution.index(matrix)

  -- The whole point: each function body line is attributed to its own test.
  lu.assertEquals(attribution.files_for_line(index, 4), {"tests/test_add.lua"})
  lu.assertEquals(attribution.files_for_line(index, 8), {"tests/test_sub.lua"})

  -- A line no test executes has no prune set → full-suite fallback.
  lu.assertNil(attribution.files_for_line(index, 12))

  -- Load-time lines are recorded separately and always fall back.
  lu.assertTrue(matrix.load_lines_known, "load-time lines must be determined")
  lu.assertNil(attribution.files_for_line(index, 1))
  lu.assertNil(attribution.files_for_line(index, 3))
end

function TestAttribution:testBuildDoesNotWriteLuacovArtifactsIntoProject()
  build_fixture(self.dir)
  lu.assertTrue(run_build(self.dir, util.join_path(self.dir, "matrix.out")))
  -- The matrix build is not a coverage report run; leaving luacov artifacts in
  -- the tree would leak into the host project's status.
  lu.assertFalse(util.path_exists(util.join_path(self.dir, "luacov.report.out")))
  lu.assertFalse(util.path_exists(util.join_path(self.dir, "luacov.stats.out")))
end

function TestAttribution:testFailingTestStillProducesMatrix()
  build_fixture(self.dir)
  write_file(util.join_path(self.dir, "tests", "test_fail.lua"), table.concat({
    'local lu = require("luaunit")',
    "TestFail = {}",
    "function TestFail:testFail() lu.assertEquals(1, 2) end",
    "return TestFail",
  }, "\n") .. "\n")
  local matrix_path = util.join_path(self.dir, "matrix.out")
  -- Suite health is the baseline run's job; a failing test must not stop the
  -- matrix from being built for every other file.
  lu.assertTrue(run_build(self.dir, matrix_path))
  local matrix = assert(attribution.decode(assert(util.read_file(matrix_path))))
  local index = attribution.index(matrix)
  lu.assertEquals(attribution.files_for_line(index, 4), {"tests/test_add.lua"})
  -- A file that failed during the build is named: its row may be short, which
  -- is a matrix-quality signal the engine reports rather than hides.
  lu.assertEquals(matrix.failing_files, {"tests/test_fail.lua"})
end

function TestAttribution:testFailingFileRowIsStillUsedForPruning()
  -- A short row must never be dropped: a killer missing from a prune set would
  -- flip a mutant from killed to survived. Keeping it can only over-run.
  local index = attribution.index({
    load_lines_known = true,
    load_lines = {},
    failing_files = {"tests/test_flaky.lua"},
    files = {["tests/test_flaky.lua"] = {4}},
  })
  lu.assertEquals(attribution.files_for_line(index, 4), {"tests/test_flaky.lua"})
  lu.assertTrue(index.failing_files["tests/test_flaky.lua"])
end

function TestAttribution:testFailingFilesSurviveRoundTrip()
  local matrix = {
    version = attribution.CURRENT_MATRIX_VERSION,
    target = "src/a.lua",
    suite_hash = "s1", target_hash = "t1",
    load_lines_known = true, load_lines = {},
    failing_files = {"tests/test_b.lua", "tests/test_a.lua"},
    files = {["tests/test_a.lua"] = {4}},
  }
  assert(attribution.save(self.dir, "src/a.lua", matrix))
  local loaded = assert(attribution.load(self.dir, "src/a.lua"))
  lu.assertEquals(loaded.failing_files, {"tests/test_a.lua", "tests/test_b.lua"})
end

function TestAttribution:testLinesRunWhileHostModulesLoadAreNotAttributedToOneFile()
  -- Regression: a target line executed while a host module loads runs once, on
  -- whichever test file's require chain got there first. Crediting it to that
  -- file alone would prune away the other tests that actually depend on it —
  -- measured on the monopoly benchmark as 168 mis-attributed lines across a
  -- 16-file sample. Such lines must fall back to the full suite.
  build_load_phase_fixture(self.dir)
  local matrix_path = util.join_path(self.dir, "matrix.out")
  lu.assertTrue(run_build(self.dir, matrix_path))
  local matrix = assert(attribution.decode(assert(util.read_file(matrix_path))))
  local index = attribution.index(matrix)

  lu.assertNil(attribution.files_for_line(index, 8),
    "a line executed while a host module loads must not be pruned to one file")
  -- It must be recorded as a load line, not merely absent from every row:
  -- "absent" would also be the result of never measuring the load phase, and
  -- then a mutation there would silently prune to whichever file loaded first.
  local recorded = {}
  for _, line in ipairs(matrix.load_lines) do recorded[line] = true end
  lu.assertTrue(recorded[8], "line 8 must be recorded as a load-phase line")
  -- It must also be kept out of the per-file rows.
  for name, lines in pairs(matrix.files) do
    for _, line in ipairs(lines) do
      lu.assertNotEquals(line, 8, name .. " must not claim a load-phase line")
    end
  end
  -- Genuine per-test lines are still attributed to every file that runs them.
  lu.assertEquals(attribution.files_for_line(index, 4),
    {"tests/test_one.lua", "tests/test_two.lua"})
end

function TestAttribution:testTargetRaisingAtLoadTimeIsNotFatal()
  build_fixture(self.dir)
  -- A target that cannot be loaded standalone (e.g. it needs host bootstrap)
  -- must degrade to "load-time lines unknown", not fail the build.
  write_file(util.join_path(self.dir, "src", "calc.lua"),
    'error("needs host bootstrap")\nreturn {}\n')
  local matrix_path = util.join_path(self.dir, "matrix.out")
  lu.assertTrue(run_build(self.dir, matrix_path))
  local matrix = assert(attribution.decode(assert(util.read_file(matrix_path))))
  lu.assertFalse(matrix.load_lines_known)
end

function TestAttribution:testRejectsAttributionWithoutTarget()
  local command = "cd " .. shell_quote(self.dir)
    .. " && lua " .. shell_quote(runner_path)
    .. " --attribution-matrix " .. shell_quote(util.join_path(self.dir, "m.out"))
    .. " > /dev/null 2>&1"
  lu.assertFalse(util.command_succeeds(command))
end

function TestAttribution:testRejectsAttributionWithCoverageReport()
  local command = "cd " .. shell_quote(self.dir)
    .. " && lua " .. shell_quote(runner_path)
    .. " --attribution-matrix " .. shell_quote(util.join_path(self.dir, "m.out"))
    .. " --attribution-target src/a.lua"
    .. " --coverage-report " .. shell_quote(util.join_path(self.dir, "r.out"))
    .. " > /dev/null 2>&1"
  lu.assertFalse(util.command_succeeds(command))
end

return TestAttribution
