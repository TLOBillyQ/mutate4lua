# mutate4lua 性能根因事实报告

> 以下结论全部来自对 `lib/mutate4lua/` 及 `tests/` 的只读源码分析，引用具体文件与行号。未运行任何基准测试，量级为基于代码路径的估算。

---

## 1. 每个 mutant 的执行路径

### 1.1 工作区准备：`cp -r` 完整复制项目

- 引擎在 `engine.mutate` 中先创建一个完整工作区副本：`cp -r <source_dir>/. <workspace>/`（`engine.lua:96-107`）。
- 串行模式下只用 **1 个**工作区；并行模式下会再创建 `worker_count - 1` 个副本，每个都是一次完整 `cp -r`（`engine.lua:109-122`、`engine.lua:661-672`）。
- 复制范围是 `env.cwd` 下的全部内容（含 `.git`、依赖、测试等），没有忽略规则。

### 1.2 每个 mutant 都派生新的 `lua` 解释器

- 无论串/并行，每个 mutant 都通过 `run_shell` 执行一条形如：

  ```sh
  cd <workspace> && lua <runner.lua> --no-coverage --fail-fast --quiet
  ```

  的命令（`engine.lua:331-344`、`engine.lua:651-656`、`engine.lua:685-687`、`engine.lua:715-718`）。
- `run_shell` 最终走 `os.execute`（`engine.lua:80`），即每个 mutant 都派生一个 **全新的 `lua` OS 进程**。

### 1.3 runner 每次重新 require 整个依赖图

`runner.lua` 被调用时：

1. 重新设置 `package.path`（`runner.lua:151-158`）；
2. `require("luaunit")`（`runner.lua:160`）；
3. 若生成覆盖率则 `require("luacov.runner")` 并 `init()`（`runner.lua:176-183`）；
4. 对每个测试文件执行 `loadfile`（`runner.lua:109-119`）；
5. 覆盖率运行结束后调用 `luacov.reporter.report()`（`runner.lua:206-211`）。

因此 **每个 mutant 都冷启动一次测试依赖图**。

### 1.4 变异应用方式

- 串行：先 `scanner.apply_mutation` 写入工作区目标文件，跑测试，再写回原始源码（`engine.lua:716-720`）。
- 并行：`prepare` 回调把当前 mutant 写入对应 workspace slot（`engine.lua:682-684`），各 slot 独立。

---

## 2. 扫描/解析侧开销

### 2.1 扫描器位置与实现

- 扫描器：`lib/mutate4lua/internal/scanner.lua`。
- **并非自研 lexer**；实际使用 **luacheck 的 decoder + parser** 生成 AST（`internal/ast.lua:6-11`、`internal/ast.lua:53-68`）。
- 扫描流程（`scanner.analyze`，`scanner.lua:334-409`）：
  1. `ast.parse_source(source)` → luacheck AST；
  2. `ast.extract_functions(chunk)` 提取所有 `Function` 节点；
  3. 为每个 scope 计算 `semantic_hash`；
  4. `walk_mutations` 递归遍历 AST 发现位点；
  5. 按位置排序位点。

### 2.2 Manifest / Scope hash 计算方式

- **Scope semantic hash**：对 scope 的 AST 子树先做 `ast.normalize_node`（抹平格式、标识符、字面量等），再做 `ast.serialize` 成 S-expression 字符串，最后 `util.fnv1a64`（`scanner.lua:384-386`、`internal/ast.lua:179-279`、`util.lua:496-531`）。
- **Project hash**：`project.project_hash` 遍历项目根下所有 `*.lua` 和 `*.rockspec`（排除 `.git`、`.mutate4lua` 等段），把“相对路径 + `\n` + 内容 + `\n\0\n`”拼接后取 FNV-1a64（`internal/project.lua:49-78`）。
- 这些 hash 计算都是 **每次运行一次**，不是每个 mutant 一次。

---

## 3. 并行架构

实现文件：`lib/mutate4lua/internal/parallel.lua`。

- **模型**：shell 后台作业 + sentinel 文件轮询。
- `parallel.run` 为每个 worker 维护一个 slot；每个 job 生成一个 launcher shell 脚本，通过：

  ```sh
  sh <launcher> >/dev/null 2>&1 &
  ```

  后台启动（`parallel.lua:132-134`）。
- launcher 把退出码原子写入 `status_path`（temp + `mv -f`），并把输出写入 `output_path`（`parallel.lua:29-71`）。
- 主循环 busy-wait 轮询每个 slot 的 `status_path` 是否出现（`parallel.lua:216-253`）。
- 默认 `DEFAULT_POLL_INTERVAL = 0`，即 **忙等**（`parallel.lua:18`、`parallel.lua:73-80`）。
- 无 `timeout(1)` 时，launcher 把子进程 PID 写入 `pid_path`，池侧看门狗到超时后 `kill` 并写入 124 退出码（`parallel.lua:94-108`）。

### 同步开销

- 每个 job 都要创建/删除 3~4 个临时 sentinel 文件（`status_path`、`output_path`、`launcher_path`、`pid_path`）。
- 完成检测靠 `util.read_file` 反复读文件；虽然是纯 Lua 不 fork shell，但对快速 mutant 来说忙等 + 文件 I/O 是显著开销。
- 测试结果回调 `on_complete` 在主线程串行执行（`parallel.lua:157-166`）。

---

## 4. “Lua 慢” vs “架构开销”分类

| 类别 | 具体环节 | 发生频率 |
|------|----------|----------|
| **Lua CPU 密集** | luacheck AST 解析；AST normalize/serialize；FNV-1a hash；project hash 读所有源文件并拼接 | 每目标文件一次 |
| **架构开销** | `cp -r` 工作区；每个 mutant `os.execute` 派生 `lua`；runner 重新 require luaunit/luacov、loadfile 所有测试；写/读 sentinel 文件；忙等轮询；写回/恢复源文件 | 每 workspace / 每 mutant |

### 典型场景估算

假设：200 行源文件、20 个 mutant、测试套件裸跑 2s、默认 `max_workers ≈ CPU/2`（按 4 核算约 2 worker）、项目不大。

- **扫描 + hash**：AST 解析 + 遍历 + project hash 读项目全部文件 ≈ **0.1–0.3s**（纯 Lua，但只一次）。
- **Baseline**：2s（跑一次完整测试）。
- **工作区复制**：串行 1 次 ≈ **0.1–0.5s**；并行 2 个 worker 共 2 次 ≈ **0.2–1.0s**。
- **每个 mutant 的固定开销**：
  - `os.execute` 派生 shell + `lua` 进程启动 ≈ **30–80ms**；
  - runner 重新 require luaunit、loadfile 测试文件 ≈ **50–200ms**；
  - sentinel 文件 I/O + 忙等 ≈ **5–20ms**。
  - 合计每个 mutant 冷启动开销 ≈ **0.1–0.3s**。
- **每个 mutant 的测试运行**：`--fail-fast` 下若被击杀通常提前退出，平均可能 **0.5–1.5s**。

**串行 20 mutant 总时间粗略**：

```
baseline 2s + 复制 0.3s + 20 × (0.2s 启动 + 1.0s 测试) ≈ 26s
```

其中架构开销（复制 + 进程/loader 启动）约占 **20–35%**。

**并行 2 worker 20 mutant 总时间粗略**：

```
baseline 2s + 2×复制 0.6s + ceil(20/2) × (0.2s + 1.0s) ≈ 14.6s
```

并行把测试时间压下来，但每个 mutant 的进程启动、runner 冷启动、sentinel 同步仍是固定税。

---

## 5. 不重写内核的优化杠杆

| 优化点 | 具体做法 | 预计能省什么 |
|--------|----------|--------------|
| **Symlink overlay 替代 `cp -r`** | 像 clj-mutate 一样，工作区里只复制目标源文件，把 `lib/`、`src/`、`spec/`、`test/`、`tests/` 等用 symlink 指回原项目 | 工作区准备时间从 O(项目大小) 降到 O(1)；大量减少磁盘 I/O。对小型项目也能省 0.1–0.5s/次，对大型项目收益巨大 |
| **runner / worker 常驻** | 不再每个 mutant 都 `lua runner.lua`，而是启动一个长期运行的 Lua worker，通过 stdin/socket 接收“运行第 i 个 mutant”指令，测试依赖只 require 一次 | 每个 mutant 省掉 0.1–0.3s 的进程启动 + loader 时间；对 20 mutant 可省 2–6s，对 200 mutant 可省 20–60s |
| **减少 sentinel 文件轮询** | 用 shell `wait -n` 或进程间 pipe/Unix socket 通知完成，替代 busy-wait 读文件 | 消除忙等 CPU；对快速 mutant 提升明显 |
| **缓存扫描与 hash** | 目标文件未变时复用上次的 AST、scope hash、project hash；用 mtime 判断 | 每目标文件省 0.1–0.3s；对 CI 增量跑尤其有效 |
| **project hash 只读相关文件** | 当前会读项目根下所有 `.lua`/`.rockspec`；可改为只读目标文件及其依赖（或允许配置 include/exclude） | 大项目中 project hash 可能从数百 ms 降到数 ms |
| **合并 launcher 文件** | 当前每个 mutant 要写一个 shell launcher 脚本；可直接内联命令到 `os.execute`，只在需要 fallback 看门狗时才写脚本 | 每个 mutant 省一次临时文件创建/删除 |
| **优先使用 `timeout` 命令** | 检测到 `timeout`/`gtimeout` 就走原生超时，不走 pid 文件看门狗路径 | 避免 pid 文件读写和 `kill` 竞态 |
| ** runner 内建测试缓存** | 首次 loadfile 后缓存 chunk，后续 mutant 复用 | 每个 mutant 省 50–200ms 测试加载时间 |

### 综合评估

- 当前瓶颈 **不是“Lua 语言本身做词法/解析慢”**；扫描、AST 遍历、hash 都是每目标文件一次，且 luacheck parser 虽是 Lua 实现但 200 行文件可忽略。
- 真正让 mutate4lua 慢的是 **架构税**：每个 mutant 都 spawn 新 `lua` 进程 + 冷启动 runner + workspace 复制 + sentinel 文件同步。
- 如果目标是“让 Lua 项目变异测试变快”，**先优化架构比用 Go 重写内核更划算**：把 `cp -r` 换成 symlink overlay、让 runner 常驻、减少进程派生，这三项 alone 可能把 20 mutant 场景从 ~15s 降到 ~10s 以内，且改动范围集中在 `engine.lua` 与 `parallel.lua`，不触及扫描/变异逻辑。

### 关键代码定位速查

- 工作区复制：`engine.lua:96-122`
- runner 命令构建：`engine.lua:331-344`、`engine.lua:651-656`
- 串行 mutant 循环：`engine.lua:714-724`
- 并行调度入口：`engine.lua:675-712`
- 并行实现/哨兵轮询：`parallel.lua:124-256`
- AST 解析：`internal/ast.lua:53-68`
- scope hash：`scanner.lua:384-386`
- project hash：`internal/project.lua:49-78`
- FNV-1a：`util.lua:496-531`