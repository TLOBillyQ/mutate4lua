package report

import (
	"fmt"
	"strings"

	"github.com/billyq/mutate4lua/internal/analysis"
	mutruntime "github.com/billyq/mutate4lua/internal/runtime"
)

type DiagnosticsInput struct {
	TotalMutationSites           int
	CoveredCount                 int
	UncoveredCount               int
	ChangedMutationSites         int
	ManifestExists               bool
	ProjectHashChanged           bool
	DifferentialSurfaceArea      int
	ManifestViolatingSurfaceArea int
}

func ScanReport(relativeFile string, sites []analysis.MutationSite, changedScopeIDs map[string]bool) string {
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

func DiagnosticsReport(input DiagnosticsInput, mutationWarning int) string {
	lines := []string{
		fmt.Sprintf("Total mutation sites: %d", input.TotalMutationSites),
		fmt.Sprintf("Covered mutation sites: %d", input.CoveredCount),
		fmt.Sprintf("Uncovered mutation sites: %d", input.UncoveredCount),
		fmt.Sprintf("Changed mutation sites: %d", input.ChangedMutationSites),
		fmt.Sprintf("Manifest exists: %t", input.ManifestExists),
		fmt.Sprintf("Project hash changed: %t", input.ProjectHashChanged),
		fmt.Sprintf("Differential surface area: %d", input.DifferentialSurfaceArea),
		fmt.Sprintf("Manifest-violating surface area: %d", input.ManifestViolatingSurfaceArea),
	}
	if input.CoveredCount == 0 {
		lines = append(lines, "No mutations need testing.")
	} else if input.CoveredCount > mutationWarning {
		lines = append(lines, fmt.Sprintf("WARNING: Found %d mutations. Consider splitting this module.", input.CoveredCount))
	}
	return strings.Join(lines, "\n") + "\n"
}

func RunReport(relativeFile string, baseline mutruntime.RunResult, diagnostics string, uncovered []analysis.MutationSite, results []mutruntime.JobResult) string {
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
