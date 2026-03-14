package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

func findProjectRoot(workspaceRoot, targetFile string) string {
	workspaceRoot, _ = filepath.Abs(workspaceRoot)
	targetFile, _ = filepath.Abs(targetFile)
	cursor := filepath.Dir(targetFile)
	for {
		if hasRootMarker(cursor) {
			return cursor
		}
		if samePath(cursor, workspaceRoot) || cursor == string(filepath.Separator) {
			break
		}
		parent := filepath.Dir(cursor)
		if parent == cursor {
			break
		}
		cursor = parent
	}
	return workspaceRoot
}

func samePath(left, right string) bool {
	l := normalizePath(left)
	r := normalizePath(right)
	if runtime.GOOS == "windows" {
		l = strings.ToLower(l)
		r = strings.ToLower(r)
	}
	return l == r
}

func hasRootMarker(path string) bool {
	if fileExists(filepath.Join(path, ".git")) {
		return true
	}
	if matches, _ := filepath.Glob(filepath.Join(path, "*.rockspec")); len(matches) > 0 {
		return true
	}
	for _, name := range []string{"spec", "test", "tests"} {
		if info, err := os.Stat(filepath.Join(path, name)); err == nil && info.IsDir() {
			return true
		}
	}
	return false
}

func relativeFile(projectRoot, path string) string {
	rel, err := filepath.Rel(projectRoot, path)
	if err != nil {
		return normalizeRelativePath(path)
	}
	return normalizeRelativePath(rel)
}

func projectHash(projectRoot, targetFile, strippedSource string) (string, error) {
	files, err := collectGitFiles(projectRoot)
	if err != nil {
		return "", err
	}
	absoluteTarget, _ := filepath.Abs(targetFile)
	parts := []string{}
	for _, rel := range files {
		abs := filepath.Join(projectRoot, rel)
		content, err := readFile(abs)
		if err != nil {
			if os.IsNotExist(err) {
				content = ""
			} else {
				return "", err
			}
		}
		if samePath(abs, absoluteTarget) && strings.HasSuffix(rel, ".lua") {
			content = strippedSource
		} else if strings.HasSuffix(rel, ".lua") {
			content = stripEmbeddedManifest(content)
		}
		parts = append(parts, rel, "\n", normalizeNewlines(content), "\n\x00\n")
	}
	return fnv1a64Hex(strings.Join(parts, "")), nil
}

func projectHashForIndex(projectRoot string) (string, error) {
	files, err := collectGitFiles(projectRoot)
	if err != nil {
		return "", err
	}
	parts := []string{}
	for _, rel := range files {
		abs := filepath.Join(projectRoot, rel)
		content, err := readFile(abs)
		if err != nil {
			if os.IsNotExist(err) {
				content = ""
			} else {
				return "", err
			}
		}
		if strings.HasSuffix(rel, ".lua") {
			content = stripEmbeddedManifest(content)
		}
		parts = append(parts, rel, "\n", normalizeNewlines(content), "\n\x00\n")
	}
	return fnv1a64Hex(strings.Join(parts, "")), nil
}
