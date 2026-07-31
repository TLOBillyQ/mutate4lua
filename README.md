# mutate4lua

`mutate4lua` is a pure-Lua, host-agnostic mutation-testing library for Lua
projects. The implementation lives under `lib/mutate4lua/`; a host project
vendors it and exposes a CLI through `require("mutate4lua.cli").run(args, env)`.

## Upstream Alignment (对齐上游)

`mutate4lua` follows the "Lua faithful implementation of the upstream spec"
doctrine, with [mutate4java's spec.md](https://github.com/unclebob/mutate4java)
as the reference (the most mature of the three upstream versions): the CLI
surface, option defaults, selection semantics, report skeleton, and exit codes
converge to it with **zero local-only inventions**. Cross-repo decisions live
as ADRs in the luatools notes repo (`projects/luatools/docs/adr/`).

**Aligned invariants (对齐不变量)**

- Exit codes `0` success / `1` usage / `2` baseline failed / `3` survived
  (the java convention — clj/go only had 0/1).
- Manifest embedded as a `--[[ ]]` footer comment in the target file
  (ADR-0002; the external `.mutate4lua/manifest/` store is abolished, with a
  one-off migration script for existing stores).
- Differential selection: no manifest → all covered sites; unchanged module
  hash → 0 sites; changed hash → changed scopes only. Manifest is written
  only after a clean run (no survivors, or nothing to execute) — the local
  "auto-record at 90% kill score" rule is abolished (ADR-0004).
- Option surface = upstream set: `--scan`, `--update-manifest`, `--lines`,
  `--since-last-run`, `--mutate-all`, `--mutation-warning` (50),
  `--max-workers` (cores/2), `--timeout-factor` (**10**, not the old local 15),
  `--test-command`, `--reuse-coverage`, `--verbose`. Removed local-only
  options: `--index-suites`, `--lane`, `--runner`, `--dry-run`,
  `--poll-interval`, `--json` (ADR-0004; `--migrate-manifest` becomes a
  one-off migration script, not a CLI flag).
- Mutation set: boolean flip, comparison/arithmetic operator swaps,
  `and` ↔ `or`, unary `not`/`-` removal, `0` ↔ `1`, rvalue → `nil`
  (the Lua counterpart of java's rvalue → `null`).
- Scope identity is declaration-based, not line-based (java spec §7.3).
- Worker copies of the module; originals are never mutated in place; a
  timed-out mutant counts as killed.

**Deliberate deviations (有意偏离)**

- Host-provided driver script instead of a built-in build-tool invocation
  (maven / `go test`) — Lua has no standard build or test runner; the driver
  contract is the Lua counterpart (suites/lane parameters removed, ADR-0004).
- Coverage source is **luacov** artifacts only (ADR-0003) — the Lua
  counterpart of JaCoCo/coverprofile; driver-produced ad-hoc coverage formats
  are not accepted.
- Scope semantic hash = FNV-1a over the normalized AST serialization
  (format-insensitive, clj `pr-str` semantics upgraded to AST; the three
  upstreams disagree — clj format-insensitive / go whitespace-normalized /
  java raw-substring — so this picks the semantics that fits the AST
  migration, ADR-0001/0004).

**Breaking changes on this branch**: suites/`--lane`, `--json`, the external
manifest store, the 90% auto-record rule, and ad-hoc driver coverage are all
removed. See "Migrating" for the upgrade path.

## Features

- Accepts one Lua source file target.
- Discovers mutation sites with a luacheck AST-based scanner.
- Tracks declaration scopes for differential mutation: by default only scopes
  whose semantic hash changed since the recorded manifest are re-tested;
  `--mutate-all` forces every covered site.
- Stores the manifest as an embedded `--[[ mutate4lua-manifest ... ]]`
  footer comment at the end of the target source file.
- Writes the manifest only after a fully clean run (all executed mutants
  killed, or no mutants needed execution) and never after a survivor or a
  baseline failure; `--lines` suppresses the write because it records partial
  state.
- Runs tests in isolated workspace copies, in parallel across workers
  (default: half the CPU cores; `--max-workers 1` for serial).
- Uses line coverage from a standard `luacov.report.out` to skip uncovered
  sites; `--reuse-coverage` skips regeneration, and `--test-command` disables
  coverage filtering with a warning.
- Reports killed, survived, and timed-out mutants in text.

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
  default_driver = "tools/mutate/driver.lua",
  command_name = "lua tools/mutate.lua",
}))
```

Typical usage through such a wrapper:

```sh
lua tools/mutate.lua --help
lua tools/mutate.lua src/demo/flag.lua
lua tools/mutate.lua src/demo/flag.lua --scan
lua tools/mutate.lua src/demo/flag.lua --lines 12,18
lua tools/mutate.lua src/demo/flag.lua --since-last-run
lua tools/mutate.lua src/demo/flag.lua --mutate-all
lua tools/mutate.lua src/demo/flag.lua --update-manifest
lua tools/mutate.lua src/demo/flag.lua --reuse-coverage
lua tools/mutate.lua src/demo/flag.lua --test-command "busted"
```

Subcommands and options (mirrors `--help`):

| Flag | Meaning |
| --- | --- |
| *(default)* | run mutation tests |
| `--scan` | list mutation sites without running tests |
| `--update-manifest` | write/refresh the embedded manifest footer without mutating |
| `--mutate-all` | mutate every covered site, ignoring the manifest |
| `--since-last-run` | restrict mutation to scopes that differ from the manifest |
| `--lines N,N` | restrict to the given line numbers (suppresses manifest writes) |
| `--reuse-coverage` | reuse the existing `luacov.report.out` instead of regenerating it |
| `--max-workers N` | parallel workers (default: half the CPU cores; `1` = serial) |
| `--timeout-factor N` | mutant timeout multiplier over the baseline (default `10`) |
| `--test-command CMD` | custom test command, bypassing the driver contract |
| `--mutation-warning N` | warn when the selected site count exceeds N (default `50`) |
| `--verbose` | verbose output |
| `-h, --help` | show help |

## Driver contract

When `--test-command` is not provided, the engine drives tests through a
host-provided driver script passed as `env.default_driver`. The library ships
**no default driver path** — when no driver is available it fails fast with
`error: driver script required: pass --test-command or provide a driver script via env.default_driver (see README)`.

A driver script is invoked by the engine as follows:

- Baseline run (coverage generation):
  `lua <driver> --coverage-report <abs-path> --quiet`
- Baseline run (`--mutate-all` or `--reuse-coverage`):
  `lua <driver> --no-coverage --quiet`
- Mutant run:
  `lua <driver> --no-coverage --fail-fast --quiet`

Exit `0` means the tests pass (a mutant survives); non-zero means failure
(a mutant is killed). The engine applies its own timeout around the run.

The driver must produce a standard `luacov.report.out` at the absolute path
given to `--coverage-report`. The engine parses that report itself; no
library dependency on luacov is required. When luacov is not installed on the
host, `--coverage-report` should fail with a clear message; `--no-coverage`
runs must still work.

`lib/mutate4lua/driver/default.lua` is a working starting point for a host
driver.

## Manifest storage

- The manifest is stored as an embedded `--[[ mutate4lua-manifest ... ]]`
  footer comment at the end of the target source file.
- It records manifest version `4`, the module hash, and for each scope:
  `id`, `kind`, `startLine`, `endLine`, `semanticHash`.
- Legacy `lastMutation*` fields are ignored on read and never written.
- Differential mode skips scopes whose `semanticHash` is unchanged.
- The manifest is written after a clean run (no survivors / no executed
  mutants) and on `--update-manifest`. It is never written after a baseline
  failure, after any survivor, or during `--scan`. `--lines` suppresses it.
- The pre-alignment external store `.mutate4lua/manifest/` is no longer read
  or written. Use `tools/migrate_manifest.lua` once per target to move from
  the old store/legacy footer to a fresh v4 footer:
  `lua tools/migrate_manifest.lua src/foo.lua`.

## Migrating from the pre-alignment version

1. Run `lua tools/migrate_manifest.lua <target.lua>` once per mutated file.
   It strips any legacy footer, deletes the corresponding
   `.mutate4lua/manifest/<relative>.manifest` store file, and appends a
   freshly computed v4 footer.
2. Remove the following options from scripts and CI: `--index-suites`,
   `--lane`, `--runner`, `--dry-run`, `--poll-interval`, `--json`,
   `--migrate-manifest`.
3. Update any custom driver to the new contract above (no `--lane`,
   `--suite-list-file`, `--emit-suite-file-map-json`, or `--list-suites`).
4. Ensure luacov is available if you rely on coverage filtering; otherwise
   use `--test-command` (which disables coverage filtering with a warning).
5. The default `--timeout-factor` changed from `15` to `10`.
6. Add `.mutate4lua/manifest/` to `.gitignore` if it still exists from an
   earlier checkout; commit the new manifest footers inside your source files.

## Integrating into a new project (example: eggy)

1. Vendor `mutate4lua` (submodule or copy) and add its `lib/` to `package.path`
   in a thin wrapper script that calls `cli.run` as shown above.
2. Provide a driver script implementing the contract in the previous section
   and pass it as `env.default_driver` (starting from
   `lib/mutate4lua/driver/default.lua` is fine).
3. Run mutations through the wrapper, e.g. `lua tools/mutate.lua src/foo.lua`.
   The manifest records automatically after a clean run;
   `lua tools/mutate.lua src/foo.lua --update-manifest` pins one explicitly.
4. Add `.mutate4lua/` to `.gitignore` (cache and any stale store files); the
   manifest lives inside the target source file and should be committed.

## Tests

The test suite uses a self-contained harness (`spec/harness.lua`) with no
external dependencies:

```sh
lua spec/run.lua            # run all spec/*_spec.lua
lua spec/run.lua spec/cli_spec.lua   # run specific files
```

## Exit Codes

- `0`: success, no surviving mutants, no mutants needed execution, scan
  succeeded, or manifest update succeeded
- `1`: command-line usage or infrastructure error
- `2`: baseline test failure
- `3`: at least one mutant survived

## Requirements

- Lua 5.3+ or LuaJIT (content hashing — file, scope, and project hashes —
  uses native 64-bit bitwise operators)
- luacov if you want coverage filtering (the reference driver uses it; the
  engine itself has no luacov dependency)
- a POSIX-ish shell environment with `find`, `mkdir`, `cp`, `rm`, `sleep`,
  and `kill` (parallel mode uses background jobs and `wait`)
- optional: `timeout` or `gtimeout` for mutant timeouts — without one, a
  pure-shell watchdog provides the same 124-exit-code semantics

## Compatibility Notes

- Manifests are now written as footer comments into target files; the
  external `.mutate4lua/manifest/` store is no longer used.
- The CLI no longer supports `--lane`, `--runner`, `--json`, or suite
  indexing; the driver contract is reduced to coverage/no-coverage +
  fail-fast.
- The default `command_name` used in help/error output is `mutate4lua`.

---

## 中文文档

`mutate4lua` 是纯 Lua、与宿主无关的变异测试库，代码位于 `lib/mutate4lua/`。
宿主项目 vendor 本库后，通过 `require("mutate4lua.cli").run(args, env)` 暴露 CLI。

它支持扫描变异点、按 manifest 做差异化变异（默认只重测 semantic hash 变化过的
scope，`--mutate-all` 强制执行全部已覆盖位点）、在隔离工作区并行执行测试（默认
worker 数为 CPU 核数的一半，`--max-workers 1` 串行）、按 luacov 报告过滤未覆盖位点，
并输出文本报告。manifest 以 `--[[ mutate4lua-manifest ... ]]` footer 注释形式嵌入
目标源码末尾，随源码一起提交。

常用命令（经宿主 wrapper）：

```sh
lua tools/mutate.lua --help
lua tools/mutate.lua src/demo/flag.lua
lua tools/mutate.lua src/demo/flag.lua --scan
lua tools/mutate.lua src/demo/flag.lua --lines 12,18
lua tools/mutate.lua src/demo/flag.lua --since-last-run
lua tools/mutate.lua src/demo/flag.lua --mutate-all
lua tools/mutate.lua src/demo/flag.lua --update-manifest
lua tools/mutate.lua src/demo/flag.lua --reuse-coverage
```

完整选项列表见 `--help` 或上文英文 CLI 一节。

manifest 机制：每个目标文件末尾的 footer 注释，内容为 `key=value` 正文：
`version`（当前为 4）与 `projectHash` 头，加上每个 scope 的 `id` / `kind` /
`startLine` / `endLine` / `semanticHash`。旧的 `lastMutation*` 字段读取时忽略、
写入时不再生成。差异化模式跳过 hash 未变的 scope。manifest 仅在干净运行后
（全部击杀或无 mutant 需执行）或 `--update-manifest` 时写入；baseline 失败、
存在 survivor、或 `--scan` 时不写入；`--lines` 时抑制写入。

从旧版本迁移：对每个目标文件执行
`lua tools/migrate_manifest.lua src/foo.lua`，它会剥离旧 footer、删除对应
`.mutate4lua/manifest/<relative>.manifest` 外部存储文件，并追加新的 v4 footer。
之后可删除 `--index-suites`、`--lane`、`--runner`、`--dry-run`、
`--poll-interval`、`--json`、`--migrate-manifest` 等旧选项；按新的 driver 契约
更新自定义 driver；注意默认 `--timeout-factor` 已从 15 改为 10；如需覆盖率过滤请
安装 luacov。

driver 契约：未传 `--test-command` 时，引擎通过宿主提供的 driver 脚本运行测试
（`env.default_driver`）。本库不再提供默认 driver 路径；缺失时报
`error: driver script required: ...`。driver 需支持：

- 基线（生成覆盖率）：`lua <driver> --coverage-report <abs-path> --quiet`
- 基线（`--mutate-all` / `--reuse-coverage`）：`lua <driver> --no-coverage --quiet`
- 变异体运行：`lua <driver> --no-coverage --fail-fast --quiet`

`lib/mutate4lua/driver/default.lua` 可作为宿主 driver 的起点。

在新项目（如 eggy）中接入：vendor 本库 → 写一个调用 `cli.run` 的薄 wrapper 并传入
`env.default_driver` → 直接运行 `lua tools/mutate.lua src/foo.lua`。无需额外配置；
manifest 嵌入在源码文件中，建议提交；`.mutate4lua/` 目录加入 `.gitignore`。

## 测试

测试使用自研的最小 harness（`spec/harness.lua`），无外部依赖：

```sh
lua spec/run.lua                       # 运行全部 spec/*_spec.lua
lua spec/run.lua spec/cli_spec.lua     # 运行指定文件
```

## 退出码

- `0`：成功、全部击杀、无 mutant 需执行、扫描成功、或 manifest 更新成功
- `1`：命令行用法错误或基础设施错误
- `2`：baseline 测试失败
- `3`：存在存活的 mutant

## 运行需求

- Lua 5.3+ 或 LuaJIT（哈希运算使用原生 64 位位运算）
- 如需覆盖率过滤，需安装 luacov（参考 driver 使用；引擎本身不依赖 luacov）
- POSIX 环境（`find`、`mkdir`、`cp`、`rm`、`sleep`、`kill`）
- 可选 `timeout` / `gtimeout`；否则内置纯 shell 看门狗提供 124 退出码语义
