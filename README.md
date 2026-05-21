# mutate4lua

`mutate4lua` is a pure-Lua mutation-testing library for Lua projects.
The implementation lives under `lib/mutate4lua/`; Monopoly exposes it through
`tools/quality/mutate.lua`.

## Features

- Accepts one Lua source file target.
- Discovers mutation sites with a Lua-aware lexer and scanner.
- Tracks declaration scopes for differential mutation.
- Stores a manifest as an embedded footer comment inside the target file.
- Runs tests in an isolated workspace copy for each selected mutant.
- Uses line coverage from the built-in Lua driver when no custom test command is provided.
- Reports killed, survived, timed-out, and uncovered mutation sites.

The mutation set includes boolean literals, comparison and arithmetic operators,
boolean operators, selected unary operators, integer constants, string literals,
and function-call expressions.

## CLI

In Monopoly, use the repository wrapper:

```sh
lua tools/quality/mutate.lua --help
lua tools/quality/mutate.lua src/demo/flag.lua
lua tools/quality/mutate.lua src/demo/flag.lua --scan
lua tools/quality/mutate.lua src/demo/flag.lua --lines 12,18
lua tools/quality/mutate.lua src/demo/flag.lua --update-manifest
lua tools/quality/mutate.lua src/demo/flag.lua --mutate-all
lua tools/quality/mutate.lua src/demo/flag.lua --test-command "busted"
```

The vendor package exposes Lua modules only. It does not ship a standalone
`bin/` entrypoint.

When `--test-command` is not provided, `mutate4lua` runs
`lib/mutate4lua/driver/default.lua`. That driver discovers Lua test files under
`spec/`, `test/`, and `tests/`, executes them with `dofile`, and writes line
coverage for coverage-based filtering.

## Exit Codes

- `0`: success, no surviving mutants, scan succeeded, or manifest update succeeded
- `1`: command-line usage or infrastructure error
- `2`: reserved for baseline test failure compatibility
- `3`: at least one mutant survived

## Requirements

- Lua
- a shell environment with `find`, `mkdir`, `cp`, and `rm`

---

## 中文文档

`mutate4lua` 是用于 Lua 项目的纯 Lua 变异测试库，代码位于 `lib/mutate4lua/`。
Monopoly 通过 `tools/quality/mutate.lua` 暴露 CLI。

它支持扫描变异点、按 manifest 做差异化变异、在隔离工作区执行测试、收集覆盖率并输出
text / JSON 报告。

常用命令：

```sh
lua tools/quality/mutate.lua --help
lua tools/quality/mutate.lua src/demo/flag.lua --scan
lua tools/quality/mutate.lua src/demo/flag.lua --mutate-all
lua tools/quality/mutate.lua src/demo/flag.lua --update-manifest
```
