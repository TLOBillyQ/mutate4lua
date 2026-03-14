local util = {}
local function shell_quote(value)
  value = tostring(value)
  if value:find("%z") then
    error("Refusing to shell-quote NUL characters")
  end
  return "'" .. value:gsub("'", "'\\''") .. "'"
end
util.shell_quote = shell_quote
function util.trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end
function util.starts_with(value, prefix)
  return value:sub(1, #prefix) == prefix
end
function util.ends_with(value, suffix)
  return suffix == "" or value:sub(-#suffix) == suffix
end
function util.read_file(path)
  local handle, err = io.open(path, "rb")
  if not handle then
    return nil, err
  end
  local data = handle:read("*a")
  handle:close()
  return data
end
function util.write_file(path, content)
  local handle, err = io.open(path, "wb")
  if not handle then
    return nil, err
  end
  handle:write(content)
  handle:close()
  return true
end
function util.capture(command)
  local handle, err = io.popen(command, "r")
  if not handle then
    return nil, err
  end
  local output = handle:read("*a")
  local ok, kind, code = handle:close()
  if ok == nil then
    if kind == "exit" and type(code) == "number" then
      return nil, string.format("command failed (exit=%d): %s", code, output)
    end
    return nil, "command failed: " .. output
  end
  return output
end
function util.command_succeeds(command)
  local ok, kind, code = os.execute(command)
  if type(ok) == "number" then
    return ok == 0
  end
  if ok == true then
    if kind == "exit" and type(code) == "number" then
      return code == 0
    end
    return true
  end
  if ok == nil and kind == "exit" and type(code) == "number" then
    return code == 0
  end
  return false
end
function util.path_exists(path)
  return util.command_succeeds("test -e " .. shell_quote(path))
end
function util.is_file(path)
  return util.command_succeeds("test -f " .. shell_quote(path))
end
function util.is_directory(path)
  return util.command_succeeds("test -d " .. shell_quote(path))
end
function util.mkdir_p(path)
  assert(util.command_succeeds("mkdir -p " .. shell_quote(path)), "failed to create " .. path)
end
function util.remove(path)
  os.execute("rm -rf " .. shell_quote(path))
end
function util.parent_dir(path)
  local normalized = path:gsub("/+$", "")
  local parent = normalized:match("^(.*)/[^/]+$")
  if not parent or parent == "" then
    return "/"
  end
  return parent
end
function util.basename(path)
  return path:match("([^/]+)$") or path
end
function util.join_path(...)
  local parts = {...}
  if #parts == 0 then
    return ""
  end
  local result = parts[1]
  for index = 2, #parts do
    local part = parts[index]
    if result:sub(-1) ~= "/" then
      result = result .. "/"
    end
    result = result .. part:gsub("^/+", "")
  end
  return result
end
function util.absolute_path(path)
  local command = "python3 -c " .. shell_quote([[import os, sys
print(os.path.abspath(sys.argv[1]))]]) .. " " .. shell_quote(path)
  local output = assert(util.capture(command))
  return util.trim(output)
end
function util.relative_path(root, path)
  root = util.absolute_path(root)
  path = util.absolute_path(path)
  if path == root then
    return "."
  end
  if util.starts_with(path, root .. "/") then
    return path:sub(#root + 2)
  end
  local command = "python3 -c " .. shell_quote([[import os, sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))]]) .. " " .. shell_quote(root) .. " " .. shell_quote(path)
  return util.trim(assert(util.capture(command)))
end
function util.list_files(root, include_patterns)
  include_patterns = include_patterns or {"*.lua"}
  local tests = {}
  for _, pattern in ipairs(include_patterns) do
    tests[#tests + 1] = "-name " .. shell_quote(pattern)
  end
  local command = "find " .. shell_quote(root) .. " -type f \\( " .. table.concat(tests, " -o ") .. " \\) | sort"
  local output = assert(util.capture(command))
  local files = {}
  for line in output:gmatch("[^\n]+") do
    if line ~= "" then
      files[#files + 1] = line
    end
  end
  return files
end
function util.find_first(root, expression)
  local command = "find " .. shell_quote(root) .. " -maxdepth 1 " .. expression .. " | head -1"
  local output = assert(util.capture(command))
  return util.trim(output)
end
function util.tmp_path(suffix)
  local base = os.tmpname()
  if suffix and suffix ~= "" then
    return base .. suffix
  end
  return base
end
function util.deepcopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[util.deepcopy(key)] = util.deepcopy(item)
  end
  return copy
end
function util.escape_lua_string(value)
  return string.format("%q", value)
end
local function encode_json(value)
  local value_type = type(value)
  if value_type == "nil" then
    return "null"
  end
  if value_type == "boolean" or value_type == "number" then
    return tostring(value)
  end
  if value_type == "string" then
    local escaped = value:gsub('\\', '\\\\')
      :gsub('"', '\\"')
      :gsub('\b', '\\b')
      :gsub('\f', '\\f')
      :gsub('\n', '\\n')
      :gsub('\r', '\\r')
      :gsub('\t', '\\t')
    return '"' .. escaped .. '"'
  end
  if value_type ~= "table" then
    error("cannot encode json type: " .. value_type)
  end
  local is_array = true
  local max_index = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key <= 0 or key % 1 ~= 0 then
      is_array = false
      break
    end
    if key > max_index then
      max_index = key
    end
  end
  if is_array then
    local parts = {}
    for index = 1, max_index do
      parts[index] = encode_json(value[index])
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local parts = {}
  for key, item in pairs(value) do
    parts[#parts + 1] = encode_json(tostring(key)) .. ":" .. encode_json(item)
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ",") .. "}"
end
function util.write_json(path, value)
  assert(util.write_file(path, encode_json(value)))
end
function util.normalize_newlines(value)
  return value:gsub("\r\n", "\n")
end
function util.split_lines(value)
  local lines = {}
  value = util.normalize_newlines(value)
  if value == "" then
    return {""}
  end
  for line in (value .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end
function util.fnv1a64(text)
  local native_bitops = pcall(function()
    return load("return (0 ~ 0) == 0 and (0 & 0) == 0")()
  end)
  if native_bitops then
    local hash = 0xcbf29ce484222325
    local prime = 0x100000001b3
    for index = 1, #text do
      hash = hash ~ text:byte(index)
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF
    end
    return string.format("%016x", hash)
  end
  local input_path = util.tmp_path(".txt")
  assert(util.write_file(input_path, text))
  local command = "python3 -c " .. shell_quote([[import sys
offset = 0xcbf29ce484222325
prime = 0x100000001b3
with open(sys.argv[1], "rb") as handle:
    data = handle.read()
value = offset
for byte in data:
    value ^= byte
    value = (value * prime) & 0xFFFFFFFFFFFFFFFF
print(f"{value:016x}")]]) .. " " .. shell_quote(input_path)
  local output = assert(util.capture(command))
  util.remove(input_path)
  return util.trim(output)
end
function util.default_max_workers()
  local command = "python3 -c " .. shell_quote([[import os
count = os.cpu_count() or 1
print(max(1, count // 2))]])
  local output = util.capture(command)
  if not output then
    return 1
  end
  local value = tonumber(util.trim(output))
  if not value or value < 1 then
    return 1
  end
  return value
end
return util
