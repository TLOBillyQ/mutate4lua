# mutate4lua

`mutate4lua` 是一个纯 Lua、与宿主无关的变异测试库，适用于 Lua 项目。实现代码位于
`lib/mutate4lua/` 目录下；宿主项目将其 vendor 进来，通过
`require("mutate4lua.cli").run(args, env)` 暴露 CLI。

## 上游对齐 (Upstream Alignment)

`mutate4lua` 遵循"Lua 忠实实现上游规格"的总纲，以
[mutate4java 的 spec.md](https://github.com/unclebob/mutate4java) 为参照（上游三版中
最成熟者）：CLI 表面、选项默认值、位点选择语义、报告骨架及退出码均向其收敛，**零本地
独有发明**。跨仓库决策以 ADR 形式记录于 luatools notes 仓库
（`projects/luatools/docs/adr/`）。

**对齐不变量 (Aligned Invariants)**

- 退出码 `0` 成功 / `1` 用法错误 / `2` baseline 失败 / `3` 存在存活 mutant
  （java 约定——clj/go 版仅有 0/1）。
- manifest 以 `--[[ ]]` footer 注释形式嵌入目标文件尾部（ADR-0002；外部
  `.mutate4lua/manifest/` 存储已废除，提供一次性迁移脚本处理现有存储）。
- 差异化选择：无 manifest → 所有已覆盖位点；模块 hash 未变 → 0 个位点；hash 变化 →
  仅变动的 scope。manifest 仅在干净运行后写入（无 survivor，或无 mutant 需执行）——
  本地"90% 击杀率自动记录"规则已废除（ADR-0004）。
- 选项表面 = 上游集合：`--scan`、`--update-manifest`、`--lines`、
  `--since-last-run`、`--mutate-all`、`--mutation-warning`（50）、
  `--max-workers`（cores/2）、`--timeout-factor`（**10**，非旧版本地值 15）、
  `--test-command`、`--reuse-coverage`、`--verbose`。已删除的本地独有选项：
  `--index-suites`、`--lane`、`--runner`、`--dry-run`、`--poll-interval`、
  `--json`（ADR-0004；`--migrate-manifest` 改为一次性迁移脚本，非 CLI 标志）。
- 变异集合：布尔翻转、比较/算术运算符交换、`and` ↔ `or`、一元 `not`/`-` 移除、
  `0` ↔ `1`、右值 → `nil`（java 版右值 → `null` 的 Lua 对应）。
- scope 身份以声明为基准，非行号为基准（java 规格 §7.3）。
- worker 操作模块副本；原始文件永不在原地变异；超时的 mutant 视为已击杀。

**有意偏离 (Deliberate Deviations)**

- 宿主提供的 driver 脚本，而非内置构建工具调用（maven / `go test`）——Lua 无标准
  构建或测试运行器；driver 契约为 Lua 对应方案（suites/lane 参数已移除，
  ADR-0004）。
- 覆盖率来源仅限于 **luacov** 产物（ADR-0003）——JaCoCo/coverprofile 的 Lua
  对应方案；不接受 driver 生成的临时覆盖率格式。
- scope 语义 hash = 对归一化 AST 序列化结果取 FNV-1a（格式无关，clj 的 `pr-str`
  语义升级为 AST；上游三版不一——clj 格式无关 / go 空白归一化 / java 原始子串——
  因此选择符合 AST 迁移的语义，ADR-0001/0004）。

**本分支的破坏性变更**：suites/`--lane`、`--json`、外部 manifest 存储、90% 自动
记录规则及临时 driver 覆盖率均已移除。升级路径见"迁移"一节。

## 功能 (Features)

- 接受单个 Lua 源文件作为目标。
- 使用 luacheck AST 扫描器发现变异位点。
- 按声明 scope 追踪差异化变异：默认情况下，仅重测自记录 manifest 以来 semantic
  hash 发生变化的 scope；`--mutate-all` 强制执行所有已覆盖位点。
- 将 manifest 存储为目标源文件末尾的嵌入式 `--[[ mutate4lua-manifest ... ]]`
  footer 注释。
- 仅在完全干净运行后写入 manifest（所有已执行 mutant 均被击杀，或无 mutant 需
  执行），存在 survivor 或 baseline 失败后绝不写入；`--lines` 抑制写入，因其记录的
  是部分状态。
- 在隔离的工作区副本中运行测试，跨 worker 并行执行（默认：CPU 核数的一半；
  `--max-workers 1` 为串行）。
- 使用标准 `luacov.report.out` 中的行覆盖率跳过未覆盖位点；`--reuse-coverage`
  跳过重新生成，使用 `--test-command` 则禁用覆盖率过滤并给出警告。
- 以文本形式报告已击杀、存活及超时的 mutant。

变异集合包括布尔字面量（`true` ↔ `false`）、比较运算符与算术运算符、布尔运算符
（`and` ↔ `or`）、一元 `not` 与一元负号移除、整型常量 `0` ↔ `1`、字符串字面量
（→ `nil`）以及函数调用表达式（→ `nil`）。

## CLI

本包仅暴露 Lua 模块。不提供独立的 `bin/` 入口点；宿主通过薄 wrapper 接入：

```lua
package.path = "vendor/mutate4lua/lib/?.lua;vendor/mutate4lua/lib/?/init.lua;" .. package.path
os.exit(require("mutate4lua.cli").run(arg, {
  cwd = ".",
  default_driver = "tools/mutate/driver.lua",
  command_name = "lua tools/mutate.lua",
}))
```

通过此类 wrapper 的典型用法：

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

子命令与选项（对应 `--help` 输出）：

| Flag | 含义 |
| --- | --- |
| *(default)* | 运行变异测试 |
| `--scan` | 列出变异位点，不运行测试 |
| `--update-manifest` | 写入/刷新嵌入式 manifest footer，不执行变异 |
| `--mutate-all` | 变异所有已覆盖位点，忽略 manifest |
| `--since-last-run` | 仅变异与 manifest 不同的 scope |
| `--lines N,N` | 限定指定行号（抑制 manifest 写入） |
| `--reuse-coverage` | 复用已有的 `luacov.report.out`，不重新生成 |
| `--max-workers N` | 并行 worker 数（默认：CPU 核数的一半；`1` = 串行） |
| `--timeout-factor N` | mutant 超时倍数，基于 baseline 时长（默认 `10`） |
| `--test-command CMD` | 自定义测试命令，绕过 driver 契约 |
| `--mutation-warning N` | 当选定位点数超过 N 时警告（默认 `50`） |
| `--verbose` | 详细输出 |
| `-h, --help` | 显示帮助 |

## Driver 契约 (Driver Contract)

未提供 `--test-command` 时，引擎通过宿主提供的 driver 脚本（以
`env.default_driver` 传入）驱动测试。本库**不提供默认 driver 路径**——无可用
driver 时立即失败，报错
`error: driver script required: pass --test-command or provide a driver script via env.default_driver (see README)`。

引擎按以下方式调用 driver 脚本：

- baseline 运行（生成覆盖率）：
  `lua <driver> --coverage-report <abs-path> --quiet`
- baseline 运行（`--mutate-all` 或 `--reuse-coverage`）：
  `lua <driver> --no-coverage --quiet`
- mutant 运行：
  `lua <driver> --no-coverage --fail-fast --quiet`

退出 `0` 表示测试通过（mutant 存活）；非零表示失败（mutant 被击杀）。引擎对运行
施加自身的超时控制。

driver 必须在 `--coverage-report` 给定的绝对路径上产出标准
`luacov.report.out`。引擎自行解析该报告，无需依赖 luacov 库。当宿主机未安装
luacov 时，`--coverage-report` 应失败并给出明确提示；`--no-coverage` 运行仍须
正常工作。

`lib/mutate4lua/driver/default.lua` 可作为宿主 driver 的可用起点。

### 真实 luacov 输出格式（解析器契约）

mutate4lua 解析 luacov 的**默认 reporter** 输出（即使用 `luacov` 且未配置自定义
reporter 时产生的格式）。driver 负责生成此精确格式。以下关键特征基于真实
luacov 0.17.0 输出验证：

- **段结构**：每个源文件出现在以 78 个 `=` 字符（`^=+$`）组成的分隔行所界定的
  独立块中。
  ```
  ==============================================================================
  <luacov 所见的路径>
  ==============================================================================
  ```
- **命中次数列**：右对齐；宽度随最大命中次数增长（最小 2 字符以容纳 `*0`）。
  该列后跟一个分隔空格，然后是**逐字**的源码行（含原始缩进）。
- **未命中可执行行**：在次数列位置显示 `*0`（单星号）——无前导空格。示例：
  `*0     return 0`。
- **非可执行行**（空行、`end`、`else`、注释）：无计数前缀——次数列为空（填充
  空格），然后是分隔空格，再是源码行。这些行进号累加但不记录为可执行行。
- **摘要段**：始终为报告的最后一块，以 `Summary` 作为"路径"名。解析器遇到
  `Summary` 即停止，其下的覆盖率表不再消费。
- **路径形态**：luacov 按 `require()` 时的所见记录路径——可能是**相对路径**（如
  `src/foo.lua`）或**绝对路径**（如 `/Users/.../src/foo.lua`）。绝对路径会归一化
  为工作区相对路径以匹配目标。

### 为 Lua 5.4 安装 luacov

driver 需要用 luacov 插桩测试运行以生成 `luacov.report.out`。Lua 5.4（唯一支持
运行时）的安装方法：

```sh
luarocks --lua-version=5.4 --lua-dir=/opt/homebrew/opt/lua@5.4 install luacov
```

使 `require("luacov")` 在 `lua5.4` 下生效：

```sh
export LUA_PATH="/Users/$USER/.luarocks/share/lua/5.4/?.lua;$LUA_PATH"
```

参考 driver（`lib/mutate4lua/driver/default.lua`）使用
`luacov.runner.init()` / `luacov.runner.save_stats()` 插桩测试运行，并调用
`luacov.reporter.report()` 生成报告产物。无法使用 luacov 的宿主应提供
`--test-command`（该选项禁用覆盖率过滤并给出警告）。

## Manifest 存储 (Manifest Storage)

- manifest 以嵌入式 `--[[ mutate4lua-manifest ... ]]` footer 注释形式存储在目标
  源文件末尾。
- 记录 manifest 版本 `4`、模块 hash，以及每个 scope 的：`id`、`kind`、
  `startLine`、`endLine`、`semanticHash`。
- 旧的 `lastMutation*` 字段读取时忽略，写入时不再生成。
- 差异化模式跳过 `semanticHash` 未变的 scope。
- manifest 在干净运行（无 survivor / 无 mutant 需执行）后及 `--update-manifest`
  时写入。baseline 失败后、存在任何 survivor 后或 `--scan` 时绝不写入。`--lines`
  抑制写入。
- 对齐前的外部存储 `.mutate4lua/manifest/` 不再读取或写入。对每个目标文件执行
  一次 `tools/migrate_manifest.lua`，从旧存储/旧 footer 迁移到新的 v4 footer：
  `lua tools/migrate_manifest.lua src/foo.lua`。

## 从对齐前版本迁移 (Migrating)

1. 对每个被变异文件执行一次 `lua tools/migrate_manifest.lua <target.lua>`。该脚本
   会剥离所有旧 footer、删除对应的 `.mutate4lua/manifest/<relative>.manifest`
   存储文件，并追加新计算的 v4 footer。
2. 从脚本和 CI 中移除以下选项：`--index-suites`、`--lane`、`--runner`、
   `--dry-run`、`--poll-interval`、`--json`、`--migrate-manifest`。
3. 将所有自定义 driver 更新为上述新契约（不再包含 `--lane`、
   `--suite-list-file`、`--emit-suite-file-map-json` 或 `--list-suites`）。
4. 如需覆盖率过滤，确保 luacov 可用；否则使用 `--test-command`（该选项禁用覆盖率
   过滤并给出警告）。
5. 默认 `--timeout-factor` 已从 `15` 改为 `10`。
6. 若 `.mutate4lua/manifest/` 目录在更早的检出中存在，将其加入 `.gitignore`；将
   新的 manifest footer 提交到源文件中。

## 接入新项目（示例：eggy）(Integrating)

1. vendor `mutate4lua`（submodule 或直接复制），在薄 wrapper 脚本中将其 `lib/`
   加入 `package.path`，并按上文所示调用 `cli.run`。
2. 提供实现上一节契约的 driver 脚本，以 `env.default_driver` 传入（从
   `lib/mutate4lua/driver/default.lua` 起步即可）。
3. 通过 wrapper 运行变异，如 `lua tools/mutate.lua src/foo.lua`。manifest 在干净
   运行后自动记录；`lua tools/mutate.lua src/foo.lua --update-manifest` 可显式
   固化一份。
4. 将 `.mutate4lua/` 加入 `.gitignore`（缓存及任何残留存储文件）；manifest 位于
   目标源文件内，应一并提交。

## 测试 (Tests)

测试套件使用自包含 harness（`spec/harness.lua`），无外部依赖：

```sh
lua spec/run.lua            # 运行全部 spec/*_spec.lua
lua spec/run.lua spec/cli_spec.lua   # 运行指定文件
```

## 退出码 (Exit Codes)

- `0`：成功，无存活 mutant，无 mutant 需执行，扫描成功，或 manifest 更新成功
- `1`：命令行用法错误或基础设施错误
- `2`：baseline 测试失败
- `3`：至少一个 mutant 存活

## 运行需求 (Requirements)

- Lua 5.3+ 或 LuaJIT（内容哈希——文件、scope 及项目哈希——使用原生 64 位位运算符）
- 如需覆盖率过滤，需 luacov（参考 driver 使用；引擎本身无 luacov 依赖）
- 类 POSIX shell 环境，需有 `find`、`mkdir`、`cp`、`rm`、`sleep` 及 `kill`（并行
  模式使用后台作业与 `wait`）
- 可选：`timeout` 或 `gtimeout`（用于 mutant 超时）——无此命令时，内置纯 shell
  看门狗提供相同的 124 退出码语义

## 兼容性说明 (Compatibility Notes)

- manifest 现以 footer 注释形式写入目标文件；外部 `.mutate4lua/manifest/` 存储
  不再使用。
- CLI 不再支持 `--lane`、`--runner`、`--json` 或 suite 索引；driver 契约缩减为
  coverage/no-coverage + fail-fast。
- 帮助/错误输出中使用的默认 `command_name` 为 `mutate4lua`。

---

## 中文文档

`mutate4lua` 是纯 Lua、与宿主无关的变异测试库，代码位于 `lib/mutate4lua/`。
宿主项目 vendor 本库后，通过 `require("mutate4lua.cli").run(args, env)` 暴露 CLI。

它支持扫描变异位点、按 manifest 做差异化变异（默认只重测 semantic hash 变化过的
scope，`--mutate-all` 强制执行全部已覆盖位点）、在隔离工作区并行执行测试（默认
worker 数为 CPU 核数的一半，`--max-workers 1` 串行）、按 luacov 报告过滤未覆盖位点，
并输出文本报告。manifest 以 `--[[ mutate4lua-manifest ... ]]` footer 注释形式嵌入
目标源文件末尾，随源码一起提交。

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

完整选项列表见 `--help` 或上文 CLI 一节。

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
