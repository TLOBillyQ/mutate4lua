package driver

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func requireCommand(t *testing.T, name string) {
	t.Helper()
	if _, err := exec.LookPath(name); err != nil {
		t.Skipf("%s not found: %v", name, err)
	}
}

func runCommand(t *testing.T, dir string, name string, args ...string) {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%s %v failed: %v\n%s", name, args, err, string(output))
	}
}

func writeFile(t *testing.T, path string, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func loadIndexFromOutput(t *testing.T, output string) SuiteIndex {
	t.Helper()
	var payload struct {
		Path string `json:"path"`
	}
	if err := json.Unmarshal([]byte(output), &payload); err != nil {
		t.Fatalf("decode output payload: %v\n%s", err, output)
	}
	if payload.Path == "" {
		t.Fatalf("missing index path in output: %s", output)
	}
	content, err := os.ReadFile(payload.Path)
	if err != nil {
		t.Fatalf("read index %s: %v", payload.Path, err)
	}
	var index SuiteIndex
	if err := json.Unmarshal(content, &index); err != nil {
		t.Fatalf("decode index: %v", err)
	}
	return index
}

func TestRunIndexSuitesUsesSingleProcessSuiteMapWhenAvailable(t *testing.T) {
	requireCommand(t, "lua")
	requireCommand(t, "git")

	root := t.TempDir()
	runCommand(t, root, "git", "init")
	writeFile(t, filepath.Join(root, "src", "probe.lua"), "return {}\n")
	driverPath := filepath.Join(root, "driver.lua")
	writeFile(t, driverPath, `
local function has(flag)
  for _, value in ipairs(arg or {}) do
    if value == flag then
      return true
    end
  end
  return false
end

if has("--emit-suite-file-map-json") then
  io.write('{"lane":"behavior","mode":"dev","suite_files":{"suite.alpha":["src/a.lua","src/b.lua"],"suite.beta":["src/c.lua"]}}')
  os.exit(0)
end

io.stderr:write("unexpected fallback path\n")
os.exit(9)
`)

	output, exitCode, err := RunIndexSuites(root, driverPath, "behavior", "dev", true)
	if err != nil {
		t.Fatalf("RunIndexSuites returned error: %v", err)
	}
	if exitCode != 0 {
		t.Fatalf("RunIndexSuites exit code = %d, output=%s", exitCode, output)
	}

	index := loadIndexFromOutput(t, output)
	if len(index.Suites) != 2 {
		t.Fatalf("expected 2 indexed suites, got %d", len(index.Suites))
	}
	if got := index.Suites["suite.alpha"]; len(got) != 2 || got[0] != "src/a.lua" || got[1] != "src/b.lua" {
		t.Fatalf("unexpected suite.alpha files: %#v", got)
	}
	if got := index.Suites["suite.beta"]; len(got) != 1 || got[0] != "src/c.lua" {
		t.Fatalf("unexpected suite.beta files: %#v", got)
	}
}

func TestRunIndexSuitesFallsBackWhenSuiteMapPayloadIsInvalid(t *testing.T) {
	requireCommand(t, "lua")
	requireCommand(t, "git")

	root := t.TempDir()
	runCommand(t, root, "git", "init")
	writeFile(t, filepath.Join(root, "src", "probe.lua"), "return {}\n")
	if err := os.MkdirAll(filepath.Join(root, ".mutate4lua", "tmp"), 0o755); err != nil {
		t.Fatalf("mkdir tmp: %v", err)
	}

	driverPath := filepath.Join(root, "driver.lua")
	writeFile(t, driverPath, `
local function has(flag)
  for _, value in ipairs(arg or {}) do
    if value == flag then
      return true
    end
  end
  return false
end

local function value_after(flag)
  for index, value in ipairs(arg or {}) do
    if value == flag then
      return arg[index + 1]
    end
  end
  return nil
end

if has("--emit-suite-file-map-json") then
  io.write("{not-json}")
  os.exit(0)
end

if has("--list-suites") then
  io.write('["suite.alpha","suite.beta"]')
  os.exit(0)
end

local suite = value_after("--suite-module")
local coverage = value_after("--coverage-file")
local handle = assert(io.open(coverage, "wb"))
if suite == "suite.alpha" then
  handle:write("src/a.lua:1\nsrc/b.lua:2\n")
elseif suite == "suite.beta" then
  handle:write("src/c.lua:3\n")
else
  handle:close()
  io.stderr:write("unexpected suite\n")
  os.exit(7)
end
handle:close()
os.exit(0)
`)

	output, exitCode, err := RunIndexSuites(root, driverPath, "behavior", "dev", true)
	if err != nil {
		t.Fatalf("RunIndexSuites returned error: %v", err)
	}
	if exitCode != 0 {
		t.Fatalf("RunIndexSuites exit code = %d, output=%s", exitCode, output)
	}

	index := loadIndexFromOutput(t, output)
	if got := index.Suites["suite.alpha"]; len(got) != 2 || got[0] != "src/a.lua" || got[1] != "src/b.lua" {
		t.Fatalf("unexpected fallback suite.alpha files: %#v", got)
	}
	if got := index.Suites["suite.beta"]; len(got) != 1 || got[0] != "src/c.lua" {
		t.Fatalf("unexpected fallback suite.beta files: %#v", got)
	}
}

func TestRunIndexSuitesFallsBackWhenSuiteMapPayloadIsMissingSuiteFiles(t *testing.T) {
	requireCommand(t, "lua")
	requireCommand(t, "git")

	root := t.TempDir()
	runCommand(t, root, "git", "init")
	writeFile(t, filepath.Join(root, "src", "probe.lua"), "return {}\n")
	if err := os.MkdirAll(filepath.Join(root, ".mutate4lua", "tmp"), 0o755); err != nil {
		t.Fatalf("mkdir tmp: %v", err)
	}

	driverPath := filepath.Join(root, "driver.lua")
	writeFile(t, driverPath, `
local function has(flag)
  for _, value in ipairs(arg or {}) do
    if value == flag then
      return true
    end
  end
  return false
end

local function value_after(flag)
  for index, value in ipairs(arg or {}) do
    if value == flag then
      return arg[index + 1]
    end
  end
  return nil
end

if has("--emit-suite-file-map-json") then
  io.write('{"lane":"behavior","mode":"dev"}')
  os.exit(0)
end

if has("--list-suites") then
  io.write('["suite.alpha"]')
  os.exit(0)
end

local coverage = value_after("--coverage-file")
local handle = assert(io.open(coverage, "wb"))
handle:write("src/a.lua:1\n")
handle:close()
os.exit(0)
`)

	output, exitCode, err := RunIndexSuites(root, driverPath, "behavior", "dev", true)
	if err != nil {
		t.Fatalf("RunIndexSuites returned error: %v", err)
	}
	if exitCode != 0 {
		t.Fatalf("RunIndexSuites exit code = %d, output=%s", exitCode, output)
	}

	index := loadIndexFromOutput(t, output)
	if got := index.Suites["suite.alpha"]; len(got) != 1 || got[0] != "src/a.lua" {
		t.Fatalf("unexpected missing-suite-files fallback files: %#v", got)
	}
}

func TestRunIndexSuitesFallsBackWhenSuiteMapCommandFails(t *testing.T) {
	requireCommand(t, "lua")
	requireCommand(t, "git")

	root := t.TempDir()
	runCommand(t, root, "git", "init")
	writeFile(t, filepath.Join(root, "src", "probe.lua"), "return {}\n")
	if err := os.MkdirAll(filepath.Join(root, ".mutate4lua", "tmp"), 0o755); err != nil {
		t.Fatalf("mkdir tmp: %v", err)
	}

	driverPath := filepath.Join(root, "driver.lua")
	writeFile(t, driverPath, `
local function has(flag)
  for _, value in ipairs(arg or {}) do
    if value == flag then
      return true
    end
  end
  return false
end

local function value_after(flag)
  for index, value in ipairs(arg or {}) do
    if value == flag then
      return arg[index + 1]
    end
  end
  return nil
end

if has("--emit-suite-file-map-json") then
  io.stderr:write("unsupported\n")
  os.exit(1)
end

if has("--list-suites") then
  io.write('["suite.alpha"]')
  os.exit(0)
end

local coverage = value_after("--coverage-file")
local handle = assert(io.open(coverage, "wb"))
handle:write("src/a.lua:1\n")
handle:close()
os.exit(0)
`)

	output, exitCode, err := RunIndexSuites(root, driverPath, "behavior", "dev", true)
	if err != nil {
		t.Fatalf("RunIndexSuites returned error: %v", err)
	}
	if exitCode != 0 {
		t.Fatalf("RunIndexSuites exit code = %d, output=%s", exitCode, output)
	}

	index := loadIndexFromOutput(t, output)
	if got := index.Suites["suite.alpha"]; len(got) != 1 || got[0] != "src/a.lua" {
		t.Fatalf("unexpected non-zero fallback files: %#v", got)
	}
}
