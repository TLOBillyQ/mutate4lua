local util = require("mutate4lua.util")
local manifest = {}
manifest.start_marker = "--[[ mutate4lua-manifest\n"
manifest.end_marker = "]]"
local function start_index(source)
  local start_at = source:match("()" .. "%-%-%[%[ mutate4lua%-manifest\n")
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
  return util.trim(source:sub(1, index - 1)) .. "\n"
end
function manifest.read(path)
  local raw = assert(util.read_file(path))
  raw = util.normalize_newlines(raw)
  local index = start_index(raw)
  if not index then
    return nil
  end
  local stop = raw:find(manifest.end_marker, index, true)
  if not stop then
    return nil
  end
  local body = util.trim(raw:sub(index + #manifest.start_marker, stop - 1))
  local data = {scopes = {}}
  local scope_map = {}
  for line in body:gmatch("[^\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key then
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
  for index_key, scope in pairs(scope_map) do
    data.scopes[index_key] = {
      id = scope.id,
      kind = scope.kind,
      start_line = tonumber(scope.startLine),
      end_line = tonumber(scope.endLine),
      semantic_hash = scope.semanticHash,
      last_mutated_at = scope.lastMutatedAt,
      last_mutation_lane = scope.lastMutationLane,
      last_mutation_status = scope.lastMutationStatus,
      last_mutation_sites = tonumber(scope.lastMutationSites),
      last_mutation_killed = tonumber(scope.lastMutationKilled),
    }
  end
  return {
    version = tonumber(data.version or "1"),
    project_hash = data.projectHash,
    scopes = data.scopes,
  }
end
function manifest.serialize(data)
  local lines = {
    manifest.start_marker:sub(1, -2),
    "version=" .. tostring(data.version or 2),
    "projectHash=" .. tostring(data.project_hash or ""),
  }
  for index, scope in ipairs(data.scopes or {}) do
    local key = string.format("scope.%d.", index - 1)
    lines[#lines + 1] = key .. "id=" .. scope.id
    lines[#lines + 1] = key .. "kind=" .. scope.kind
    lines[#lines + 1] = key .. "startLine=" .. tostring(scope.start_line)
    lines[#lines + 1] = key .. "endLine=" .. tostring(scope.end_line)
    lines[#lines + 1] = key .. "semanticHash=" .. scope.semantic_hash
    if scope.last_mutated_at ~= nil then
      lines[#lines + 1] = key .. "lastMutatedAt=" .. tostring(scope.last_mutated_at)
    end
    if scope.last_mutation_lane ~= nil then
      lines[#lines + 1] = key .. "lastMutationLane=" .. tostring(scope.last_mutation_lane)
    end
    if scope.last_mutation_status ~= nil then
      lines[#lines + 1] = key .. "lastMutationStatus=" .. tostring(scope.last_mutation_status)
    end
    if scope.last_mutation_sites ~= nil then
      lines[#lines + 1] = key .. "lastMutationSites=" .. tostring(scope.last_mutation_sites)
    end
    if scope.last_mutation_killed ~= nil then
      lines[#lines + 1] = key .. "lastMutationKilled=" .. tostring(scope.last_mutation_killed)
    end
  end
  lines[#lines + 1] = manifest.end_marker
  return table.concat(lines, "\n") .. "\n"
end
function manifest.write(path, source_without_manifest, data)
  local output = util.trim(source_without_manifest) .. "\n\n" .. manifest.serialize(data)
  assert(util.write_file(path, output))
end
return manifest
