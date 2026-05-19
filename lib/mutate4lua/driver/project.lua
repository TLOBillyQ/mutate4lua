local util = require("mutate4lua.util")
local project = {}
local ignored_segments = {
  ["/.git/"] = true,
  ["/.mutate4lua/"] = true,
  ["/coverage/"] = true,
  ["/.coverage/"] = true,
  ["/__pycache__/"] = true,
}
local function has_root_marker(path)
  if util.path_exists(util.join_path(path, ".git")) then
    return true
  end
  if util.find_first(path, "-name '*.rockspec'") ~= "" then
    return true
  end
  if util.is_directory(util.join_path(path, "spec")) or util.is_directory(util.join_path(path, "test")) or util.is_directory(util.join_path(path, "tests")) then
    return true
  end
  return false
end
function project.find_root(workspace_root, target_file)
  workspace_root = util.absolute_path(workspace_root)
  local cursor = util.parent_dir(util.absolute_path(target_file))
  while cursor and cursor ~= "/" do
    if has_root_marker(cursor) then
      return cursor
    end
    if cursor == workspace_root then
      break
    end
    local parent = util.parent_dir(cursor)
    if parent == cursor then
      break
    end
    cursor = parent
  end
  return workspace_root
end
function project.relative_file(project_root, path)
  return util.relative_path(project_root, path):gsub("\\", "/")
end
function project.project_hash(project_root, target_file, stripped_source)
  local files = util.list_files(project_root, {"*.lua", "*.rockspec"})
  local parts = {}
  for _, path in ipairs(files) do
    local skip = false
    for segment in pairs(ignored_segments) do
      if path:find(segment, 1, true) then
        skip = true
        break
      end
    end
    if not skip then
      local content = assert(util.read_file(path))
      content = util.normalize_newlines(content)
      if util.absolute_path(path) == util.absolute_path(target_file) then
        content = stripped_source
      end
      parts[#parts + 1] = project.relative_file(project_root, path)
      parts[#parts + 1] = "\n"
      parts[#parts + 1] = content
      parts[#parts + 1] = "\n\0\n"
    end
  end
  return util.fnv1a64(table.concat(parts))
end
function project.default_test_command(tool_root, _opts)
  return {
    "lua",
    util.join_path(tool_root, "lib", "mutate4lua", "driver", "default.lua"),
    "--root",
    ".",
    "--tool-root",
    tool_root,
  }
end
function project.discover_test_files(project_root)
  local candidates = {}
  local patterns = {
    util.join_path(project_root, "spec"),
    util.join_path(project_root, "test"),
    util.join_path(project_root, "tests"),
  }
  for _, directory in ipairs(patterns) do
    if util.is_directory(directory) then
      local files = util.list_files(directory, {"*_spec.lua", "*_test.lua", "*.lua"})
      for _, file in ipairs(files) do
        candidates[#candidates + 1] = file
      end
    end
  end
  table.sort(candidates)
  return candidates
end
return project
