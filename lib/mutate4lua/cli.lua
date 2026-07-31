local default_engine = require("mutate4lua.engine")

local cli = {}

local function _help_text(command_name)
  return table.concat({
    "用法: lua " .. tostring(command_name) .. " <file.lua> [选项]",
    "Usage: lua " .. tostring(command_name) .. " <file.lua> [options]",
    "",
    "子命令 / Subcommands:",
    "  (default)          运行变异测试 / run mutation tests",
    "  --scan             扫描变异位点 / scan mutation sites",
    "  --update-manifest  写入 embedded manifest footer / write embedded manifest footer",
    "",
    "选项 / Options:",
    "  --mutate-all               忽略 manifest 变异所有位点 / ignore manifest and mutate all sites",
    "  --since-last-run           只变异与 manifest 不同的 scope / restrict to changed scopes",
    "  --lines N,N                限制行号 / restrict to lines",
    "  --reuse-coverage           复用已有 luacov 报告 / reuse existing luacov report",
    "  --max-workers N            并行 worker 数（默认 CPU 核数的一半，1=串行）",
    "  --timeout-factor N         超时倍数 / timeout multiplier (default 10)",
    "  --test-command CMD         自定义测试命令 / custom test command",
    "  --mutation-warning N       变异数量警告阈值 / mutation count warning threshold (default 50)",
    "  --verbose                  详细输出 / verbose output",
    "  -h, --help                 显示帮助 / show help",
  }, "\n") .. "\n"
end

local function _parse_line_set(text)
  local line_set = {}
  for num in tostring(text):gmatch("(%d+)") do
    line_set[tonumber(num)] = true
  end
  if not next(line_set) then
    error("--lines requires a comma-separated list of line numbers", 0)
  end
  return line_set
end

local function _parse_args(args)
  local options = {
    target = nil,
    subcommand = "mutate",
    scan = false,
    update_manifest = false,
    mutate_all = false,
    since_last_run = false,
    reuse_coverage = false,
    line_set = nil,
    timeout_factor = 10,
    test_command = nil,
    mutation_warning = 50,
    verbose = false,
    help = false,
  }

  local index = 1
  while index <= #args do
    local token = args[index]
    if token == "--help" or token == "-h" then
      options.help = true
    elseif token == "--scan" then
      options.scan = true
      options.subcommand = "scan"
    elseif token == "--update-manifest" then
      options.update_manifest = true
      options.subcommand = "update-manifest"
    elseif token == "--mutate-all" then
      options.mutate_all = true
    elseif token == "--since-last-run" then
      options.since_last_run = true
    elseif token == "--reuse-coverage" then
      options.reuse_coverage = true
    elseif token == "--verbose" then
      options.verbose = true
    elseif token == "--lines" then
      index = index + 1
      options.line_set = _parse_line_set(args[index] or error("--lines requires a value", 0))
    elseif token == "--max-workers" then
      index = index + 1
      options.max_workers = tonumber(args[index] or "") or error("--max-workers requires a numeric value", 0)
    elseif token == "--timeout-factor" then
      index = index + 1
      options.timeout_factor = tonumber(args[index] or "") or error("--timeout-factor requires a numeric value", 0)
    elseif token == "--test-command" then
      index = index + 1
      options.test_command = args[index] or error("--test-command requires a value", 0)
    elseif token == "--mutation-warning" then
      index = index + 1
      options.mutation_warning = tonumber(args[index] or "") or error("--mutation-warning requires a numeric value", 0)
    elseif options.target == nil and token:sub(1, 2) ~= "--" then
      options.target = token
    else
      error("unknown option: " .. tostring(token), 0)
    end
    index = index + 1
  end

  return options
end

local function _has_conflict(options)
  local scan = options.scan
  local update = options.update_manifest
  local lines = options.line_set ~= nil
  local since = options.since_last_run
  local all = options.mutate_all
  local reuse = options.reuse_coverage

  if scan and since then return "--scan cannot be combined with --since-last-run" end
  if scan and all then return "--scan cannot be combined with --mutate-all" end
  if scan and update then return "--scan cannot be combined with --update-manifest" end
  if scan and reuse then return "--scan cannot be combined with --reuse-coverage" end
  if lines and since then return "--lines cannot be combined with --since-last-run" end
  if lines and all then return "--lines cannot be combined with --mutate-all" end
  if lines and update then return "--lines cannot be combined with --update-manifest" end
  if since and all then return "--since-last-run cannot be combined with --mutate-all" end
  if update and since then return "--update-manifest cannot be combined with --since-last-run" end
  if update and all then return "--update-manifest cannot be combined with --mutate-all" end
  if update and reuse then return "--update-manifest cannot be combined with --reuse-coverage" end
  return nil
end

function cli.run(args, env)
  env = env or {}
  local engine = env.engine or default_engine
  local stdout = env.stdout or io.stdout
  local stderr = env.stderr or io.stderr
  local command_name = env.command_name or "mutate4lua"

  local ok, parsed_or_err = pcall(_parse_args, args or {})
  if not ok then
    stderr:write(tostring(parsed_or_err), "\n")
    stderr:write(_help_text(command_name))
    return 1
  end

  local options = parsed_or_err

  if options.help then
    stdout:write(_help_text(command_name))
    return 0
  end

  local conflict = _has_conflict(options)
  if conflict then
    stderr:write("error: ", conflict, "\n")
    stderr:write(_help_text(command_name))
    return 1
  end

  -- Runs go through the built-in luaunit runner (ADR-0005); the removed
  -- env.default_driver hook is no longer read. --test-command remains as the
  -- upstream escape hatch for hosts that cannot use the runner.

  if options.subcommand == "scan" then
    return engine.scan(options, env)
  elseif options.subcommand == "update-manifest" then
    return engine.update_manifest(options, env)
  else
    return engine.mutate(options, env)
  end
end

function cli.usage()
  return _help_text("mutate4lua")
end

return cli
