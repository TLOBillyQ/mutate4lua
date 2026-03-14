local util = require("mutate4lua.util")

local engine = {}

local function _source_path()
  local source = debug.getinfo(1, "S").source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  return util.absolute_path(source)
end

local function _repo_root()
  local module_dir = util.parent_dir(_source_path())
  return util.parent_dir(util.parent_dir(module_dir))
end

local function _binary_name()
  return "mutate4lua-engine"
end

local function _binary_path()
  local name = _binary_name()
  if package.config:sub(1, 1) == "\\" then
    name = name .. ".exe"
  end
  return util.join_path(_repo_root(), "bin/" .. name)
end

local function _build_binary(path)
  if not util.command_succeeds("command -v go >/dev/null 2>&1") then
    return nil, "go command not found; build mutate4lua with `go build -o " .. tostring(path) .. " ./cmd/mutate4lua-engine`"
  end
  util.mkdir_p(util.parent_dir(path))
  local command = table.concat({
    "cd", util.shell_quote(_repo_root()), "&&",
    "go build -o", util.shell_quote(path), util.shell_quote("./cmd/mutate4lua-engine"),
  }, " ")
  local output, err = util.capture(command)
  if output == nil then
    return nil, err
  end
  return path
end

function engine.resolve_binary(env)
  env = env or {}
  local explicit = env.binary_path or os.getenv("MUTATE4LUA_ENGINE_BIN")
  if explicit and explicit ~= "" then
    local path = util.absolute_path(explicit)
    if util.is_file(path) then
      return path
    end
    return _build_binary(path)
  end
  local default_path = _binary_path()
  if util.is_file(default_path) then
    return default_path
  end
  return _build_binary(default_path)
end

local function _run_command(command, cwd)
  local output_path = util.tmp_path(".log")
  local wrapped = "cd " .. util.shell_quote(cwd or ".") .. " && " .. command
  local shell_command = wrapped .. " > " .. util.shell_quote(output_path) .. " 2>&1"
  local ok, kind, code = os.execute(shell_command)
  local content = util.read_file(output_path) or ""
  util.remove(output_path)

  local exit_code = 1
  local success = false
  if type(ok) == "number" then
    exit_code = ok
    success = ok == 0
  elseif ok == true then
    if kind == "exit" and type(code) == "number" then
      exit_code = code
      success = code == 0
    else
      exit_code = 0
      success = true
    end
  elseif ok == nil and kind == "exit" and type(code) == "number" then
    exit_code = code
    success = code == 0
  end

  return {
    ok = success,
    code = exit_code,
    output = content,
  }
end

function engine.run(args, workspace_root, out, err, env)
  out = out or io.stdout
  err = err or io.stderr
  env = env or {}
  local binary_path, resolve_err = engine.resolve_binary(env)
  if not binary_path then
    err:write(tostring(resolve_err), "\n")
    return 1
  end
  local command = util.shell_quote(binary_path)
  for _, value in ipairs(args or {}) do
    command = command .. " " .. util.shell_quote(value)
  end
  local result = _run_command(command, workspace_root or ".")
  local output = tostring(result.output or "")
  if output ~= "" then
    if result.ok then
      out:write(output)
    else
      err:write(output)
    end
  end
  return result.code or (result.ok and 0 or 1)
end

return engine
