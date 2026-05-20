local scanner = require("mutate4lua.internal.scanner")
local manifest = require("mutate4lua.internal.manifest")
local project = require("mutate4lua.driver.project")
local util = require("mutate4lua.util")

local engine = {}

local TIMEOUT_EXIT_CODE = 124

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
  local full = "cd " .. util.shell_quote(cwd or ".") .. " && "
  if timeout_seconds and timeout_seconds > 0 then
    local tc = _find_timeout_command()
    if tc then
      full = full .. tc .. " " .. tostring(math.ceil(timeout_seconds)) .. " "
    end
  end
  full = full .. shell_command .. " > " .. util.shell_quote(output_path) .. " 2>&1"

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
  os.execute("cp -r " .. util.shell_quote(source_dir .. "/.") .. " " .. util.shell_quote(workspace .. "/"))
  return workspace
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
  local prefix = target_relative .. ":"
  for line in content:gmatch("[^\n]+") do
    if util.starts_with(line, prefix) then
      local line_num = tonumber(line:sub(#prefix + 1))
      if line_num then covered[line_num] = true end
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

local function _passed_scope_updates(results, timestamp, lane)
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

local function _write_manifest_update(abs_target, stripped, project_root, scopes, old_manifest, changed_scopes, updates)
  if updates == nil or next(updates) == nil then
    return false
  end
  if not _updates_cover_changed_scopes(scopes, changed_scopes, updates) then
    return false
  end
  local proj_hash = project.project_hash(project_root, abs_target, stripped)
  manifest.write(abs_target, stripped, {
    version = 2,
    project_hash = proj_hash,
    scopes = _build_manifest_scopes(scopes, old_manifest, updates),
  })
  return true
end

local function _build_driver_command(driver_path, lane, suite_list_file, coverage_file)
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
  parts[#parts + 1] = "--quiet"
  return _shell_join(parts)
end

local function _discover_relevant_suites(run_shell, workspace_root, driver_script, lane, target_relative)
  local driver_path = util.join_path(workspace_root, driver_script)
  local cmd = _shell_join({"lua", driver_path, "--lane", lane, "--emit-suite-file-map-json"})
  local result = run_shell(cmd, workspace_root, nil)
  if not result.ok then return nil end

  local map = util.decode_json(util.trim(result.output or ""))
  if not map or type(map.suite_files) ~= "table" then return nil end

  local relevant = {}
  for suite_name, files in pairs(map.suite_files) do
    for _, file in ipairs(files) do
      if file == target_relative then
        relevant[#relevant + 1] = suite_name
        break
      end
    end
  end
  if #relevant == 0 then return nil end

  table.sort(relevant)
  local suite_file = util.tmp_path("_suites.txt")
  util.write_file(suite_file, table.concat(relevant, "\n") .. "\n")
  return suite_file
end

local function _scan_target(workspace_root, target)
  local abs_target = util.absolute_path(util.join_path(workspace_root, target))
  local source = util.read_file(abs_target)
  if not source then return nil, nil, nil, "cannot read " .. target end
  local relative = project.relative_file(workspace_root, abs_target)
  local stripped = manifest.strip(source)
  local data = scanner.analyze(abs_target, relative, stripped)
  return data, stripped, abs_target, nil
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
  local timeout_factor = options.timeout_factor or 15

  if not options.target then
    stderr:write("error: target file required\n")
    return 1
  end

  local data, stripped, abs_target, scan_err = _scan_target(workspace_root, options.target)
  if not data then
    stderr:write("error: ", scan_err, "\n")
    return 1
  end

  local relative = data.relative_file
  local sites = data.sites
  local scopes = data.scopes
  local old_manifest = manifest.read(abs_target)
  local changed_scopes = _changed_scope_lookup(scopes, old_manifest)
  local initial_site_counts = _site_counts_by_scope(data.sites)

  if options.since_last_run and not options.mutate_all then
    if old_manifest then
      sites = _filter_by_changed_scopes(sites, changed_scopes)
    end
  end

  if options.line_set then
    sites = _filter_by_lines(sites, options.line_set)
  end

  if #sites == 0 then
    local manifest_updated = false
    if not options.line_set then
      manifest_updated = _write_manifest_update(
        abs_target,
        stripped,
        project.find_root(workspace_root, abs_target),
        scopes,
        old_manifest,
        changed_scopes,
        _no_site_updates(scopes, changed_scopes, initial_site_counts, _utc_timestamp(), options.lane)
      )
    end
    if options.json then
      stdout:write(util.encode_json({
        file = relative,
        total_sites = 0,
        killed = 0,
        survived = 0,
        timeout = 0,
        score = 100,
        baseline_seconds = 0,
        manifest_updated = manifest_updated,
        mutations = {},
      }), "\n")
    else
      stdout:write("no mutation sites to test\n")
      if manifest_updated then
        stdout:write("manifest updated: ", relative, "\n")
      end
    end
    return 0
  end

  local suite_list_file = nil
  if not options.test_command then
    suite_list_file = _discover_relevant_suites(
      run_shell, workspace_root, options.driver_script, options.lane, relative)
  end

  local workspace = _create_workspace(workspace_root)
  local coverage_file = nil

  local baseline_cmd
  if options.test_command then
    baseline_cmd = options.test_command
  else
    coverage_file = util.tmp_path("_cov.txt")
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
    if not options.json then
      stdout:write("no covered mutation sites\n")
    end
    local manifest_updated = false
    if not options.line_set then
      manifest_updated = _write_manifest_update(
        abs_target,
        stripped,
        project.find_root(workspace_root, abs_target),
        scopes,
        old_manifest,
        changed_scopes,
        _no_site_updates(scopes, changed_scopes, initial_site_counts, _utc_timestamp(), options.lane)
      )
    end
    if manifest_updated and not options.json then
      stdout:write("manifest updated: ", relative, "\n")
    end
    if options.json then
      stdout:write(util.encode_json({
        file = relative,
        total_sites = 0,
        killed = 0,
        survived = 0,
        timeout = 0,
        score = 100,
        baseline_seconds = baseline.elapsed,
        manifest_updated = manifest_updated,
        mutations = {},
      }), "\n")
    end
    _cleanup(workspace, suite_list_file)
    return 0
  end

  if options.mutation_warning and #sites > options.mutation_warning then
    stderr:write("warning: ", tostring(#sites), " mutations exceed threshold ", tostring(options.mutation_warning), "\n")
  end

  local timeout = math.max(5, (baseline.elapsed + 1) * timeout_factor)
  local target_in_ws = util.join_path(workspace, relative)

  local mutant_cmd
  if options.test_command then
    mutant_cmd = options.test_command
  else
    local driver_in_ws = util.join_path(workspace, options.driver_script)
    mutant_cmd = _build_driver_command(driver_in_ws, options.lane, suite_list_file, nil)
  end

  if not options.json then
    stdout:write("baseline: ", tostring(baseline.elapsed), "s (timeout: ", tostring(math.ceil(timeout)), "s)\n")
  end

  local results = {}
  for i, site in ipairs(sites) do
    local mutated = scanner.apply_mutation(stripped, site)
    util.write_file(target_in_ws, mutated)

    local result = run_shell(mutant_cmd, workspace, timeout)

    local status = "survived"
    if result.timed_out then
      status = "timeout"
    elseif not result.ok then
      status = "killed"
    end

    results[#results + 1] = {
      line = site.line,
      description = site.description,
      original = site.original_text,
      replacement = site.replacement_text,
      status = status,
      elapsed = result.elapsed,
      scope_id = site.scope_id,
    }

    util.write_file(target_in_ws, stripped)

    if not options.json then
      stdout:write(string.format("[%d/%d] L%d: %s ... %s (%ds)\n",
        i, #sites, site.line, site.description, status, result.elapsed))
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
  if survived == 0 and timed_out == 0 and not options.line_set then
    local timestamp = _utc_timestamp()
    local updates = _passed_scope_updates(results, timestamp, options.lane)
    _merge_updates(updates, _no_site_updates(scopes, changed_scopes, initial_site_counts, timestamp, options.lane))
    manifest_updated = _write_manifest_update(
      abs_target,
      stripped,
      project.find_root(workspace_root, abs_target),
      scopes,
      old_manifest,
      changed_scopes,
      updates
    )
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

  local project_root = project.find_root(workspace_root, abs_target)
  local proj_hash = project.project_hash(project_root, abs_target, stripped)

  manifest.write(abs_target, stripped, {
    version = 2,
    project_hash = proj_hash,
    scopes = data.scopes,
  })

  stdout:write("manifest updated: ", data.relative_file, "\n")
  return 0
end

function engine.index_suites(options, env)
  local stdout = env.stdout or io.stdout
  local stderr = env.stderr or io.stderr
  local workspace_root = env.cwd or "."
  local run_shell = env.run_shell or _default_run_shell

  local driver_path = util.join_path(workspace_root, options.driver_script)
  local cmd = _shell_join({"lua", driver_path, "--lane", options.lane, "--list-suites", "--json"})
  local result = run_shell(cmd, workspace_root, nil)

  local output = util.trim(result.output or "")
  if output ~= "" then
    if result.ok then
      if options.json then
        local suites = util.decode_json(output) or {}
        stdout:write(util.encode_json({
          ok = true,
          suite_count = #suites,
          suites = suites,
        }), "\n")
      else
        stdout:write(output, "\n")
      end
    else
      stderr:write(output, "\n")
    end
  end
  return result.ok and 0 or 1
end

return engine
