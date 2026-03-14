package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

func suiteIndexPath(projectRoot, lane, mode, projectHash string) string {
	modePart := mode
	if modePart == "" {
		modePart = "default"
	}
	return filepath.Join(projectRoot, ".mutate4lua", "index", lane, modePart+"--"+projectHash+".json")
}

func baselineCachePath(projectRoot, key string) string {
	return filepath.Join(projectRoot, ".mutate4lua", "cache", "baseline", key+".json")
}

func suiteFingerprint(suites []string) string {
	copied := append([]string{}, suites...)
	sort.Strings(copied)
	return fnv1a64Hex(joinStrings(copied, "\x00"))
}

func loadSuiteIndex(projectRoot, lane, mode, projectHash string) (*suiteIndex, error) {
	path := suiteIndexPath(projectRoot, lane, mode, projectHash)
	if !fileExists(path) {
		return nil, nil
	}
	var index suiteIndex
	if err := readJSONFile(path, &index); err != nil {
		return nil, err
	}
	return &index, nil
}

func selectSuitesForTarget(index *suiteIndex, targetFile string) []string {
	if index == nil {
		return nil
	}
	normalized := normalizeRelativePath(targetFile)
	selected := []string{}
	for suite, files := range index.Suites {
		for _, file := range files {
			if normalizeRelativePath(file) == normalized {
				selected = append(selected, suite)
				break
			}
		}
	}
	sort.Strings(selected)
	return selected
}

func commandSuiteSelection(projectRoot, lane, mode, projectHash, targetFile string) ([]string, error) {
	if lane != "behavior" {
		return nil, nil
	}
	index, err := loadSuiteIndex(projectRoot, lane, mode, projectHash)
	if err != nil || index == nil {
		return nil, err
	}
	selected := selectSuitesForTarget(index, targetFile)
	if len(selected) == 0 {
		return nil, nil
	}
	return selected, nil
}

func runIndexSuites(projectRoot, lane, mode string, jsonOutput bool) (string, int, error) {
	if lane != "behavior" {
		return "index-suites only supports behavior lane\n", 1, nil
	}
	files, err := collectGitFiles(projectRoot)
	if err != nil {
		return "", 1, err
	}
	projectHashValue := fnv1a64Hex(joinStrings(files, "\n"))
	suites, err := listSuites(projectRoot, lane, mode)
	if err != nil {
		return "", 1, err
	}
	index := suiteIndex{Lane: lane, Mode: mode, ProjectHash: projectHashValue, Suites: map[string][]string{}}
	for _, suite := range suites {
		coverageFile := filepath.Join(projectRoot, ".mutate4lua", "tmp", fnv1a64Hex(suite)+".coverage")
		args := []string{"lua", driverPath(projectRoot), "--lane", lane, "--coverage-file", coverageFile, "--suite-module", suite, "--quiet"}
		if mode != "" {
			args = append(args, "--mode", mode)
		}
		result := runCommand(projectRoot, args, 0, false)
		if result.ExitCode != 0 {
			return "", 1, fmt.Errorf("index suite %s failed: %s", suite, result.Output)
		}
		coverageLines, err := readCoverageLines(coverageFile)
		_ = os.Remove(coverageFile)
		if err != nil {
			return "", 1, err
		}
		files := []string{}
		for line := range coverageLines {
			file := line
			if idx := lastIndexByte(line, ':'); idx >= 0 {
				file = line[:idx]
			}
			files = append(files, normalizeRelativePath(file))
		}
		sort.Strings(files)
		index.Suites[suite] = dedupeStrings(files)
	}
	path := suiteIndexPath(projectRoot, lane, mode, projectHashValue)
	if err := writeJSONFile(path, index); err != nil {
		return "", 1, err
	}
	if jsonOutput {
		payload, _ := jsonString(map[string]any{"ok": true, "path": normalizePath(path), "project_hash": projectHashValue, "suite_count": len(index.Suites)})
		return payload + "\n", 0, nil
	}
	return fmt.Sprintf("Indexed %d suites for %s (%s)\n", len(index.Suites), lane, projectHashValue), 0, nil
}
