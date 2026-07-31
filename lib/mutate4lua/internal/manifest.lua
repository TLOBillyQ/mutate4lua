local util = require("mutate4lua.util")

local manifest = {}
manifest.start_marker = "--[[ mutate4lua-manifest\n"
manifest.end_marker = "]]"

-- Position capture + escaped marker text, hoisted so the scan loop in
-- start_index does not rebuild it for every candidate position.
local start_pattern = "()%-%-%[%[ mutate4lua%-manifest\n"

local function start_index(source)
  -- The manifest block is always the LAST occurrence of the marker: marker
  -- text inside an earlier string or comment must not truncate the source.
  local start_at = nil
  local from = 1
  while true do
    local at = source:match(start_pattern, from)
    if not at then
      break
    end
    start_at = at
    from = at + 1
  end
  if not start_at then
    return nil
  end
  local tail = source:sub(start_at)
  if util.trim(tail):sub(-2) ~= manifest.end_marker then
    return nil
  end
  return start_at
end

function manifest.strip(source)
  source = util.normalize_newlines(source)
  local index = start_index(source)
  if not index then
    return source
  end
  -- Collapse only the trailing newlines before the marker; leading blank
  -- lines stay so line numbers and the project hash input do not shift.
  return (source:sub(1, index - 1):gsub("\n+$", "")) .. "\n"
end

local function parse_body(body)
  body = util.trim(body)
  local data = {scopes = {}}
  local scope_map = {}
  local parsed_keys = 0
  for line in body:gmatch("[^\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key then
      parsed_keys = parsed_keys + 1
      local scope_index, field = key:match("^scope%.(%d+)%.(.+)$")
      if scope_index then
        scope_index = tonumber(scope_index) + 1
        scope_map[scope_index] = scope_map[scope_index] or {}
        scope_map[scope_index][field] = value
      else
        data[key] = value
      end
    end
  end
  if parsed_keys == 0 then
    return nil
  end
  -- Scope numbers may be non-contiguous; insert in sorted order so
  -- data.scopes stays a dense array for ipairs consumers.
  local ordered_keys = {}
  for index_key in pairs(scope_map) do
    ordered_keys[#ordered_keys + 1] = index_key
  end
  table.sort(ordered_keys)
  for _, index_key in ipairs(ordered_keys) do
    local scope = scope_map[index_key]
    data.scopes[#data.scopes + 1] = {
      id = scope.id,
      kind = scope.kind,
      start_line = tonumber(scope.startLine),
      end_line = tonumber(scope.endLine),
      semantic_hash = scope.semanticHash,
    }
  end
  return {
    version = tonumber(data.version or "1"),
    project_hash = data.projectHash,
    scopes = data.scopes,
  }
end

local function serialize_body(data)
  local lines = {
    "version=" .. tostring(data.version or 4),
    "projectHash=" .. tostring(data.project_hash or ""),
  }
  for index, scope in ipairs(data.scopes or {}) do
    local key = string.format("scope.%d.", index - 1)
    lines[#lines + 1] = key .. "id=" .. tostring(scope.id)
    lines[#lines + 1] = key .. "kind=" .. tostring(scope.kind)
    lines[#lines + 1] = key .. "startLine=" .. tostring(scope.start_line)
    lines[#lines + 1] = key .. "endLine=" .. tostring(scope.end_line)
    lines[#lines + 1] = key .. "semanticHash=" .. tostring(scope.semantic_hash)
  end
  return table.concat(lines, "\n") .. "\n"
end

function manifest.read(path)
  local raw = util.read_file(path)
  if raw == nil then
    return nil
  end
  raw = util.normalize_newlines(raw)
  local index = start_index(raw)
  if not index then
    return nil
  end
  local stop = raw:find(manifest.end_marker, index, true)
  if not stop then
    return nil
  end
  local body = raw:sub(index + #manifest.start_marker, stop - 1)
  -- A footer whose body holds no parseable entry is treated as "no manifest".
  return parse_body(body)
end

function manifest.serialize(data)
  return manifest.start_marker
    .. serialize_body(data)
    .. manifest.end_marker .. "\n"
end

function manifest.write(path, source_without_manifest, data)
  -- Normalize only the trailing newlines and keep the head byte-for-byte:
  -- trimming leading blank lines would shift line numbers, and the written
  -- file would differ from the strip() output the project hash covers.
  -- Write via temp + rename so an interrupt cannot truncate the user source.
  local output = (source_without_manifest:gsub("\n+$", "")) .. "\n\n" .. manifest.serialize(data)
  local part_path = path .. ".part"
  assert(util.write_file(part_path, output))
  assert(os.rename(part_path, path))
end

return manifest
