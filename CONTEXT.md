# CONTEXT

mutate4lua 领域术语表。

## 核心概念

- **mutant（变异体）**：对目标源文件应用一条变异规则后的版本；测试通过则"存活"（survivor），失败/超时则"被击杀"（killed）。
- **scope**：差异化追踪的最小单位，以声明为基准（函数、`if`、`do`、`repeat` 块），以 semantic hash 判变。
- **manifest**：嵌入目标源文件尾部的 `--[[ mutate4lua-manifest ... ]]` footer，记录各 scope 的 hash，用于差分选择。
- **baseline**：变异前先跑的一次完整测试，确认套件本身通过并生成覆盖率。

## 性能专题术语（Gitea 地图 #1「mutate4lua 性能优化」）

- **架构税**：每个 mutant 的固定开销——进程派生 + runner 冷启动（重新 require luaunit / loadfile 测试）+ 工作区 `cp -r` 复制 + sentinel 文件同步。与 Lua 语言本身的速度无关；瓶颈分析显示它是慢的主因。
- **低风险档**：不改变行为规格的优化杠杆集合（symlink overlay、消除忙等、扫描/hash 缓存、project hash 收窄）。
- **架构档**：改变组件契约的优化杠杆（目前仅 runner 常驻一项），需 ADR。
