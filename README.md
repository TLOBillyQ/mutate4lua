# mutate4lua

`mutate4lua` is a standalone mutation-testing tool for Lua projects.
It now uses a Lua-first layout with a Go execution engine:

- `lua/mutate4lua/` - public Lua package, default driver, and internal pure-Lua helpers
- `cmd/mutate4lua-engine/` - Go engine entrypoint
- `internal/` - Go engine implementation packages
- `bin/mutate4lua` - Lua wrapper that resolves/builds the Go engine and forwards CLI calls

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

## CLI

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

The Lua wrapper resolves the Go engine in this order:

1. `MUTATE4LUA_ENGINE_BIN`
2. `bin/mutate4lua-engine`
3. local `go build -o bin/mutate4lua-engine ./cmd/mutate4lua-engine`

When `--test-command` is not provided, `mutate4lua` runs the bundled `lua/mutate4lua/driver/default.lua` driver.
The default driver:

- discovers test files under `spec/`, `test/`, and `tests/`
- runs them with `dofile`
- records executed lines with `debug.sethook`
- writes line coverage for coverage-based filtering

This works well for plain Lua test files that execute assertions directly.
If your project uses another runner such as `busted`, pass `--test-command`. In that mode, `mutate4lua` does not inject coverage, so discovered sites are treated as covered.

The manifest is stored as a footer block at the end of the target file.

## Exit codes

- `0`: success, no surviving mutants, scan succeeded, or manifest update succeeded
- `1`: command-line usage error
- `2`: baseline tests failed
- `3`: at least one mutant survived

## Requirements

- Lua
- Go 1.22+
- a shell environment with `find`, `mkdir`, and `rm`

## Tests

```bash
make test-go
make test-lua
```

---

## 中文文档

`mutate4lua` 是一个用于 Lua 项目的独立变异测试工具。
它采用 Lua 优先的布局，使用 Go 作为执行引擎：

- `lua/mutate4lua/` - 公共 Lua 包、默认驱动程序和内部纯 Lua 辅助函数
- `cmd/mutate4lua-engine/` - Go 引擎入口
- `internal/` - Go 引擎实现包
- `bin/mutate4lua` - Lua 包装器，解析/构建 Go 引擎并转发 CLI 调用

### 功能特性

对于请求的 Lua 源文件，`mutate4lua`：

- 接受恰好一个 `.lua` 文件目标
- 从 Lua 感知词法分析器中发现变异点
- 跟踪声明作用域以进行差异化变异
- 将清单存储为目标文件内的嵌入式页脚注释
- 使用默认的进程内 Lua 测试运行器收集行覆盖率
- 当有覆盖率时跳过未覆盖的变异点
- 在隔离的工作空间副本中为每个选定的变异体重新运行测试命令
- 报告被杀死、存活、超时和未覆盖的变异体
- 在成功的干净运行后更新嵌入式清单

### 当前支持的 Lua 变异集合

- 布尔字面量：`true` <-> `false`
- 相等/比较：`==`, `~=`, `<`, `<=`, `>`, `>=`
- 算术运算：`+` <-> `-`, `*` <-> `/`
- 布尔运算符：`and` <-> `or`
- 一元运算符：
  - `not expr` -> `expr`
  - `-expr` -> `expr`
- 整数常量：`0` <-> `1`
- 字符串字面量替换为 `nil`
- 函数调用表达式替换为 `nil`

### CLI 用法

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

### 退出代码

- `0`：成功，无存活变异体，扫描成功，或清单更新成功
- `1`：命令行使用错误
- `2`：基线测试失败
- `3`：至少有一个变异体存活

### 环境要求

- Lua
- Go 1.22+
- 带有 `find`、`mkdir` 和 `rm` 的 shell 环境
