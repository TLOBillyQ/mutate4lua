package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

func parseLines(value string) ([]int, map[int]bool, error) {
	if trim(value) == "" {
		return nil, map[int]bool{}, nil
	}
	parts := strings.Split(value, ",")
	lines := []int{}
	lookup := map[int]bool{}
	for _, part := range parts {
		number, err := strconv.Atoi(strings.TrimSpace(part))
		if err != nil || number < 1 {
			return nil, nil, fmt.Errorf("--lines must be a positive integer")
		}
		if !lookup[number] {
			lookup[number] = true
			lines = append(lines, number)
		}
	}
	return lines, lookup, nil
}

func defaultMaxWorkers() int {
	workers := runtime.NumCPU() / 2
	if workers < 1 {
		return 1
	}
	return workers
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usageText())
		os.Exit(1)
	}
	switch os.Args[1] {
	case "scan", "mutate", "migrate-manifest":
		os.Exit(runCoreCommand(os.Args[1], os.Args[2:]))
	case "index-suites":
		os.Exit(runIndexCommand(os.Args[2:]))
	case "help", "--help", "-h":
		fmt.Print(usageText())
		os.Exit(0)
	default:
		fmt.Fprint(os.Stderr, usageText())
		os.Exit(1)
	}
}

func runCoreCommand(command string, argv []string) int {
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	target := flags.String("target", "", "target lua file")
	lane := flags.String("lane", "behavior", "lane")
	mode := flags.String("mode", "", "mode")
	driverScript := flags.String("driver-script", "", "driver script")
	linesFlag := flags.String("lines", "", "lines")
	sinceLastRun := flags.Bool("since-last-run", false, "since last run")
	mutateAll := flags.Bool("mutate-all", false, "mutate all")
	mutationWarning := flags.Int("mutation-warning", 50, "mutation warning")
	maxWorkers := flags.Int("max-workers", defaultMaxWorkers(), "max workers")
	timeoutFactor := flags.Int("timeout-factor", 10, "timeout factor")
	testCommand := flags.String("test-command", "", "test command")
	jsonOutput := flags.Bool("json", false, "json output")
	flags.SetOutput(os.Stderr)
	if err := flags.Parse(argv); err != nil {
		return 1
	}
	if *target == "" {
		fmt.Fprint(os.Stderr, usageText())
		return 1
	}
	lines, lookup, err := parseLines(*linesFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		return 1
	}
	cwd, _ := os.Getwd()
	workspaceRoot := cwd
	if workspaceRoot == "" {
		workspaceRoot = "."
	}
	output, code, err := runScanOrMutate(workspaceRoot, coreOptions{
		Target:          *target,
		Lane:            *lane,
		Mode:            *mode,
		DriverScript:    *driverScript,
		Scan:            command == "scan",
		UpdateManifest:  command == "migrate-manifest",
		SinceLastRun:    *sinceLastRun,
		MutateAll:       *mutateAll,
		Lines:           lines,
		LinesLookup:     lookup,
		MutationWarning: *mutationWarning,
		MaxWorkers:      *maxWorkers,
		TimeoutFactor:   *timeoutFactor,
		TestCommand:     *testCommand,
		JSON:            *jsonOutput,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		return 1
	}
	fmt.Print(output)
	return code
}

func runIndexCommand(argv []string) int {
	flags := flag.NewFlagSet("index-suites", flag.ContinueOnError)
	lane := flags.String("lane", "behavior", "lane")
	mode := flags.String("mode", "", "mode")
	driverScript := flags.String("driver-script", "", "driver script")
	jsonOutput := flags.Bool("json", false, "json output")
	flags.SetOutput(os.Stderr)
	if err := flags.Parse(argv); err != nil {
		return 1
	}
	cwd, _ := os.Getwd()
	projectRoot := cwd
	output, code, err := runIndexSuites(projectRoot, *driverScript, *lane, *mode, *jsonOutput)
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		return 1
	}
	fmt.Print(output)
	return code
}

func usageText() string {
	return strings.TrimSpace(`Usage:
  mutate4lua-go scan --target <file.lua> [--lane behavior|contract] [--mode MODE] [--lines 12,18] [--json]
  mutate4lua-go mutate --target <file.lua> [--lane behavior|contract] [--mode MODE] [--since-last-run|--mutate-all|--lines 12,18] [--max-workers N] [--timeout-factor N] [--test-command CMD] [--json]
  mutate4lua-go migrate-manifest --target <file.lua>
  mutate4lua-go index-suites --lane behavior [--mode MODE] [--json]
`) + "\n"
}

func binaryPath(projectRoot string) string {
	name := "mutate4lua-go"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	return filepath.Join(projectRoot, ".mutate4lua", "bin", name)
}
