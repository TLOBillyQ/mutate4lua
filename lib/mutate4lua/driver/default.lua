local function parse_args(argv)
  local args = {root = ".", tool_root = ".", coverage_report = nil, no_coverage = false, fail_fast = false, quiet = false}
  local index = 1
  while index <= #argv do
    local token = argv[index]
    if token == "--root" then
      index = index + 1
      if argv[index] == nil then
        error("--root requires a value")
      end
      args.root = argv[index]
    elseif token == "--tool-root" then
      index = index + 1
      if argv[index] == nil then
        error("--tool-root requires a value")
      end
      args.tool_root = argv[index]
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
    else
      error("Unknown test driver option: " .. tostring(token))
    end
    index = index + 1
  end
  if args.coverage_report and args.no_coverage then
    error("--coverage-report and --no-coverage are mutually exclusive")
  end
  return args
end

local function run_tests(files, fail_fast)
  local failed = false
  for _, file in ipairs(files) do
    local ok, message = xpcall(function()
      dofile(file)
    end, debug.traceback)
    if not ok then
      io.stderr:write(tostring(message), "\n")
      failed = true
      if fail_fast then
        return 1
      end
    end
  end
  return failed and 1 or 0
end

local function generate_luacov_report(requested_path)
  -- Try the luacov reporter module first; if it is unavailable fall back to
  -- the `luacov` command. The driver only needs coverage when explicitly
  -- requested, so a missing luacov is a hard error here, not a silent fallback.
  local ok, reporter = pcall(require, "luacov.reporter")
  if ok and type(reporter) == "table" and type(reporter.report) == "function" then
    reporter.report()
  else
    if not os.execute("luacov >/dev/null 2>&1") then
      io.stderr:write("error: luacov is required for coverage but is not installed\n")
      return false
    end
  end
  -- luacov writes its report to luacov.report.out by default; move it to the
  -- path the engine expects when they differ.
  if requested_path and requested_path ~= "luacov.report.out" then
    local mv = "mv -f " .. util.shell_quote("luacov.report.out") .. " " .. util.shell_quote(requested_path)
    local ok2, kind, code = os.execute(mv)
    if type(ok2) == "number" and ok2 ~= 0 then
      return false
    end
    if ok2 == false or (ok2 == nil and kind == "exit" and code ~= 0) then
      return false
    end
  end
  return true
end

local function run()
  local args = parse_args(arg)
  package.path = table.concat({
    args.tool_root .. "/lib/?.lua",
    args.tool_root .. "/lib/?/init.lua",
    "lib/?.lua",
    "lib/?/init.lua",
    "?.lua",
    package.path,
  }, ";")
  local project = require("mutate4lua.driver.project")
  local util = require("mutate4lua.util")
  local root = util.absolute_path(args.root)
  local files = project.discover_test_files(root)
  if #files == 0 then
    io.stderr:write("No test files found.\n")
    return 1
  end

  local luacov_runner
  if args.coverage_report then
    local ok, runner = pcall(require, "luacov.runner")
    if not ok then
      io.stderr:write("error: luacov is required for coverage but is not installed\n")
      return 1
    end
    luacov_runner = runner
    luacov_runner.init()
  end

  local exit_code = run_tests(files, args.fail_fast)

  if args.coverage_report then
    luacov_runner.save_stats()
    if not generate_luacov_report(args.coverage_report) then
      return 1
    end
  end

  return exit_code
end

os.exit(run())
