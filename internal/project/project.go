package project

import (
	"os"
	"path/filepath"
	goruntime "runtime"
	"strings"

	"github.com/billyq/mutate4lua/internal/runtime"
)

func FindRoot(workspaceRoot, targetFile string) string {
	workspaceRoot, _ = filepath.Abs(workspaceRoot)
	targetFile, _ = filepath.Abs(targetFile)
	cursor := filepath.Dir(targetFile)
	for {
		if hasRootMarker(cursor) {
			return cursor
		}
		if SamePath(cursor, workspaceRoot) || cursor == string(filepath.Separator) {
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

func SamePath(left, right string) bool {
	l := runtime.NormalizePath(left)
	r := runtime.NormalizePath(right)
	if goruntime.GOOS == "windows" {
		l = strings.ToLower(l)
		r = strings.ToLower(r)
	}
	return l == r
}

func hasRootMarker(path string) bool {
	if runtime.FileExists(filepath.Join(path, ".git")) {
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

func RelativeFile(projectRoot, path string) string {
	rel, err := filepath.Rel(projectRoot, path)
	if err != nil {
		return runtime.NormalizeRelativePath(path)
	}
	return runtime.NormalizeRelativePath(rel)
}

func ProjectHash(projectRoot, targetFile, strippedSource string) (string, error) {
	files, err := runtime.CollectGitFiles(projectRoot)
	if err != nil {
		return "", err
	}
	absoluteTarget, _ := filepath.Abs(targetFile)
	parts := []string{}
	for _, rel := range files {
		abs := filepath.Join(projectRoot, rel)
		content, err := runtime.ReadFile(abs)
		if err != nil {
			if os.IsNotExist(err) {
				content = ""
			} else {
				return "", err
			}
		}
		if SamePath(abs, absoluteTarget) && strings.HasSuffix(rel, ".lua") {
			content = strippedSource
		} else if strings.HasSuffix(rel, ".lua") {
			content = stripEmbeddedManifest(content)
		}
		parts = append(parts, rel, "\n", runtime.NormalizeNewlines(content), "\n\x00\n")
	}
	return runtime.FNV1a64Hex(strings.Join(parts, "")), nil
}

func ProjectHashForIndex(projectRoot string) (string, error) {
	files, err := runtime.CollectGitFiles(projectRoot)
	if err != nil {
		return "", err
	}
	parts := []string{}
	for _, rel := range files {
		abs := filepath.Join(projectRoot, rel)
		content, err := runtime.ReadFile(abs)
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
		parts = append(parts, rel, "\n", runtime.NormalizeNewlines(content), "\n\x00\n")
	}
	return runtime.FNV1a64Hex(strings.Join(parts, "")), nil
}

func stripEmbeddedManifest(source string) string {
	source = runtime.NormalizeNewlines(source)
	marker := strings.Index(source, "--[[ mutate4lua-manifest\n")
	if marker < 0 {
		return source
	}
	tail := runtime.Trim(source[marker:])
	if !strings.HasSuffix(tail, "]]") {
		return source
	}
	stripped := runtime.Trim(source[:marker])
	if stripped == "" {
		return ""
	}
	return stripped + "\n"
}
