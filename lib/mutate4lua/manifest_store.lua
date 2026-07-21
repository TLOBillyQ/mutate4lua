local util = require("mutate4lua.util")

-- External per-file manifest storage: one "<relative>.manifest" text file per
-- target under a store root. The file body reuses the exact key=value format
-- that older versions embedded as a "--[[ mutate4lua-manifest ... ]]" footer
-- comment inside the target source, so the parser/serializer here are shared
-- with the legacy footer reader (internal/manifest.lua). Storing manifests
-- outside the target keeps business sources byte-untouched.
--
-- The module lives next to engine.lua (not under internal/) because hosts may
-- legitimately read or prune stored manifests from their own tooling.
local manifest_store = {}

-- Parse a manifest body (the key=value text, without any comment markers).
-- Returns the same table shape the legacy footer reader produced
-- ({version, project_hash, scopes}), or nil when the body holds no parseable
-- entry at all, so callers can treat an empty/corrupt store file as absent.
function manifest_store.parse_body(body)
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

-- Serialize manifest data to the bare key=value body (no comment markers),
-- terminated by a trailing newline.
function manifest_store.serialize_body(data)
  local lines = {
    "version=" .. tostring(data.version or 2),
    "projectHash=" .. tostring(data.project_hash or ""),
  }
  for index, scope in ipairs(data.scopes or {}) do
    local key = string.format("scope.%d.", index - 1)
    lines[#lines + 1] = key .. "id=" .. tostring(scope.id)
    lines[#lines + 1] = key .. "kind=" .. tostring(scope.kind)
    lines[#lines + 1] = key .. "startLine=" .. tostring(scope.start_line)
    lines[#lines + 1] = key .. "endLine=" .. tostring(scope.end_line)
    lines[#lines + 1] = key .. "semanticHash=" .. tostring(scope.semantic_hash)
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
  return table.concat(lines, "\n") .. "\n"
end

-- "<store_root>/<relative>.manifest"; relative is a forward-slash path such as
-- "src/player.lua", so nested targets map to nested store directories.
function manifest_store.store_path(store_root, relative)
  return util.join_path(store_root, util.normalize_relative_path(relative) .. ".manifest")
end

function manifest_store.read(store_root, relative)
  local raw = util.read_file(manifest_store.store_path(store_root, relative))
  if raw == nil then
    return nil
  end
  return manifest_store.parse_body(util.normalize_newlines(raw))
end

function manifest_store.write(store_root, relative, data)
  -- Write via temp + rename (same style as the legacy footer writer) so an
  -- interrupt cannot truncate a stored manifest.
  local path = manifest_store.store_path(store_root, relative)
  util.mkdir_p(util.parent_dir(path))
  local part_path = path .. ".part"
  assert(util.write_file(part_path, manifest_store.serialize_body(data)))
  assert(os.rename(part_path, path))
end

return manifest_store
