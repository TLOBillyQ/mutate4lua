local util = {}
local sep = package.config:sub(1, 1)

local function shell_quote(value)
  value = tostring(value)
  if value:find("%z") then
    error("Refusing to shell-quote NUL characters")
  end
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function is_windows_path(path)
  return tostring(path or ""):match("^%a:[/\\]") ~= nil
end

local function is_absolute_path(path)
  path = tostring(path or "")
  return path:sub(1, 1) == "/" or path:sub(1, 2) == "\\\\" or is_windows_path(path)
end

local function current_working_directory()
  local env_pwd = os.getenv("PWD")
  if env_pwd and env_pwd ~= "" then
    return env_pwd
  end
  local command = sep == "\\" and "cd" or "pwd"
  local output = assert(util.capture(command))
  return util.trim(output)
end

local function split_prefix(path)
  path = tostring(path or ""):gsub("\\", "/")
  if path:match("^%a:/") then
    return path:sub(1, 3), path:sub(4)
  end
  if path:sub(1, 2) == "//" then
    local server, share, rest = path:match("^(//[^/]+/[^/]+)(/?)(.*)$")
    if server then
      return server .. "/", rest
    end
  end
  if path:sub(1, 1) == "/" then
    return "/", path:sub(2)
  end
  return "", path
end

local function split_segments(path)
  local segments = {}
  for segment in path:gmatch("[^/]+") do
    segments[#segments + 1] = segment
  end
  return segments
end

local function normalize_path(path)
  local prefix, remainder = split_prefix(path)
  local segments = split_segments(remainder)
  local normalized = {}
  for _, segment in ipairs(segments) do
    if segment == "." or segment == "" then
      -- skip
    elseif segment == ".." then
      if #normalized > 0 and normalized[#normalized] ~= ".." then
        normalized[#normalized] = nil
      elseif prefix == "" then
        normalized[#normalized + 1] = segment
      end
    else
      normalized[#normalized + 1] = segment
    end
  end
  local joined = table.concat(normalized, "/")
  if prefix == "" then
    return joined == "" and "." or joined
  end
  if joined == "" then
    return prefix:gsub("/$", "") == "" and "/" or prefix:gsub("/$", "")
  end
  return prefix .. joined
end

local function lowercase_drive(path)
  return (path:gsub("^(%a:)", string.lower))
end

util.shell_quote = shell_quote

function util.trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function util.starts_with(value, prefix)
  value = tostring(value or "")
  prefix = tostring(prefix or "")
  return value:sub(1, #prefix) == prefix
end

function util.ends_with(value, suffix)
  value = tostring(value or "")
  suffix = tostring(suffix or "")
  return suffix == "" or value:sub(-#suffix) == suffix
end

function util.normalize_relative_path(path)
  local normalized = tostring(path or ""):gsub("\\", "/")
  while util.starts_with(normalized, "./") do
    normalized = normalized:sub(3)
  end
  normalized = normalized:gsub("/+", "/")
  if normalized == "" then
    return "."
  end
  return normalized
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
  local normalized = normalize_path(path):gsub("/+$", "")
  if normalized == "." then
    return "."
  end
  local prefix, remainder = split_prefix(normalized)
  local segments = split_segments(remainder)
  if #segments == 0 then
    return prefix == "" and "." or prefix:gsub("/$", "")
  end
  segments[#segments] = nil
  local joined = table.concat(segments, "/")
  if prefix == "" then
    return joined == "" and "." or joined
  end
  if joined == "" then
    return prefix:gsub("/$", "")
  end
  return prefix .. joined
end

function util.basename(path)
  return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

function util.join_path(...)
  local parts = {...}
  if #parts == 0 then
    return ""
  end
  local result = tostring(parts[1] or "")
  for index = 2, #parts do
    local part = tostring(parts[index] or "")
    if result == "" or result:sub(-1) == "/" then
      result = result .. part:gsub("^/+", "")
    else
      result = result .. "/" .. part:gsub("^/+", "")
    end
  end
  return result
end

function util.absolute_path(path)
  path = tostring(path or "")
  if path == "" then
    return normalize_path(current_working_directory())
  end
  if is_absolute_path(path) then
    return normalize_path(path)
  end
  return normalize_path(util.join_path(current_working_directory(), path))
end

function util.relative_path(root, path)
  root = util.absolute_path(root)
  path = util.absolute_path(path)
  local root_prefix, root_remainder = split_prefix(root)
  local path_prefix, path_remainder = split_prefix(path)
  if lowercase_drive(root_prefix) ~= lowercase_drive(path_prefix) then
    return path
  end
  local root_segments = split_segments(root_remainder)
  local path_segments = split_segments(path_remainder)
  local index = 1
  while root_segments[index] and path_segments[index] and root_segments[index] == path_segments[index] do
    index = index + 1
  end
  local parts = {}
  for _ = index, #root_segments do
    parts[#parts + 1] = ".."
  end
  for segment_index = index, #path_segments do
    parts[#parts + 1] = path_segments[segment_index]
  end
  if #parts == 0 then
    return "."
  end
  return table.concat(parts, "/")
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

util.encode_json = encode_json

function util.write_json(path, value)
  assert(util.write_file(path, encode_json(value)))
end

local function _json_decode(text, pos)
  pos = text:match("^%s*()", pos or 1)
  local ch = text:sub(pos, pos)
  if ch == '"' then
    local cursor = pos + 1
    local parts = {}
    while cursor <= #text do
      local c = text:sub(cursor, cursor)
      if c == '\\' then
        local nc = text:sub(cursor + 1, cursor + 1)
        if nc == 'n' then parts[#parts + 1] = '\n'
        elseif nc == 't' then parts[#parts + 1] = '\t'
        elseif nc == 'r' then parts[#parts + 1] = '\r'
        elseif nc == '"' then parts[#parts + 1] = '"'
        elseif nc == '\\' then parts[#parts + 1] = '\\'
        elseif nc == '/' then parts[#parts + 1] = '/'
        else parts[#parts + 1] = nc end
        cursor = cursor + 2
      elseif c == '"' then
        return table.concat(parts), cursor + 1
      else
        parts[#parts + 1] = c
        cursor = cursor + 1
      end
    end
    return nil, pos
  elseif ch == '{' then
    local obj = {}
    pos = text:match("^%s*()", pos + 1)
    if text:sub(pos, pos) == '}' then return obj, pos + 1 end
    while true do
      local key, val
      key, pos = _json_decode(text, pos)
      pos = text:match("^%s*:%s*()", pos)
      val, pos = _json_decode(text, pos)
      obj[key] = val
      pos = text:match("^%s*()", pos)
      if text:sub(pos, pos) == '}' then return obj, pos + 1 end
      pos = text:match("^%s*,%s*()", pos)
    end
  elseif ch == '[' then
    local arr = {}
    pos = text:match("^%s*()", pos + 1)
    if text:sub(pos, pos) == ']' then return arr, pos + 1 end
    while true do
      local val
      val, pos = _json_decode(text, pos)
      arr[#arr + 1] = val
      pos = text:match("^%s*()", pos)
      if text:sub(pos, pos) == ']' then return arr, pos + 1 end
      pos = text:match("^%s*,%s*()", pos)
    end
  elseif text:sub(pos, pos + 3) == 'true' then
    return true, pos + 4
  elseif text:sub(pos, pos + 4) == 'false' then
    return false, pos + 5
  elseif text:sub(pos, pos + 3) == 'null' then
    return nil, pos + 4
  else
    local num_str = text:match("^%-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if num_str then return tonumber(num_str), pos + #num_str end
    return nil, pos
  end
end

function util.decode_json(text)
  if type(text) ~= "string" or text == "" then return nil end
  local value = _json_decode(text, 1)
  return value
end

function util.normalize_newlines(value)
  return tostring(value or ""):gsub("\r\n", "\n")
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

local _fnv1a_fn = nil
function util.fnv1a64(text)
  if not _fnv1a_fn then
    local ok_native = pcall(function()
      return load("return (0 ~ 0) == 0 and (0 & 0) == 0")()
    end)
    if ok_native then
      _fnv1a_fn = assert(load(table.concat({
        "return function(t)",
        "  local h = 0xcbf29ce484222325",
        "  local p = 0x100000001b3",
        "  for i = 1, #t do",
        "    h = h ~ t:byte(i)",
        "    h = (h * p) & 0xFFFFFFFFFFFFFFFF",
        "  end",
        "  return string.format('%016x', h)",
        "end",
      }, "\n")))()
    else
      local ok_bit, bit_lib = pcall(require, "bit")
      if ok_bit then
        _fnv1a_fn = function(t)
          local h = bit_lib.tobit(-2128831035)
          for i = 1, #t do
            h = bit_lib.bxor(h, t:byte(i))
            h = bit_lib.tobit(h * 16777619)
          end
          local u = h < 0 and h + 4294967296 or h
          return string.format("%08x", u)
        end
      else
        error("fnv1a requires Lua 5.3+ or LuaJIT")
      end
    end
  end
  return _fnv1a_fn(text)
end

function util.default_max_workers()
  -- Probes are functions, not a literal array: on Unix `NUMBER_OF_PROCESSORS`
  -- is unset, and a `{ nil, ... }` array literal would make `ipairs` stop at
  -- the first hole before the working getconf/sysctl probes ever run. Lazy
  -- evaluation also avoids spawning later probes once one succeeds.
  local probes = {
    function() return os.getenv("NUMBER_OF_PROCESSORS") end,
    function() return util.capture("getconf _NPROCESSORS_ONLN 2>/dev/null") end,
    function() return util.capture("nproc 2>/dev/null") end,
    function() return util.capture("sysctl -n hw.ncpu 2>/dev/null") end,
  }
  for _, probe in ipairs(probes) do
    local value = tonumber(util.trim(probe() or ""))
    if value and value >= 1 then
      return math.max(1, math.floor(value / 2))
    end
  end
  return 1
end

return util
