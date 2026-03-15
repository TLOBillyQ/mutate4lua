# mutate4lua Specification

`mutate4lua` is a mutation-testing tool for Lua source code.

It uses a Lua-first package layout plus a Go execution engine. The Go engine is the
canonical implementation for CLI `scan`, `mutate`, `update-manifest`, and `index-suites`
commands; the Lua package provides the public wrapper, default driver, and archived pure-Lua helpers.

It shall:
- accept exactly one Lua source file as its target
- discover mutation sites from Lua source tokens
- optionally use an embedded manifest to restrict work to changed scopes
- use line coverage when the built-in test driver is active
- execute tests against each selected mutant
- report killed, survived, timed-out, and uncovered mutation sites
- update the embedded manifest after successful clean runs

Supported forms:
- `mutate4lua <file.lua>`
- `mutate4lua <file.lua> --scan`
- `mutate4lua <file.lua> --update-manifest`
- `mutate4lua <file.lua> --lines 12,18`
- `mutate4lua <file.lua> --since-last-run`
- `mutate4lua <file.lua> --mutate-all`
- `mutate4lua <file.lua> --mutation-warning N`
- `mutate4lua <file.lua> --max-workers N`
- `mutate4lua <file.lua> --timeout-factor N`
- `mutate4lua <file.lua> --test-command CMD`
- `mutate4lua <file.lua> --verbose`
- `mutate4lua --help`

The internal Go engine also supports:
- `mutate4lua-engine scan --target <file.lua>`
- `mutate4lua-engine mutate --target <file.lua>`
- `mutate4lua-engine update-manifest --target <file.lua>`
- `mutate4lua-engine index-suites --lane behavior`

Defaults:
- timeout factor: `10`
- mutation warning threshold: `50`
- max workers: half the available processors, minimum `1`

Rejected combinations:
- `--scan` with `--since-last-run`
- `--scan` with `--mutate-all`
- `--scan` with `--update-manifest`
- `--lines` with `--since-last-run`
- `--lines` with `--mutate-all`
- `--lines` with `--update-manifest`
- `--since-last-run` with `--mutate-all`
- `--update-manifest` with `--since-last-run`
- `--update-manifest` with `--mutate-all`

The current mutation set includes:
- `true` <-> `false`
- `==` <-> `~=`
- `<` <-> `<=`
- `>` <-> `>=`
- `+` <-> `-`
- `*` <-> `/`
- `and` <-> `or`
- `not expr` -> `expr`
- `-expr` -> `expr`
- `0` <-> `1`
- string literals -> `nil`
- function-call expressions -> `nil`

Comments and embedded manifest content shall not be treated as mutation sites.
