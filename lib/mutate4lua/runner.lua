-- Built-in test runner (ADR-0005): discovers luaunit test files in the host
-- project, runs them under a single luaunit suite, and optionally produces a
-- standard luacov report. The engine invokes this script for baseline and
-- mutant runs; it replaces the removed host-provided driver contract.
--
-- Usage:
--   lua runner.lua [--root DIR] [--coverage-report PATH | --no-coverage]
--                  [--fail-fast] [--quiet] [test-file ...]
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
  local args = {root = ".", coverage_report = nil, no_coverage = false, fail_fast = false, quiet = false, files = {}}
  local index = 1
  while index <= #argv do
    local token = argv[index]
    if token == "--root" then
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
    -- Direct human invocations (e.g. lua spec/run.lua) default to no coverage;
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
      local pipe = io.popen("find " .. shell_quote(dir) .. " -name 'test_*.lua' -type f -not -path '*/fixtures/*' 2>/dev/null")
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

local function load_suite(path)
  local chunk, load_err = loadfile(path)
  if chunk == nil then
    error("cannot load test file " .. path .. ": " .. tostring(load_err))
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

local function run()
  local args = parse_args(arg)
  local root = absolute_path(args.root)

  -- Host code convention: modules under lib/ or src/ of the project root,
  -- loadable both as lib/?.lua and lib/?/init.lua.
  package.path = table.concat({
    root .. "/lib/?.lua",
    root .. "/lib/?/init.lua",
    root .. "/src/?.lua",
    root .. "/src/?/init.lua",
    root .. "/?.lua",
    package.path,
  }, ";")

  local ok_lu, lu = pcall(require, "luaunit")
  if not ok_lu then
    io.stderr:write("error: luaunit is required but is not installed (luarocks install luaunit)\n")
    return 1
  end

  local files = args.files
  if #files == 0 then
    files = discover_test_files(root)
  end
  if #files == 0 then
    io.stderr:write("No test files found.\n")
    return 1
  end

  local luacov_runner
  if args.coverage_report then
    local ok, runner_mod = pcall(require, "luacov.runner")
    if not ok then
      io.stderr:write("error: luacov is required for coverage but is not installed\n")
      return 1
    end
    luacov_runner = runner_mod
    luacov_runner.init()
  end

  local instances = {}
  for _, file in ipairs(files) do
    local ok, instance_or_err = pcall(load_suite, file)
    if not ok then
      io.stderr:write(tostring(instance_or_err), "\n")
      return 1
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
  local failures = runner:runSuiteByInstancesNoCmdLineParsing(instances)

  if args.coverage_report then
    luacov_runner.save_stats()
    if not generate_luacov_report(args.coverage_report) then
      return 1
    end
  end

  return failures > 0 and 1 or 0
end

os.exit(run())
