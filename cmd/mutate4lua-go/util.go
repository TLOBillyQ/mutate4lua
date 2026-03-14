package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

func normalizeNewlines(value string) string {
	return strings.ReplaceAll(value, "\r\n", "\n")
}

func normalizePath(value string) string {
	return filepath.ToSlash(value)
}

func normalizeRelativePath(value string) string {
	normalized := normalizePath(value)
	for strings.HasPrefix(normalized, "./") {
		normalized = strings.TrimPrefix(normalized, "./")
	}
	normalized = strings.ReplaceAll(normalized, "//", "/")
	if normalized == "" {
		return "."
	}
	return normalized
}

func trim(value string) string {
	return strings.TrimSpace(value)
}

func splitLines(value string) []string {
	value = normalizeNewlines(value)
	if value == "" {
		return []string{""}
	}
	return strings.Split(strings.TrimSuffix(value, "\n"), "\n")
}

func fnv1a64Hex(text string) string {
	hash := fnv.New64a()
	_, _ = io.WriteString(hash, text)
	return fmt.Sprintf("%016x", hash.Sum64())
}

func readFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func writeFile(path, content string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(content), 0o644)
}

func readJSONFile(path string, out any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, out)
}

func writeJSONFile(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return os.WriteFile(path, data, 0o644)
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func commandString(args []string) string {
	quoted := make([]string, 0, len(args))
	for _, arg := range args {
		quoted = append(quoted, shellQuote(arg))
	}
	return strings.Join(quoted, " ")
}

func shellQuote(value string) string {
	if runtime.GOOS == "windows" {
		return fmt.Sprintf("\"%s\"", strings.ReplaceAll(value, "\"", "\"\""))
	}
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func runCommand(cwd string, args []string, timeoutSeconds int, shell bool) runResult {
	return runCommandWithInput(cwd, args, timeoutSeconds, shell, "")
}

func runCommandWithInput(cwd string, args []string, timeoutSeconds int, shell bool, stdinPath string) runResult {
	started := nowMillis()
	ctx := context.Background()
	cancel := func() {}
	if timeoutSeconds > 0 {
		ctx, cancel = context.WithTimeout(context.Background(), time.Duration(timeoutSeconds)*time.Second)
	}
	defer cancel()
	var cmd *exec.Cmd
	if shell {
		command := strings.Join(args, " ")
		if runtime.GOOS == "windows" {
			cmd = exec.CommandContext(ctx, "cmd.exe", "/d", "/s", "/c", command)
		} else {
			cmd = exec.CommandContext(ctx, "sh", "-lc", command)
		}
	} else {
		if len(args) == 0 {
			return runResult{ExitCode: 1, Output: "missing command"}
		}
		cmd = exec.CommandContext(ctx, args[0], args[1:]...)
	}
	if cwd != "" {
		cmd.Dir = cwd
	}
	if stdinPath != "" {
		handle, err := os.Open(stdinPath)
		if err != nil {
			return runResult{ExitCode: 1, Output: err.Error()}
		}
		defer handle.Close()
		cmd.Stdin = handle
	}
	output, err := cmd.CombinedOutput()
	duration := nowMillis() - started
	result := runResult{
		ExitCode:   0,
		TimedOut:   false,
		DurationMS: duration,
		Output:     strings.TrimSpace(string(output)),
	}
	if err == nil {
		return result
	}
	if ctx.Err() == context.DeadlineExceeded {
		result.ExitCode = 124
		result.TimedOut = true
		return result
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		result.ExitCode = exitErr.ExitCode()
		return result
	}
	result.ExitCode = 1
	if result.Output == "" {
		result.Output = err.Error()
	}
	return result
}

func nowMillis() int64 {
	return unixNowMillis()
}

func collectGitFiles(root string) ([]string, error) {
	cmd := exec.Command("git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "--", "*.lua", "*.rockspec")
	output, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	files := []string{}
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	for scanner.Scan() {
		line := normalizeRelativePath(scanner.Text())
		if line == "" || strings.HasPrefix(line, ".mutate4lua/") {
			continue
		}
		files = append(files, line)
	}
	sort.Strings(files)
	return files, nil
}

func copyProject(sourceRoot, destinationRoot string) error {
	return filepath.WalkDir(sourceRoot, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(sourceRoot, path)
		if err != nil {
			return err
		}
		rel = normalizeRelativePath(rel)
		if rel == "." {
			return os.MkdirAll(destinationRoot, 0o755)
		}
		base := filepath.Base(path)
		if shouldIgnoreName(base) {
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		target := filepath.Join(destinationRoot, rel)
		if entry.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		return copyFile(path, target, info.Mode())
	})
}

func copyFile(sourcePath, destinationPath string, mode fs.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(destinationPath), 0o755); err != nil {
		return err
	}
	source, err := os.Open(sourcePath)
	if err != nil {
		return err
	}
	defer source.Close()
	destination, err := os.Create(destinationPath)
	if err != nil {
		return err
	}
	if _, err := io.Copy(destination, source); err != nil {
		destination.Close()
		return err
	}
	if err := destination.Close(); err != nil {
		return err
	}
	return os.Chmod(destinationPath, mode)
}

func shouldIgnoreName(name string) bool {
	switch name {
	case ".git", ".mutate4lua", "__pycache__", ".pytest_cache":
		return true
	}
	return strings.HasPrefix(name, ".coverage") || strings.HasPrefix(name, ".luacov")
}

func resetWorkspace(root string) error {
	names := []string{".mutate4lua", "__pycache__", ".pytest_cache", ".arch_view"}
	for _, name := range names {
		_ = os.RemoveAll(filepath.Join(root, name))
	}
	entries, err := os.ReadDir(root)
	if err == nil {
		for _, entry := range entries {
			name := entry.Name()
			if strings.HasPrefix(name, ".coverage") || strings.HasPrefix(name, ".luacov") {
				_ = os.RemoveAll(filepath.Join(root, name))
			}
		}
	}
	return nil
}
