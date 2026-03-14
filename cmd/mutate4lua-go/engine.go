package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

type coreOptions struct {
	Target          string
	Lane            string
	Mode            string
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

func defaultMode() string { return "" }

func buildAnalysis(workspaceRoot, target string) (string, string, string, analysisResult, error) {
	absoluteTarget, err := filepath.Abs(target)
	if err != nil {
		return "", "", "", analysisResult{}, err
	}
	projectRoot := findProjectRoot(workspaceRoot, absoluteTarget)
	rawSource, err := readFile(absoluteTarget)
	if err != nil {
		return "", "", "", analysisResult{}, err
	}
	strippedSource := stripEmbeddedManifest(rawSource)
	relative := relativeFile(projectRoot, absoluteTarget)
	analysis := analyzeSource(absoluteTarget, relative, strippedSource)
	hash, err := projectHash(projectRoot, absoluteTarget, strippedSource)
	if err != nil {
		return "", "", "", analysisResult{}, err
	}
	analysis.ProjectHash = hash
	return projectRoot, absoluteTarget, strippedSource, analysis, nil
}

func driverSuites(projectRoot string, analysis analysisResult, opts coreOptions) ([]string, error) {
	if opts.TestCommand != "" {
		return nil, nil
	}
	return commandSuiteSelection(projectRoot, opts.Lane, opts.Mode, analysis.ProjectHash, analysis.RelativeFile)
}

func baselineKey(projectHash, lane, mode, targetFile, suiteFingerprint string) string {
	return fnv1a64Hex(strings.Join([]string{projectHash, lane, mode, targetFile, suiteFingerprint}, "\x00"))
}

func runScanOrMutate(workspaceRoot string, opts coreOptions) (string, int, error) {
	projectRoot, absoluteTarget, strippedSource, analysis, err := buildAnalysis(workspaceRoot, opts.Target)
	if err != nil {
		return "", 1, err
	}
	previous, err := loadManifest(projectRoot, absoluteTarget, analysis.RelativeFile, strippedSource)
	if err != nil {
		return "", 1, err
	}
	if opts.Scan {
		changed := computeChangedScopes(previous, analysis)
		sites := analysis.Sites
		if len(opts.Lines) > 0 {
			filtered := []mutationSite{}
			for _, site := range sites {
				if opts.LinesLookup[site.Line] {
					filtered = append(filtered, site)
				}
			}
			sites = filtered
		}
		if opts.JSON {
			payload, _ := jsonString(map[string]any{"relative_file": analysis.RelativeFile, "sites": sites, "changed_scope_ids": changed.All})
			return payload + "\n", 0, nil
		}
		return scanReport(analysis.RelativeFile, sites, changed.All), 0, nil
	}
	if opts.UpdateManifest {
		if err := writeManifest(projectRoot, analysis.RelativeFile, analysis); err != nil {
			return "", 1, err
		}
		if opts.JSON {
			payload, _ := jsonString(map[string]any{"ok": true, "target": analysis.RelativeFile})
			return payload + "\n", 0, nil
		}
		return fmt.Sprintf("Updated manifest for %s\n", analysis.RelativeFile), 0, nil
	}

	var baseline runResult
	var coverageLines map[string]bool
	suites, err := driverSuites(projectRoot, analysis, opts)
	if err != nil {
		return "", 1, err
	}
	suiteKey := suiteFingerprint(suites)
	if suiteKey == "" {
		suiteKey = "full"
	}
	cacheKey := baselineKey(analysis.ProjectHash, opts.Lane, opts.Mode, analysis.RelativeFile, suiteKey)
	cachePath := baselineCachePath(projectRoot, cacheKey)
	if opts.TestCommand == "" && fileExists(cachePath) {
		var cached baselineCache
		if err := readJSONFile(cachePath, &cached); err == nil {
			baseline = runResult{ExitCode: 0, DurationMS: cached.DurationMS}
			coverageFile := filepath.Join(projectRoot, ".mutate4lua", "cache", "baseline", cacheKey+".coverage")
			coverageLines, err = readCoverageLines(coverageFile)
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
			baselineArgs, tempSuiteList, err = buildDefaultDriverCommand(projectRoot, opts.Lane, opts.Mode, analysis.RelativeFile, analysis.ProjectHash, tempCoverage, suites, true)
			if err != nil {
				return "", 1, err
			}
			defer func() {
				if tempSuiteList != "" {
					_ = os.Remove(tempSuiteList)
				}
			}()
		}
		baseline = runCommand(projectRoot, baselineArgs, 0, shell)
		if baseline.ExitCode != 0 || baseline.TimedOut {
			return formatBaselineFailure(baseline), 2, nil
		}
		if opts.TestCommand == "" {
			coverageLines, err = readCoverageLines(tempCoverage)
			if err != nil {
				return "", 1, err
			}
			_ = writeJSONFile(cachePath, baselineCache{DurationMS: baseline.DurationMS, SuiteFingerprint: suiteKey, Suites: suites})
		}
	}
	selection := filterSelection(selectionArgs{Lines: opts.Lines, LinesLookup: opts.LinesLookup, SinceLastRun: opts.SinceLastRun, MutateAll: opts.MutateAll}, analysis, previous, coverageLines)
	diagnostics := diagnosticsReport(selection, opts.MutationWarning)
	if len(selection.Covered) == 0 {
		if err := writeManifest(projectRoot, analysis.RelativeFile, analysis); err != nil {
			return "", 1, err
		}
		text := runReport(analysis.RelativeFile, baseline, diagnostics, selection.Uncovered, nil)
		if opts.JSON {
			payload, _ := jsonString(map[string]any{"baseline": baseline, "selection": selection, "results": []jobResult{}})
			return payload + "\n", 0, nil
		}
		return text, 0, nil
	}

	timeoutSeconds := int(maxInt64(1, (baseline.DurationMS*int64(maxInt(1, opts.TimeoutFactor))+999)/1000))
	commandArgs := []string{}
	commandShell := false
	tempSuiteList := ""
	if opts.TestCommand != "" {
		commandArgs = []string{opts.TestCommand}
		commandShell = true
	} else {
		commandArgs, tempSuiteList, err = buildDefaultDriverCommand(projectRoot, opts.Lane, opts.Mode, analysis.RelativeFile, analysis.ProjectHash, "", suites, true)
		if err != nil {
			return "", 1, err
		}
		defer func() {
			if tempSuiteList != "" {
				_ = os.Remove(tempSuiteList)
			}
		}()
	}
	jobs := make([]mutationJob, 0, len(selection.Covered))
	for index, site := range selection.Covered {
		jobs = append(jobs, mutationJob{SiteIndex: index + 1, Site: site, MutatedSource: applyMutation(strippedSource, site)})
	}
	workerCount := opts.MaxWorkers
	if workerCount <= 0 {
		workerCount = maxInt(1, runtime.NumCPU()/2)
	}
	results, err := runMutationBatch(projectRoot, analysis.RelativeFile, commandArgs, commandShell, timeoutSeconds, jobs, workerCount)
	if err != nil {
		return "", 1, err
	}
	survived := false
	for _, result := range results {
		if !result.Killed {
			survived = true
			break
		}
	}
	if !survived {
		if err := writeManifest(projectRoot, analysis.RelativeFile, analysis); err != nil {
			return "", 1, err
		}
	}
	if opts.JSON {
		payload, _ := jsonString(map[string]any{"baseline": baseline, "selection": selection, "results": results})
		if survived {
			return payload + "\n", 3, nil
		}
		return payload + "\n", 0, nil
	}
	text := runReport(analysis.RelativeFile, baseline, diagnostics, selection.Uncovered, results)
	if survived {
		return text, 3, nil
	}
	return text, 0, nil
}

func formatBaselineFailure(baseline runResult) string {
	lines := []string{"Baseline tests failed."}
	if trim(baseline.Output) != "" {
		lines = append(lines, trim(baseline.Output))
	}
	return strings.Join(lines, "\n") + "\n"
}

func maxInt(left, right int) int {
	if left > right {
		return left
	}
	return right
}

func maxInt64(left, right int64) int64 {
	if left > right {
		return left
	}
	return right
}
