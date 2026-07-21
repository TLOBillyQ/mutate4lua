local util = require("mutate4lua.util")
local manifest_store = require("mutate4lua.manifest_store")
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
  -- Body parsing is shared with the external manifest store; a footer whose
  -- body holds no parseable entry is treated as "no manifest".
  return manifest_store.parse_body(body)
end
function manifest.serialize(data)
  return manifest.start_marker
    .. manifest_store.serialize_body(data)
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
