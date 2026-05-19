# mutate4lua Specification

`mutate4lua` is a pure-Lua mutation-testing tool for Lua source code.

It shall:

- accept exactly one Lua source file as its target, except suite-index commands
- discover mutation sites from Lua source tokens
- optionally use an embedded manifest to restrict work to changed scopes
- use line coverage when the built-in test driver is active
- execute tests against each selected mutant in an isolated workspace copy
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
- `mutate4lua --index-suites --lane behavior`
- `mutate4lua --help`

Defaults:

- lane: `behavior`
- timeout factor: `15`
- runner: `harness`
- max workers: accepted for compatibility; execution is sequential

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
