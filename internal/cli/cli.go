package cli

import (
	"flag"
	"fmt"
	"io"
	goruntime "runtime"
	"strconv"
	"strings"

	"github.com/billyq/mutate4lua/internal/driver"
	"github.com/billyq/mutate4lua/internal/engine"
)

func parseLines(value string) ([]int, map[int]bool, error) {
	if strings.TrimSpace(value) == "" {
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
	workers := goruntime.NumCPU() / 2
	if workers < 1 {
		return 1
	}
	return workers
}

func Execute(argv []string, cwd string, stdout, stderr io.Writer) int {
	if len(argv) == 0 {
		fmt.Fprint(stderr, UsageText())
		return 1
	}
	switch argv[0] {
	case "scan", "mutate", "update-manifest":
		return runCoreCommand(argv[0], argv[1:], cwd, stdout, stderr)
	case "index-suites":
		return runIndexCommand(argv[1:], cwd, stdout, stderr)
	case "help", "--help", "-h":
		fmt.Fprint(stdout, UsageText())
		return 0
	default:
		fmt.Fprint(stderr, UsageText())
		return 1
	}
}

func runCoreCommand(command string, argv []string, cwd string, stdout, stderr io.Writer) int {
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
	flags.SetOutput(stderr)
	if err := flags.Parse(argv); err != nil {
		return 1
	}
	if *target == "" {
		fmt.Fprint(stderr, UsageText())
		return 1
	}
	lines, lookup, err := parseLines(*linesFlag)
	if err != nil {
		fmt.Fprintln(stderr, err.Error())
		return 1
	}
	output, code, err := engine.RunScanOrMutate(cwd, engine.CoreOptions{
		Target:          *target,
		Lane:            *lane,
		Mode:            *mode,
		DriverScript:    *driverScript,
		Scan:            command == "scan",
		UpdateManifest:  command == "update-manifest",
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
		fmt.Fprintln(stderr, err.Error())
		return 1
	}
	fmt.Fprint(stdout, output)
	return code
}

func runIndexCommand(argv []string, cwd string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("index-suites", flag.ContinueOnError)
	lane := flags.String("lane", "behavior", "lane")
	mode := flags.String("mode", "", "mode")
	driverScript := flags.String("driver-script", "", "driver script")
	jsonOutput := flags.Bool("json", false, "json output")
	flags.SetOutput(stderr)
	if err := flags.Parse(argv); err != nil {
		return 1
	}
	output, code, err := driver.RunIndexSuites(cwd, *driverScript, *lane, *mode, *jsonOutput)
	if err != nil {
		fmt.Fprintln(stderr, err.Error())
		return 1
	}
	fmt.Fprint(stdout, output)
	return code
}

func UsageText() string {
	return strings.TrimSpace(`Usage:
  mutate4lua-engine scan --target <file.lua> [--lane behavior|contract] [--mode MODE] [--lines 12,18] [--json]
  mutate4lua-engine mutate --target <file.lua> [--lane behavior|contract] [--mode MODE] [--since-last-run|--mutate-all|--lines 12,18] [--max-workers N] [--timeout-factor N] [--test-command CMD] [--json]
  mutate4lua-engine update-manifest --target <file.lua>
  mutate4lua-engine index-suites --lane behavior [--mode MODE] [--json]
`) + "\n"
}
