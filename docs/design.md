# 设计文档

记录取舍与实测数据。所有数字都是本机实测，命令在文末。

---

## 0. 目标

两条硬要求：**精准**、**快**。

不是"功能最全的 computer-use"，是"每步模型调用最少的 computer-use"。

---

## 1. 为什么不用截图 + 坐标

| 方案 | 准 | 快 | 说明 |
|---|---|---|---|
| 截图 → 模型输出坐标 | ❌ | ❌ | Retina 缩放、多屏、窗口移动后全废；每步一次视觉模型 |
| 截图 → 视觉定位模型 | △ | ❌ | 好一点，但仍然贵，且不可解释 |
| **AX 树 + 元素 ref** | ✅ | ✅ | 不受缩放/位置影响，可按语义选，可解释 |

选第三条。截图只做兜底（Electron app 没有 AX 树时）。

---

## 2. 关键实测：每个属性读都是一次跨进程 IPC

这是整个性能设计的起点。

要渲染一个节点，需要读 role / subrole / title / description / value / placeholder / position / size / children / enabled / focused —— **11 个属性**。逐个读就是 11 次跨进程往返。

实测（180 节点的 Finder 窗口）：

```
逐属性读:  152.7 ms   ≈ 0.85 ms/节点
批量读:     51.5 ms   ≈ 0.29 ms/节点
加速比:     2.97x
```

`AXUIElementCopyMultipleAttributeValues` 一次拿完。Chrome 上同样成立（44.0ms → 16.7ms，2.63x）。

**结论：这是本项目的头号性能杠杆，任何新增属性读取都必须走批量。**

进一步：`AXUIElementCopyActionNames` 是另一条独立 IPC。对 `AXStaticText` / `AXImage` / `AXWindow` 这类几乎不可能带动作的角色直接跳过，省掉约 1/4 的快照耗时。

---

## 3. 端到端延迟预算

`scu snapshot`（含 Python 进程启动与 Swift 子进程启动）：

| app | p50 | p95 | 节点数 |
|---|---|---|---|
| Finder | 92.3 ms | 115.3 ms | ~150 |
| Chrome | 40.8 ms | 55.3 ms | ~54 |
| 飞书 | 50.7 ms | 64.3 ms | ~52 |

拆开看：

| 组成 | 耗时 |
|---|---|
| Swift 进程启动 + dyld（AppKit/ApplicationServices） | ~30 ms |
| AX 遍历（批量读） | Finder ~70 ms / Chrome ~40 ms |
| Python 启动 + JSON | ~30 ms |

**下一步优化**：常驻 daemon 可以省掉两次进程启动（~60ms），并且能缓存树做增量。预计端到端能进 30ms 内。这一版没做，因为无状态版本更简单、更好调试，而且 100ms 已经比模型层快两个数量级。

---

## 4. ref 的稳定性设计

ref 不能是数组下标 —— 树一变就全错。

```
signature = join(祖先的 "角色|前48字文字", "/") + "/" + "角色|自己的文字"
ref       = base36(fnv1a64(signature))[:6]
```

- 用**祖先路径**而不是下标：插入兄弟节点不影响已有元素的 ref
- 用**文字**而不是序号：同类容器也能区分
- 同签名兄弟用 `#2` `#3` 消歧
- 哈希碰撞时追加 `-2`

实测：Finder 连续两次快照，**150/150 ref 一致，0 标签漂移**。

按 ref 操作时会**重新走一遍树**再定位。代价是一次遍历（40–70ms），换来的是"绝不会点到位置上已经变成别的东西的地方"。这是精准的一部分，不是浪费。

---

## 5. 可点祖先解析

实测发现：Finder 侧边栏的 `StaticText: 下载` **不可点**，真正可点的是祖先 `Cell`（带 `AXOpen`）。

所以快照 JSON 里每个元素多一个 `target_ref`：

- 如果自己可点（有动作或是交互角色）→ `target_ref = ref`
- 否则向上找最近的、可点的祖先 → `target_ref = 那个祖先的 ref`

调用方不需要懂 AX 的层级语义，直接用 `target_ref` 就行。

---

## 6. 六级快路径

```
exact   → 目标点名了元素                          0 成本
memory  → 上次谁选对就记住，重新验证后直接用        0 成本
recipe  → 录过的步骤序列直接回放                    0 成本
lexical → 本地 bigram 打分 + 可点击性先验          <1ms
jev     → ≤8 个候选里做封闭选择                    ~2s
handoff → 返回候选表，交回调用方                    0 成本
```

设计原则：

1. **越前面越便宜**，且前面的层能处理绝大多数步骤。
2. **每一级都报告 tier 和 confidence**，调用方永远知道自己在快路径还是慢路径上。
3. **降级不是报错**。`handoff` 仍然给出 `bestGuess` 和排好序的 `candidates`，调用方不用重跑一次。
4. **不确定就说不确定**。低置信一律 `ok:false`，绝不假装。

### 为什么要有 memory 层

这是"重复任务变快"的唯一办法。第一次靠 JEV 或调用方 LLM 选对，把 `(app, goal) → (ref, label, role)` 记下来；第二次直接命中，0 成本。

记忆存 ref + label + role：ref 命中就用，ref 失效就按 label+role 重新定位。所以记忆不会因为 app 重启、窗口重排而失效。

---

## 7. 本地打分的实测边界

17 条**改写过的中文指令**（不是元素标签原文），纯本地路径：

- top-1 **13/17 = 76.5%**（冷启动，无记忆）
- 高置信判定全部正确
- 耗时 **中位 0.5 ms**

失败样例：

| 指令 | 正确 | 选中 | 原因 |
|---|---|---|---|
| 往前面走一页 | 前进 | 群组 | "前面" vs "前进" 只有单字重叠 |
| 搜一下文件 | 搜索 | 共享文件夹 | 被"文件"带偏 |
| 回到上一个文件夹 | 返回 | 共享文件夹 | 零字面重叠 |
| 点击"编辑标签" | 编辑标签 | 标签 | 该视图下没有精确叫"编辑标签"的节点 |

这两条都被如实标成 `gate=low`，会升级到 JEV 或交回调用方 —— 这正是设计意图。

**结论：纯词法做不到精准，所以必须有语义层。但它的置信度是可靠的**，所以适合做分流。

### 踩过的一个坑

第一版打分器用 `score > 0` 过滤候选，导致零字面重叠的候选**直接出局**，正确答案根本进不了候选集（recall@20 只有 71.4%）。

> **预筛绝不能返空。** 词法弱时必须用可点击性兜底补齐。

这条已经写进 AGENTS.md 作为硬约束。

---

## 8. 关于「JEV 能加速」

需要修正这个说法。

| 场景 | 延迟 |
|---|---|
| JEV 官方 benchmark | ~180 ms（美西服务端算力） |
| 从国内实测 | **1.2–4.4 s**（中位 2.1 s） |

180ms 是算力，不是端到端。跨太平洋的光就 150ms 往上了。

所以 JEV 的定位是：**更可靠的决策 + 更低成本 + 结构化概率输出**，不是快。

它被放在第 5 级 —— 只有前面四级都搞不定时才付这个成本。这才是它正确的用法。

---

## 9. 输入合成：默认不抢焦点、不动鼠标

这是整个项目最重要的设计约束 —— **用户正在用电脑时，Agent 不能和他抢**。

### 9.1 先说 Codex 怎么做的（拆二进制得到的事实）

```
SkyComputerUseService 导入符号：
  AXUIElementPerformAction / SetAttributeValue / CopyElementAtPosition / CopyAttributeValue...
  CGEventGetFlags   ← 只用来读修饰键状态

  ✗ 没有 CGEventPost
  ✗ 没有 CGEventPostToPid
  ✗ 没有 IOHIDPostEvent
```

整个 CUA 包、`codex` 主程序、ChatGPT 主程序都查过，一处都没有。
**它不合成鼠标键盘事件，全部通过无障碍动作完成。** 这就是"不占桌面"的真正原因 ——
它压根不碰桌面那一层，而不是"占得比较少"。

### 9.2 三层策略

| 层 | 手段 | 是否打扰用户 |
|---|---|---|
| 元素操作 | `AXUIElementPerformAction`（AXPress/AXOpen/AXConfirm） | 否 |
| 坐标操作 | `AXUIElementCopyElementAtPosition` → 向上找可按祖先 → AXPress | 否 |
| 文本写入 | `AXUIElementSetAttributeValue`（AXSelectedText / AXValue） | 否 |
| 滚动 | `AXScrollUpByPage` 等动作 | 否 |
| 组合键 | 找 `AXMenuItemCmdChar` + `AXMenuItemCmdModifiers` 匹配的菜单项并 AXPress | 否 |
| 兜底 | `CGEvent` 合成 | **是**，必须显式授权 |

### 9.3 实测过的两件事

**① 后台 AXPress 真的能工作。** 飞书不是前台 app，直接对它发 AXPress，
搜索模态被打开了，鼠标没动、前台 app 没变。

**② `CGEvent.postToPid` 能不动鼠标，但后台 app 不响应。**
发给飞书 pid 一个 ⌘K：鼠标位置前后完全一致（说明 `postToPid` 有效），
但飞书毫无反应 —— 键盘事件必须 app 活跃才生效。

所以组合键没有纯后台方案，只能走菜单栏，否则必须接管。这是硬约束，不是实现偷懒。

### 9.4 一个必须澄清的边界：不抢焦点 ≠ 界面上看不见

`AXPress` 不合成输入事件，但它**执行 app 自己的点击逻辑**。实测：后台对飞书搜索按钮
发 AXPress，鼠标没动、前台仍是 Chrome，但飞书的搜索模态**弹出来了**（它是浮动窗口，
盖在所有 app 之上）。

所以"不打扰"要拆成两件事：

| 主张 | 是否成立 |
|---|---|
| 不动你的指针 | ✅ 成立 |
| 不抢你的焦点 | ✅ 成立 |
| 界面上看不见任何变化 | ❌ **不成立**，任何 computer-use 都做不到 |

Codex 同样如此：它做了截图闪光层、快门音、和 `"Esc to cancel"` 取消条，正因为操作可见。

这个边界决定了选型顺序：**能走 API 的别走 GUI；GUI 只读安全，GUI 写入必然可见。**

### 9.5 接管的两个门槛

```bash
--take-over                  # 1. 显式授权
--idle-seconds 2             # 2. 用户至少空闲这么久
```

`--idle-seconds` 用 `CGEventSource.secondsSinceLastEventType(.combinedSessionState, ...)`
取键盘/鼠标/滚动/修饰键里最近的一次事件。

默认 **2 秒**：用户停下手的 2 秒内不会去抢。这比"检测到用户在用就永远不做"实用 ——
Agent 总能等到空隙。

拒绝时给出可分流的原因：`needs_takeover`(11) / `user_active`(12) / `no_ax_action_at_point`(13)。

## 9. 输入合成

| 场景 | 做法 | 副作用 |
|---|---|---|
| 控件点击 | `AXPress` | **不动鼠标、不抢焦点**，用户能继续工作 |
| 普通元素点击 | `CGEvent` 鼠标事件 | 需要窗口在前台，会移动鼠标 |
| 输入文字 | `CGEvent` 逐字符 unicode | 需要目标已聚焦 |
| 快捷键 | `CGEvent` + modifier flags | xdotool 风格的 `super+s` |

优先 AXPress：它对用户打扰最小，而且不依赖窗口层级。

---

## 10. 截图为什么不走 ScreenCaptureKit

SCK 需要真正的 app 生命周期 + 主 runloop。在纯 CLI 进程里调用会直接崩：

```
Assertion failed: (did_initialize), function CGS_REQUIRE_INIT
```

这就是 Codex 要单独打包一个签名 `.app` 的原因。

本项目选择 `screencapture -R <窗口矩形>`：零依赖、任何 CLI 都能跑、启动快。代价是**矩形内的其他窗口会被拍进去**，跨 Space / 多屏时可能拍到别的内容（实测确认）。

截图只做兜底。真要纯净窗口图，得做一个 `.app` 走 SCK —— 这是个明确的后续项。

---

## 10.5 AX 不可用：三种完全不同的情况

排查时踩了很久，值得单独记下来。三种情况表面都像"权限没了"，实际处理方式完全不同。

### A. `AXIsProcessTrusted()` 为 false —— 真的没授权

去 系统设置 → 隐私与安全性 → 辅助功能 勾选终端。标准路径，无歧义。

### B. 系统级探针返回 `-25204` —— **假阴性，不是故障**

```swift
AXUIElementCreateSystemWide() + kAXFocusedApplicationAttribute  →  -25204 (cannotComplete)
```

实测在**一切正常**的时候这个调用也会稳定失败。所以**绝对不能拿它当健康探针** ——
第一版 `doctor` 就是这么写的，导致工具明明能用却报"不可用"。

正确探针：对**某个具体 app** 读一次 `AXRole`：

```swift
AXUIElementCreateApplication(front.pid) + kAXRoleAttribute  →  0 (success)
```

现在已经改成这样。如果用 `-25204` 判断健康，会遇到"doctor 说不行但 snapshot 正常"的怪现象。

### C. 窗口全部变成 app 代理 —— AX 服务真的无响应

`scu doctor` 现在会单独报这个：`accessibilityUsable: true` 但 `windowUsable: false`，
reasonCode 是 `no_accessible_windows`，exit 3。**只看第一项会误报可用** —— 这就是
"doctor 说行、snapshot 说 no_window" 的根源。

症状很有辨识度：

| 现象 | 说明 |
|---|---|
| `kAXWindowsAttribute` 里每个元素 `CFEqual(app, w) == true` | 拿回来的是 app 元素本身 |
| 这些"窗口"没有 `AXPosition` / `AXSize` / `AXCloseButton` | 不是真窗口 |
| 所有 app 同时这样 | 不是某个 app 的问题 |
| 早先能用的旧二进制也卡住 | 排除代码回归 |

实测触发条件：**显示器休眠 / 长时间无人操作**。约 36 分钟无操作后进入这个状态，
用户回到机器后自行恢复。会话本身没有锁定（`CGSessionCopyCurrentDictionary()` 里
没有 `CGSSessionScreenIsLocked`，`kCGSSessionOnConsoleKey = 1`）。

处理：
- 工具侧**快速失败**，报 `no_window` 或 `ax_cannot_complete`（exit 10），
  而不是往桌面里递归——第一版就是这么炸到 4000 个节点的
- 窗口校验必须检查 role ∈ {AXWindow, AXSheet, AXDialog}，不能拿到什么就用什么

### 顺带：为什么 Codex 要做一个签名 `.app`

同一类问题的产品化答案。Codex 的 `CUALockScreenGuardian` 专门处理锁屏，
错误文案写得很直白："The Mac is locked. Unlock it before reading accessibility text."
这印证了 AX 的可用性依赖 GUI 会话/显示器状态，而不是一次授权终身有效。

## 11. 没做的和为什么

| 没做 | 原因 |
|---|---|
| 常驻 daemon | 无状态版本更简单、更好调试。100ms 已经够快。列为下一步（预计进 30ms） |
| ScreenCaptureKit | 需要 .app 上下文，和"单文件 CLI"的定位冲突 |
| 多平台 | AX / UIA / AT-SPI 语义差太多，硬套一个抽象是负担 |
| drag | AX 无法表达拖拽语义，必须坐标。优先级低于精度 |
| 录制回放 | recipe 已支持静态步骤序列；自动录制需要监听用户操作，成本高 |

---

## 12. 复现本文数字

```bash
cd runtime && swift build -c release && cd ..
python3 bench/run.py --runs 10
./cli/scu bench --app com.apple.finder --runs 20
```

批量 vs 逐属性的对比需要手工验证（`AXUIElementCopyMultipleAttributeValues` 的 A/B）。本项目当前只保留了批量实现。
