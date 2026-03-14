local selection = {}
local function scope_hash_map(scopes)
  local map = {}
  for _, scope in ipairs(scopes or {}) do
    map[scope.id] = scope.semantic_hash
  end
  return map
end
local function mutation_count(sites, scope_ids)
  if not scope_ids then
    return #sites
  end
  local count = 0
  for _, site in ipairs(sites) do
    if scope_ids[site.scope_id] then
      count = count + 1
    end
  end
  return count
end
function selection.changed_scopes(previous_manifest, analysis)
  if not previous_manifest then
    return {
      manifest_exists = false,
      project_hash_changed = false,
      all = {},
      unregistered = {},
      violations = {},
    }
  end
  if previous_manifest.project_hash == analysis.project_hash then
    return {
      manifest_exists = true,
      project_hash_changed = false,
      all = {},
      unregistered = {},
      violations = {},
    }
  end
  local previous = scope_hash_map(previous_manifest.scopes)
  local unregistered = {}
  local violations = {}
  local all = {}
  for _, scope in ipairs(analysis.scopes) do
    local old_hash = previous[scope.id]
    if not old_hash then
      unregistered[scope.id] = true
      all[scope.id] = true
    elseif old_hash ~= scope.semantic_hash then
      violations[scope.id] = true
      all[scope.id] = true
    end
  end
  return {
    manifest_exists = true,
    project_hash_changed = true,
    all = all,
    unregistered = unregistered,
    violations = violations,
  }
end
function selection.filter(args, analysis, previous_manifest, coverage_lines)
  local changed = selection.changed_scopes(previous_manifest, analysis)
  local selected = {}
  local covered = {}
  local uncovered = {}
  local all_sites = analysis.sites
  local function line_selected(site)
    if not args.lines or #args.lines == 0 then
      return true
    end
    return args.lines_lookup[site.line] == true
  end
  local function scope_selected(site)
    if args.mutate_all then
      return true
    end
    if args.lines and #args.lines > 0 then
      return true
    end
    if args.since_last_run then
      return changed.all[site.scope_id] == true
    end
    if not previous_manifest then
      return true
    end
    if not changed.project_hash_changed then
      return false
    end
    return changed.all[site.scope_id] == true
  end
  for _, site in ipairs(all_sites) do
    if line_selected(site) and scope_selected(site) then
      selected[#selected + 1] = site
      if coverage_lines and next(coverage_lines) ~= nil then
        if coverage_lines[site.relative_file .. ":" .. site.line] then
          covered[#covered + 1] = site
        else
          uncovered[#uncovered + 1] = site
        end
      else
        covered[#covered + 1] = site
      end
    end
  end
  return {
    total_mutation_sites = #all_sites,
    selected = selected,
    covered = covered,
    uncovered = uncovered,
    changed_mutation_sites = mutation_count(all_sites, changed.all),
    manifest_exists = changed.manifest_exists,
    project_hash_changed = changed.project_hash_changed,
    differential_surface_area = mutation_count(all_sites, changed.unregistered),
    manifest_violating_surface_area = mutation_count(all_sites, changed.violations),
    changed_scope_ids = changed.all,
  }
end
return selection
