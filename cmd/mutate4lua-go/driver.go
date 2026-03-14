package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func driverPath(projectRoot, driverScript string) string {
	if trim(driverScript) != "" {
		if filepath.IsAbs(driverScript) {
			return driverScript
		}
		return filepath.Join(projectRoot, driverScript)
	}
	executablePath, err := os.Executable()
	if err == nil && trim(executablePath) != "" {
		return filepath.Join(filepath.Dir(filepath.Dir(executablePath)), "scripts", "test_driver.lua")
	}
	return filepath.Join(projectRoot, "scripts", "test_driver.lua")
}

func driverToolRoot(path string) string {
	return filepath.Dir(filepath.Dir(path))
}

func listSuites(projectRoot, driverScript, lane, mode string) ([]string, error) {
	if trim(driverScript) == "" {
		return nil, errors.New("index-suites requires --driver-script")
	}
	args := []string{"lua", driverPath(projectRoot, driverScript), "--lane", lane, "--list-suites", "--json"}
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

func buildDefaultDriverCommand(projectRoot, driverScript, lane, mode, targetFile, projectHash string, coverageFile string, suites []string, quiet bool) ([]string, string, error) {
	resolvedDriverPath := driverPath(projectRoot, driverScript)
	args := []string{"lua", resolvedDriverPath}
	if trim(driverScript) != "" {
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
		args = append(args, "--root", projectRoot, "--tool-root", driverToolRoot(resolvedDriverPath))
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
