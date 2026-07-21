# mutate4lua

`mutate4lua` is a pure-Lua, host-agnostic mutation-testing library for Lua
projects. The implementation lives under `lib/mutate4lua/`; a host project
vendors it and exposes a CLI through `require("mutate4lua.cli").run(args, env)`.

## Features

- Accepts one Lua source file target.
- Discovers mutation sites with a Lua-aware lexer and scanner.
- Tracks declaration scopes for differential mutation.
- Stores per-file manifests in an external store
  (`<project_root>/.mutate4lua/manifest/`) — target sources are never modified.
- Runs tests in an isolated workspace copy for each selected mutant.
- Uses line coverage from the host-provided driver when no custom test command is provided.
- Reports killed, survived, timed-out, and uncovered mutation sites.

The mutation set includes boolean literals, comparison and arithmetic operators,
boolean operators, selected unary operators, integer constants, string literals,
and function-call expressions.

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
```

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
  - `--suite-list-file <file>`: newline-separated suite names to run.
  - `--coverage-file <file>`: the driver writes one `<relative/path>:<line>`
    entry per executed line (used for coverage-based site filtering);
    `--no-coverage` suppresses coverage collection.
  - `--fail-fast`: stop at the first failing case (mutant runs only; baselines
    always run everything).
- Suite discovery: `lua <driver> --lane <lane> --emit-suite-file-map-json`
  prints `{"suite_files": {"<suite>": ["<relative file>", ...]}}` mapping each
  suite to the source files it covers.
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
  `--[[ mutate4lua-manifest ... ]]` footer comment, without the comment markers.
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
   A manifest records automatically once the kill score reaches 90%;
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

- Lua
- a shell environment with `find`, `mkdir`, `cp`, and `rm`

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

它支持扫描变异点、按 manifest 做差异化变异、在隔离工作区执行测试、收集覆盖率并输出
text / JSON 报告。manifest 存放在外部存储（`<项目根>/.mutate4lua/manifest/`），
绝不改写业务源码。

常用命令（经宿主 wrapper）：

```sh
lua tools/mutate.lua --help
lua tools/mutate.lua src/demo/flag.lua --scan
lua tools/mutate.lua src/demo/flag.lua --mutate-all
lua tools/mutate.lua src/demo/flag.lua --update-manifest
lua tools/mutate.lua src/demo/flag.lua --migrate-manifest
```

manifest 机制：每个目标文件对应 `<store_root>/<relative>.manifest`，内容为旧版
footer 注释里的 `key=value` 正文（不带注释标记）。读取时若 store 无条目会回退读旧
footer，因此未迁移的项目行为不变；`--migrate-manifest` 幂等地把 footer 迁入 store
并把目标文件还原为无 footer 内容。`.gitignore` 建议：忽略 `.mutate4lua/cache/`，
提交 `.mutate4lua/manifest/` 以保留变异历史。

driver 契约：未传 `--test-command` 时，引擎通过宿主提供的 driver 脚本运行测试
（harness runner 用 `env.default_driver`，busted runner 用 `env.busted_driver`）。
本库不再提供默认 driver 路径；缺失时报 `error: driver script required: ...`。
driver 需支持 `--lane`、`--suite-list-file`、`--coverage-file`/`--no-coverage`、
`--fail-fast`、`--quiet`、`--emit-suite-file-map-json`、`--list-suites --json`
（详见上文英文 Driver contract 一节）。`lib/mutate4lua/driver/default.lua` 可作为
宿主 driver 的起点。

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
