local scanner = require("mutate4lua.internal.scanner")
local manifest = require("mutate4lua.internal.manifest")
local project = require("mutate4lua.driver.project")
local parallel = require("mutate4lua.internal.parallel")
local util = require("mutate4lua.util")

local engine = {}

local TIMEOUT_EXIT_CODE = 124
-- Manifest format version (bumped when scope-hash semantics change, e.g. the
-- v3→v4 switch from lexer-based to normalized-AST hashing, ADR-0001/0004).
local CURRENT_MANIFEST_VERSION = 4

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

-- Mirrors util's (module-local) is_absolute_path/is_windows_path, which are
-- not exported: leading "/", UNC "\\", or a Windows drive prefix.
local function _is_absolute_path(path)
  path = tostring(path or "")
  return path:sub(1, 1) == "/" or path:sub(1, 2) == "\\\\" or path:match("^%a:[/\\]") ~= nil
end

-- Parse a standard luacov default-reporter report. Coverage is tracked at
-- line granularity: a line is covered iff its right-aligned hit count is a
-- number greater than 0. "*0" marks an uncovered executable line; an empty
-- count column marks a non-executable line.
-- Real-format findings (verified against luacov 0.17.0):
--   - Section separator: 78 "=" chars (matched by "^=+").
--   - Hit-count column: right-aligned, width grows with max count (min 2).
--   - Missed executable lines: *0 (single asterisk) at the count-column position.
--   - Summary section: always the last block, headed by "Summary" as the path
--     name; the parser stops when it encounters it to avoid parsing the
--     coverage table as source lines.
local function _parse_luacov_report(report_path, workspace_root, target_relative)
  local content = util.read_file(report_path)
  if not content then return nil end
  content = util.normalize_newlines(content)

  local covered = {}
  local normalized_target = util.normalize_relative_path(target_relative)
  local lines = util.split_lines(content)
  local index = 1

  while index <= #lines do
    local line = lines[index]
    if line:match("^=+") then
      -- filename line between two separator lines
      index = index + 1
      if index > #lines then break end
      local filename = util.trim(lines[index])
      -- luacov's default reporter always places the Summary section last;
      -- its content is a coverage table, not per-line hit data.  Stop
      -- parsing so coverage-table lines don't leak into a file entry.
      if filename == "Summary" then break end
      index = index + 1
      if index > #lines or not lines[index]:match("^=+") then break end
      index = index + 1

      local match_filename = util.normalize_relative_path(filename)
      if _is_absolute_path(filename) then
        local rel = util.relative_path(workspace_root, filename):gsub("\\", "/")
        if not _is_absolute_path(rel) then
          match_filename = util.normalize_relative_path(rel)
        end
      end
      local is_target = match_filename == normalized_target

      local line_num = 1
      while index <= #lines and not lines[index]:match("^=+") do
        if is_target then
          local token = lines[index]:match("^%s*(%S+)")
          if token then
            local hit = tonumber(token)
            if hit and hit > 0 then
              covered[line_num] = true
            end
          end
        end
        line_num = line_num + 1
        index = index + 1
      end
    else
      index = index + 1
    end
  end

  return covered
end

-- Exposed only for fixture-based tests; not part of the public API.
engine._parse_luacov_report = _parse_luacov_report

local function _coverage_report_path(workspace_root)
  return util.join_path(workspace_root, "luacov.report.out")
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

-- A manifest from an older format (version < CURRENT_MANIFEST_VERSION) is
-- invalid: its scope hashes were computed with different semantics (v3 used
-- the pre-AST lexer-based hash), so trusting it would skip rescanning scopes
-- whose hashes merely happened to differ from the new algorithm.  Treat it as
-- absent, forcing a full rescan (the "old footer → full rescan" guarantee).
local function _valid_manifest(old_manifest)
  if old_manifest == nil then
    return nil
  end
  if old_manifest.version == nil or old_manifest.version < CURRENT_MANIFEST_VERSION then
    return nil
  end
  return old_manifest
end

local function _changed_scope_lookup(scopes, old_manifest)
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

local function _build_driver_command(driver_path, coverage_report_path, fail_fast)
  local parts = {"lua", driver_path}
  if coverage_report_path then
    parts[#parts + 1] = "--coverage-report"
    parts[#parts + 1] = coverage_report_path
  else
    parts[#parts + 1] = "--no-coverage"
  end
  if fail_fast then
    parts[#parts + 1] = "--fail-fast"
  end
  parts[#parts + 1] = "--quiet"
  return _shell_join(parts)
end

-- Driver-based runs need a driver script; without it the command line would
-- silently degrade. The library ships no default driver path: the host
-- provides one via env.default_driver, or bypasses drivers entirely with
-- --test-command.
local function _check_driver_options(stderr, options)
  if not options.driver_script then
    stderr:write("error: driver script required: pass --test-command or provide a driver script via env.default_driver (see README)\n")
    return false
  end
  return true
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

local function _write_manifest(scan_ctx)
  local proj_hash = project.project_hash(scan_ctx.project_root, scan_ctx.abs_target, scan_ctx.stripped)
  manifest.write(scan_ctx.abs_target, scan_ctx.stripped, {
    version = 4,
    project_hash = proj_hash,
    scopes = scan_ctx.scopes,
  })
  return true
end

local function _count_sites_in_changed_scopes(sites, changed_scopes)
  local count = 0
  for _, site in ipairs(sites or {}) do
    if changed_scopes[site.scope_id] then
      count = count + 1
    end
  end
  return count
end

local function _surface_areas(selected_sites, old_manifest)
  if not old_manifest then
    return #selected_sites, 0
  end
  local old_scopes = _scope_manifest_map(old_manifest)
  local differential = 0
  local violating = 0
  for _, site in ipairs(selected_sites) do
    local old_scope = old_scopes[site.scope_id]
    if old_scope == nil then
      differential = differential + 1
    elseif old_scope.semantic_hash ~= nil then
      -- The current semantic hash is attached to the site via the current scope
      -- set, but the site record itself does not carry it. We cannot compute
      -- hash equality here without a current-scope lookup, so this branch is
      -- left to the caller that has both maps. (The engine computes the split
      -- from changed_scopes below.)
    end
  end
  return differential, violating
end

local function _compute_surface_areas(selected_sites, old_manifest, changed_scopes)
  if not old_manifest then
    return #selected_sites, 0
  end
  local old_scopes = _scope_manifest_map(old_manifest)
  local differential = 0
  local violating = 0
  for _, site in ipairs(selected_sites) do
    local old_scope = old_scopes[site.scope_id]
    if old_scope == nil then
      differential = differential + 1
    elseif changed_scopes[site.scope_id] then
      violating = violating + 1
    end
  end
  return differential, violating
end

local function _print_diagnostics(stdout, total, covered, uncovered, changed, manifest_exists, module_hash_changed, differential, violating)
  stdout:write("total mutation sites: ", tostring(total), "\n")
  stdout:write("covered mutation sites: ", tostring(covered), "\n")
  stdout:write("uncovered mutation sites: ", tostring(uncovered), "\n")
  stdout:write("changed mutation sites: ", tostring(changed), "\n")
  stdout:write("manifest exists: ", manifest_exists and "yes" or "no", "\n")
  stdout:write("module hash changed: ", module_hash_changed and "yes" or "no", "\n")
  stdout:write("differential surface area: ", tostring(differential), "\n")
  stdout:write("manifest-violating surface area: ", tostring(violating), "\n")
end

local function _emit_empty_result(stdout, options, scan_ctx, message, baseline_seconds)
  local manifest_updated = false
  if not options.line_set then
    manifest_updated = _write_manifest(scan_ctx)
  end
  stdout:write(message, "\n")
  if manifest_updated then
    stdout:write("manifest updated: ", scan_ctx.relative, "\n")
  end
  return 0
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

  local old_manifest = _valid_manifest(manifest.read(data.file))
  local changed_scopes = _changed_scope_lookup(data.scopes, old_manifest)

  stdout:write("file: ", data.relative_file, "\n")
  stdout:write("sites: ", tostring(#data.sites), "\n")
  for _, site in ipairs(data.sites) do
    local prefix = (old_manifest and changed_scopes[site.scope_id]) and "* " or "  "
    stdout:write(prefix, "L", tostring(site.line), " ", site.description, " (scope: ", site.scope_id, ")\n")
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
  local timeout_factor = options.timeout_factor or 10

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
  local old_manifest = _valid_manifest(manifest.read(abs_target))
  local proj_hash = project.project_hash(project_root, abs_target, stripped)
  local module_hash_changed = old_manifest == nil or old_manifest.project_hash ~= proj_hash
  local changed_scopes = _changed_scope_lookup(scopes, old_manifest)

  local scan_ctx = {
    workspace_root = workspace_root,
    abs_target = abs_target,
    stripped = stripped,
    relative = relative,
    project_root = project_root,
    scopes = scopes,
  }

  -- Selection (spec §8)
  if options.line_set then
    sites = _filter_by_lines(sites, options.line_set)
  elseif options.mutate_all then
    -- all sites
  elseif options.since_last_run then
    sites = _filter_by_changed_scopes(sites, changed_scopes)
  else
    if old_manifest and not module_hash_changed then
      sites = {}
    else
      sites = _filter_by_changed_scopes(sites, changed_scopes)
    end
  end

  if #sites == 0 then
    return _emit_empty_result(stdout, options, scan_ctx, "no mutation sites to test", 0)
  end

  local coverage_path = _coverage_report_path(workspace_root)
  local coverage_available = false
  local coverage_lines = nil
  local baseline_cmd
  local baseline_uses_coverage = false

  if options.test_command then
    baseline_cmd = options.test_command
    stderr:write("warning: --test-command disables coverage filtering; treating all sites as covered\n")
    coverage_available = true
  elseif options.mutate_all then
    if not _check_driver_options(stderr, options) then
      return 1
    end
    local driver_in_ws = util.join_path(workspace_root, options.driver_script)
    baseline_cmd = _build_driver_command(driver_in_ws, nil, false)
    coverage_available = true
  elseif options.reuse_coverage then
    if not _check_driver_options(stderr, options) then
      return 1
    end
    coverage_lines = _parse_luacov_report(coverage_path, workspace_root, relative)
    if coverage_lines then
      coverage_available = true
    else
      stderr:write("warning: --reuse-coverage requested but ", coverage_path, " not found; continuing without coverage filtering\n")
      coverage_available = true
    end
    local driver_in_ws = util.join_path(workspace_root, options.driver_script)
    baseline_cmd = _build_driver_command(driver_in_ws, nil, false)
  else
    if not _check_driver_options(stderr, options) then
      return 1
    end
    local driver_in_ws = util.join_path(workspace_root, options.driver_script)
    baseline_cmd = _build_driver_command(driver_in_ws, coverage_path, false)
    baseline_uses_coverage = true
  end

  stdout:write("mutate4lua: ", relative, "\n")
  stdout:write("baseline: running...\n")

  local workspace, workspace_err = _create_workspace(workspace_root)
  if not workspace then
    stderr:write("error: ", workspace_err, "\n")
    return 1
  end

  local baseline = run_shell(baseline_cmd, workspace, nil)
  if not baseline.ok then
    stderr:write("baseline test failed (exit ", tostring(baseline.code), ")\n")
    if baseline.output ~= "" then stderr:write(baseline.output, "\n") end
    _cleanup(workspace)
    return 2
  end

  if baseline_uses_coverage then
    coverage_lines = _parse_luacov_report(coverage_path, workspace, relative)
    coverage_available = true
  end

  if coverage_available and coverage_lines then
    sites = _filter_by_coverage(sites, coverage_lines)
  end

  local total_sites = #data.sites
  local covered_count
  local uncovered_count
  if coverage_available and coverage_lines then
    covered_count = #_filter_by_coverage(data.sites, coverage_lines)
    uncovered_count = total_sites - covered_count
  else
    covered_count = total_sites
    uncovered_count = 0
  end
  local changed_count = _count_sites_in_changed_scopes(data.sites, changed_scopes)
  local differential, violating = _compute_surface_areas(sites, old_manifest, changed_scopes)

  _print_diagnostics(stdout, total_sites, covered_count, uncovered_count, changed_count,
    old_manifest ~= nil, module_hash_changed, differential, violating)

  if uncovered_count > 0 then
    local list = {}
    for _, site in ipairs(data.sites) do
      if not (coverage_lines or {})[site.line] then
        list[#list + 1] = tostring(site.line)
      end
    end
    if #list > 0 then
      table.sort(list)
      stdout:write("uncovered sites: ", table.concat(list, ", "), "\n")
    end
  end

  if #sites == 0 then
    local code = _emit_empty_result(stdout, options, scan_ctx, "no covered mutation sites", baseline.elapsed)
    _cleanup(workspace)
    return code
  end

  if options.mutation_warning and #sites > options.mutation_warning then
    stderr:write("warning: ", tostring(#sites), " mutations exceed threshold ", tostring(options.mutation_warning), "\n")
  end

  local timeout = math.max(5, (baseline.elapsed + 1) * timeout_factor)
  stdout:write("baseline: ", tostring(baseline.elapsed), "s (timeout: ", tostring(math.ceil(timeout)), "s)\n")

  local function _mutant_command(ws)
    if options.test_command then
      return options.test_command
    end
    return _build_driver_command(util.join_path(ws, options.driver_script), nil, true)
  end

  local worker_count = _resolve_worker_count(options, #sites)
  local results = {}

  if worker_count > 1 then
    stdout:write("workers: ", tostring(worker_count), " (parallel)\n")
    local extra_workspaces, workspaces_err = create_workspaces(workspace_root, worker_count - 1)
    if not extra_workspaces then
      stderr:write("error: ", workspaces_err or "failed to create workspaces", "\n")
      _cleanup(workspace)
      return 1
    end
    local workspaces = { workspace }
    for _, ws in ipairs(extra_workspaces) do
      workspaces[#workspaces + 1] = ws
    end

    local completed = 0
    local ok_run, run_results = pcall(function()
      local collected = run_parallel({
        worker_count = worker_count,
        job_count = #sites,
        workspaces = workspaces,
        timeout = timeout,
        timeout_command = _find_timeout_command(),
        prepare = function(i, ws)
          util.write_file(util.join_path(ws, relative), scanner.apply_mutation(stripped, sites[i]))
        end,
        command = function(_, ws)
          return _mutant_command(ws)
        end,
        on_complete = function(i, run_result)
          completed = completed + 1
          local site = sites[i]
          stdout:write(string.format("[%d/%d] L%d: %s ... %s (%ds)\n",
            completed, #sites, site.line, site.description,
            _classify_status(run_result), run_result.elapsed))
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
      _cleanup(workspace)
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
      stdout:write(string.format("[%d/%d] L%d: %s ... %s (%ds)\n",
        i, #sites, site.line, site.description, results[i].status, result.elapsed))
    end
  end

  _cleanup(workspace)

  local killed, survived, timed_out = 0, 0, 0
  for _, r in ipairs(results) do
    if r.status == "killed" then killed = killed + 1
    elseif r.status == "survived" then survived = survived + 1
    else timed_out = timed_out + 1 end
  end

  local total = #results
  local score = total > 0 and (killed / total * 100) or 100
  local manifest_updated = false
  if survived == 0 and timed_out == 0 and not options.line_set then
    manifest_updated = _write_manifest(scan_ctx)
  end

  stdout:write(string.format("score: %.1f%% (%d/%d killed", score, killed, total))
  if timed_out > 0 then stdout:write(", ", tostring(timed_out), " timeout") end
  stdout:write(")\n")
  if manifest_updated then
    stdout:write("manifest updated: ", relative, "\n")
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
  local proj_hash = project.project_hash(project_root, abs_target, stripped)

  manifest.write(abs_target, stripped, {
    version = 4,
    project_hash = proj_hash,
    scopes = data.scopes,
  })

  stdout:write("manifest updated: ", data.relative_file, "\n")
  return 0
end

return engine
