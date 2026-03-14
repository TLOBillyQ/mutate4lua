package engine

import (
	"fmt"
	"os"
	"path/filepath"
	goruntime "runtime"
	"strings"

	"github.com/billyq/mutate4lua/internal/analysis"
	"github.com/billyq/mutate4lua/internal/driver"
	"github.com/billyq/mutate4lua/internal/manifest"
	mutproject "github.com/billyq/mutate4lua/internal/project"
	"github.com/billyq/mutate4lua/internal/report"
	mutruntime "github.com/billyq/mutate4lua/internal/runtime"
)

type CoreOptions struct {
	Target          string
	Lane            string
	Mode            string
	DriverScript    string
	Scan            bool
	UpdateManifest  bool
	SinceLastRun    bool
	MutateAll       bool
	Lines           []int
	LinesLookup     map[int]bool
	MutationWarning int
	MaxWorkers      int
	TimeoutFactor   int
	TestCommand     string
	JSON            bool
}

type ChangedScopes struct {
	ManifestExists     bool            `json:"manifest_exists"`
	ProjectHashChanged bool            `json:"project_hash_changed"`
	All                map[string]bool `json:"all"`
	Unregistered       map[string]bool `json:"unregistered"`
	Violations         map[string]bool `json:"violations"`
}

type SelectionArgs struct {
	Lines        []int        `json:"lines"`
	LinesLookup  map[int]bool `json:"-"`
	SinceLastRun bool         `json:"since_last_run"`
	MutateAll    bool         `json:"mutate_all"`
}

type SelectionResult struct {
	TotalMutationSites           int                     `json:"total_mutation_sites"`
	Selected                     []analysis.MutationSite `json:"selected"`
	Covered                      []analysis.MutationSite `json:"covered"`
	Uncovered                    []analysis.MutationSite `json:"uncovered"`
	ChangedMutationSites         int                     `json:"changed_mutation_sites"`
	ManifestExists               bool                    `json:"manifest_exists"`
	ProjectHashChanged           bool                    `json:"project_hash_changed"`
	DifferentialSurfaceArea      int                     `json:"differential_surface_area"`
	ManifestViolatingSurfaceArea int                     `json:"manifest_violating_surface_area"`
	ChangedScopeIDs              map[string]bool         `json:"changed_scope_ids"`
}

func BuildAnalysis(workspaceRoot, target string) (string, string, string, analysis.Result, error) {
	absoluteTarget, err := filepath.Abs(target)
	if err != nil {
		return "", "", "", analysis.Result{}, err
	}
	projectRoot := mutproject.FindRoot(workspaceRoot, absoluteTarget)
	rawSource, err := mutruntime.ReadFile(absoluteTarget)
	if err != nil {
		return "", "", "", analysis.Result{}, err
	}
	strippedSource := manifest.StripEmbedded(rawSource)
	relative := mutproject.RelativeFile(projectRoot, absoluteTarget)
	result := analysis.AnalyzeSource(absoluteTarget, relative, strippedSource)
	hash, err := mutproject.ProjectHash(projectRoot, absoluteTarget, strippedSource)
	if err != nil {
		return "", "", "", analysis.Result{}, err
	}
	result.ProjectHash = hash
	return projectRoot, absoluteTarget, strippedSource, result, nil
}

func driverSuites(projectRoot string, result analysis.Result, opts CoreOptions) ([]string, error) {
	if opts.TestCommand != "" {
		return nil, nil
	}
	return driver.CommandSuiteSelection(projectRoot, opts.DriverScript, opts.Lane, opts.Mode, result.ProjectHash, result.RelativeFile)
}

func baselineKey(projectHash, lane, mode, targetFile, suiteFingerprint string) string {
	return mutruntime.FNV1a64Hex(strings.Join([]string{projectHash, lane, mode, targetFile, suiteFingerprint}, "\x00"))
}

func scopeHashMap(scopes []analysis.ScopeInfo) map[string]string {
	result := map[string]string{}
	for _, scope := range scopes {
		result[scope.ID] = scope.SemanticHash
	}
	return result
}

func mutationCount(sites []analysis.MutationSite, scopeIDs map[string]bool) int {
	if scopeIDs == nil {
		return len(sites)
	}
	count := 0
	for _, site := range sites {
		if scopeIDs[site.ScopeID] {
			count++
		}
	}
	return count
}

func computeChangedScopes(previous *manifest.Data, result analysis.Result) ChangedScopes {
	if previous == nil {
		return ChangedScopes{All: map[string]bool{}, Unregistered: map[string]bool{}, Violations: map[string]bool{}}
	}
	if previous.ProjectHash == result.ProjectHash {
		return ChangedScopes{ManifestExists: true, All: map[string]bool{}, Unregistered: map[string]bool{}, Violations: map[string]bool{}}
	}
	previousHashes := scopeHashMap(previous.Scopes)
	all := map[string]bool{}
	unregistered := map[string]bool{}
	violations := map[string]bool{}
	for _, scope := range result.Scopes {
		oldHash, ok := previousHashes[scope.ID]
		if !ok {
			unregistered[scope.ID] = true
			all[scope.ID] = true
		} else if oldHash != scope.SemanticHash {
			violations[scope.ID] = true
			all[scope.ID] = true
		}
	}
	return ChangedScopes{
		ManifestExists:     true,
		ProjectHashChanged: true,
		All:                all,
		Unregistered:       unregistered,
		Violations:         violations,
	}
}

func FilterSelection(args SelectionArgs, result analysis.Result, previous *manifest.Data, coverageLines map[string]bool) SelectionResult {
	changed := computeChangedScopes(previous, result)
	selected := []analysis.MutationSite{}
	covered := []analysis.MutationSite{}
	uncovered := []analysis.MutationSite{}
	lineSelected := func(site analysis.MutationSite) bool {
		if len(args.Lines) == 0 {
			return true
		}
		return args.LinesLookup[site.Line]
	}
	scopeSelected := func(site analysis.MutationSite) bool {
		if args.MutateAll {
			return true
		}
		if len(args.Lines) > 0 {
			return true
		}
		if args.SinceLastRun {
			return changed.All[site.ScopeID]
		}
		if previous == nil {
			return true
		}
		if !changed.ProjectHashChanged {
			return false
		}
		return changed.All[site.ScopeID]
	}
	for _, site := range result.Sites {
		if !lineSelected(site) || !scopeSelected(site) {
			continue
		}
		selected = append(selected, site)
		if len(coverageLines) > 0 {
			key := mutruntime.NormalizeRelativePath(site.RelativeFile) + ":" + mutruntime.Itoa(site.Line)
			if coverageLines[key] {
				covered = append(covered, site)
			} else {
				uncovered = append(uncovered, site)
			}
		} else {
			covered = append(covered, site)
		}
	}
	return SelectionResult{
		TotalMutationSites:           len(result.Sites),
		Selected:                     selected,
		Covered:                      covered,
		Uncovered:                    uncovered,
		ChangedMutationSites:         mutationCount(result.Sites, changed.All),
		ManifestExists:               changed.ManifestExists,
		ProjectHashChanged:           changed.ProjectHashChanged,
		DifferentialSurfaceArea:      mutationCount(result.Sites, changed.Unregistered),
		ManifestViolatingSurfaceArea: mutationCount(result.Sites, changed.Violations),
		ChangedScopeIDs:              changed.All,
	}
}

func RunScanOrMutate(workspaceRoot string, opts CoreOptions) (string, int, error) {
	projectRoot, absoluteTarget, strippedSource, result, err := BuildAnalysis(workspaceRoot, opts.Target)
	if err != nil {
		return "", 1, err
	}
	previous, err := manifest.Load(projectRoot, absoluteTarget, result.RelativeFile, strippedSource)
	if err != nil {
		return "", 1, err
	}
	if opts.Scan {
		changed := computeChangedScopes(previous, result)
		sites := result.Sites
		if len(opts.Lines) > 0 {
			filtered := []analysis.MutationSite{}
			for _, site := range sites {
				if opts.LinesLookup[site.Line] {
					filtered = append(filtered, site)
				}
			}
			sites = filtered
		}
		if opts.JSON {
			payload, _ := mutruntime.JSONString(map[string]any{"relative_file": result.RelativeFile, "sites": sites, "changed_scope_ids": changed.All})
			return payload + "\n", 0, nil
		}
		return report.ScanReport(result.RelativeFile, sites, changed.All), 0, nil
	}
	if opts.UpdateManifest {
		if err := manifest.Write(projectRoot, result.RelativeFile, result); err != nil {
			return "", 1, err
		}
		if opts.JSON {
			payload, _ := mutruntime.JSONString(map[string]any{"ok": true, "target": result.RelativeFile})
			return payload + "\n", 0, nil
		}
		return fmt.Sprintf("Updated manifest for %s\n", result.RelativeFile), 0, nil
	}

	var baseline mutruntime.RunResult
	var coverageLines map[string]bool
	suites, err := driverSuites(projectRoot, result, opts)
	if err != nil {
		return "", 1, err
	}
	suiteKey := driver.SuiteFingerprint(suites)
	if suiteKey == "" {
		suiteKey = "full"
	}
	cacheKey := baselineKey(result.ProjectHash, opts.Lane, opts.Mode, result.RelativeFile, suiteKey)
	cachePath := driver.BaselineCachePath(projectRoot, cacheKey)
	if opts.TestCommand == "" && mutruntime.FileExists(cachePath) {
		var cached mutruntime.BaselineCache
		if err := mutruntime.ReadJSONFile(cachePath, &cached); err == nil {
			baseline = mutruntime.RunResult{ExitCode: 0, DurationMS: cached.DurationMS}
			coverageFile := filepath.Join(projectRoot, ".mutate4lua", "cache", "baseline", cacheKey+".coverage")
			coverageLines, err = driver.ReadCoverageLines(coverageFile)
			if err != nil {
				return "", 1, err
			}
		}
	}
	if baseline.DurationMS == 0 && len(coverageLines) == 0 {
		var baselineArgs []string
		var shell bool
		tempCoverage := ""
		tempSuiteList := ""
		if opts.TestCommand != "" {
			baselineArgs = []string{opts.TestCommand}
			shell = true
		} else {
			tempCoverage = filepath.Join(projectRoot, ".mutate4lua", "cache", "baseline", cacheKey+".coverage")
			baselineArgs, tempSuiteList, err = driver.BuildDefaultDriverCommand(projectRoot, opts.DriverScript, opts.Lane, opts.Mode, result.RelativeFile, result.ProjectHash, tempCoverage, suites, true)
			if err != nil {
				return "", 1, err
			}
			defer func() {
				if tempSuiteList != "" {
					_ = os.Remove(tempSuiteList)
				}
			}()
		}
		baseline = mutruntime.RunCommand(projectRoot, baselineArgs, 0, shell)
		if baseline.ExitCode != 0 || baseline.TimedOut {
			return formatBaselineFailure(baseline), 2, nil
		}
		if opts.TestCommand == "" {
			coverageLines, err = driver.ReadCoverageLines(tempCoverage)
			if err != nil {
				return "", 1, err
			}
			_ = mutruntime.WriteJSONFile(cachePath, mutruntime.BaselineCache{DurationMS: baseline.DurationMS, SuiteFingerprint: suiteKey, Suites: suites})
		}
	}
	selection := FilterSelection(SelectionArgs{Lines: opts.Lines, LinesLookup: opts.LinesLookup, SinceLastRun: opts.SinceLastRun, MutateAll: opts.MutateAll}, result, previous, coverageLines)
	diagnostics := report.DiagnosticsReport(report.DiagnosticsInput{
		TotalMutationSites:           selection.TotalMutationSites,
		CoveredCount:                 len(selection.Covered),
		UncoveredCount:               len(selection.Uncovered),
		ChangedMutationSites:         selection.ChangedMutationSites,
		ManifestExists:               selection.ManifestExists,
		ProjectHashChanged:           selection.ProjectHashChanged,
		DifferentialSurfaceArea:      selection.DifferentialSurfaceArea,
		ManifestViolatingSurfaceArea: selection.ManifestViolatingSurfaceArea,
	}, opts.MutationWarning)
	if len(selection.Covered) == 0 {
		if err := manifest.Write(projectRoot, result.RelativeFile, result); err != nil {
			return "", 1, err
		}
		text := report.RunReport(result.RelativeFile, baseline, diagnostics, selection.Uncovered, nil)
		if opts.JSON {
			payload, _ := mutruntime.JSONString(map[string]any{"baseline": baseline, "selection": selection, "results": []mutruntime.JobResult{}})
			return payload + "\n", 0, nil
		}
		return text, 0, nil
	}

	timeoutSeconds := int(mutruntime.MaxInt64(1, (baseline.DurationMS*int64(mutruntime.MaxInt(1, opts.TimeoutFactor))+999)/1000))
	commandArgs := []string{}
	commandShell := false
	tempSuiteList := ""
	if opts.TestCommand != "" {
		commandArgs = []string{opts.TestCommand}
		commandShell = true
	} else {
		commandArgs, tempSuiteList, err = driver.BuildDefaultDriverCommand(projectRoot, opts.DriverScript, opts.Lane, opts.Mode, result.RelativeFile, result.ProjectHash, "", suites, true)
		if err != nil {
			return "", 1, err
		}
		defer func() {
			if tempSuiteList != "" {
				_ = os.Remove(tempSuiteList)
			}
		}()
	}
	jobs := make([]mutruntime.MutationJob, 0, len(selection.Covered))
	for index, site := range selection.Covered {
		jobs = append(jobs, mutruntime.MutationJob{SiteIndex: index + 1, Line: site.Line, Description: site.Description, MutatedSource: analysis.ApplyMutation(strippedSource, site)})
	}
	workerCount := opts.MaxWorkers
	if workerCount <= 0 {
		workerCount = mutruntime.MaxInt(1, goruntime.NumCPU()/2)
	}
	results, err := mutruntime.RunMutationBatch(projectRoot, result.RelativeFile, commandArgs, commandShell, timeoutSeconds, jobs, workerCount)
	if err != nil {
		return "", 1, err
	}
	survived := false
	for _, item := range results {
		if !item.Killed {
			survived = true
			break
		}
	}
	if !survived {
		if err := manifest.Write(projectRoot, result.RelativeFile, result); err != nil {
			return "", 1, err
		}
	}
	if opts.JSON {
		payload, _ := mutruntime.JSONString(map[string]any{"baseline": baseline, "selection": selection, "results": results})
		if survived {
			return payload + "\n", 3, nil
		}
		return payload + "\n", 0, nil
	}
	text := report.RunReport(result.RelativeFile, baseline, diagnostics, selection.Uncovered, results)
	if survived {
		return text, 3, nil
	}
	return text, 0, nil
}

func formatBaselineFailure(baseline mutruntime.RunResult) string {
	lines := []string{"Baseline tests failed."}
	if mutruntime.Trim(baseline.Output) != "" {
		lines = append(lines, mutruntime.Trim(baseline.Output))
	}
	return strings.Join(lines, "\n") + "\n"
}
