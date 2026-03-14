local util = require("mutate4lua.util")
local runner = {}
local function helper_path(tool_root)
  return util.join_path(tool_root, "scripts", "process_helper.py")
end
local function load_lua_table(path)
  local chunk, err = loadfile(path)
  if not chunk then
    return nil, err
  end
  local ok, result = pcall(chunk)
  if not ok then
    return nil, result
  end
  return result
end
local function invoke(tool_root, mode, payload)
  local config_path = util.tmp_path(".json")
  local output_path = util.tmp_path(".lua")
  util.write_json(config_path, payload)
  local command = table.concat({
    "python3",
    util.shell_quote(helper_path(tool_root)),
    mode,
    "--config",
    util.shell_quote(config_path),
    "--output",
    util.shell_quote(output_path),
  }, " ")
  local ok = util.command_succeeds(command)
  local result, load_err = load_lua_table(output_path)
  util.remove(config_path)
  util.remove(output_path)
  if not result then
    local message = load_err or "unknown helper output error"
    if not ok then
      error("helper command failed: " .. message)
    end
    error("helper output could not be read: " .. message)
  end
  return result
end
function runner.run_command(tool_root, cwd, command, timeout_seconds, coverage_file)
  local payload = {
    cwd = cwd,
    timeout_seconds = timeout_seconds,
    coverage_file = coverage_file,
  }
  if type(command) == "table" then
    payload.command_args = command
  else
    payload.command = command
  end
  return invoke(tool_root, "run", payload)
end
function runner.run_mutations(tool_root, config)
  local payload = util.deepcopy(config)
  if type(payload.command) == "table" then
    payload.command_args = payload.command
    payload.command = nil
  end
  return invoke(tool_root, "mutate-batch", payload)
end
function runner.read_coverage(path)
  local lines = {}
  if not util.is_file(path) then
    return lines
  end
  local content = assert(util.read_file(path))
  for line in content:gmatch("[^\n]+") do
    if line ~= "" then
      lines[line] = true
    end
  end
  return lines
end
return runner
