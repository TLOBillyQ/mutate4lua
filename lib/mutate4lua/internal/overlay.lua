-- Overlay workspace preparation for mutate4lua (clj-mutate §6 port).
--
-- Instead of a physical `cp -r` of the whole project for every worker, the
-- workspace reuses the source tree's data blocks: the fast path (workspace
-- outside the source tree) APFS-clones the tree with copy-on-write semantics;
-- the safe path (workspace nested inside the source tree, used by tests)
-- creates real directories and symlinks files back to the source. Both keep
-- the full directory structure as real directories, required so git commands
-- inside the workspace treat it as the worktree root and so tools that walk
-- the directory tree (e.g. `find -type d`, `git ls-files --others`) see normal
-- directories. Only the mutation target is materialized as a real file; on the
-- fast path the filesystem copies a block on write, so mutations never leak
-- into the host project.
--
-- Gitignored top-level entries (build/, tmp/, …) are cloned along with
-- everything else: a plain `cp -r` workspace contains them, and excluding
-- them makes the test suite run measurably slower inside the workspace (the
-- monopoly suite runs ~2.3× slower without `.toolcache`, measured 2026-08-08).
--
-- Cleanup safety: the workspace is removed with `rm -rf <path>` (no trailing
-- slash), which removes symlinks themselves without following them; contents of
-- the real project are never touched by cleanup. Callers must preserve that
-- invariant.
local util = require("mutate4lua.util")

local overlay = {}

-- Top-level names that the engine or runner writes into the workspace root.
-- They must be real copies (cp -r parity) so coverage/stats writes stay inside
-- the workspace instead of leaking through a symlink into the host project.
local ROOT_WRITE_NAMES = {
  ["luacov.report.out"] = true,
  ["luacov.stats.out"] = true,
  ["luacov.tick"] = true,
}

-- Top-level dotfiles that git and other tooling must read as real files. Git
-- refuses to follow a symlinked .gitignore ("Too many levels of symbolic links"),
-- so these are copied instead of symlinked.
local ROOT_READ_NAMES = {
  [".gitignore"] = true,
  [".gitattributes"] = true,
}

local function _shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function _copy_git(source_dir, destination)
  -- Try an APFS copy-on-write clone first (fast and shares blocks); fall back
  -- to a plain recursive copy for other filesystems.
  local clone = "cp -R -c " .. _shell_quote(source_dir) .. " " .. _shell_quote(destination) .. " 2>/dev/null"
  local plain = "cp -R " .. _shell_quote(source_dir) .. " " .. _shell_quote(destination)
  return clone .. " || " .. plain
end

local function _copy_root_names(source_dir, workspace)
  local src = _shell_quote(source_dir)
  local ws = _shell_quote(workspace)
  local names = {}
  for name, _ in pairs(ROOT_WRITE_NAMES) do names[name] = true end
  for name, _ in pairs(ROOT_READ_NAMES) do names[name] = true end
  local parts = {}
  for name, _ in pairs(names) do
    parts[#parts + 1] = "if [ -e " .. src .. "/" .. _shell_quote(name)
      .. " ]; then rm -f " .. ws .. "/" .. _shell_quote(name)
      .. " && cp " .. src .. "/" .. _shell_quote(name)
      .. " " .. ws .. "/" .. _shell_quote(name)
      .. "; fi"
  end
  return parts
end

-- Mirrors util's (module-local) is_absolute_path, which is not exported.
local function _is_absolute_path(path)
  path = tostring(path or "")
  return path:sub(1, 1) == "/" or path:sub(1, 2) == "\\\\" or path:match("^%a:[/\\]") ~= nil
end

local function _find_excludes(workspace_rel)
  local excludes = {}
  excludes[#excludes + 1] = "-not -path './.git'"
  excludes[#excludes + 1] = "-not -path './.git/*'"
  if workspace_rel and workspace_rel ~= "" and not _is_absolute_path(workspace_rel)
    and not util.starts_with(workspace_rel, "../") then
    excludes[#excludes + 1] = "-not -path './" .. workspace_rel .. "'"
    excludes[#excludes + 1] = "-not -path './" .. workspace_rel .. "/*'"
  end
  return table.concat(excludes, " ")
end

-- Collect source entries by walking the tree once per type. Directories are
-- created as real directories; files and symlinks are created as symlinks back
-- to the source so mutations never leak into the host project.
local function _collect_entries(source_dir, workspace_rel)
  local base = "cd " .. _shell_quote(source_dir)
  local excludes = _find_excludes(workspace_rel)

  local function collect(type_flag)
    local output = util.capture(base .. " && find . " .. type_flag .. " " .. excludes .. " -print")
    local entries = {}
    if output then
      for line in output:gmatch("[^\n]+") do
        if line ~= "" then
          entries[#entries + 1] = line:match("^%./(.+)$") or line
        end
      end
    end
    return entries
  end

  return collect("-type d"), collect("-type f"), collect("-type l")
end

local function _workspace_inside_source(source_dir, workspace)
  local rel = util.relative_path(source_dir, workspace)
  return rel ~= ""
    and not _is_absolute_path(rel)
    and not util.starts_with(rel, "../")
end

local function _append_git_setup(script_parts, source_dir, workspace, shared_git_dir)
  -- Git metadata must be a real directory (or a gitdir file pointing to one) so
  -- git commands inside the workspace treat the workspace as the worktree root.
  -- A symlink back to the real project's .git would make git operate on the real
  -- project instead, breaking guards that inspect the root (e.g.
  -- root_whitelist_guard).
  local src = _shell_quote(source_dir)
  local ws = _shell_quote(workspace)
  if shared_git_dir then
    script_parts[#script_parts + 1] = "rm -rf " .. ws .. "/.git && printf '%s\\n' "
      .. _shell_quote("gitdir: " .. shared_git_dir)
      .. " > " .. ws .. "/.git"
  elseif util.path_exists(util.join_path(source_dir, ".git")) then
    script_parts[#script_parts + 1] = "rm -rf " .. ws .. "/.git && "
      .. _copy_git(util.join_path(source_dir, ".git"), util.join_path(workspace, ".git"))
  end
end

local function _append_root_names(script_parts, source_dir, workspace)
  for _, part in ipairs(_copy_root_names(source_dir, workspace)) do
    script_parts[#script_parts + 1] = part
  end
end

local function _append_target_copy(script_parts, source_dir, workspace, target_relative)
  local src = _shell_quote(source_dir)
  local ws = _shell_quote(workspace)
  local target_quoted = _shell_quote(target_relative)
  script_parts[#script_parts + 1] = "rm -f " .. ws .. "/" .. target_quoted
  script_parts[#script_parts + 1] = "cp " .. src .. "/" .. target_quoted
    .. " " .. ws .. "/" .. target_quoted
end

local function _write_script_and_return_command(script_parts)
  local script = table.concat(script_parts, "\n")
  local script_path = util.tmp_path("_overlay")
  local f, open_err = io.open(script_path, "w")
  if not f then
    return nil, "failed to write overlay script: " .. tostring(open_err)
  end
  f:write(script)
  f:close()
  local script_quoted = _shell_quote(script_path)
  return "bash " .. script_quoted .. "; __status__=$?; rm -f " .. script_quoted .. "; exit $__status__"
end

-- Recursive copy of the whole project tree. Fast path: a one-shot APFS
-- clonefile() on the root directory — a single syscall that clones the entire
-- tree sharing data blocks with copy-on-write isolation (~0.05s vs ~0.5s for
-- per-file `cp -R -c` on a ~2.5k-file tree). No stock macOS CLI exposes a
-- recursive directory clone, so it is invoked through python3's ctypes when
-- available. Falls back to per-file `cp -R -c` (still CoW) and finally plain
-- `cp -R`. All three produce real files, so tree-walking tools (`find -type f`,
-- git) behave exactly as in a full copy.
local function _clone_tree_command(src, ws)
  local py = table.concat({
    "import ctypes,os,sys",
    "r=1",
    "try:",
    " r=ctypes.CDLL(\"/usr/lib/libc.dylib\",use_errno=True).clonefile(os.fsencode(sys.argv[1]),os.fsencode(sys.argv[2]),0)",
    "except Exception:",
    " pass",
    "sys.exit(0 if r==0 else 1)",
  }, "\n")
  return "python3 -c '" .. py .. "' " .. src .. " " .. ws .. " 2>/dev/null"
    .. " || cp -R -c " .. src .. "/. " .. ws .. "/ 2>/dev/null"
    .. " || cp -R " .. src .. "/. " .. ws .. "/"
end

-- Fast path: clone the tree in one shot. This is only safe when the workspace
-- lives outside the source tree; the safe path below handles workspaces nested
-- inside it (used by tests).
local function _build_fast_overlay_command(source_dir, target_relative, workspace, shared_git_dir)
  local src = _shell_quote(source_dir)
  local ws = _shell_quote(workspace)
  local script_parts = {}

  -- clonefile() requires the destination to not exist; the cp fallbacks
  -- create it themselves, so no mkdir here.
  script_parts[#script_parts + 1] = "rm -rf " .. ws
  script_parts[#script_parts + 1] = _clone_tree_command(src, ws)

  _append_git_setup(script_parts, source_dir, workspace, shared_git_dir)
  _append_root_names(script_parts, source_dir, workspace)
  _append_target_copy(script_parts, source_dir, workspace, target_relative)
  return _write_script_and_return_command(script_parts)
end

-- Safe path: build the directory tree explicitly so the workspace can live
-- inside the source tree (used by tests). Directories are real; files and
-- symlinks are linked back to the source.
local function _build_safe_overlay_command(source_dir, target_relative, workspace, shared_git_dir, pre_collected)
  local abs_src = util.absolute_path(source_dir)
  local abs_ws = util.absolute_path(workspace)
  local src = _shell_quote(abs_src)
  local ws = _shell_quote(abs_ws)
  local workspace_rel = util.relative_path(abs_src, abs_ws)

  local dirs, files, symlinks
  if pre_collected then
    dirs, files, symlinks = pre_collected.dirs, pre_collected.files, pre_collected.symlinks
  else
    dirs, files, symlinks = _collect_entries(abs_src, workspace_rel)
  end

  local script_parts = {}
  script_parts[#script_parts + 1] = "rm -rf " .. ws .. " && mkdir -p " .. ws

  if #dirs > 0 then
    local mkdir_parts = {}
    for _, rel in ipairs(dirs) do
      mkdir_parts[#mkdir_parts + 1] = _shell_quote(abs_ws .. "/" .. rel)
    end
    script_parts[#script_parts + 1] = "mkdir -p " .. table.concat(mkdir_parts, " ")
  end

  local function group_by_dir(entries)
    local groups = {}
    for _, rel in ipairs(entries) do
      local dir = rel:match("^(.*)/[^/]+$") or "."
      groups[dir] = groups[dir] or {}
      table.insert(groups[dir], rel)
    end
    return groups
  end

  local function emit_link_batches(groups)
    for dir, entries in pairs(groups) do
      local batch = {}
      for _, rel in ipairs(entries) do
        batch[#batch + 1] = _shell_quote(abs_src .. "/" .. rel)
      end
      script_parts[#script_parts + 1] = "ln -s " .. table.concat(batch, " ")
        .. " " .. _shell_quote(abs_ws .. "/" .. dir) .. "/"
    end
  end

  emit_link_batches(group_by_dir(files))
  emit_link_batches(group_by_dir(symlinks))

  _append_git_setup(script_parts, abs_src, abs_ws, shared_git_dir)
  _append_root_names(script_parts, abs_src, abs_ws)
  _append_target_copy(script_parts, abs_src, abs_ws, target_relative)

  return _write_script_and_return_command(script_parts)
end

-- Build one POSIX shell command that creates the whole overlay.
--
-- `pre_collected` is optional and, when provided, must contain the three entry
-- lists returned by `_collect_entries`. It is used by `populate_many` so the
-- source tree is walked only once for all workspaces.
local function _build_overlay_command(source_dir, target_relative, workspace, shared_git_dir, pre_collected)
  if not target_relative or tostring(target_relative) == "" then
    return nil, "cannot build overlay for empty target path"
  end

  local abs_src = util.absolute_path(source_dir)
  local abs_ws = util.absolute_path(workspace)

  if _workspace_inside_source(abs_src, abs_ws) then
    return _build_safe_overlay_command(abs_src, target_relative, abs_ws, shared_git_dir, pre_collected)
  end
  return _build_fast_overlay_command(abs_src, target_relative, abs_ws, shared_git_dir)
end

-- Create a shared, real copy of the source .git directory that multiple
-- workspaces can reference via gitdir files. Returns the shared directory path,
-- or nil if the source has no .git directory.
function overlay.prepare_shared_git(source_dir)
  source_dir = util.absolute_path(source_dir)
  local git_source = util.join_path(source_dir, ".git")
  if not util.path_exists(git_source) then
    return nil
  end
  local shared = util.tmp_path("_git")
  util.remove(shared)
  if not util.command_succeeds(_copy_git(git_source, shared)) then
    return nil, "failed to copy .git directory"
  end
  return shared
end

-- Populate an existing, empty workspace directory.
--
--   source_dir      absolute or relative path to the project root
--   target_relative mutation target path relative to source_dir
--   workspace       absolute or relative path to the workspace root
--   shared_git_dir  optional shared .git directory (created by prepare_shared_git)
--
-- Returns true, or nil + error message. On error the caller is responsible for
-- removing the workspace (and any partial overlay) without a trailing slash.
function overlay.populate(source_dir, target_relative, workspace, shared_git_dir)
  source_dir = util.absolute_path(source_dir)
  workspace = util.absolute_path(workspace)

  local command, err = _build_overlay_command(source_dir, target_relative, workspace, shared_git_dir)
  if not command then
    return nil, err
  end

  if not util.command_succeeds(command) then
    return nil, "failed to build workspace overlay"
  end
  return true
end

-- Create a fresh workspace directory and populate it as an overlay.
-- Returns the workspace path, or nil + error message.
function overlay.create(source_dir, target_relative)
  local workspace = util.tmp_path("_ws")
  util.remove(workspace)
  util.mkdir_p(workspace)
  local shared_git, git_err = overlay.prepare_shared_git(source_dir)
  local ok, err = overlay.populate(source_dir, target_relative, workspace, shared_git)
  if shared_git then
    util.remove(shared_git)
  end
  if not ok then
    util.remove(workspace)
    return nil, err
  end
  return workspace
end

-- Populate multiple workspaces concurrently. The caller owns the workspace paths
-- and must clean them up on failure. On success, also returns the shared .git
-- directory path so the caller can remove it after all workspaces are done.
function overlay.populate_many(source_dir, target_relative, workspaces)
  if #workspaces == 0 then return true end
  source_dir = util.absolute_path(source_dir)

  local shared_git, git_err = overlay.prepare_shared_git(source_dir)
  if git_err then
    return nil, git_err
  end

  local parts = {}
  for _, workspace in ipairs(workspaces) do
    local command, err = _build_overlay_command(source_dir, target_relative, workspace, shared_git)
    if not command then
      if shared_git then util.remove(shared_git) end
      return nil, err
    end
    parts[#parts + 1] = "(" .. command .. ") &"
  end

  -- Wait for every background job and fail if any failed. `wait` alone only
  -- reports the last job, so we collect PIDs and wait on each one.
  parts[#parts + 1] = "__pids__=\"\"; for __job__ in $(jobs -p); do __pids__=\"$__pids__ $__job__\"; done"
  parts[#parts + 1] = "__fail__=0; for __pid__ in $__pids__; do wait $__pid__ || __fail__=1; done; exit $__fail__"

  if not util.command_succeeds(table.concat(parts, "\n")) then
    if shared_git then util.remove(shared_git) end
    for _, workspace in ipairs(workspaces) do
      util.remove(workspace)
    end
    return nil, "failed to build one or more workspace overlays"
  end
  return true, shared_git
end

return overlay
