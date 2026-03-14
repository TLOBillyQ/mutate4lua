package runtime

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
	goruntime "runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type RunResult struct {
	ExitCode   int    `json:"exit_code"`
	TimedOut   bool   `json:"timed_out"`
	DurationMS int64  `json:"duration_ms"`
	Output     string `json:"output"`
}

type JobResult struct {
	SiteIndex   int    `json:"site_index"`
	Line        int    `json:"line"`
	Description string `json:"description"`
	Killed      bool   `json:"killed"`
	TimedOut    bool   `json:"timed_out"`
	DurationMS  int64  `json:"duration_ms"`
	JobWallMS   int64  `json:"job_wall_ms"`
	ExitCode    int    `json:"exit_code"`
}

type BaselineCache struct {
	DurationMS       int64    `json:"duration_ms"`
	SuiteFingerprint string   `json:"suite_fingerprint"`
	Suites           []string `json:"suites,omitempty"`
}

type MutationJob struct {
	SiteIndex     int
	Line          int
	Description   string
	MutatedSource string
}

func NormalizeNewlines(value string) string {
	return strings.ReplaceAll(value, "\r\n", "\n")
}

func NormalizePath(value string) string {
	return filepath.ToSlash(value)
}

func NormalizeRelativePath(value string) string {
	normalized := NormalizePath(value)
	for strings.HasPrefix(normalized, "./") {
		normalized = strings.TrimPrefix(normalized, "./")
	}
	normalized = strings.ReplaceAll(normalized, "//", "/")
	if normalized == "" {
		return "."
	}
	return normalized
}

func Trim(value string) string {
	return strings.TrimSpace(value)
}

func SplitLines(value string) []string {
	value = NormalizeNewlines(value)
	if value == "" {
		return []string{""}
	}
	return strings.Split(strings.TrimSuffix(value, "\n"), "\n")
}

func FNV1a64Hex(text string) string {
	hash := fnv.New64a()
	_, _ = io.WriteString(hash, text)
	return fmt.Sprintf("%016x", hash.Sum64())
}

func ReadFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func WriteFile(path, content string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(content), 0o644)
}

func ReadJSONFile(path string, out any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, out)
}

func WriteJSONFile(path string, value any) error {
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

func FileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func CommandString(args []string) string {
	quoted := make([]string, 0, len(args))
	for _, arg := range args {
		quoted = append(quoted, ShellQuote(arg))
	}
	return strings.Join(quoted, " ")
}

func ShellQuote(value string) string {
	if goruntime.GOOS == "windows" {
		return fmt.Sprintf("\"%s\"", strings.ReplaceAll(value, "\"", "\"\""))
	}
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func RunCommand(cwd string, args []string, timeoutSeconds int, shell bool) RunResult {
	return RunCommandWithInput(cwd, args, timeoutSeconds, shell, "")
}

func RunCommandWithInput(cwd string, args []string, timeoutSeconds int, shell bool, stdinPath string) RunResult {
	started := NowMillis()
	ctx := context.Background()
	cancel := func() {}
	if timeoutSeconds > 0 {
		ctx, cancel = context.WithTimeout(context.Background(), time.Duration(timeoutSeconds)*time.Second)
	}
	defer cancel()

	var cmd *exec.Cmd
	if shell {
		command := strings.Join(args, " ")
		if goruntime.GOOS == "windows" {
			cmd = exec.CommandContext(ctx, "cmd.exe", "/d", "/s", "/c", command)
		} else {
			cmd = exec.CommandContext(ctx, "sh", "-lc", command)
		}
	} else {
		if len(args) == 0 {
			return RunResult{ExitCode: 1, Output: "missing command"}
		}
		cmd = exec.CommandContext(ctx, args[0], args[1:]...)
	}
	if cwd != "" {
		cmd.Dir = cwd
	}
	if stdinPath != "" {
		handle, err := os.Open(stdinPath)
		if err != nil {
			return RunResult{ExitCode: 1, Output: err.Error()}
		}
		defer handle.Close()
		cmd.Stdin = handle
	}

	output, err := cmd.CombinedOutput()
	duration := NowMillis() - started
	result := RunResult{
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

func NowMillis() int64 {
	return time.Now().UnixMilli()
}

func Itoa(value int) string {
	return strconv.Itoa(value)
}

func JoinStrings(values []string, delimiter string) string {
	return strings.Join(values, delimiter)
}

func DedupeStrings(values []string) []string {
	seen := map[string]bool{}
	result := []string{}
	for _, value := range values {
		if !seen[value] {
			seen[value] = true
			result = append(result, value)
		}
	}
	return result
}

func LastIndexByte(value string, needle byte) int {
	return strings.LastIndexByte(value, needle)
}

func JSONString(value any) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func CollectGitFiles(root string) ([]string, error) {
	cmd := exec.Command("git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "--", "*.lua", "*.rockspec")
	output, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	files := []string{}
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	for scanner.Scan() {
		line := NormalizeRelativePath(scanner.Text())
		if line == "" || strings.HasPrefix(line, ".mutate4lua/") {
			continue
		}
		files = append(files, line)
	}
	sort.Strings(files)
	return files, nil
}

func CopyProject(sourceRoot, destinationRoot string) error {
	return filepath.WalkDir(sourceRoot, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(sourceRoot, path)
		if err != nil {
			return err
		}
		rel = NormalizeRelativePath(rel)
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

func ResetWorkspace(root string) error {
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

func RunMutationBatch(projectRoot, targetFile string, commandArgs []string, commandShell bool, timeoutSeconds int, jobs []MutationJob, workerCount int) ([]JobResult, error) {
	if workerCount < 1 {
		workerCount = 1
	}
	if workerCount > len(jobs) && len(jobs) > 0 {
		workerCount = len(jobs)
	}
	workerRoot := filepath.Join(projectRoot, ".mutate4lua", "cache", "workers")
	_ = os.MkdirAll(workerRoot, 0o755)
	batches := partitionJobs(jobs, workerCount)
	results := make([]JobResult, 0, len(jobs))
	var mu sync.Mutex
	var firstErr error
	var wg sync.WaitGroup
	for _, batch := range batches {
		batch := batch
		wg.Add(1)
		go func() {
			defer wg.Done()
			sandbox, err := os.MkdirTemp(workerRoot, "mutatecore-")
			if err != nil {
				mu.Lock()
				if firstErr == nil {
					firstErr = err
				}
				mu.Unlock()
				return
			}
			defer os.RemoveAll(sandbox)
			if err := CopyProject(projectRoot, sandbox); err != nil {
				mu.Lock()
				if firstErr == nil {
					firstErr = err
				}
				mu.Unlock()
				return
			}
			localResults := []JobResult{}
			for _, job := range batch {
				_ = ResetWorkspace(sandbox)
				if err := WriteFile(filepath.Join(sandbox, targetFile), job.MutatedSource); err != nil {
					mu.Lock()
					if firstErr == nil {
						firstErr = err
					}
					mu.Unlock()
					return
				}
				started := NowMillis()
				result := RunCommand(sandbox, commandArgs, timeoutSeconds, commandShell)
				localResults = append(localResults, JobResult{
					SiteIndex:   job.SiteIndex,
					Line:        job.Line,
					Description: job.Description,
					Killed:      result.TimedOut || result.ExitCode != 0,
					TimedOut:    result.TimedOut,
					DurationMS:  result.DurationMS,
					JobWallMS:   NowMillis() - started,
					ExitCode:    result.ExitCode,
				})
			}
			mu.Lock()
			results = append(results, localResults...)
			mu.Unlock()
		}()
	}
	wg.Wait()
	sort.Slice(results, func(i, j int) bool { return results[i].SiteIndex < results[j].SiteIndex })
	return results, firstErr
}

func partitionJobs(jobs []MutationJob, workerCount int) [][]MutationJob {
	if workerCount < 1 {
		workerCount = 1
	}
	buckets := make([][]MutationJob, workerCount)
	for index, job := range jobs {
		bucket := index % workerCount
		buckets[bucket] = append(buckets[bucket], job)
	}
	result := [][]MutationJob{}
	for _, bucket := range buckets {
		if len(bucket) > 0 {
			result = append(result, bucket)
		}
	}
	return result
}

func MaxInt(left, right int) int {
	if left > right {
		return left
	}
	return right
}

func MaxInt64(left, right int64) int64 {
	if left > right {
		return left
	}
	return right
}
