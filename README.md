# mutate4lua
`mutate4lua` is a standalone mutation-testing tool for Lua projects, modeled after [unclebob/mutate4java](https://github.com/unclebob/mutate4java) and adapted to Lua source, Lua test workflows, and embedded Lua manifests.
It targets one `.lua` file at a time, discovers mutation sites, optionally narrows work to scopes changed since the last clean run, executes tests against each selected mutant, and updates an embedded manifest footer when the run finishes cleanly.
For a requested Lua source file, `mutate4lua`:
- accepts exactly one `.lua` file target
- discovers mutation sites from a Lua-aware lexer
- tracks declaration scopes for differential mutation
- stores a manifest as an embedded footer comment inside the target file
- uses the default in-process Lua test runner to collect line coverage
- skips uncovered mutation sites when coverage is available
- reruns the test command for each selected mutant in isolated workspace copies
- reports killed, survived, timed-out, and uncovered mutants
- updates the embedded manifest after successful clean runs
The current Lua mutation set includes:
- boolean literals: `true` <-> `false`
- equality/comparison: `==`, `~=`, `<`, `<=`, `>`, `>=`
- arithmetic: `+` <-> `-`, `*` <-> `/`
- boolean operators: `and` <-> `or`
- unary operators:
  - `not expr` -> `expr`
  - `-expr` -> `expr`
- integer constants: `0` <-> `1`
- string literals replaced with `nil`
- function-call expressions replaced with `nil`
```bash
lua bin/mutate4lua --help
lua bin/mutate4lua src/demo/flag.lua
lua bin/mutate4lua src/demo/flag.lua --scan
lua bin/mutate4lua src/demo/flag.lua --lines 12,18
lua bin/mutate4lua src/demo/flag.lua --update-manifest
lua bin/mutate4lua src/demo/flag.lua --since-last-run
lua bin/mutate4lua src/demo/flag.lua --mutate-all
lua bin/mutate4lua src/demo/flag.lua --test-command "busted"
```
When `--test-command` is not provided, `mutate4lua` runs the bundled `scripts/test_driver.lua`.
The default driver:
- discovers test files under `spec/`, `test/`, and `tests/`
- runs them with `dofile`
- records executed lines with `debug.sethook`
- writes line coverage for coverage-based filtering
This works well for plain Lua test files that execute assertions directly.
If your project uses another runner such as `busted`, pass `--test-command`. In that mode, `mutate4lua` does not inject coverage, so discovered sites are treated as covered.
The manifest is stored as a footer block at the end of the target file:
```lua
--[[ mutate4lua-manifest
version=1
projectHash=...
scope.0.id=...
scope.0.kind=function
scope.0.startLine=...
scope.0.endLine=...
scope.0.semanticHash=...
]]
```
`mutate4lua` strips the manifest before scanning, hashing, and mutating source.
- `0`: success, no surviving mutants, scan succeeded, or manifest update succeeded
- `1`: command-line usage error
- `2`: baseline tests failed
- `3`: at least one mutant survived
- Lua
- Python 3
- a shell environment with `find`, `mkdir`, and `rm`
```bash
lua test/run.lua
```
