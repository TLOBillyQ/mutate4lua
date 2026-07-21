local scanner = require("mutate4lua.internal.scanner")
local manifest = require("mutate4lua.internal.manifest")
local manifest_store = require("mutate4lua.manifest_store")
local project = require("mutate4lua.driver.project")
local parallel = require("mutate4lua.internal.parallel")
local util = require("mutate4lua.util")

local engine = {}

local TIMEOUT_EXIT_CODE = 124

-- A scope-level manifest is recorded once the kill score reaches this
-- threshold (percent), instead of requiring every mutant to die. Files that
-- contain irreducible-equivalent mutants can never reach 100%, so a hard
-- "zero survivors" gate would strand them bootstrap-only forever. Residual
-- survivors below the threshold are recorded honestly per scope
-- (last_mutation_status = "survived") rather than masked as "passed".
local MANIFEST_MIN_KILL_SCORE = 90

local function _parse_exit_code(ok, kind, code)
  if type(ok) == "number" then
    if ok > 255 then return math.floor(ok / 256) end
    return ok
  end
  if ok == true then
    if kind == "exit" and type(code) == "number" then return code end
    return 0
  end
  if ok == nil and kind == "exit" and type(code) == "number" then
    return code
  end
  return 1
end

local _timeout_cmd_cache = nil
local function _find_timeout_command()
  if _timeout_cmd_cache ~= nil then return _timeout_cmd_cache end
  if util.command_succeeds("command -v timeout >/dev/null 2>&1") then
    _timeout_cmd_cache = "timeout"
  elseif util.command_succeeds("command -v gtimeout >/dev/null 2>&1") then
    _timeout_cmd_cache = "gtimeout"
  else
    _timeout_cmd_cache = false
  end
  return _timeout_cmd_cache
end

local function _shell_join(parts)
  local quoted = {}
  for _, part in ipairs(parts) do
    quoted[#quoted + 1] = util.shell_quote(part)
  end
  return table.concat(quoted, " ")
end

local function _default_run_shell(shell_command, cwd, timeout_seconds)
  local output_path = util.tmp_path(".log")
  local redirect = " > " .. util.shell_quote(output_path) .. " 2>&1"
  local full = "cd " .. util.shell_quote(cwd or ".") .. " && "
  if timeout_seconds and timeout_seconds > 0 then
    local tc = _find_timeout_command()
    if tc then
      full = full .. tc .. " " .. tostring(math.ceil(timeout_seconds)) .. " " .. shell_command .. redirect
    else
      -- No timeout(1) on this host: fall back to a pure-shell watchdog so a
      -- runaway (e.g. infinite-loop) mutant cannot hang the run forever. The
      -- watchdog touches a flag file before killing the command; the flag maps
      -- the kill to the conventional 124 exit code, keeping timeout detection
      -- identical to the timeout(1) path.
      local flag = util.shell_quote(util.tmp_path(".timeout"))
      local seconds = tostring(math.ceil(timeout_seconds))
      full = full .. "{ "
        .. "( " .. shell_command .. redirect .. " ) & pid=$!; "
        .. "( sleep " .. seconds .. "; touch " .. flag .. "; kill -9 $pid 2>/dev/null ) & wp=$!; "
        .. "wait $pid; ec=$?; "
        .. "kill $wp 2>/dev/null; wait $wp 2>/dev/null; "
        .. "if [ -f " .. flag .. " ]; then ec=" .. tostring(TIMEOUT_EXIT_CODE) .. "; fi; "
        .. "rm -f " .. flag .. "; "
        .. "exit $ec; } 2>/dev/null"
    end
  else
    full = full .. shell_command .. redirect
  end

  local start_time = os.time()
  local ok, kind, code = os.execute(full)
  local elapsed = os.difftime(os.time(), start_time)

  local content = util.read_file(output_path) or ""
  util.remove(output_path)

  local exit_code = _parse_exit_code(ok, kind, code)
  return {
    ok = exit_code == 0,
    code = exit_code,
    output = content,
    elapsed = elapsed,
    timed_out = exit_code == TIMEOUT_EXIT_CODE,
  }
end

local function _create_workspace(source_dir)
  local workspace = util.tmp_path("_ws")
  util.remove(workspace)
  util.mkdir_p(workspace)
  local ok, kind, code = os.execute("cp -r " .. util.shell_quote(source_dir .. "/.") .. " " .. util.shell_quote(workspace .. "/"))
  local exit_code = _parse_exit_code(ok, kind, code)
  if exit_code ~= 0 then
    util.remove(workspace)
    return nil, "failed to copy workspace (exit " .. tostring(exit_code) .. ")"
  end
  return workspace
end

local function _create_workspaces(source_dir, count)
  local workspaces = {}
  for _ = 1, count do
    local workspace, err = _create_workspace(source_dir)
    if not workspace then
      for _, created in ipairs(workspaces) do
        util.remove(created)
      end
      return nil, err
    end
    workspaces[#workspaces + 1] = workspace
  end
  return workspaces
end

local function _classify_status(run_result)
  if run_result.timed_out then
    return "timeout"
  end
  if not run_result.ok then
    return "killed"
  end
  return "survived"
end

local function _result_entry(site, run_result)
  return {
    line = site.line,
    description = site.description,
    original = site.original_text,
    replacement = site.replacement_text,
    status = _classify_status(run_result),
    elapsed = run_result.elapsed,
    scope_id = site.scope_id,
  }
end

local function _resolve_worker_count(options, site_count)
  local requested = tonumber(options.max_workers)
  if requested == nil then
    requested = util.default_max_workers()
  end
  requested = math.max(1, math.floor(requested))
  return math.min(requested, site_count)
end

local function _cleanup(...)
  for _, path in ipairs({...}) do
    if path and path ~= "" then
      util.remove(path)
    end
  end
end

local function _parse_coverage_lines(coverage_path, target_relative)
  local content = util.read_file(coverage_path)
  if not content then return {} end
  local covered = {}
  local normalized_target = util.normalize_relative_path(target_relative)
  for line in content:gmatch("[^\n]+") do
    local last_colon = line:find(":[^:]*$")
    if last_colon then
      local file = line:sub(1, last_colon - 1)
      local line_text = line:sub(last_colon + 1)
      if util.normalize_relative_path(file) == normalized_target then
        local line_num = tonumber(line_text)
        if line_num then covered[line_num] = true end
      end
    end
  end
  return covered
end

local function _filter_by_coverage(sites, covered_lines)
  local filtered = {}
  for _, site in ipairs(sites) do
    if covered_lines[site.line] then
      filtered[#filtered + 1] = site
    end
  end
  return filtered
end

local function _filter_by_lines(sites, line_set)
  if not line_set or not next(line_set) then return sites end
  local filtered = {}
  for _, site in ipairs(sites) do
    if line_set[site.line] then
      filtered[#filtered + 1] = site
    end
  end
  return filtered
end

local function _scope_manifest_map(old_manifest)
  local old_scopes = {}
  for _, scope in ipairs(old_manifest.scopes or {}) do
    old_scopes[scope.id] = scope
  end
  return old_scopes
end

local function _changed_scope_lookup(scopes, old_manifest, lane)
  if not old_manifest then
    local changed_scopes = {}
    for _, scope in ipairs(scopes or {}) do
      changed_scopes[scope.id] = true
    end
    return changed_scopes
  end

  local old_scopes = _scope_manifest_map(old_manifest)
  local changed_scopes = {}
  for _, scope in ipairs(scopes) do
    local old_scope = old_scopes[scope.id]
    if old_scope == nil or old_scope.semantic_hash ~= scope.semantic_hash then
      changed_scopes[scope.id] = true
    elseif lane ~= nil and old_scope.last_mutation_lane ~= nil and old_scope.last_mutation_lane ~= lane then
      -- Recorded under a different lane: re-test instead of skipping on
      -- evidence that may not hold for the current lane's suites.
      changed_scopes[scope.id] = true
    end
  end
  return changed_scopes
end

local function _filter_by_changed_scopes(sites, changed_scopes)
  if not changed_scopes then return sites end
  local filtered = {}
  for _, site in ipairs(sites) do
    if changed_scopes[site.scope_id] then
      filtered[#filtered + 1] = site
    end
  end
  return filtered
end

local function _site_counts_by_scope(sites)
  local counts = {}
  for _, site in ipairs(sites or {}) do
    local scope_id = site.scope_id
    counts[scope_id] = (counts[scope_id] or 0) + 1
  end
  return counts
end

local function _copy_scope(scope)
  return {
    id = scope.id,
    kind = scope.kind,
    start_line = scope.start_line,
    end_line = scope.end_line,
    semantic_hash = scope.semantic_hash,
  }
end

local function _copy_last_mutation_fields(target, source)
  if source == nil then
    return
  end
  target.last_mutated_at = source.last_mutated_at
  target.last_mutation_lane = source.last_mutation_lane
  target.last_mutation_status = source.last_mutation_status
  target.last_mutation_sites = source.last_mutation_sites
  target.last_mutation_killed = source.last_mutation_killed
end

local function _build_manifest_scopes(scopes, old_manifest, updates)
  local old_scopes = old_manifest and _scope_manifest_map(old_manifest) or {}
  local next_scopes = {}
  for _, scope in ipairs(scopes or {}) do
    local next_scope = _copy_scope(scope)
    local old_scope = old_scopes[scope.id]
    if old_scope ~= nil and old_scope.semantic_hash == scope.semantic_hash then
      _copy_last_mutation_fields(next_scope, old_scope)
    end
    local update = updates and updates[scope.id] or nil
    if update ~= nil then
      _copy_last_mutation_fields(next_scope, update)
    end
    next_scopes[#next_scopes + 1] = next_scope
  end
  return next_scopes
end

local function _utc_timestamp()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function _no_site_updates(scopes, changed_scopes, initial_site_counts, timestamp, lane)
  local updates = {}
  for _, scope in ipairs(scopes or {}) do
    if changed_scopes[scope.id] == true and (initial_site_counts[scope.id] or 0) == 0 then
      updates[scope.id] = {
        last_mutated_at = timestamp,
        last_mutation_lane = lane,
        last_mutation_status = "no_sites",
        last_mutation_sites = 0,
        last_mutation_killed = 0,
      }
    end
  end
  return updates
end

local function _result_scope_updates(results, timestamp, lane)
  local updates = {}
  for _, result in ipairs(results or {}) do
    local scope_id = result.scope_id
    local update = updates[scope_id]
    if update == nil then
      update = {
        last_mutated_at = timestamp,
        last_mutation_lane = lane,
        last_mutation_status = "passed",
        last_mutation_sites = 0,
        last_mutation_killed = 0,
      }
      updates[scope_id] = update
    end
    update.last_mutation_sites = update.last_mutation_sites + 1
    if result.status == "killed" then
      update.last_mutation_killed = update.last_mutation_killed + 1
    else
      -- A surviving (or timed-out) mutant in this scope: record it honestly so
      -- the manifest does not claim a clean "passed" for a scope with residue.
      update.last_mutation_status = "survived"
    end
  end
  return updates
end

local function _merge_updates(base, extra)
  for key, value in pairs(extra or {}) do
    base[key] = value
  end
  return base
end

local function _updates_cover_changed_scopes(scopes, changed_scopes, updates)
  for _, scope in ipairs(scopes or {}) do
    if changed_scopes[scope.id] == true and (updates == nil or updates[scope.id] == nil) then
      return false
    end
  end
  return true
end

-- Mirrors util's (module-local) is_absolute_path/is_windows_path, which are
-- not exported: leading "/", UNC "\\", or a Windows drive prefix.
local function _is_absolute_path(path)
  path = tostring(path or "")
  return path:sub(1, 1) == "/" or path:sub(1, 2) == "\\\\" or path:match("^%a:[/\\]") ~= nil
end

-- Manifests live outside the target sources: one "<relative>.manifest" file
-- per target under the store root. Default is "<project_root>/.mutate4lua/manifest/"
-- (next to the existing ".mutate4lua/cache" convention); hosts may override it
-- with env.manifest_dir (relative paths resolve against the workspace root).
local function _resolve_store_root(workspace_root, project_root, env)
  local override = env and env.manifest_dir or nil
  if override ~= nil and override ~= "" then
    if _is_absolute_path(override) then
      return util.absolute_path(override)
    end
    return util.absolute_path(util.join_path(workspace_root, override))
  end
  return util.join_path(project_root, ".mutate4lua", "manifest")
end

-- Store-first read with a legacy fallback: projects not yet migrated keep
-- their footer manifest working until --migrate-manifest moves it out.
local function _read_manifest(store_root, relative, abs_target)
  return manifest_store.read(store_root, relative) or manifest.read(abs_target)
end

local function _write_manifest_update(scan_ctx, updates)
  if updates == nil or next(updates) == nil then
    return false
  end
  if not _updates_cover_changed_scopes(scan_ctx.scopes, scan_ctx.changed_scopes, updates) then
    return false
  end
  local proj_hash = project.project_hash(scan_ctx.project_root, scan_ctx.abs_target, scan_ctx.stripped)
  manifest_store.write(scan_ctx.store_root, scan_ctx.relative, {
    version = 2,
    project_hash = proj_hash,
    scopes = _build_manifest_scopes(scan_ctx.scopes, scan_ctx.old_manifest, updates),
  })
  return true
end

local function _build_driver_command(driver_path, lane, suite_list_file, coverage_file, fail_fast)
  local parts = {"lua", driver_path, "--lane", lane}
  if suite_list_file then
    parts[#parts + 1] = "--suite-list-file"
    parts[#parts + 1] = suite_list_file
  end
  if coverage_file then
    parts[#parts + 1] = "--coverage-file"
    parts[#parts + 1] = coverage_file
  else
    parts[#parts + 1] = "--no-coverage"
  end
  -- Killed mutants only need one failing case; baseline (coverage-collecting)
  -- must run every case, so fail-fast is requested for mutant runs only.
  if fail_fast then
    parts[#parts + 1] = "--fail-fast"
  end
  parts[#parts + 1] = "--quiet"
  return _shell_join(parts)
end

-- Driver-based runs need both a driver script and a lane; without them the
-- command line would silently degrade to "--lane 'nil'" / ".../nil" garbage.
-- The library ships no default driver path: the host provides one via
-- env.default_driver / env.busted_driver, or bypasses drivers entirely with
-- --test-command.
local function _check_driver_options(stderr, options)
  if not options.driver_script then
    stderr:write("error: driver script required: pass --test-command or provide a driver script via env.default_driver / env.busted_driver (see README)\n")
    return false
  end
  if not options.lane then
    stderr:write("error: lane required\n")
    return false
  end
  return true
end

-- Shared "nothing to mutate" exit: records no-site manifest updates (unless a
-- line filter suppresses them) and emits the empty result in text or JSON.
-- Callers differ only in the headline message, the reported baseline seconds,
-- and any cleanup they do afterwards.
local function _emit_empty_result(stdout, options, scan_ctx, message, baseline_seconds)
  local manifest_updated = false
  if not options.line_set then
    manifest_updated = _write_manifest_update(
      scan_ctx,
      _no_site_updates(scan_ctx.scopes, scan_ctx.changed_scopes, scan_ctx.initial_site_counts, _utc_timestamp(), options.lane)
    )
  end
  if options.json then
    stdout:write(util.encode_json({
      file = scan_ctx.relative,
      total_sites = 0,
      killed = 0,
      survived = 0,
      timeout = 0,
      score = 100,
      baseline_seconds = baseline_seconds,
      manifest_updated = manifest_updated,
      mutations = {},
    }), "\n")
  else
    stdout:write(message, "\n")
    if manifest_updated then
      stdout:write("manifest updated: ", scan_ctx.relative, "\n")
    end
  end
  return 0
end

local function _suite_map_cache_path(workspace_root, lane, hash)
  return util.join_path(workspace_root, ".mutate4lua", "cache",
    "suite_file_map." .. lane .. "." .. hash .. ".json")
end

-- Drop cached maps for the same lane under older fingerprints before writing
-- a new one, so the cache directory does not slowly accumulate one file per
-- spec/driver edit.
local function _purge_stale_suite_maps(workspace_root, lane, keep_path)
  local cache_dir = util.join_path(workspace_root, ".mutate4lua", "cache")
  if not util.is_directory(cache_dir) then return end
  local prefix = "suite_file_map." .. lane .. "."
  for _, path in ipairs(util.list_files(cache_dir, {"suite_file_map.*.json"})) do
    if util.starts_with(util.basename(path), prefix) and path ~= keep_path then
      util.remove(path)
    end
  end
end

-- NOTE: the fingerprint covers spec/*.lua and the driver script only, not the
-- lib/ sources; a lib-only change keeps the cached map until a spec or the
-- driver changes. Suite -> file mapping rarely depends on lib contents, so
-- this is accepted rather than hashing the whole tree.
local function _spec_and_driver_fingerprint(workspace_root, driver_script)
  local parts = {}
  local driver_path = util.join_path(workspace_root, driver_script)
  local driver_content = util.read_file(driver_path)
  if driver_content then
    parts[#parts + 1] = "driver:"
    parts[#parts + 1] = driver_script
    parts[#parts + 1] = "\n"
    parts[#parts + 1] = util.normalize_newlines(driver_content)
    parts[#parts + 1] = "\n\0\n"
  end
  local spec_dir = util.join_path(workspace_root, "spec")
  if util.is_directory(spec_dir) then
    local files = util.list_files(spec_dir, {"*.lua"})
    for _, abs_path in ipairs(files) do
      local content = util.read_file(abs_path)
      if content then
        parts[#parts + 1] = project.relative_file(workspace_root, abs_path)
        parts[#parts + 1] = "\n"
        parts[#parts + 1] = util.normalize_newlines(content)
        parts[#parts + 1] = "\n\0\n"
      end
    end
  end
  return util.fnv1a64(table.concat(parts))
end

local function _load_cached_suite_map(cache_path)
  local content = util.read_file(cache_path)
  if not content then return nil end
  local map = util.decode_json(util.trim(content))
  if type(map) ~= "table" or type(map.suite_files) ~= "table" then return nil end
  return map
end

local function _store_cached_suite_map(cache_path, raw_json)
  util.mkdir_p(util.parent_dir(cache_path))
  util.write_file(cache_path, raw_json)
end

local function _fetch_suite_file_map(run_shell, workspace_root, driver_script, lane)
  local hash = _spec_and_driver_fingerprint(workspace_root, driver_script)
  local cache_path = _suite_map_cache_path(workspace_root, lane, hash)

  local cached = _load_cached_suite_map(cache_path)
  if cached then return cached, nil end

  local driver_path = util.join_path(workspace_root, driver_script)
  local cmd = _shell_join({"lua", driver_path, "--lane", lane, "--emit-suite-file-map-json"})
  local result = run_shell(cmd, workspace_root, nil)
  if not result.ok then
    return nil, "suite-file map discovery failed (exit " .. tostring(result.code) .. "): " .. tostring(result.output or "")
  end

  local raw = util.trim(result.output or "")
  local map = util.decode_json(raw)
  if type(map) ~= "table" or type(map.suite_files) ~= "table" then
    return nil, "suite-file map malformed (missing suite_files table)"
  end

  _purge_stale_suite_maps(workspace_root, lane, cache_path)
  _store_cached_suite_map(cache_path, raw)
  return map, nil
end

local function _discover_relevant_suites(run_shell, workspace_root, driver_script, lane, target_relative)
  local map, err = _fetch_suite_file_map(run_shell, workspace_root, driver_script, lane)
  if not map then return nil, err end

  local normalized_target = util.normalize_relative_path(target_relative)
  local relevant = {}
  for suite_name, files in pairs(map.suite_files) do
    for _, file in ipairs(files) do
      if util.normalize_relative_path(file) == normalized_target then
        relevant[#relevant + 1] = suite_name
        break
      end
    end
  end
  if #relevant == 0 then
    return nil, "no specs in lane '" .. lane .. "' cover " .. target_relative
  end

  table.sort(relevant)
  local suite_file = util.tmp_path("_suites.txt")
  util.write_file(suite_file, table.concat(relevant, "\n") .. "\n")
  return suite_file, nil
end

local function _scan_target(workspace_root, target)
  local abs_target
  if _is_absolute_path(target) then
    -- join_path strips leading slashes, which would corrupt an absolute target
    abs_target = util.absolute_path(target)
  else
    abs_target = util.absolute_path(util.join_path(workspace_root, target))
  end
  local source = util.read_file(abs_target)
  if not source then return nil, nil, nil, "cannot read " .. target end
  local relative = project.relative_file(workspace_root, abs_target)
  local stripped = manifest.strip(source)
  local data = scanner.analyze(abs_target, relative, stripped)
  return data, stripped, abs_target, nil
end

-- A target resolving outside the workspace root would make every mutant write
-- outside the workspace (and silently "survive"); reject it at the entrypoints.
local function _target_outside_workspace(relative_file)
  return _is_absolute_path(relative_file)
    or relative_file == ".."
    or util.starts_with(relative_file, "../")
end

function engine.scan(options, env)
  local stdout = env.stdout or io.stdout
  local stderr = env.stderr or io.stderr
  local workspace_root = env.cwd or "."

  if not options.target then
    stderr:write("error: target file required\n")
    return 1
  end

  local data, _, _, err = _scan_target(workspace_root, options.target)
  if not data then
    stderr:write("error: ", err, "\n")
    return 1
  end
  if _target_outside_workspace(data.relative_file) then
    stderr:write("error: target file escapes workspace root: ", options.target, "\n")
    return 1
  end

  if options.line_set then
    data.sites = _filter_by_lines(data.sites, options.line_set)
  end

  if options.json then
    local sites_out = {}
    for _, site in ipairs(data.sites) do
      sites_out[#sites_out + 1] = {
        line = site.line,
        start_pos = site.start_pos,
        end_pos = site.end_pos,
        original = site.original_text,
        replacement = site.replacement_text,
        description = site.description,
        scope_id = site.scope_id,
      }
    end
    local scopes_out = {}
    for _, scope in ipairs(data.scopes) do
      scopes_out[#scopes_out + 1] = {
        id = scope.id,
        kind = scope.kind,
        start_line = scope.start_line,
        end_line = scope.end_line,
        semantic_hash = scope.semantic_hash,
      }
    end
    stdout:write(util.encode_json({
      file = data.file,
      relative_file = data.relative_file,
      file_hash = data.file_hash,
      scopes = scopes_out,
      sites = sites_out,
    }), "\n")
  else
    stdout:write("file: ", data.relative_file, "\n")
    stdout:write("hash: ", data.file_hash, "\n")
    stdout:write("scopes: ", tostring(#data.scopes), "\n")
    for _, scope in ipairs(data.scopes) do
      stdout:write("  ", scope.id, " [", tostring(scope.start_line), "-", tostring(scope.end_line), "] ", scope.semantic_hash, "\n")
    end
    stdout:write("sites: ", tostring(#data.sites), "\n")
    for _, site in ipairs(data.sites) do
      stdout:write("  L", tostring(site.line), " ", site.description, " (scope: ", site.scope_id, ")\n")
    end
  end
  return 0
end

function engine.mutate(options, env)
  local stdout = env.stdout or io.stdout
  local stderr = env.stderr or io.stderr
  local workspace_root = env.cwd or "."
  local run_shell = env.run_shell or _default_run_shell
  local create_workspaces = env.create_workspaces or _create_workspaces
  local run_parallel = env.run_parallel or parallel.run
  local timeout_factor = options.timeout_factor or 15

  -- "--lines ''" parses to an empty (but truthy) table; treat it as no filter,
  -- otherwise every site would run while manifest updates stayed suppressed.
  if options.line_set and not next(options.line_set) then
    options.line_set = nil
  end

  if not options.target then
    stderr:write("error: target file required\n")
    return 1
  end

  local data, stripped, abs_target, scan_err = _scan_target(workspace_root, options.target)
  if not data then
    stderr:write("error: ", scan_err, "\n")
    return 1
  end
  if _target_outside_workspace(data.relative_file) then
    stderr:write("error: target file escapes workspace root: ", options.target, "\n")
    return 1
  end

  local relative = data.relative_file
  local sites = data.sites
  local scopes = data.scopes
  local project_root = project.find_root(workspace_root, abs_target)
  local store_root = _resolve_store_root(workspace_root, project_root, env)
  local old_manifest = _read_manifest(store_root, relative, abs_target)
  local changed_scopes = _changed_scope_lookup(scopes, old_manifest, options.lane)
  local initial_site_counts = _site_counts_by_scope(data.sites)
  local scan_ctx = {
    workspace_root = workspace_root,
    abs_target = abs_target,
    stripped = stripped,
    relative = relative,
    project_root = project_root,
    store_root = store_root,
    scopes = scopes,
    old_manifest = old_manifest,
    changed_scopes = changed_scopes,
    initial_site_counts = initial_site_counts,
  }

  if not options.mutate_all then
    if old_manifest then
      sites = _filter_by_changed_scopes(sites, changed_scopes)
    end
  end

  if options.line_set then
    sites = _filter_by_lines(sites, options.line_set)
  end

  if #sites == 0 then
    return _emit_empty_result(stdout, options, scan_ctx, "no mutation sites to test", 0)
  end

  local suite_list_file = nil
  if not options.test_command then
    if not _check_driver_options(stderr, options) then
      return 1
    end
    local discover_err
    suite_list_file, discover_err = _discover_relevant_suites(
      run_shell, workspace_root, options.driver_script, options.lane, relative)
    if not suite_list_file then
      stderr:write("error: ", discover_err or "suite discovery failed", "\n")
      return 1
    end
  end

  local workspace, workspace_err = _create_workspace(workspace_root)
  if not workspace then
    stderr:write("error: ", workspace_err, "\n")
    _cleanup(suite_list_file)
    return 1
  end
  local coverage_file = nil

  local baseline_cmd
  if options.test_command then
    baseline_cmd = options.test_command
  else
    if not options.mutate_all then
      coverage_file = util.tmp_path("_cov.txt")
    end
    local driver_in_ws = util.join_path(workspace, options.driver_script)
    baseline_cmd = _build_driver_command(driver_in_ws, options.lane, suite_list_file, coverage_file)
  end

  if not options.json then
    stdout:write("mutate4lua: ", relative, "\n")
    stdout:write("scanning: ", tostring(#sites), " sites\n")
    stdout:write("baseline: running...\n")
  end

  local baseline = run_shell(baseline_cmd, workspace, nil)
  if not baseline.ok then
    stderr:write("baseline test failed (exit ", tostring(baseline.code), ")\n")
    if baseline.output ~= "" then stderr:write(baseline.output, "\n") end
    _cleanup(workspace, suite_list_file, coverage_file)
    return 1
  end

  if coverage_file then
    local covered = _parse_coverage_lines(coverage_file, relative)
    if not options.mutate_all then
      sites = _filter_by_coverage(sites, covered)
    end
    util.remove(coverage_file)
    coverage_file = nil
  end

  if #sites == 0 then
    local code = _emit_empty_result(stdout, options, scan_ctx, "no covered mutation sites", baseline.elapsed)
    _cleanup(workspace, suite_list_file)
    return code
  end

  if options.mutation_warning and #sites > options.mutation_warning then
    stderr:write("warning: ", tostring(#sites), " mutations exceed threshold ", tostring(options.mutation_warning), "\n")
  end

  local timeout = math.max(5, (baseline.elapsed + 1) * timeout_factor)

  local function _mutant_command(ws)
    if options.test_command then
      return options.test_command
    end
    return _build_driver_command(util.join_path(ws, options.driver_script), options.lane, suite_list_file, nil, true)
  end

  if not options.json then
    stdout:write("baseline: ", tostring(baseline.elapsed), "s (timeout: ", tostring(math.ceil(timeout)), "s)\n")
  end

  local worker_count = _resolve_worker_count(options, #sites)
  local results = {}

  if worker_count > 1 then
    if not options.json then
      stdout:write("workers: ", tostring(worker_count), " (parallel)\n")
    end
    local extra_workspaces, workspaces_err = create_workspaces(workspace_root, worker_count - 1)
    if not extra_workspaces then
      stderr:write("error: ", workspaces_err or "failed to create workspaces", "\n")
      _cleanup(workspace, suite_list_file)
      return 1
    end
    local workspaces = { workspace }
    for _, ws in ipairs(extra_workspaces) do
      workspaces[#workspaces + 1] = ws
    end

    local completed = 0
    -- A throw from run_parallel (or a short result table, treated as an error
    -- below) must still clean up the extra workspaces before propagating.
    local ok_run, run_results = pcall(function()
      local collected = run_parallel({
        worker_count = worker_count,
        job_count = #sites,
        workspaces = workspaces,
        timeout = timeout,
        timeout_command = _find_timeout_command(),
        poll_interval = options.poll_interval,
        prepare = function(i, ws)
          util.write_file(util.join_path(ws, relative), scanner.apply_mutation(stripped, sites[i]))
        end,
        command = function(_, ws)
          return _mutant_command(ws)
        end,
        on_complete = function(i, run_result)
          if not options.json then
            completed = completed + 1
            local site = sites[i]
            stdout:write(string.format("[%d/%d] L%d: %s ... %s (%ds)\n",
              completed, #sites, site.line, site.description,
              _classify_status(run_result), run_result.elapsed))
          end
        end,
      })

      for i, site in ipairs(sites) do
        local run_result = collected[i]
        if run_result == nil then
          error("mutate4lua: missing result for mutation site " .. tostring(i))
        end
        results[i] = _result_entry(site, run_result)
      end
    end)

    for _, ws in ipairs(extra_workspaces) do
      util.remove(ws)
    end
    if not ok_run then
      _cleanup(workspace, suite_list_file)
      error(run_results, 0)
    end
  else
    local target_in_ws = util.join_path(workspace, relative)
    local mutant_cmd = _mutant_command(workspace)
    for i, site in ipairs(sites) do
      util.write_file(target_in_ws, scanner.apply_mutation(stripped, site))
      local result = run_shell(mutant_cmd, workspace, timeout)
      results[i] = _result_entry(site, result)
      util.write_file(target_in_ws, stripped)
      if not options.json then
        stdout:write(string.format("[%d/%d] L%d: %s ... %s (%ds)\n",
          i, #sites, site.line, site.description, results[i].status, result.elapsed))
      end
    end
  end

  _cleanup(workspace, suite_list_file)

  local killed, survived, timed_out = 0, 0, 0
  for _, r in ipairs(results) do
    if r.status == "killed" then killed = killed + 1
    elseif r.status == "survived" then survived = survived + 1
    else timed_out = timed_out + 1 end
  end

  local total = #results
  local score = total > 0 and (killed / total * 100) or 100
  local manifest_updated = false
  if score >= MANIFEST_MIN_KILL_SCORE and timed_out == 0 and not options.line_set then
    local timestamp = _utc_timestamp()
    local updates = _result_scope_updates(results, timestamp, options.lane)
    _merge_updates(updates, _no_site_updates(scopes, changed_scopes, initial_site_counts, timestamp, options.lane))
    manifest_updated = _write_manifest_update(scan_ctx, updates)
  end

  if options.json then
    local mutations_out = {}
    for _, r in ipairs(results) do
      mutations_out[#mutations_out + 1] = {
        line = r.line,
        description = r.description,
        original = r.original,
        replacement = r.replacement,
        status = r.status,
        elapsed_seconds = r.elapsed,
        scope_id = r.scope_id,
      }
    end
    stdout:write(util.encode_json({
      file = relative,
      total_sites = total,
      killed = killed,
      survived = survived,
      timeout = timed_out,
      score = score,
      baseline_seconds = baseline.elapsed,
      manifest_updated = manifest_updated,
      mutations = mutations_out,
    }), "\n")
  else
    stdout:write(string.format("score: %.1f%% (%d/%d killed", score, killed, total))
    if timed_out > 0 then stdout:write(", ", tostring(timed_out), " timeout") end
    stdout:write(")\n")
    if manifest_updated then
      stdout:write("manifest updated: ", relative, "\n")
    end
  end

  if survived > 0 then return 3 end
  return 0
end

function engine.update_manifest(options, env)
  local stderr = env.stderr or io.stderr
  local stdout = env.stdout or io.stdout
  local workspace_root = env.cwd or "."

  if not options.target then
    stderr:write("error: target file required\n")
    return 1
  end

  local data, stripped, abs_target, scan_err = _scan_target(workspace_root, options.target)
  if not data then
    stderr:write("error: ", scan_err, "\n")
    return 1
  end
  if _target_outside_workspace(data.relative_file) then
    stderr:write("error: target file escapes workspace root: ", options.target, "\n")
    return 1
  end

  local project_root = project.find_root(workspace_root, abs_target)
  local store_root = _resolve_store_root(workspace_root, project_root, env)
  local proj_hash = project.project_hash(project_root, abs_target, stripped)

  manifest_store.write(store_root, data.relative_file, {
    version = 2,
    project_hash = proj_hash,
    scopes = data.scopes,
  })

  stdout:write("manifest updated: ", data.relative_file, "\n")
  return 0
end

-- One-shot migration for projects that still carry legacy in-source footer
-- manifests: move the footer into the external store (preserving every field)
-- and rewrite the target without the footer. Idempotent — a target without a
-- footer whose store entry already exists is reported as already migrated.
function engine.migrate_manifest(options, env)
  local stderr = env.stderr or io.stderr
  local stdout = env.stdout or io.stdout
  local workspace_root = env.cwd or "."

  if not options.target then
    stderr:write("error: target file required\n")
    return 1
  end

  local data, _, abs_target, scan_err = _scan_target(workspace_root, options.target)
  if not data then
    stderr:write("error: ", scan_err, "\n")
    return 1
  end
  if _target_outside_workspace(data.relative_file) then
    stderr:write("error: target file escapes workspace root: ", options.target, "\n")
    return 1
  end

  local relative = data.relative_file
  local project_root = project.find_root(workspace_root, abs_target)
  local store_root = _resolve_store_root(workspace_root, project_root, env)

  local footer = manifest.read(abs_target)
  if footer then
    manifest_store.write(store_root, relative, footer)
    -- Rewrite the target without the footer (temp + rename, same style as the
    -- legacy footer writer); strip() keeps the head byte-for-byte.
    local stripped = manifest.strip(util.read_file(abs_target))
    local part_path = abs_target .. ".part"
    assert(util.write_file(part_path, stripped))
    assert(os.rename(part_path, abs_target))
    if options.json then
      stdout:write(util.encode_json({
        file = relative,
        migrated = true,
        store_path = manifest_store.store_path(store_root, relative),
      }), "\n")
    else
      stdout:write("manifest migrated: ", relative, "\n")
    end
    return 0
  end

  local stored = manifest_store.read(store_root, relative)
  if options.json then
    stdout:write(util.encode_json({
      file = relative,
      migrated = false,
      already_migrated = stored ~= nil,
    }), "\n")
  elseif stored then
    stdout:write("manifest already migrated: ", relative, "\n")
  else
    stdout:write("no manifest to migrate: ", relative, "\n")
  end
  return 0
end

function engine.index_suites(options, env)
  local stdout = env.stdout or io.stdout
  local stderr = env.stderr or io.stderr
  local workspace_root = env.cwd or "."
  local run_shell = env.run_shell or _default_run_shell

  if not _check_driver_options(stderr, options) then
    return 1
  end

  local driver_path = util.join_path(workspace_root, options.driver_script)
  local cmd = _shell_join({"lua", driver_path, "--lane", options.lane, "--list-suites", "--json"})
  local result = run_shell(cmd, workspace_root, nil)

  local output = util.trim(result.output or "")
  if result.ok then
    if options.json then
      local suites = util.decode_json(output)
      if type(suites) ~= "table" then
        stderr:write("error: suite list output is not valid JSON\n")
        return 1
      end
      stdout:write(util.encode_json({
        ok = true,
        suite_count = #suites,
        suites = suites,
      }), "\n")
    elseif output ~= "" then
      stdout:write(output, "\n")
    end
    return 0
  end
  if output ~= "" then
    stderr:write(output, "\n")
  else
    stderr:write("error: suite listing failed (exit ", tostring(result.code), ")\n")
  end
  return 1
end

return engine
