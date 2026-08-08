-- Built-in test runner (ADR-0005): discovers luaunit test files in the host
-- project, runs them under a single luaunit suite, and optionally produces a
-- standard luacov report. The engine invokes this script for baseline and
-- mutant runs; it replaces the removed host-provided driver contract.
--
-- Usage:
--   lua runner.lua [--root DIR] [--coverage-report PATH | --no-coverage]
--                  [--fail-fast] [--quiet] [test-file ...]
--   lua runner.lua --serve DIR
--
-- Serve mode (ADR-0007): the runner stays resident as one worker per parallel
-- slot. It waits for job-<n>.req files in DIR (a loadable Lua table carrying
-- the per-run parameters that the one-shot form takes as process arguments:
-- root, coverage_report/no_coverage, fail_fast, files, shutdown), executes
-- one test pass per job, and commits job-<n>.res (temp + mv) with the failure
-- count. Reload semantics: loadfile chunks and the discovered file list are
-- cached per root; every job replays all test chunks and drops every
-- package.loaded entry captured since worker boot, so each job sees host
-- modules exactly as a fresh process would.
--
-- Host test convention:
--   - test files live in spec/, test/ or tests/ under the project root and
--     are named test_*.lua (positional arguments bypass discovery);
--   - each test file returns a luaunit test table (functions named test*).
--
-- This script is deliberately self-contained: it must NOT require any
-- mutate4lua.* module. The engine invokes the pristine runner (outside the
-- mutation workspace) while the workspace copy of the library may be mutated;
-- preloading a library module here would poison package.loaded and let tests
-- see unmutated code.

local function parse_args(argv)
  local args = {root = ".", coverage_report = nil, no_coverage = false, fail_fast = false, quiet = false, serve = nil, files = {}}
  local index = 1
  while index <= #argv do
    local token = argv[index]
    if token == "--serve" then
      index = index + 1
      if argv[index] == nil then
        error("--serve requires a value")
      end
      args.serve = argv[index]
    elseif token == "--root" then
      index = index + 1
      if argv[index] == nil then
        error("--root requires a value")
      end
      args.root = argv[index]
    elseif token == "--coverage-report" then
      index = index + 1
      if argv[index] == nil then
        error("--coverage-report requires a value")
      end
      args.coverage_report = argv[index]
    elseif token == "--no-coverage" then
      args.no_coverage = true
    elseif token == "--fail-fast" then
      args.fail_fast = true
    elseif token == "--quiet" then
      args.quiet = true
    elseif token:sub(1, 2) == "--" then
      error("Unknown runner option: " .. tostring(token))
    else
      args.files[#args.files + 1] = token
    end
    index = index + 1
  end
  if args.coverage_report and args.no_coverage then
    error("--coverage-report and --no-coverage are mutually exclusive")
  end
  if not args.coverage_report and not args.no_coverage then
    -- Direct human invocations (e.g. lua tests/run.lua) default to no coverage;
    -- the engine always passes one of the two flags explicitly.
    args.no_coverage = true
  end
  return args
end

local function is_absolute(path)
  path = tostring(path or "")
  return path:sub(1, 1) == "/" or path:sub(1, 2) == "\\\\" or path:match("^%a:[/\\]") ~= nil
end

local function absolute_path(path)
  if is_absolute(path) then return path end
  local pipe = io.popen("pwd")
  local cwd = pipe:read("*l")
  pipe:close()
  if path == "." then return cwd end
  return cwd .. "/" .. path
end

local function shell_quote(text)
  return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function is_directory(path)
  local ok, _, code = os.execute("test -d " .. shell_quote(path))
  return ok == true or ok == 0
end

-- Test discovery: test_*.lua under spec/, test/ or tests/ (recursive), sorted
-- for deterministic execution order. fixtures/ directories are test data, not
-- suites, and are pruned.
local function discover_test_files(root)
  local files = {}
  for _, dirname in ipairs({"spec", "test", "tests"}) do
    local dir = root .. "/" .. dirname
    if is_directory(dir) then
      local pipe = io.popen("find -L " .. shell_quote(dir) .. " -name 'test_*.lua' -type f -not -path '*/fixtures/*' 2>/dev/null")
      for line in pipe:lines() do
        files[#files + 1] = line
      end
      pipe:close()
    end
  end
  table.sort(files)
  return files
end

local function suite_name_for(path)
  local base = tostring(path):match("([^/]+)%.lua$") or tostring(path)
  return (base:gsub("[^%w_]", "_"))
end

-- package.path is rebuilt from the base captured at load time on every pass,
-- so serve mode can switch roots per job without accumulating duplicates.
local base_package_path = package.path

local function set_package_path(root)
  -- Host code convention: modules under lib/ or src/ of the project root,
  -- loadable both as lib/?.lua and lib/?/init.lua.
  package.path = table.concat({
    root .. "/lib/?.lua",
    root .. "/lib/?/init.lua",
    root .. "/src/?.lua",
    root .. "/src/?/init.lua",
    root .. "/?.lua",
    base_package_path,
  }, ";")
end

local function load_suite(path, chunk_cache)
  local chunk = chunk_cache and chunk_cache[path]
  if chunk == nil then
    local load_err
    chunk, load_err = loadfile(path)
    if chunk == nil then
      error("cannot load test file " .. path .. ": " .. tostring(load_err))
    end
    if chunk_cache then
      chunk_cache[path] = chunk
    end
  end
  local suite = chunk()
  if type(suite) ~= "table" then
    error("test file " .. path .. " must return a luaunit test table")
  end
  return {suite_name_for(path), suite}
end

local function generate_luacov_report(requested_path)
  -- luacov's reporter writes luacov.report.out in the cwd; move it to the path
  -- the engine expects when they differ. A missing luacov is a hard error
  -- here: coverage was explicitly requested, silent fallback would corrupt
  -- the "uncovered sites are skipped" semantics.
  local ok, reporter = pcall(require, "luacov.reporter")
  if not (ok and type(reporter) == "table" and type(reporter.report) == "function") then
    io.stderr:write("error: luacov is required for coverage but is not installed\n")
    return false
  end
  reporter.report()
  if requested_path and requested_path ~= "luacov.report.out" then
    local mv = "mv -f " .. shell_quote("luacov.report.out") .. " " .. shell_quote(requested_path)
    local mv_ok, kind, code = os.execute(mv)
    if type(mv_ok) == "number" and mv_ok ~= 0 then
      return false
    end
    if mv_ok == false or (mv_ok == nil and kind == "exit" and code ~= 0) then
      return false
    end
  end
  return true
end

-- One full test pass over args.root: set package.path, load every test file,
-- run the combined luaunit suite, and (optionally) emit a luacov report.
-- Returns the failure count, or nil + error message when the pass could not
-- run (missing luaunit/luacov, unloadable test file, report failure).
--
-- `cache` is nil on the one-shot CLI path. Serve mode passes a per-root table
-- that survives across jobs:
--   cache.chunks       loadfile chunks keyed by test-file path — parsing the
--                      test files dominates cold start, so each job replays
--                      cached chunks instead of re-parsing;
--   cache.files        discovered test-file list (the engine only ever mutates
--                      the target source file, so discovery cannot change).
--
-- Reload semantics (measured revision of ADR-0007's target-only clear; see
-- the #10 resolution): every pass drops ALL of package.loaded except the
-- stdlib, so module-level code — including load-time global installs like
-- monopoly's host aliases (_G.GameAPI) — re-runs exactly as it would in a
-- fresh process. Dropping only the mutated file's entries was refuted on the
-- benchmark host two ways: globals a test installs at runtime (_G.SetTimeOut)
-- leaked into later jobs and flipped their outcomes, and clearing _G without
-- reloading modules removed globals whose installer was require-cached.
local function execute_pass(args, cache)
  local root = absolute_path(args.root)
  set_package_path(root)

  local ok_lu, lu = pcall(require, "luaunit")
  if not ok_lu then
    return nil, "error: luaunit is required but is not installed (luarocks install luaunit)"
  end

  if cache then
    -- Full module reload per pass. The stdlib is kept: builtin modules
    -- (math, string, ...) live in the interpreter, not on disk, so a cleared
    -- stdlib entry can never be re-required. Everything else — luaunit,
    -- luacov (whose in-memory stats must not accumulate across jobs), host
    -- modules, the mutated target — loads fresh.
    local keep = {
      coroutine = true, string = true, table = true, math = true, io = true,
      os = true, debug = true, utf8 = true, package = true, _G = true,
    }
    for name in pairs(package.loaded) do
      if not keep[name] then
        package.loaded[name] = nil
      end
    end
    -- A previous coverage pass may have left luacov's debug hook installed;
    -- drop it so non-coverage jobs never pay instrumentation cost.
    debug.sethook()
  end

  local files = args.files
  if #files == 0 then
    if cache and cache.files then
      files = cache.files
    else
      files = discover_test_files(root)
      if cache then
        cache.files = files
      end
    end
  end
  if #files == 0 then
    return nil, "No test files found."
  end

  local luacov_runner
  local rollback_luacov
  if args.coverage_report then
    local ok, runner_mod = pcall(require, "luacov.runner")
    if not ok then
      return nil, "error: luacov is required for coverage but is not installed"
    end
    luacov_runner = runner_mod
    if cache then
      -- Per-job isolation in serve mode. save_stats() merges in-memory stats
      -- with the on-disk stats file, so drop any stale file first; and
      -- init() monkey-patches globals (os.exit, coroutine.create/wrap), so
      -- snapshot them for rollback once the pass is done.
      os.remove("luacov.stats.out")
      local saved_os_exit, saved_co_create, saved_co_wrap = os.exit, coroutine.create, coroutine.wrap
      rollback_luacov = function()
        debug.sethook()
        os.exit = saved_os_exit
        coroutine.create = saved_co_create
        coroutine.wrap = saved_co_wrap
      end
    end
    luacov_runner.init()
  end

  local instances = {}
  for _, file in ipairs(files) do
    local ok, instance_or_err = pcall(load_suite, file, cache and cache.chunks)
    if not ok then
      if rollback_luacov then
        rollback_luacov()
      end
      return nil, tostring(instance_or_err)
    end
    instances[#instances + 1] = instance_or_err
  end

  if args.quiet then
    lu.LuaUnit.verbosity = lu.VERBOSITY_QUIET
  end

  local runner = lu.LuaUnit.new()
  if args.fail_fast then
    runner.quitOnFailure = true
  end
  local failures
  if cache then
    -- luaunit's abort path (quitOnFailure/quitOnError) ends the suite with
    -- os.exit(-2), and a stray test-side os.exit would likewise kill the
    -- resident worker. Trap exits for the duration of the suite: a trapped
    -- exit classifies exactly like the one-shot process exit (nonzero ~
    -- notSuccessCount > 0, via the tallies endSuite() has already finalized).
    local real_exit = os.exit
    local trapped = false
    os.exit = function(_)
      trapped = true
      error({}, 0)
    end
    local ok, result = pcall(runner.runSuiteByInstancesNoCmdLineParsing, runner, instances)
    os.exit = real_exit
    if ok then
      failures = result
    elseif trapped then
      -- An exit trapped inside a test lands in luaunit's protectedCall and
      -- the suite carries on (mirroring luaunit's own os.exit patch), so
      -- this branch is only reached by the suite-level abort exit.
      failures = math.max(tonumber(runner.result and runner.result.notSuccessCount) or 0, 1)
    else
      error(result, 0)
    end
  else
    failures = runner:runSuiteByInstancesNoCmdLineParsing(instances)
  end

  if args.coverage_report then
    luacov_runner.save_stats()
    local report_ok = generate_luacov_report(args.coverage_report)
    if rollback_luacov then
      rollback_luacov()
      -- Force the old module's on-exit anchor to fire now (isolated and
      -- harmless), then drop the stats file so the next coverage pass does
      -- not merge stale data. The fresh require on the next pass starts
      -- from clean in-memory state.
      collectgarbage("collect")
      os.remove(luacov_runner.configuration.statsfile)
    end
    if not report_ok then
      return nil, "error: failed to generate coverage report"
    end
  end

  return failures
end

local function run(args)
  local failures, err = execute_pass(args, nil)
  if failures == nil then
    io.stderr:write(tostring(err), "\n")
    return 1
  end
  return failures > 0 and 1 or 0
end

-- ---- serve mode (ADR-0007): resident worker loop ----

-- Blocking wait granularity, same probe as the engine-side sentinel waiter:
-- fractional sleep is a macOS/GNU extension; strict POSIX sleep(1) hosts fall
-- back to 1s (correct, but detection latency degrades to the second).
local WAIT_GRANULARITY
do
  -- Lua 5.x returns true on success; LuaJIT returns 0.
  local ok = os.execute("sleep 0.01 >/dev/null 2>&1")
  local success = ok == true or ok == 0
  WAIT_GRANULARITY = success and 0.01 or 1
end

-- Block (inside a child sh) until `path` exists. Returns false when the
-- sentinel directory disappeared, which means the engine tore the pool down
-- and the worker should exit instead of waiting forever.
local function wait_for_file(path, dir)
  local cmd = "while :; do"
    .. " [ -e " .. shell_quote(path) .. " ] && exit 0;"
    .. " [ -d " .. shell_quote(dir) .. " ] || exit 1;"
    .. " sleep " .. tostring(WAIT_GRANULARITY) .. " 2>/dev/null;"
    .. "done"
  local ok = os.execute(cmd)
  return ok == true or ok == 0
end

-- temp + mv keeps the commit atomic: the engine polls for the res file and
-- must never observe a half-written one.
local function write_result(res_path, failures)
  local tmp_path = res_path .. ".part"
  local handle = assert(io.open(tmp_path, "w"))
  handle:write("return { failures = ", tostring(failures), " }\n")
  handle:close()
  assert(os.rename(tmp_path, res_path))
end

-- Tests and host code install globals at runtime (monopoly: its host alias
-- install sets _G.SetTimeOut), and with_patches-style helpers only restore
-- what they themselves touched — so a global added by one job is still
-- visible to every later job in the same worker, diverging from the fresh
-- process each one-shot pass gets. Snapshot _G once at worker start and
-- restore it after every job: added keys are removed, reassigned values are
-- rolled back. In-place mutations to pre-existing tables (stdlib, package)
-- are not rolled back; package.loaded is managed separately per ADR-0007.
local function snapshot_globals()
  local snapshot = {}
  for k, v in pairs(_G) do
    snapshot[k] = v
  end
  return snapshot
end

local function restore_globals(snapshot)
  for k in pairs(_G) do
    if snapshot[k] == nil then
      rawset(_G, k, nil)
    end
  end
  for k, v in pairs(snapshot) do
    if rawget(_G, k) ~= v then
      rawset(_G, k, v)
    end
  end
end

local function serve(dir)
  local caches = {}
  local globals_snapshot = snapshot_globals()
  local seq = 1
  while true do
    local base = dir .. "/job-" .. tostring(seq)
    local req_path = base .. ".req"
    if not wait_for_file(req_path, dir) then
      return 0
    end
    local req_chunk, req_err = loadfile(req_path)
    local req = req_chunk and req_chunk()
    if type(req) ~= "table" then
      io.stderr:write("mutate4lua runner: cannot parse job request ", req_path, ": ", tostring(req_err), "\n")
      return 1
    end
    if req.shutdown then
      write_result(base .. ".res", 0)
      return 0
    end

    -- Per-job diagnostics: luaunit writes through io.stdout AND through
    -- print(), which since Lua 5.4 bypasses the io library and goes straight
    -- to C stdout — so print itself is swapped for the duration of the job.
    local out_path = base .. ".out"
    local out_handle = io.open(out_path, "w")
    local real_stdout, real_stderr, real_output = io.stdout, io.stderr, io.output()
    local real_print = print
    if out_handle then
      io.stdout = out_handle
      io.stderr = out_handle
      io.output(out_handle)
      print = function(...)
        local pieces = {}
        for i = 1, select("#", ...) do
          pieces[i] = tostring((select(i, ...)))
        end
        out_handle:write(table.concat(pieces, "\t"), "\n")
      end
    end

    local root = absolute_path(req.root or ".")
    if caches[root] == nil then
      caches[root] = {chunks = {}}
    end
    -- A job must never take the worker down: unexpected errors are caught and
    -- reported like an unloadable pass (killed), and the loop continues.
    local pass_ok, failures, run_err = pcall(execute_pass, {
      root = root,
      coverage_report = req.coverage_report,
      fail_fast = req.fail_fast == true,
      quiet = true,
      files = req.files or {},
      mutated = req.mutated,
    }, caches[root])
    if not pass_ok then
      failures, run_err = nil, failures
    end

    io.stdout, io.stderr = real_stdout, real_stderr
    io.output(real_output)
    print = real_print
    if out_handle then
      out_handle:close()
    end
    restore_globals(globals_snapshot)

    if failures == nil then
      local append = io.open(out_path, "a")
      if append then
        append:write(tostring(run_err), "\n")
        append:close()
      end
      -- A pass that could not run mirrors the one-shot exit-1 semantics; the
      -- engine classifies a nonzero failure count as killed.
      failures = 1
    end
    write_result(base .. ".res", failures)
    seq = seq + 1
  end
end

local parsed = parse_args(arg)
if parsed.serve then
  os.exit(serve(parsed.serve))
end
os.exit(run(parsed))
