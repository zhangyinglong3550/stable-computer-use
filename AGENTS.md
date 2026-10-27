# AGENTS.md

给在这个仓库里干活的 Agent 的约定。

## 这是什么

给任意 Agent 用的 macOS computer-use。核心是 Swift 读 AX 树 + Python CLI 包一层。

## 目录

- `cli/scu` — 单文件 Python CLI，**只用标准库**。不要引入第三方依赖。
- `runtime/Sources/scu-ax/main.swift` — Swift，负责 AX 遍历、ref 计算、输入合成。
- `bench/run.py` — 延迟与准确率基准。改性能后必须重跑，数字写进 README。
- `skill/SKILL.md` — 给 Agent 的一页说明书。改命令必须同步改这里。

## 改代码的硬约束

1. **不加依赖**。CLI 只用标准库；Swift 不用第三方包。
2. **动作用 ref，不用下标**。ref 必须是祖先路径签名的哈希，不能是 `nodes[i]` 的序号。
3. **预筛绝不返空**。词法信号弱时用可点击性兜底，否则正确答案会永久出局。
4. **每一级决策必须报告 tier 和 confidence**。不许假装确定。
5. **降级不是报错**。没 key / JEV 不可用 / Electron 没 AX 树，都要给出可用的替代路径和 reasonCode。
6. **数字必须实测**。README 里的延迟和准确率来自 `bench/run.py`，不要写估计值。
7. **每个属性读取都是一次跨进程 IPC**。新增属性读取要评估代价，能用批量读就用批量读。

## 提交前

```bash
cd runtime && swift build -c release && cd ..
./scripts/test.sh
./cli/scu doctor
python3 bench/run.py --runs 10
```

全都要过。bench 数字变了就更新 README 里的表格。

集成测试在 AX 不可用时自动跳过 —— 跳过不等于通过，本地提交前请确认 `scu doctor`
的 `accessibilityUsable` 是 `true`，让集成测试真的跑起来。
