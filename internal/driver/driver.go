package driver

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	mutproject "github.com/billyq/mutate4lua/internal/project"
	mutruntime "github.com/billyq/mutate4lua/internal/runtime"
)

type SuiteIndex struct {
	Lane        string              `json:"lane"`
	Mode        string              `json:"mode"`
	ProjectHash string              `json:"project_hash"`
	Suites      map[string][]string `json:"suites"`
}

type suiteFileMapPayload struct {
	Lane       string              `json:"lane"`
	Mode       string              `json:"mode"`
	SuiteFiles map[string][]string `json:"suite_files"`
}

func Path(projectRoot, driverScript string) string {
	if mutruntime.Trim(driverScript) != "" {
		if filepath.IsAbs(driverScript) {
			return driverScript
		}
		return filepath.Join(projectRoot, driverScript)
	}
	executablePath, err := os.Executable()
	if err == nil && mutruntime.Trim(executablePath) != "" {
		return filepath.Join(filepath.Dir(filepath.Dir(executablePath)), "lua", "mutate4lua", "driver", "default.lua")
	}
	return filepath.Join(projectRoot, "lua", "mutate4lua", "driver", "default.lua")
}

func ToolRoot(path string) string {
	return filepath.Dir(filepath.Dir(filepath.Dir(filepath.Dir(path))))
}

func ListSuites(projectRoot, driverScript, lane, mode string) ([]string, error) {
	if mutruntime.Trim(driverScript) == "" {
		return nil, errors.New("index-suites requires --driver-script")
	}
	args := []string{"lua", Path(projectRoot, driverScript), "--lane", lane, "--list-suites", "--json"}
	if mode != "" {
		args = append(args, "--mode", mode)
	}
	result := mutruntime.RunCommand(projectRoot, args, 0, false)
	if result.ExitCode != 0 {
		return nil, errors.New(result.Output)
	}
	var suites []string
	if err := json.Unmarshal([]byte(result.Output), &suites); err != nil {
		return nil, err
	}
	sort.Strings(suites)
	return suites, nil
}

func ReadCoverageLines(path string) (map[string]bool, error) {
	lines := map[string]bool{}
	if !mutruntime.FileExists(path) {
		return lines, nil
	}
	content, err := mutruntime.ReadFile(path)
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(mutruntime.NormalizeNewlines(content), "\n") {
		line = mutruntime.Trim(line)
		if line == "" {
			continue
		}
		idx := mutruntime.LastIndexByte(line, ':')
		if idx >= 0 {
			lines[mutruntime.NormalizeRelativePath(line[:idx])+":"+line[idx+1:]] = true
		} else {
			lines[mutruntime.NormalizeRelativePath(line)] = true
		}
	}
	return lines, nil
}

func writeSuiteListFile(path string, suites []string) error {
	return mutruntime.WriteFile(path, strings.Join(suites, "\n")+"\n")
}

func BuildDefaultDriverCommand(projectRoot, driverScript, lane, mode, targetFile, projectHash, coverageFile string, suites []string, quiet bool) ([]string, string, error) {
	resolvedDriverPath := Path(projectRoot, driverScript)
	args := []string{"lua", resolvedDriverPath}
	if mutruntime.Trim(driverScript) != "" {
		args = append(args, "--lane", lane)
		if mode != "" {
			args = append(args, "--mode", mode)
		}
		if targetFile != "" {
			args = append(args, "--target-file", targetFile)
		}
		if projectHash != "" {
			args = append(args, "--project-hash", projectHash)
		}
	} else {
		args = append(args, "--root", projectRoot, "--tool-root", ToolRoot(resolvedDriverPath))
	}
	if coverageFile != "" {
		args = append(args, "--coverage-file", coverageFile)
	} else {
		args = append(args, "--no-coverage")
	}
	suiteListFile := ""
	if len(suites) > 0 {
		suiteListFile = filepath.Join(projectRoot, ".mutate4lua", "tmp", mutruntime.FNV1a64Hex(strings.Join(suites, "\x00"))+".suites")
		if err := writeSuiteListFile(suiteListFile, suites); err != nil {
			return nil, "", err
		}
		args = append(args, "--suite-list-file", suiteListFile)
	}
	if quiet {
		args = append(args, "--quiet")
	}
	return args, suiteListFile, nil
}

func suiteIndexPath(projectRoot, lane, mode, projectHash string) string {
	modePart := mode
	if modePart == "" {
		modePart = "default"
	}
	return filepath.Join(projectRoot, ".mutate4lua", "index", lane, modePart+"--"+projectHash+".json")
}

func BaselineCachePath(projectRoot, key string) string {
	return filepath.Join(projectRoot, ".mutate4lua", "cache", "baseline", key+".json")
}

func SuiteFingerprint(suites []string) string {
	copied := append([]string{}, suites...)
	sort.Strings(copied)
	return mutruntime.FNV1a64Hex(mutruntime.JoinStrings(copied, "\x00"))
}

func loadSuiteIndex(projectRoot, lane, mode, projectHash string) (*SuiteIndex, error) {
	path := suiteIndexPath(projectRoot, lane, mode, projectHash)
	if !mutruntime.FileExists(path) {
		return nil, nil
	}
	var index SuiteIndex
	if err := mutruntime.ReadJSONFile(path, &index); err != nil {
		return nil, err
	}
	return &index, nil
}

func selectSuitesForTarget(index *SuiteIndex, targetFile string) []string {
	if index == nil {
		return nil
	}
	normalized := mutruntime.NormalizeRelativePath(targetFile)
	selected := []string{}
	for suite, files := range index.Suites {
		for _, file := range files {
			if mutruntime.NormalizeRelativePath(file) == normalized {
				selected = append(selected, suite)
				break
			}
		}
	}
	sort.Strings(selected)
	return selected
}

func suiteMapIndex(projectRoot, driverScript, lane, mode, projectHash string) (*SuiteIndex, error) {
	if mutruntime.Trim(driverScript) == "" {
		return nil, nil
	}

	args := []string{"lua", Path(projectRoot, driverScript), "--lane", lane, "--emit-suite-file-map-json", "--json"}
	if mode != "" {
		args = append(args, "--mode", mode)
	}
	result := mutruntime.RunCommand(projectRoot, args, 0, false)
	if result.ExitCode != 0 {
		return nil, nil
	}

	var payload suiteFileMapPayload
	if err := json.Unmarshal([]byte(result.Output), &payload); err != nil {
		return nil, nil
	}
	if payload.SuiteFiles == nil {
		return nil, nil
	}

	index := &SuiteIndex{
		Lane:        lane,
		Mode:        mode,
		ProjectHash: projectHash,
		Suites:      map[string][]string{},
	}
	for suite, files := range payload.SuiteFiles {
		normalized := []string{}
		for _, file := range files {
			normalized = append(normalized, mutruntime.NormalizeRelativePath(file))
		}
		sort.Strings(normalized)
		index.Suites[suite] = mutruntime.DedupeStrings(normalized)
	}
	return index, nil
}

func CommandSuiteSelection(projectRoot, driverScript, lane, mode, projectHash, targetFile string) ([]string, error) {
	if lane != "behavior" || mutruntime.Trim(driverScript) == "" {
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

func RunIndexSuites(projectRoot, driverScript, lane, mode string, jsonOutput bool) (string, int, error) {
	if mutruntime.Trim(driverScript) == "" {
		return "index-suites requires --driver-script\n", 1, nil
	}
	if lane != "behavior" {
		return "index-suites only supports behavior lane\n", 1, nil
	}
	files, err := mutruntime.CollectGitFiles(projectRoot)
	if err != nil {
		return "", 1, err
	}
	projectHashValue := mutruntime.FNV1a64Hex(mutruntime.JoinStrings(files, "\n"))
	index, err := suiteMapIndex(projectRoot, driverScript, lane, mode, projectHashValue)
	if err != nil {
		return "", 1, err
	}
	if index == nil {
		suites, listErr := ListSuites(projectRoot, driverScript, lane, mode)
		if listErr != nil {
			return "", 1, listErr
		}
		index = &SuiteIndex{Lane: lane, Mode: mode, ProjectHash: projectHashValue, Suites: map[string][]string{}}
		for _, suite := range suites {
			coverageFile := filepath.Join(projectRoot, ".mutate4lua", "tmp", mutruntime.FNV1a64Hex(suite)+".coverage")
			args := []string{"lua", Path(projectRoot, driverScript), "--lane", lane, "--coverage-file", coverageFile, "--suite-module", suite, "--quiet"}
			if mode != "" {
				args = append(args, "--mode", mode)
			}
			result := mutruntime.RunCommand(projectRoot, args, 0, false)
			if result.ExitCode != 0 {
				return "", 1, fmt.Errorf("index suite %s failed: %s", suite, result.Output)
			}
			coverageLines, readErr := ReadCoverageLines(coverageFile)
			_ = os.Remove(coverageFile)
			if readErr != nil {
				return "", 1, readErr
			}
			coveredFiles := []string{}
			for line := range coverageLines {
				file := line
				if idx := mutruntime.LastIndexByte(line, ':'); idx >= 0 {
					file = line[:idx]
				}
				coveredFiles = append(coveredFiles, mutruntime.NormalizeRelativePath(file))
			}
			sort.Strings(coveredFiles)
			index.Suites[suite] = mutruntime.DedupeStrings(coveredFiles)
		}
	}
	path := suiteIndexPath(projectRoot, lane, mode, projectHashValue)
	if err := mutruntime.WriteJSONFile(path, index); err != nil {
		return "", 1, err
	}
	if jsonOutput {
		payload, _ := mutruntime.JSONString(map[string]any{"ok": true, "path": mutruntime.NormalizePath(path), "project_hash": projectHashValue, "suite_count": len(index.Suites)})
		return payload + "\n", 0, nil
	}
	return fmt.Sprintf("Indexed %d suites for %s (%s)\n", len(index.Suites), lane, projectHashValue), 0, nil
}

func ProjectHashForIndex(projectRoot string) (string, error) {
	return mutproject.ProjectHashForIndex(projectRoot)
}
