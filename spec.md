# mutate4lua Specification
`mutate4lua` is a mutation-testing tool for Lua source code.
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
The manifest shall be stored as an embedded footer comment.
It shall record:
- manifest version
- project hash
- scope ids
- scope kinds
- scope start and end lines
- scope semantic hashes
The tool shall write the manifest:
- after a successful mutation run with no surviving mutants
- after a successful run with no executed mutants
- when `--update-manifest` is used
The tool shall not write the manifest:
- after a baseline failure
- after any surviving mutant
- during `--scan`
When no explicit selection flag is provided:
- if no manifest exists, all covered sites are selected
- if a manifest exists and the project hash is unchanged, no sites are selected
- if a manifest exists and the project hash changed, only sites in changed scopes are selected
When `--since-last-run` is provided, only sites in changed scopes are selected.
When `--mutate-all` is provided, all covered sites are selected.
When `--lines` is provided, only sites on those lines are selected.
When `--test-command` is not provided, the built-in Lua test driver shall collect line coverage and uncovered mutation sites shall be skipped.
When `--test-command` is provided, the tool shall not inject coverage and discovered mutation sites shall be treated as covered.
- `0`: success
- `1`: usage error
- `2`: baseline failure
- `3`: surviving mutant
