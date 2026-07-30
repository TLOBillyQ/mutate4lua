# mutate4lua

`mutate4lua` is a pure-Lua, host-agnostic mutation-testing library for Lua
projects. The implementation lives under `lib/mutate4lua/`; a host project
vendors it and exposes a CLI through `require("mutate4lua.cli").run(args, env)`.

## Features

- Accepts one Lua source file target.
- Discovers mutation sites with a Lua-aware lexer and scanner.
- Tracks declaration scopes for differential mutation: by default only scopes
  whose semantic hash changed since the recorded manifest are re-tested;
  `--mutate-all` forces every site.
- Stores per-file manifests in an external store
  (`<project_root>/.mutate4lua/manifest/`) — target sources are never modified.
- Records a manifest automatically once the kill score reaches 90% (with zero
  timeouts and no `--lines` filter); residual survivors are recorded honestly
  per scope instead of being masked as passed.
- Runs tests in isolated workspace copies, in parallel across workers
  (default: half the CPU cores; `--max-workers 1` for serial).
- Uses line coverage from the host-provided driver to filter uncovered sites
  in differential mode (skipped under `--mutate-all` or with
  `--test-command`).
- Reports killed, survived, and timed-out mutants in text or `--json`.

The mutation set includes boolean literals (`true` ↔ `false`), comparison and
arithmetic operators, boolean operators (`and` ↔ `or`), unary `not` and unary
minus removal, the integer constants `0` ↔ `1`, string literals (→ `nil`),
and function-call expressions (→ `nil`).

## CLI

The package exposes Lua modules only. It does not ship a standalone `bin/`
entrypoint; a host wires it up with a thin wrapper:

```lua
package.path = "vendor/mutate4lua/lib/?.lua;vendor/mutate4lua/lib/?/init.lua;" .. package.path
os.exit(require("mutate4lua.cli").run(arg, {
  cwd = ".",
  default_driver = "tools/mutate/driver.lua",   -- harness runner driver
  busted_driver = "tools/mutate/busted_driver.lua", -- busted runner driver
  command_name = "lua tools/mutate.lua",
}))
```

Typical usage through such a wrapper:

```sh
lua tools/mutate.lua --help
lua tools/mutate.lua src/demo/flag.lua
lua tools/mutate.lua src/demo/flag.lua --scan
lua tools/mutate.lua src/demo/flag.lua --lines 12,18
lua tools/mutate.lua src/demo/flag.lua --update-manifest
lua tools/mutate.lua src/demo/flag.lua --migrate-manifest
lua tools/mutate.lua src/demo/flag.lua --mutate-all
lua tools/mutate.lua src/demo/flag.lua --test-command "busted"
lua tools/mutate.lua --index-suites --dry-run
lua tools/mutate.lua src/demo/flag.lua --json
```

Subcommands and options (mirrors `--help`):

| Flag | Meaning |
| --- | --- |
| *(default)* | run mutation tests |
| `--scan` | list mutation sites without running tests |
| `--update-manifest` | write the manifest to the external store without mutating |
| `--migrate-manifest` | move a legacy in-source footer manifest into the store |
| `--index-suites` | list test suites (via the driver) |
| `--lane behavior\|contract` | test lane, default `behavior` |
| `--runner harness\|busted` | runner, default `harness` (selects `env.default_driver` / `env.busted_driver`) |
| `--mutate-all` | mutate every site, ignoring the manifest and coverage |
| `--lines N,N` | restrict to the given line numbers (suppresses manifest writes) |
| `--max-workers N` | parallel workers (default: half the CPU cores; `1` = serial) |
| `--poll-interval N` | seconds between parallel polls (default `0` = busy-wait, no shell forks) |
| `--timeout-factor N` | mutant timeout multiplier over the baseline (default `15`) |
| `--test-command CMD` | custom test command, bypassing the driver contract |
| `--mutation-warning N` | warn when the site count exceeds N |
| `--dry-run` | list suites without running (modifier of `--index-suites`) |
| `--json` | JSON output |
| `--verbose` | verbose output |

## Driver contract

When `--test-command` is not provided, the engine drives tests through a
host-provided driver script: `env.default_driver` for the harness runner,
`env.busted_driver` for the busted runner. The library ships **no default
driver path** — when no driver is available it fails fast with
`error: driver script required: pass --test-command or provide a driver script via env.default_driver / env.busted_driver`.

A driver script is invoked by the engine as follows:

- Baseline and mutant runs:
  `lua <driver> --lane <lane> [--suite-list-file <file>] [--coverage-file <file> | --no-coverage] [--fail-fast] --quiet`
  - Exit `0` means the tests pass (a mutant survives); non-zero means failure
    (a mutant is killed). The engine applies its own timeout around the run.
  - `--suite-list-file <file>`: newline-separated suite names to run (only the
    suites covering the target, from suite discovery).
  - `--coverage-file <file>`: the driver writes one `<relative/path>:<line>`
    entry per executed line (used for coverage-based site filtering);
    `--no-coverage` suppresses coverage collection.
  - `--fail-fast`: stop at the first failing case (mutant runs only; baselines
    always run everything).
  - Concretely: the baseline run passes `--coverage-file` (except under
    `--mutate-all`, which passes `--no-coverage`) and never `--fail-fast`;
    every mutant run passes `--no-coverage --fail-fast`.
- Suite discovery: `lua <driver> --lane <lane> --emit-suite-file-map-json`
  prints `{"suite_files": {"<suite>": ["<relative file>", ...]}}` mapping each
  suite to the source files it covers. The result is cached per lane under
  `<workspace_root>/.mutate4lua/cache/`, keyed by a fingerprint of
  `spec/*.lua` and the driver script; editing a spec or the driver
  invalidates it automatically.
- Suite listing (for `--index-suites` / `--dry-run`):
  `lua <driver> --lane <lane> --list-suites --json` prints a JSON array of
  suite names.

`lib/mutate4lua/driver/default.lua` is a working starting point for a host
driver — read it to understand the invocation and coverage conventions (it
implements the `dofile`-based subset the engine uses via
`project.default_test_command`).

## Manifest storage

- One manifest file per target: `<store_root>/<relative>.manifest`
  (e.g. `src/player.lua` → `.mutate4lua/manifest/src/player.lua.manifest`).
- Default store root: `<project_root>/.mutate4lua/manifest/` (the project root
  found by walking up from the target for `.git`, a rockspec, or a
  `spec`/`test`/`tests` directory). Hosts may override it with
  `env.manifest_dir`; a relative value resolves against `env.cwd`.
- The file body is the same `key=value` text older versions embedded as a
  `--[[ mutate4lua-manifest ... ]]` footer comment, without the comment
  markers: a `version` (currently `2`) and `projectHash` header, then per
  scope `id` / `kind` / `startLine` / `endLine` / `semanticHash` plus the
  `lastMutatedAt` / `lastMutationLane` / `lastMutationStatus` /
  `lastMutationSites` / `lastMutationKilled` fields from the most recent run.
- Differential mode skips scopes whose `semanticHash` is unchanged, and
  re-tests scopes last recorded under a different `--lane`.
- Reads fall back to a legacy in-source footer when the store has no entry, so
  unmigrated projects keep working unchanged.
- `--migrate-manifest <file>` moves a legacy footer into the store (preserving
  all fields) and rewrites the target without the footer. It is idempotent and
  supports `--json`.
- `.gitignore` recommendation: ignore `.mutate4lua/cache/` (derived data), but
  commit `.mutate4lua/manifest/` to preserve mutation history.

## Integrating into a new project (example: eggy)

1. Vendor `mutate4lua` (submodule or copy) and add its `lib/` to `package.path`
   in a thin wrapper script that calls `cli.run` as shown above.
2. Provide a driver script implementing the contract in the previous section
   and pass it as `env.default_driver` (starting from
   `lib/mutate4lua/driver/default.lua` is fine). No further configuration —
   no steps, no source annotations — is needed.
3. Run mutations through the wrapper, e.g. `lua tools/mutate.lua src/foo.lua`.
   A manifest records automatically once the kill score reaches 90% (with no
   timed-out mutants and no `--lines` filter);
   `lua tools/mutate.lua --update-manifest src/foo.lua` pins one explicitly.
4. Manifests appear under `eggy/.mutate4lua/manifest/`. Commit that directory;
   add `.mutate4lua/cache/` to `eggy/.gitignore`.

## Tests

The test suite uses a self-contained harness (`spec/harness.lua`) with no
external dependencies:

```sh
lua spec/run.lua            # run all spec/*_spec.lua
lua spec/run.lua spec/cli_spec.lua   # run specific files
```

## Exit Codes

- `0`: success, no surviving mutants, scan succeeded, or manifest update succeeded
- `1`: command-line usage or infrastructure error
- `2`: reserved for baseline test failure compatibility
- `3`: at least one mutant survived

## Requirements

- Lua 5.3+ or LuaJIT (content hashing — file, scope, and project hashes —
  uses native 64-bit bitwise operators)
- a POSIX-ish shell environment with `find`, `mkdir`, `cp`, `rm`, `sleep`,
  and `kill` (parallel mode uses background jobs and `wait`)
- optional: `timeout` or `gtimeout` for mutant timeouts — without one, a
  pure-shell watchdog provides the same 124-exit-code semantics

## Compatibility Notes

- Manifests are no longer written as footer comments into target files; all
  writes go to the external store. Reads still fall back to legacy footers, and
  `--migrate-manifest` removes them from existing sources.
- The CLI no longer falls back to host-specific default driver paths: hosts
  must pass `env.default_driver` / `env.busted_driver`, or use `--test-command`.
- The default `command_name` used in help/error output is `mutate4lua`.

---

## 中文文档

`mutate4lua` 是纯 Lua、与宿主无关的变异测试库，代码位于 `lib/mutate4lua/`。
宿主项目 vendor 本库后，通过 `require("mutate4lua.cli").run(args, env)` 暴露 CLI。

它支持扫描变异点、按 manifest 做差异化变异（默认只重测 semantic hash 变化过的
scope，`--mutate-all` 强制执行全部位点）、在隔离工作区并行执行测试（默认 worker 数为
CPU 核数的一半，`--max-workers 1` 串行）、按覆盖率过滤未覆盖位点，并输出 text / JSON
报告。manifest 存放在外部存储（`<项目根>/.mutate4lua/manifest/`），绝不改写业务源码。

常用命令（经宿主 wrapper）：

```sh
lua tools/mutate.lua --help
lua tools/mutate.lua src/demo/flag.lua --scan
lua tools/mutate.lua src/demo/flag.lua --mutate-all
lua tools/mutate.lua src/demo/flag.lua --update-manifest
lua tools/mutate.lua src/demo/flag.lua --migrate-manifest
lua tools/mutate.lua --index-suites --dry-run
```

完整选项列表见 `--help` 或上文英文 CLI 一节（`--lane`、`--runner`、`--lines`、
`--max-workers`、`--poll-interval`、`--timeout-factor`、`--test-command`、
`--mutation-warning`、`--json` 等）。

manifest 机制：每个目标文件对应 `<store_root>/<relative>.manifest`，内容为旧版
footer 注释里的 `key=value` 正文（不带注释标记）：`version`（当前为 2）与
`projectHash` 头，加上每个 scope 的 `semanticHash` 及 `lastMutationStatus` 等
最近运行字段。差异化模式跳过 hash 未变的 scope；若 scope 上次记录于不同 `--lane`
则会重测。击杀率达到 90%（且无超时、未用 `--lines`）时自动写入 manifest，残留
survivor 按 scope 如实标注。读取时若 store 无条目会回退读旧 footer，因此未迁移的
项目行为不变；`--migrate-manifest` 幂等地把 footer 迁入 store 并把目标文件还原为
无 footer 内容。`.gitignore` 建议：忽略 `.mutate4lua/cache/`，提交
`.mutate4lua/manifest/` 以保留变异历史。

driver 契约：未传 `--test-command` 时，引擎通过宿主提供的 driver 脚本运行测试
（harness runner 用 `env.default_driver`，busted runner 用 `env.busted_driver`）。
本库不再提供默认 driver 路径；缺失时报 `error: driver script required: ...`。
driver 需支持 `--lane`、`--suite-list-file`、`--coverage-file`/`--no-coverage`、
`--fail-fast`、`--quiet`、`--emit-suite-file-map-json`、`--list-suites --json`。
基线运行传 `--coverage-file`（`--mutate-all` 时传 `--no-coverage`）且不带
`--fail-fast`；每个变异体运行传 `--no-coverage --fail-fast`。suite → 文件映射按
lane 缓存在 `.mutate4lua/cache/`，以 `spec/*.lua` 与 driver 脚本的指纹为 key，
改动后自动失效（详见上文英文 Driver contract 一节）。
`lib/mutate4lua/driver/default.lua` 可作为宿主 driver 的起点。

在新项目（如 eggy）中接入：vendor 本库 → 写一个调用 `cli.run` 的薄 wrapper 并传入
`env.default_driver` → 直接运行 `lua tools/mutate.lua src/foo.lua`。无需 steps 等
额外配置；manifest 自动写入 `eggy/.mutate4lua/manifest/`（建议提交），
`.mutate4lua/cache/` 加入 `.gitignore`。

兼容性说明：不再向目标文件写入 footer manifest；CLI 不再内置任何宿主编码的默认
driver 路径；帮助输出的默认命令名为 `mutate4lua`。

## 测试

测试使用自研的最小 harness（`spec/harness.lua`），无外部依赖：

```sh
lua spec/run.lua                       # 运行全部 spec/*_spec.lua
lua spec/run.lua spec/cli_spec.lua     # 运行指定文件
```
