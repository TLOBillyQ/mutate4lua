local manifest = require("mutate4lua.legacy.manifest")
local project = require("mutate4lua.legacy.project")
local report = require("mutate4lua.legacy.report")
local runner = require("mutate4lua.legacy.runner")
local scanner = require("mutate4lua.legacy.scanner")
local selection = require("mutate4lua.legacy.selection")
local util = require("mutate4lua.util")
local cli = {}
local module_path = debug.getinfo(1, "S").source:sub(2)
local tool_root = util.parent_dir(util.parent_dir(util.parent_dir(util.absolute_path(module_path))))
local usage_text = [[
Usage:
  mutate4lua <file.lua>                      Mutate one Lua source file
  mutate4lua <file.lua> --scan              Print mutation-site scan without running tests
  mutate4lua <file.lua> --update-manifest   Write embedded manifest without running tests
  mutate4lua <file.lua> --lines 12,18       Restrict mutations to specific source lines
  mutate4lua <file.lua> --since-last-run    Mutate only scopes changed since embedded manifest
  mutate4lua <file.lua> --mutate-all        Ignore embedded manifest and mutate all covered sites
  mutate4lua <file.lua> --mutation-warning 50 Warn when selected mutation count exceeds threshold
  mutate4lua <file.lua> --max-workers 4     Limit parallel worker count
  mutate4lua <file.lua> --timeout-factor 15 Set mutant timeout as baseline multiplier
  mutate4lua <file.lua> --test-command CMD  Override the test command used for baseline and mutants
  mutate4lua <file.lua> --verbose           Print live worker progress
  mutate4lua --help                         Print this help message
]]
local function write_to(stream, text)
  stream:write(text)
end
local function parse_positive_integer(option, value)
  if not value or value == "" then
    error(option .. " requires a value")
  end
  local number = tonumber(value)
  if not number or number < 1 or number % 1 ~= 0 then
    error(option .. " must be a positive integer")
  end
  return number
end
local function parse_lines(value)
  if not value or value == "" then
    error("--lines requires a value")
  end
  local lines = {}
  local lookup = {}
  for token in value:gmatch("[^,]+") do
    local number = tonumber(token)
    if not number or number < 1 or number % 1 ~= 0 then
      error("--lines must be a positive integer")
    end
    if not lookup[number] then
      lines[#lines + 1] = number
      lookup[number] = true
    end
  end
  if #lines == 0 then
    error("--lines requires at least one line number")
  end
  table.sort(lines)
  return lines, lookup
end
local function parse_args(argv)
  if #argv == 0 then
    error("mutate4lua target must be a .lua file")
  end
  local args = {
    help = false,
    scan = false,
    update_manifest = false,
    since_last_run = false,
    mutate_all = false,
    mutation_warning = 50,
    max_workers = util.default_max_workers(),
    timeout_factor = 10,
    test_command = nil,
    verbose = false,
    target = nil,
    lines = {},
    lines_lookup = {},
  }
  local index = 1
  while index <= #argv do
    local token = argv[index]
    if token == "--help" then
      args.help = true
    elseif token == "--scan" then
      args.scan = true
    elseif token == "--update-manifest" then
      args.update_manifest = true
    elseif token == "--since-last-run" then
      args.since_last_run = true
    elseif token == "--mutate-all" then
      args.mutate_all = true
    elseif token == "--mutation-warning" then
      index = index + 1
      args.mutation_warning = parse_positive_integer("--mutation-warning", argv[index])
    elseif token == "--max-workers" then
      index = index + 1
      args.max_workers = parse_positive_integer("--max-workers", argv[index])
    elseif token == "--timeout-factor" then
      index = index + 1
      args.timeout_factor = parse_positive_integer("--timeout-factor", argv[index])
    elseif token == "--test-command" then
      index = index + 1
      if not argv[index] then
        error("--test-command requires a value")
      end
      args.test_command = argv[index]
    elseif token == "--verbose" then
      args.verbose = true
    elseif token == "--lines" then
      index = index + 1
      args.lines, args.lines_lookup = parse_lines(argv[index])
    elseif util.starts_with(token, "--") then
      error("Unknown option: " .. token)
    elseif args.target then
      error("mutate4lua accepts exactly one target file")
    else
      args.target = token
    end
    index = index + 1
  end
  if args.help then
    return args
  end
  if not args.target then
    error("mutate4lua target must be a .lua file")
  end
  if not util.ends_with(args.target, ".lua") then
    error("mutate4lua target must be a .lua file")
  end
  if args.lines and #args.lines > 0 and args.since_last_run then
    error("--lines may not be combined with --since-last-run")
  end
  if args.lines and #args.lines > 0 and args.mutate_all then
    error("--lines may not be combined with --mutate-all")
  end
  if args.lines and #args.lines > 0 and args.update_manifest then
    error("--update-manifest may not be combined with --lines")
  end
  if args.scan and args.since_last_run then
    error("--scan may not be combined with --since-last-run")
  end
  if args.scan and args.mutate_all then
    error("--scan may not be combined with --mutate-all")
  end
  if args.scan and args.update_manifest then
    error("--scan may not be combined with --update-manifest")
  end
  if args.since_last_run and args.mutate_all then
    error("--since-last-run may not be combined with --mutate-all")
  end
  if args.update_manifest and args.since_last_run then
    error("--update-manifest may not be combined with --since-last-run")
  end
  if args.update_manifest and args.mutate_all then
    error("--update-manifest may not be combined with --mutate-all")
  end
  return args
end
local function manifest_data(analysis)
  return {
    version = 1,
    project_hash = analysis.project_hash,
    scopes = analysis.scopes,
  }
end
local function sorted_results(batch_results)
  table.sort(batch_results, function(left, right)
    return left.site_index < right.site_index
  end)
  return batch_results
end
local function command_signature(command)
  if type(command) == "table" then
    return table.concat(command, "\0")
  end
  return tostring(command or "")
end
local function load_lua_value(path)
  local chunk, load_err = loadfile(path)
  if not chunk then
    return nil, load_err
  end
  local ok, value = pcall(chunk)
  if not ok then
    return nil, value
  end
  return value
end
local function baseline_cache_key(project_hash, command)
  return util.fnv1a64((project_hash or "") .. "\0" .. command_signature(command))
end
local function baseline_cache_paths(project_root, cache_key)
  local root = util.join_path(project_root, ".mutate4lua", "cache", "baseline")
  return {
    root = root,
    coverage = util.join_path(root, cache_key .. ".coverage"),
    meta = util.join_path(root, cache_key .. ".meta.lua"),
  }
end
local function load_baseline_cache(project_root, cache_key)
  local paths = baseline_cache_paths(project_root, cache_key)
  if not util.is_file(paths.coverage) or not util.is_file(paths.meta) then
    return nil
  end
  local meta, load_err = load_lua_value(paths.meta)
  if not meta then
    util.remove(paths.meta)
    return nil, load_err
  end
  return {
    coverage_path = paths.coverage,
    duration_ms = tonumber(meta.duration_ms) or 0,
  }
end
local function write_baseline_cache(project_root, cache_key, baseline, coverage_path)
  if not cache_key or not coverage_path or not util.is_file(coverage_path) then
    return
  end
  local paths = baseline_cache_paths(project_root, cache_key)
  util.mkdir_p(paths.root)
  assert(util.write_file(paths.coverage, assert(util.read_file(coverage_path))))
  assert(util.write_file(paths.meta, string.format("return { duration_ms = %d }\n", baseline.duration_ms or 0)))
end
local function analyze_file(project_root, target_file)
  local raw_source = assert(util.read_file(target_file))
  local stripped_source = manifest.strip(raw_source)
  local relative_file = project.relative_file(project_root, target_file)
  local analysis = scanner.analyze(target_file, relative_file, stripped_source)
  analysis.project_hash = project.project_hash(project_root, target_file, stripped_source)
  return raw_source, stripped_source, analysis, relative_file
end
local function resolve_target(workspace_root, target)
  if util.starts_with(target, "/") then
    return util.absolute_path(target)
  end
  return util.absolute_path(util.join_path(workspace_root, target))
end

local function default_baseline_command(coverage_file, analysis, relative_file)
  local args = project.default_test_command(tool_root, {
    target_file = relative_file,
    project_hash = analysis and analysis.project_hash or nil,
  })
  args[#args + 1] = "--coverage-file"
  args[#args + 1] = coverage_file
  return args
end
function cli.usage()
  return usage_text
end
function cli.run(argv, workspace_root, out, err)
  workspace_root = workspace_root or util.absolute_path(".")
  out = out or io.stdout
  err = err or io.stderr
  local ok, args_or_error = pcall(parse_args, argv)
  if not ok then
    write_to(err, args_or_error .. "\n")
    write_to(out, usage_text)
    return 1
  end
  local args = args_or_error
  if args.help then
    write_to(out, usage_text)
    return 0
  end
  local target_file = resolve_target(workspace_root, args.target)
  if not util.is_file(target_file) then
    write_to(err, "mutate4lua target must be a .lua file\n")
    write_to(out, usage_text)
    return 1
  end
  local project_root = project.find_root(workspace_root, target_file)
  local raw_source, stripped_source, analysis, relative_file = analyze_file(project_root, target_file)
  local previous_manifest = manifest.read(target_file)
  if args.scan then
    local changed = selection.changed_scopes(previous_manifest, analysis)
    local sites = analysis.sites
    if args.lines and #args.lines > 0 then
      local filtered = {}
      for _, site in ipairs(sites) do
        if args.lines_lookup[site.line] then
          filtered[#filtered + 1] = site
        end
      end
      sites = filtered
    end
    write_to(out, report.scan(relative_file, sites, changed.all))
    return 0
  end
  if args.update_manifest then
    manifest.write(target_file, stripped_source, manifest_data(analysis))
    write_to(out, "Updated manifest for " .. relative_file .. "\n")
    return 0
  end
  local coverage_file = nil
  local baseline_command = nil
  local coverage_cache_key = nil
  if args.test_command then
    baseline_command = args.test_command
  else
    baseline_command = project.default_test_command(tool_root, {
      target_file = relative_file,
      project_hash = analysis.project_hash,
    })
    coverage_cache_key = baseline_cache_key(analysis.project_hash, baseline_command)
  end
  local function cleanup()
    if coverage_file then
      util.remove(coverage_file)
      coverage_file = nil
    end
  end
  local function execute()
    local baseline = nil
    local coverage_lines = nil
    local baseline_cache = nil
    if not args.test_command and coverage_cache_key then
      baseline_cache = load_baseline_cache(project_root, coverage_cache_key)
    end
    if baseline_cache then
      if args.verbose then
        write_to(out, "Baseline cache hit for " .. relative_file .. "\n")
      end
      baseline = {
        exit_code = 0,
        timed_out = false,
        duration_ms = baseline_cache.duration_ms,
        output = "",
      }
      coverage_lines = runner.read_coverage(baseline_cache.coverage_path)
    else
      if not args.test_command then
        coverage_file = util.tmp_path(".coverage")
        baseline_command = default_baseline_command(coverage_file, analysis, relative_file)
      end
      if args.verbose then
        write_to(out, "Baseline starting for " .. relative_file .. "\n")
      end
      baseline = runner.run_command(tool_root, project_root, baseline_command, nil, coverage_file)
      if args.verbose then
        write_to(out, string.format("Baseline finished: exit=%d timedOut=%s duration=%d ms\n", baseline.exit_code, tostring(baseline.timed_out), baseline.duration_ms))
      end
      if baseline.exit_code ~= 0 or baseline.timed_out then
        write_to(err, "Baseline tests failed.\n")
        if baseline.output and baseline.output ~= "" then
          write_to(err, baseline.output .. "\n")
        end
        return 2
      end
      if not args.test_command then
        coverage_lines = runner.read_coverage(coverage_file)
        write_baseline_cache(project_root, coverage_cache_key, baseline, coverage_file)
      end
      cleanup()
    end
    local selection_result = selection.filter(args, analysis, previous_manifest, coverage_lines)
    local diagnostics = report.diagnostics(selection_result, args.mutation_warning)
    if #selection_result.covered == 0 then
      write_to(out, report.run(relative_file, baseline, diagnostics, selection_result.uncovered, {}))
      manifest.write(target_file, stripped_source, manifest_data(analysis))
      return 0
    end
    local command = args.test_command or project.default_test_command(tool_root, {
      target_file = relative_file,
      project_hash = analysis.project_hash,
    })
    local timeout_seconds = math.max(1, math.ceil((baseline.duration_ms * args.timeout_factor) / 1000))
    local jobs = {}
    for index, site in ipairs(selection_result.covered) do
      jobs[#jobs + 1] = {
        site_index = index,
        line = site.line,
        description = site.description,
        relative_file = relative_file,
        mutated_source = scanner.apply_mutation(stripped_source, site),
      }
    end
    if args.verbose then
      write_to(out, string.format("Running %d mutations with %d workers.\n", #jobs, args.max_workers))
    end
    local batch_results = runner.run_mutations(tool_root, {
      project_root = project_root,
      target_file = relative_file,
      command = command,
      timeout_seconds = timeout_seconds,
      max_workers = args.max_workers,
      verbose = args.verbose,
      jobs = jobs,
    })
    local results = {}
    local survived = false
    for _, item in ipairs(sorted_results(batch_results.results or {})) do
      local killed = item.timed_out or item.exit_code ~= 0
      if not killed then
        survived = true
      end
      results[#results + 1] = {
        killed = killed,
        timed_out = item.timed_out,
        duration_ms = item.duration_ms,
        line = item.line,
        description = item.description,
      }
    end
    write_to(out, report.run(relative_file, baseline, diagnostics, selection_result.uncovered, results))
    if not survived then
      manifest.write(target_file, stripped_source, manifest_data(analysis))
      return 0
    end
    return 3
  end
  local ok, result = xpcall(execute, debug.traceback)
  if not ok then
    cleanup()
    error(result)
  end
  cleanup()
  return result
end
return cli
