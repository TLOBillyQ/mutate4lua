local report = {}
function report.scan(relative_file, sites, changed_scope_ids)
  local lines = {
    string.format("Scan: %d mutation sites in %s", #sites, relative_file),
  }
  for _, site in ipairs(sites) do
    local marker = changed_scope_ids and changed_scope_ids[site.scope_id] and "* " or "  "
    lines[#lines + 1] = string.format("%s%s:%d %s", marker, relative_file, site.line, site.description)
  end
  if changed_scope_ids and next(changed_scope_ids) ~= nil then
    lines[#lines + 1] = "* indicates a scope that differs from the embedded manifest."
  end
  return table.concat(lines, "\n") .. "\n"
end
function report.diagnostics(selection_result, mutation_warning)
  local lines = {
    "Total mutation sites: " .. selection_result.total_mutation_sites,
    "Covered mutation sites: " .. #selection_result.covered,
    "Uncovered mutation sites: " .. #selection_result.uncovered,
    "Changed mutation sites: " .. selection_result.changed_mutation_sites,
    "Manifest exists: " .. tostring(selection_result.manifest_exists),
    "Project hash changed: " .. tostring(selection_result.project_hash_changed),
    "Differential surface area: " .. selection_result.differential_surface_area,
    "Manifest-violating surface area: " .. selection_result.manifest_violating_surface_area,
  }
  if #selection_result.covered == 0 then
    lines[#lines + 1] = "No mutations need testing."
  elseif #selection_result.covered > mutation_warning then
    lines[#lines + 1] = string.format("WARNING: Found %d mutations. Consider splitting this module.", #selection_result.covered)
  end
  return table.concat(lines, "\n") .. "\n"
end
function report.run(relative_file, baseline, diagnostics, uncovered, results)
  local diagnostics_text = diagnostics:gsub("\n$", "")
  local lines = {
    string.format("Baseline tests passed in %d ms.", baseline.duration_ms),
    diagnostics_text,
  }
  for _, site in ipairs(uncovered) do
    lines[#lines + 1] = string.format("UNCOVERED %s:%d %s", relative_file, site.line, site.description)
  end
  local killed = 0
  for _, result in ipairs(results) do
    if result.killed then
      killed = killed + 1
    end
    lines[#lines + 1] = string.format("%s %s:%d %s (%d ms)", result.killed and "KILLED" or "SURVIVED", relative_file, result.line, result.description, result.duration_ms)
    if result.timed_out then
      lines[#lines + 1] = "  timed out"
    end
  end
  lines[#lines + 1] = string.format("Coverage: %d uncovered sites skipped.", #uncovered)
  lines[#lines + 1] = string.format("Summary: %d killed, %d survived, %d total.", killed, #results - killed, #results)
  return table.concat(lines, "\n") .. "\n"
end
return report
