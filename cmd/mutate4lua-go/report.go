package main

import (
	"fmt"
	"strings"
)

func scanReport(relativeFile string, sites []mutationSite, changedScopeIDs map[string]bool) string {
	lines := []string{fmt.Sprintf("Scan: %d mutation sites in %s", len(sites), relativeFile)}
	for _, site := range sites {
		marker := "  "
		if changedScopeIDs != nil && changedScopeIDs[site.ScopeID] {
			marker = "* "
		}
		lines = append(lines, fmt.Sprintf("%s%s:%d %s", marker, relativeFile, site.Line, site.Description))
	}
	if len(changedScopeIDs) > 0 {
		lines = append(lines, "* indicates a scope that differs from the embedded manifest.")
	}
	return strings.Join(lines, "\n") + "\n"
}

func diagnosticsReport(selection selectionResult, mutationWarning int) string {
	lines := []string{
		fmt.Sprintf("Total mutation sites: %d", selection.TotalMutationSites),
		fmt.Sprintf("Covered mutation sites: %d", len(selection.Covered)),
		fmt.Sprintf("Uncovered mutation sites: %d", len(selection.Uncovered)),
		fmt.Sprintf("Changed mutation sites: %d", selection.ChangedMutationSites),
		fmt.Sprintf("Manifest exists: %t", selection.ManifestExists),
		fmt.Sprintf("Project hash changed: %t", selection.ProjectHashChanged),
		fmt.Sprintf("Differential surface area: %d", selection.DifferentialSurfaceArea),
		fmt.Sprintf("Manifest-violating surface area: %d", selection.ManifestViolatingSurfaceArea),
	}
	if len(selection.Covered) == 0 {
		lines = append(lines, "No mutations need testing.")
	} else if len(selection.Covered) > mutationWarning {
		lines = append(lines, fmt.Sprintf("WARNING: Found %d mutations. Consider splitting this module.", len(selection.Covered)))
	}
	return strings.Join(lines, "\n") + "\n"
}

func runReport(relativeFile string, baseline runResult, diagnostics string, uncovered []mutationSite, results []jobResult) string {
	lines := []string{fmt.Sprintf("Baseline tests passed in %d ms.", baseline.DurationMS), strings.TrimSuffix(diagnostics, "\n")}
	for _, site := range uncovered {
		lines = append(lines, fmt.Sprintf("UNCOVERED %s:%d %s", relativeFile, site.Line, site.Description))
	}
	killed := 0
	for _, result := range results {
		if result.Killed {
			killed++
		}
		status := "SURVIVED"
		if result.Killed {
			status = "KILLED"
		}
		lines = append(lines, fmt.Sprintf("%s %s:%d %s (%d ms, %d ms wall)", status, relativeFile, result.Line, result.Description, result.DurationMS, result.JobWallMS))
		if result.TimedOut {
			lines = append(lines, "  timed out")
		}
	}
	lines = append(lines, fmt.Sprintf("Coverage: %d uncovered sites skipped.", len(uncovered)))
	lines = append(lines, fmt.Sprintf("Summary: %d killed, %d survived, %d total.", killed, len(results)-killed, len(results)))
	return strings.Join(lines, "\n") + "\n"
}
