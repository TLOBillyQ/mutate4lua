package main

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"sort"
	"strings"
)

func driverPath(projectRoot string) string {
	return filepath.Join(projectRoot, "scripts", "quality", "mutate_monopoly_driver.lua")
}

func listSuites(projectRoot, lane, mode string) ([]string, error) {
	args := []string{"lua", driverPath(projectRoot), "--lane", lane, "--list-suites", "--json"}
	if mode != "" {
		args = append(args, "--mode", mode)
	}
	result := runCommand(projectRoot, args, 0, false)
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

func readCoverageLines(path string) (map[string]bool, error) {
	lines := map[string]bool{}
	if !fileExists(path) {
		return lines, nil
	}
	content, err := readFile(path)
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(normalizeNewlines(content), "\n") {
		line = trim(line)
		if line == "" {
			continue
		}
		idx := lastIndexByte(line, ':')
		if idx >= 0 {
			lines[normalizeRelativePath(line[:idx])+":"+line[idx+1:]] = true
		} else {
			lines[normalizeRelativePath(line)] = true
		}
	}
	return lines, nil
}

func writeSuiteListFile(path string, suites []string) error {
	return writeFile(path, strings.Join(suites, "\n")+"\n")
}

func buildDefaultDriverCommand(projectRoot, lane, mode, targetFile, projectHash string, coverageFile string, suites []string, quiet bool) ([]string, string, error) {
	args := []string{"lua", driverPath(projectRoot), "--lane", lane}
	if mode != "" {
		args = append(args, "--mode", mode)
	}
	if targetFile != "" {
		args = append(args, "--target-file", targetFile)
	}
	if projectHash != "" {
		args = append(args, "--project-hash", projectHash)
	}
	if coverageFile != "" {
		args = append(args, "--coverage-file", coverageFile)
	} else {
		args = append(args, "--no-coverage")
	}
	suiteListFile := ""
	if len(suites) > 0 {
		suiteListFile = filepath.Join(projectRoot, ".mutate4lua", "tmp", fnv1a64Hex(strings.Join(suites, "\x00"))+".suites")
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
