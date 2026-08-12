# mutate4* 系列变异测试工具研究报告

> Robert C. Martin (Uncle Bob) 的跨语言变异测试工具族系分析
> 研究范围：mutate4go · clj-mutate · mutate4lua

---

## 一、概述

Uncle Bob 在三个语言生态中分别实现了变异测试工具，遵循相同的核心哲学但做出了截然不同的架构取舍：

| 工具 | 语言 | 仓库位置 | 定位 |
|------|------|---------|------|
| **mutate4go** | Go | `github.com/unclebob/mutate4go` | 独立二进制 CLI，标准 Go 测试 |
| **clj-mutate** | Clojure | `github.com/unclebob/clj-mutate` | Speclj 绑定，`bb`/`clj` 启动 |
| **mutate4lua** | Lua | `lzxsvn:3000/eggy/mutate4lua` | 宿主无关纯库，Driver 契约 |

三个工具共享的核心流程：

```
源码解析 → 发现变异点 → 运行覆盖率 → 过滤未覆盖位点
→ Baseline 测试 → 逐个应用变异 → 运行测试 → 报告结果 → 更新 Manifest
```

---

## 二、源码解析：语言特性决定实现方式

这是三个工具差异最大的维度，完全由宿主语言的特性决定。

### mutate4go — 标准库 AST

```go
import "go/ast"       // Go 标准库
import "go/parser"    // Go 标准库

// 解析
fset := token.NewFileSet()
file, _ := parser.ParseFile(fset, path, content, 0)

// 遍历
ast.Inspect(file, func(node ast.Node) bool {
    switch n := node.(type) {
    case *ast.BasicLit:   // 字面量
    case *ast.Ident:      // 标识符 true/false
    case *ast.BinaryExpr: // 二元表达式
    }
})
```

利用 Go 标准库的 `go/ast` 和 `go/parser`，直接用完整的语法树。这是最正统的 AST 方式——节点类型系统完善，位置信息精确。但 Go AST 的类型系统比较繁琐，每个节点类型都要做 type switch。

### clj-mutate — S-表达式树遍历

```clojure
(require '[clojure.tools.reader :as reader])

;; Clojure 代码本身就是数据结构
(letfn [(walk [grandparent parent node]
          ;; node 就是普通的 list/vector/map/symbol
          )]
  (walk nil nil form))
```

Clojure 的**同像性**（homoiconicity）让变异发现变得极其简单。`clojure.tools.reader` 直接将源码读成嵌套的数据结构（list、vector、map、symbol、keyword 等）。`find-mutations` 函数不需要任何 AST 遍历框架，只需要递归处理 Clojure 内置的集合类型。这是三者中最简洁的实现。

### mutate4lua — 自研词法分析器

Lua 没有标准 AST 库，所以 mutate4lua 手写了一个完整的词法分析器：

```lua
-- 200+ 行的词法分析器，处理：
-- 字符串：[=[...]=] 长括号转义
-- 数字：0x hex, 0b binary, 科学计数法
-- 注释：--[[ 块注释, -- 行注释
-- 关键字：and/or/not/function/end 等
local tokens = lexer.tokenize(source)

-- 然后基于 token 流做模式匹配
-- 函数调用检测需要前看多个 token
local begin, finish = match_call(tokens, index)
```

这是三者中复杂度最高的实现，而且受限于 token 流的表达力，有些判断（如一圆负号、函数调用位置的确认）需要手动处理上下文。

### 对比总结

| 语言 | 解析方法 | 实现难度 | 精确度 | 代码量 |
|------|---------|---------|--------|--------|
| Go | 标准库 AST | 低 | 高 | ~100 行（mutations.go） |
| Clojure | 同像性 + reader | **极低** | **极高**（S-表达式） | ~80 行（mutations.cljc） |
| Lua | 自研 lexer | 高 | 中等（token 级） | ~200 行 lexer + ~200 行 scanner |

---

## 三、变异规则

| 类别 | mutate4go | clj-mutate | mutate4lua |
|------|-----------|------------|------------|
| **算术** | `+`↔`-`, `*`→`/` | `+`↔`-`, `*`→`/`, **`inc`↔`dec`** | `+`↔`-`, `*`↔`/` |
| **比较** | `>`↔`>=`, `<`↔`<=` | `>`↔`>=`, `<`↔`<=` | `>`↔`>=`, `<`↔`<=` |
| **相等** | `==`↔`!=` | `=`↔`not=` | `==`↔`~=` |
| **布尔** | `true`↔`false` | `true`↔`false` | `true`↔`false` |
| **逻辑** | `&&`↔`\|\|` | — | `and`↔`or` |
| **条件** | — | **`if`↔`if-not`, `when`↔`when-not`** | — |
| **常量** | `0`↔`1` | `0`↔`1` | `0`↔`1` |
| **一元操作符** | — | — | `not` 删除、一元 `-` 删除 |
| **字符串** | — | — | **字符串 → `nil`** |
| **函数调用** | — | — | **函数调用表达式 → `nil`** |
| **等价变异抑制** | — | ✅ `suppress-when` 谓词链 | — |

### 等价变异抑制（clj-mutate 独有）

```clojure
;; 规则 + 抑制谓词
{:original '>   :mutant '>=  :category :comparison
 :suppress-when [rand-comparison? subvec-trim-boundary?]}

;; 抑制条件：父节点是 (< (rand) ...)
(defn- rand-comparison?
  [{:keys [parent]}]
  (and (seq? parent) (>= (count parent) 3)
       (let [second-elem (second parent)]
         (and (seq? second-elem) (= 'rand (first second-elem))))))
```

clj-mutate 的抑制谓词可以访问 `parent` 和 `grandparent`，做任意深度的树结构检查。这是三个工具中唯一具备等价变异抑制能力的。抑制的场景包括：

- `(< (rand) 0.5)` → `<` 变异为 `<=` 在 double 上等价
- `(rand-nth [0 1])` → 池中常量 `0`/`1` 变异等价
- `(if (= 1 (count x)) (first x) (rand-nth x))` → 保护逻辑
- `(if (> (count v) N) (subvec v 0 N) v)` → subvec 边界变异等价

### mutate4lua 的额外规则

mutate4lua 拥有三个其他工具没有的规则：

1. **字符串 → `nil`**：检测对字符串参数的依赖是否被正确处理
2. **函数调用 → `nil`**：检测函数返回值的使用是否被正确验证
3. **一元操作符删除**：`not` 和一元负号的移除

这些规则的加入反映了 Lua 语言的惯用模式——函数调用无处不在，字符串作为参数传递频繁，一元操作符使用普遍。

---

## 四、Manifest 存储：家族的共同选择与一个叛逃者

三个工具中有两个选择了**嵌入源文件**的方案，mutate4lua 选择了**外部存储**。

### mutate4go — Go 注释尾部嵌入

```go
// mutate4go-manifest-begin
// {"version":1,"tested_at":"...","module_hash":"abc...",
//  "functions":[
//   {"id":"func/Score","name":"Score","line":3,"end_line":5,"hash":"def..."}
// ]}
// mutate4go-manifest-end
```

JSON 格式，通过 `//` 注释嵌入。写入前会备份源文件 (`.mutate4go.bak`)，防止中断导致文件损坏。

### clj-mutate — Clojure 注释尾部嵌入

```clojure
;; clj-mutate-manifest-begin
;; {:version 1, :tested-at "2026-03-14T08:12:00Z",
;;  :module-hash "-1711527434",
;;  :forms [{:id "defn/find-mutations", :kind "defn", :line 117, :end-line 139, :hash "..."}]}
;; clj-mutate-manifest-end
```

EDN 格式（Clojure 原生数据格式），通过 `;;` 注释嵌入。格式与 mutate4go 的结构高度相似，应该是同一设计思路的产物。

### mutate4lua — 外部存储

```
.mutate4lua/manifest/
  └── src/
      └── demo/
          └── flag.lua.manifest
```

外部存储文件的主体复用旧版 footer 的 `key=value` 格式。mutate4lua 还保留了**读取回退**能力——当外部 store 无条目时，会回退读取源文件中的旧 footer（`--[[ mutate4lua-manifest ... ]]`），并提供了 `--migrate-manifest` 命令将旧 footer 迁出。

### 设计权衡

| 方案 | 代表 | 优点 | 缺点 |
|------|------|------|------|
| **源文件嵌入** | mutate4go, clj-mutate | 版本控制同步、无漂移风险 | 修改业务源码、多人协作产生 diff |
| **外部存储** | mutate4lua | 业务流程零侵入、支持跨 lane 记录 | 需额外管理同步、可能与源码漂移 |

---

## 五、差分粒度

| 工具 | 差分单位 | 哈希输入 | 示例 |
|------|---------|---------|------|
| **mutate4go** | 函数 | 函数体源码（normalize 后 SHA256） | `func/Score` |
| **clj-mutate** | 顶层表单 | `(hash (pr-str form))` | `defn/find-mutations`、`def/usage-summary` |
| **mutate4lua** | 作用域 | scope 内所有 token 拼接后 FNV-1a | `function:Score:5`、`chunk:src/demo.lua` |

clj-mutate 的顶层表单粒度最为丰富——除了 `defn` 和 `def`，还包括 `ns`、`defn-`、`defmacro`、`defmulti`、`defmethod`，以及匿名表单（`form/{idx}/{head}`）。

mutate4lua 的作用域粒度最细——它跟踪的不只是函数，还有 `if`、`do`、`repeat` 块。而且引入了 **lane** 概念：即使 scope 内容没变，如果上次跑的是 `behavior` lane 而这次是 `contract` lane，也会触发重测。

### clj-mutate 的差分标注

```clojure
{:new-form-indices #{3 5}                        ;; 全新的表单
 :manifest-violating-form-indices #{1 7}          ;; 哈希变化的既有表单
 :changed-form-indices #{1 3 5 7}}                ;; 合并结果
```

clj-mutate 区分了"新增表单"和"manifest 违规表单"，并在头部报告中分别计数，对开发者更友好。

---

## 六、并行执行架构

| 维度 | mutate4go | clj-mutate | mutate4lua |
|------|-----------|------------|------------|
| **并发模型** | Goroutine + Channel + WaitGroup | JVM `future` + `LinkedBlockingQueue` | Shell 进程池 + sentinel 文件轮询 |
| **Worker 隔离** | 完整复制项目目录 | **符号链接 overlay** + 目标文件副本 | 完整 `cp -r` 复制 |
| **默认 worker** | 0（串行，需 `--max-workers`） | `Runtime.availableProcessors` | CPU 核数的一半 |
| **超时机制** | `context.WithTimeout` | `Process.waitFor(timeout, TimeUnit)` | `timeout`/`gtimeout` 命令或纯 shell 看门狗 |
| **同步方式** | Channel 原生同步 | `LinkedBlockingQueue.poll()` + `future` | 轮询 sentinel 文件（可忙等或 sleep） |
| **Worker 目录** | `target/mutation-workers/run-{pid}-{timestamp}/` | `target/mutation-workers/run-<UUID>/` | 临时目录 `_ws*` |

### clj-mutate 的 symlink overlay 设计

```clojure
;; 只复制项目配置文件和目标源文件
(spit (str dir-path "/" config) (slurp (str project-root "/" config)))
;; spec/ 目录是软链，所有 worker 共享
(symlink! (str dir-path "/spec") (str project-root "/spec"))
;; 只有目标源文件是真实副本
(spit (.getPath source-file) original-content)
```

这是三个中最高效的隔离方案——利用文件系统的符号链接避免了重复复制不变的 `spec/` 目录。mutate4go 和 mutate4lua 都采用完整的目录复制，更简单但启动开销更大。

### mutate4lua 的超时看门狗

```lua
-- 当系统没有 timeout 命令时的纯 Lua/shell 看门狗
local flag = util.shell_quote(util.tmp_path(".timeout"))
local seconds = tostring(math.ceil(timeout_seconds))
full = full .. "{ "
  .. "( " .. shell_command .. redirect .. " ) & pid=$!; "
  .. "( sleep " .. seconds .. "; touch " .. flag .. "; kill -9 $pid 2>/dev/null ) & wp=$!; "
  .. "wait $pid; ec=$?; "
  .. "kill $wp 2>/dev/null; wait $wp 2>/dev/null; "
  .. "if [ -f " .. flag .. " ]; then ec=" .. tostring(TIMEOUT_EXIT_CODE) .. "; fi; "
  .. "rm -f " .. flag .. "; "
  .. "exit $ec; } 2>/dev/null"
```

mutate4lua 在没有 `timeout(1)` 命令的系统上通过纯 shell 实现了等价的超时控制。这种"自给自足"的设计是 mutate4lua 全篇的基调。

---

## 七、覆盖率集成

| 维度 | mutate4go | clj-mutate | mutate4lua |
|------|-----------|------------|------------|
| **格式** | Go `-coverprofile` | LCOV（Cloverage） | 自定义 `file:line`（Driver 输出） |
| **新鲜度检查** | 无（每次重新生成） | ✅ 对比 `mtime`，自动或提示重新生成 | 无 |
| **Stale 警告** | `--reuse-coverage` 时简单提示 | **详细的 stale 诊断信息** | 无 |
| **BB 模式** | N/A | ✅ 自动检测并跳过覆盖 | N/A |
| **未覆盖过滤** | 差分模式下默认 | 差分模式下默认 | 非 `--mutate-all` 时默认 |

clj-mutate 的覆盖集成最完善：

```clojure
(defn- stale-reason [^File lcov-file source-path]
  (cond
    (not (.exists lcov-file)) :missing
    (< (.lastModified lcov-file) (newest-input-mtime source-path)) :stale
    :else nil))

;; 对比 src/ 和 spec/ 的最新 mtime
(defn- newest-input-mtime [source-path]
  (let [source-file (File. source-path)
        src-mtime (newest-file-mtime (File. "src"))
        spec-mtime (newest-file-mtime (File. "spec"))]
    (max source-mtime src-mtime spec-mtime)))
```

当使用 `--reuse-lcov` 且 LCOV 缺失时，抛出带 ex-data 的异常，在上层捕获并给出清晰错误：

```
Error: --reuse-lcov was requested, but target/coverage/lcov.info does not exist.
Run without --reuse-lcov once to generate coverage.
```

mutate4go 的覆盖集成最简单——每次拼接 `-coverprofile=` 到测试命令后执行。mutate4lua 则完全交由 Driver 脚本处理，引擎通过 `--coverage-file` 参数接收。

---

## 八、测试框架耦合度

这条谱系从"紧密绑定"到"完全解耦"：

```
clj-mutate (Speclj 绑定)
       ↓
mutate4go (go test，但有 --test-command 退路)
       ↓
mutate4lua (纯 Driver 契约，无默认实现)
```

### clj-mutate — 深度绑定 Speclj

```clojure
(defn default-test-command [dir]
  (if (bb-project? dir)
    "bb spec"
    "clj -M:spec --tag ~no-mutate"))
```

自动探测 Babashka 还是标准 Clojure，但两者都意味着 Speclj。`--tag ~no-mutate` 是 Speclj 特有的标签排除语法，用于避免 mutation worker 内部递归启动 mutation 测试。

### mutate4go — 默认 go test，可覆盖

```go
const DefaultTestCommand = "go test ./..."
```

默认绑定 `go test`，但通过 `--test-command` 可以完全替换。不过覆盖率集成（追加 `-coverprofile=`）会假设目标测试框架支持 Go 标准覆盖格式。

### mutate4lua — 完全解耦的 Driver 契约

```
Driver 契约接口：
  ├── --coverage-file <path>    写入覆盖率数据
  ├── --no-coverage             跳过覆盖率收集
  ├── --suite-list-file <path>  只运行指定 suites
  ├── --fail-fast               遇到失败立即停止
  ├── --quiet                   安静模式
  ├── --emit-suite-file-map-json  输出 suite→文件 映射
  └── --list-suites --json      列出所有 suite 名称
```

mutate4lua 不假定任何测试框架。宿主提供 Driver 脚本实现上述接口，引擎通过标准化的命令行参数驱动。这让 mutate4lua 可以适配 harness、busted 等任何测试框架，但代价是入门的复杂度——宿主需要先写一个 Driver。

---

## 九、家族设计 DNA

尽管实现差异巨大，三个工具共享了 Uncle Bob 的设计基因：

### 1. 增量优先

```go
// mutate4go: 默认差分（manifest 存在时）
effectiveSinceLastRun := options.SinceLastRun || (hasManifest && !options.MutateAll)
```

```clojure
;; clj-mutate: 默认差分
(defn default-since-last-run? [lines since-last-run mutate-all prior-manifest]
  (and (nil? lines) (not mutate-all)
       (or since-last-run (some? prior-manifest))))
```

```lua
-- mutate4lua: 默认差分
if not options.mutate_all then
    if old_manifest then
        sites = filter_by_changed_scopes(sites, changed_scopes)
    end
end
```

三个工具首次运行都是全量，之后默认走差分模式，只测变化的部分。

### 2. 逐文件运行

工作流完全一致：一次一个源文件，逐个清理。

### 3. 覆盖率过滤

都先跑覆盖率，跳过未覆盖的变异位点，节省时间。

### 4. 中断保护

```go
// mutate4go
func SaveBackup(path, content string) error { ... }
func RestoreBackup(path string) (bool, error) { ... }
```

```clojure
;; clj-mutate
(defn- backup-path [source-path] (str source-path ".mutation-backup"))
```

```lua
-- mutate4lua: 复制到隔离目录运行，无需备份
```

mutate4go 和 clj-mutate 都保存源文件备份，因为它们在原目录修改源文件。mutate4lua 在隔离目录工作，天然受保护。

### 5. Worker 隔离

都在隔离目录中运行并行变异，避免相互干扰。

### 6. CLI 选项高度同构

```
--scan / --update-manifest / --mutate-all / --lines / --since-last-run
--max-workers / --timeout-factor / --test-command / --mutation-warning
```

三个工具的 CLI 选项几乎一一对应，明显出自同一蓝图。

---

## 十、总评

| 评价维度 | mutate4go | clj-mutate | mutate4lua |
|---------|-----------|------------|------------|
| **实现简洁度** | ★★★★☆ | **★★★★★** | ★★★☆☆ |
| **变异规则丰富度** | ★★★☆☆ | **★★★★☆**（含等效抑制） | **★★★★★**（含函数调用/字符串） |
| **源代码解析精确度** | ★★★★★（AST） | **★★★★★**（S-表达式） | ★★★☆☆（Token 级） |
| **框架独立性** | ★★★★☆ | ★★☆☆☆（Speclj） | **★★★★★**（Driver 契约） |
| **并行效率** | ★★★★☆ | **★★★★★**（symlink overlay） | ★★★☆☆（完整复制） |
| **覆盖集成成熟度** | ★★★☆☆ | **★★★★★**（mtime 新鲜度检查） | ★★★★☆ |
| **增量工作流** | ★★★★☆ | **★★★★★**（标注 new vs violating） | ★★★★☆（scope + lane） |
| **自给自足程度** | ★★★★☆（依赖 go 工具链） | ★★★★☆（依赖 JVM） | **★★★★★**（纯 Lua + POSIX） |
| **生态适应性** | ★★★★☆（Go 单一测试框架） | ★★☆☆☆（Speclj 专用） | **★★★★★**（适配任意框架） |
| **代码侵入性** | ★★☆☆☆（修改源文件） | ★★☆☆☆（修改源文件） | **★★★★★**（绝不修改源码） |

### 最佳实践场景

- **mutate4go**：Go 项目，标准 `go test` 工作流，需要简单可靠的变异测试
- **clj-mutate**：Clojure + Speclj 项目，需要等价变异抑制和精细化差分
- **mutate4lua**：Lua 项目，需要无损源码、适配自定义测试框架、跨测试 lane 的新增工具

### 设计启示

1. **语言生态决定架构复杂度**：Go 有标准 AST 库和统一测试框架，实现最简单；Lua 生态碎片化，迫使 mutate4lua 走更复杂的架构路线；Clojure 的同像性使实现最简洁但代价是框架绑定。

2. **Manifest 嵌入 vs 外部存储**：嵌入方案在单人项目中简单有效，但在多人协作中会产生 diff 噪音。外部存储方案更干净但需要额外的同步机制。

3. **等价变异抑制是进阶功能**：clj-mutate 的 `suppress-when` 机制通过 parent/grandparent 上下文做树结构检查，是一个值得其他工具借鉴的设计模式。

4. **Driver 契约是解耦的利器**：mutate4lua 的 Driver 设计虽然入门门槛高，但一旦建立就能适配任意测试框架，是三个中扩展性最强的方案。
