-- One-off migration from the pre-alignment external manifest store to an
-- embedded v4 manifest footer.
--
-- Usage: lua tools/migrate_manifest.lua <file.lua>
--
-- The script:
--   1. strips any existing legacy footer manifest from the target file;
--   2. removes the corresponding .mutate4lua/manifest/<relative>.manifest store
--      file, if present;
--   3. computes a fresh v4 manifest from the stripped source;
--   4. appends the manifest as a --[[ mutate4lua-manifest ... ]] footer.

local script_path = arg[0] or "."
local script_dir = script_path:match("^(.*)/") or "."
package.path = script_dir .. "/../lib/?.lua;" .. script_dir .. "/../lib/?/init.lua;" .. package.path

local manifest = require("mutate4lua.internal.manifest")
local scanner = require("mutate4lua.internal.scanner")
local project = require("mutate4lua.driver.project")
local util = require("mutate4lua.util")

local function is_absolute(path)
  path = tostring(path or "")
  return path:sub(1, 1) == "/" or path:sub(1, 2) == "\\\\" or path:match("^%a:[/\\]") ~= nil
end

local function usage()
  io.stderr:write("Usage: lua tools/migrate_manifest.lua <file.lua>\n")
end

if #arg < 1 then
  usage()
  os.exit(1)
end

local target = arg[1]
local workspace_root = "."
local abs_target
if is_absolute(target) then
  abs_target = util.absolute_path(target)
else
  abs_target = util.absolute_path(util.join_path(workspace_root, target))
end

local source = util.read_file(abs_target)
if not source then
  io.stderr:write("error: cannot read ", target, "\n")
  os.exit(1)
end

local stripped = manifest.strip(source)
local project_root = project.find_root(workspace_root, abs_target)
local relative = project.relative_file(project_root, abs_target)

-- Remove any legacy external store entry.
local store_file = util.join_path(project_root, ".mutate4lua", "manifest", relative .. ".manifest")
if util.is_file(store_file) then
  util.remove(store_file)
end

local data = scanner.analyze(abs_target, relative, stripped)
local proj_hash = project.project_hash(project_root, abs_target, stripped)
manifest.write(abs_target, stripped, {
  version = 4,
  project_hash = proj_hash,
  scopes = data.scopes,
})

io.write("manifest migrated: ", relative, "\n")
