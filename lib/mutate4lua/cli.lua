local engine = require("mutate4lua.engine")

local cli = {}

local function _help_text(command_name)
  return table.concat({
    "用法: lua " .. tostring(command_name) .. " <file.lua> [选项]",
    "Usage: lua " .. tostring(command_name) .. " <file.lua> [options]",
    "",
    "子命令 / Subcommands:",
    "  (default)          运行变异测试 / run mutation tests",
    "  --scan             扫描变异位点 / scan mutation sites",
    "  --update-manifest  写入 manifest / write manifest block",
    "  --index-suites     列出 suites / list test suites",
    "  --dry-run          打印 suite 列表 / print suite list",
    "",
    "选项 / Options:",
    "  --lane behavior|contract   默认 behavior / default behavior",
    "  --runner harness|busted    默认 harness / default harness",
    "  --mutate-all               忽略 manifest 变异所有位点（默认跳过未修改 scope）",
    "  --lines N,N                限制行号 / restrict to lines",
    "  --max-workers N            并行 worker 数（默认 CPU 核数的一半，1=串行）",
    "  --timeout-factor N         超时倍数 / timeout multiplier (default 15)",
    "  --test-command CMD         自定义测试命令 / custom test command",
    "  --mutation-warning N       变异数量警告阈值",
    "  --json                     JSON 输出",
    "  --verbose                  详细输出",
    "  --help                     显示帮助 / show help",
  }, "\n") .. "\n"
end

local function _parse_line_set(text)
  local line_set = {}
  for num in tostring(text):gmatch("(%d+)") do
    line_set[tonumber(num)] = true
  end
  return line_set
end

local function _parse_args(args)
  local options = {
    target = nil,
    subcommand = "mutate",
    lane = "behavior",
    runner = "harness",
    dry_run = false,
    mutate_all = false,
    line_set = nil,
    timeout_factor = 15,
    test_command = nil,
    mutation_warning = nil,
    json = false,
    verbose = false,
    help = false,
  }

  local index = 1
  while index <= #args do
    local token = args[index]
    if token == "--help" or token == "-h" then
      options.help = true
    elseif token == "--scan" then
      options.subcommand = "scan"
    elseif token == "--update-manifest" then
      options.subcommand = "update-manifest"
    elseif token == "--index-suites" then
      options.subcommand = "index-suites"
    elseif token == "--dry-run" then
      options.dry_run = true
    elseif token == "--mutate-all" then
      options.mutate_all = true
    elseif token == "--json" then
      options.json = true
    elseif token == "--verbose" then
      options.verbose = true
    elseif token == "--lane" then
      index = index + 1
      options.lane = args[index] or error("--lane requires a value")
    elseif token == "--runner" then
      index = index + 1
      options.runner = args[index] or error("--runner requires a value")
    elseif token == "--lines" then
      index = index + 1
      options.line_set = _parse_line_set(args[index] or error("--lines requires a value"))
    elseif token == "--max-workers" then
      index = index + 1
      options.max_workers = tonumber(args[index] or "")
    elseif token == "--timeout-factor" then
      index = index + 1
      options.timeout_factor = tonumber(args[index] or "15") or 15
    elseif token == "--test-command" then
      index = index + 1
      options.test_command = args[index] or error("--test-command requires a value")
    elseif token == "--mutation-warning" then
      index = index + 1
      options.mutation_warning = tonumber(args[index] or "0")
    elseif options.target == nil and token:sub(1, 2) ~= "--" then
      options.target = token
    else
      error("unknown option: " .. tostring(token))
    end
    index = index + 1
  end

  return options
end

local function _resolve_driver_script(options, env)
  if options.runner == "busted" then
    return env.busted_driver or "tools/quality/mutate/busted_adapter.lua"
  end
  return env.default_driver or "tools/quality/mutate/driver.lua"
end

function cli.run(args, env)
  env = env or {}
  local stdout = env.stdout or io.stdout
  local stderr = env.stderr or io.stderr
  local command_name = env.command_name or "tools/quality/mutate.lua"

  local ok, parsed_or_err = pcall(_parse_args, args or {})
  if not ok then
    stderr:write(tostring(parsed_or_err), "\n")
    stdout:write(_help_text(command_name))
    return 1
  end

  local options = parsed_or_err

  if options.help then
    stdout:write(_help_text(command_name))
    return 0
  end

  if options.lane ~= "behavior" and options.lane ~= "contract" then
    stderr:write("unsupported lane: ", tostring(options.lane), "\n")
    return 1
  end
  if options.runner ~= "harness" and options.runner ~= "busted" then
    stderr:write("unsupported runner: ", tostring(options.runner), "\n")
    return 1
  end

  options.driver_script = _resolve_driver_script(options, env)

  if options.dry_run then
    if options.runner == "busted" and env.busted_discover then
      local specs, err = env.busted_discover(options.lane)
      if not specs then
        stderr:write(tostring(err), "\n")
        return 1
      end
      stdout:write(table.concat(specs, "\n"), "\n")
      return 0
    end
    options.subcommand = "index-suites"
  end

  if options.subcommand == "scan" then
    return engine.scan(options, env)
  elseif options.subcommand == "update-manifest" then
    return engine.update_manifest(options, env)
  elseif options.subcommand == "index-suites" then
    return engine.index_suites(options, env)
  else
    return engine.mutate(options, env)
  end
end

function cli.usage()
  return _help_text("mutate4lua")
end

return cli
