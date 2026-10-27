# stable-computer-use

给任意 AI Agent 用的 **macOS 精准 computer-use**。读无障碍树（AX），给每个元素一个**跨快照稳定的 ref**，按 ref 操作。

> [stable-chrome](https://github.com/zhangyinglong3550/stable-chrome) 的姊妹项目：那边给 Agent 一双操作浏览器的手，这边给一双操作桌面 app 的手。

中文 | [English](#english)

**核心要求只有两条：精准，快。**

---

## 它解决什么问题

Agent 要操作桌面 app，主流做法是「截图 → 模型看像素 → 输出坐标点击」。这条路的问题是：

- **不准**：Retina 缩放、多屏、窗口移动后坐标全废
- **慢**：每一步都要过一次模型

stable-computer-use 换成另一条路：**读 AX 树，按元素操作**。

```
[3netay] Button: 搜索  <AXPress>
[2i3k0m] StaticText: 个人收藏
[1w5zxu] Row  <AXOpen>
```

元素带 ref，动作直接引用 ref。不用算坐标，不怕缩放，不怕窗口移动。

---

## 最重要的一条：不抢焦点、不动鼠标

**默认情况下 `scu` 不移动你的指针、不切换焦点、不激活目标 app。** 你继续用你的窗口，它在后台操作。

| 动作 | 默认路径 | 动鼠标/抢焦点 |
|---|---|---|
| 点按钮 / 菜单项 | `AXUIElementPerformAction` | ❌ |
| 按坐标点 | 命中测试 → 找可点祖先 → `AXPress` | ❌ |
| 往输入框写字 | 直接写 `AXSelectedText` / `AXValue` | ❌ |
| 滚动 | AX 滚动动作 | ❌ |
| 组合键 ⌘K 等 | 查菜单栏同名菜单项并触发 | ❌（命中时） |
| 读界面 | AX 树 / 按窗口截图 | ❌ |

### 但要说清楚：**不抢焦点 ≠ 界面上看不见变化**

`AXPress` 不合成输入事件，可它**执行的是 app 自己的点击逻辑**。目标 app 完全可能因此弹出一个模态窗、展开一个面板、或刷新整页——那些窗口盖在谁上面，不由库决定。

> 实测：后台对飞书的搜索按钮发 `AXPress`，鼠标没动、前台没变，但飞书的搜索模态**确实弹出来了**。

这不是实现缺陷，是任何 computer-use 的固有属性。Codex 也一样——它专门做了 `AppshotCaptureTransitionOverlayWindow`（截图闪光）、`Appshot.wav`（快门音）和一句 `"ChatGPT is using your computer" / "Esc to cancel"` 的取消条，**正因为它的操作是可见的。**

所以选型时按这个顺序：

| 优先级 | 做法 | 会打扰吗 |
|---|---|---|
| 1 | **用 API / CLI，不碰界面**（如 `lark-cli` 查消息） | 完全不打扰，而且更准 |
| 2 | **GUI 只读**：`snapshot` / `shot` | 完全不打扰 |
| 3 | GUI 写入：点击/输入/开菜单 | **必然可见**，只能选你不在用的时候做 |

**能用 API 解决的任务，不要用 GUI 解决。** 这是这个项目的第一原则，比任何 AX 技巧都重要。

### 确实需要抢前台时

只有真的没辙的动作（比如发送真键盘组合键），才会要求接管，而且两个条件同时满足：

```bash
scu click --app X --xy 100,200 --via mouse --take-over --idle-seconds 2
#                                              ^^^^^^^^^^^  ^^^^^^^^^^^^^^^^
#                                              明确授权      你至少空闲 2 秒
```

| reasonCode | exit | 含义 |
|---|---|---|
| `needs_takeover` | 11 | 这个动作会打断你，需要显式 `--take-over` |
| `user_active` | 12 | 你刚操作过电脑，现在抢焦点会打扰你 |
| `no_ax_action_at_point` | 13 | 该坐标没有可执行的无障碍元素（可退回 `--via mouse`） |

### 为什么能做到不动鼠标

Codex 的 computer-use 也是这么做的——我拆了它的二进制，它**根本不合成鼠标事件**：

```
SkyComputerUseService 导入的符号里没有 CGEventPost / CGEventPostToPid / IOHIDPostEvent
只有 AXUIElementPerformAction、AXUIElementSetAttributeValue、AXUIElementCopyElementAtPosition
```

唯一绕不开的是真键盘输入：实测 `CGEvent.postToPid` 能把事件投给指定进程且不移动鼠标，但 app 不在前台时**不会响应**。所以组合键要么走菜单栏，要么就得接管。

## 为什么是它：三个可验证的点

### 1. 快照快到不值得优化

`scu snapshot` 端到端（含进程启动）：

| app | p50 | p95 |
|---|---|---|
| Finder | **92 ms** | 115 ms |
| Chrome | **41 ms** | 55 ms |
| 飞书 | **51 ms** | 64 ms |

其中 AX 遍历用**批量属性读**（一次 IPC 拿全部属性，而不是每个属性一次往返），比逐属性读快 **3 倍**：

```
Finder  逐属性 152.7ms → 批量 51.5ms   (2.97x)
Chrome  逐属性  44.0ms → 批量 16.7ms   (2.63x)
```

对比一下成本：JEV 从国内实测 1.2–4.4s，大模型一步数秒。**本地这层比模型层快 40–120 倍。**

### 2. 六级快路径，越前面的越少花钱

不是「要么本地要么模型」，而是一条阶梯：

| 层级 | 手段 | 成本 | 何时命中 |
|---|---|---|---|
| `exact` | 目标里点名了元素（引号包裹或全表唯一） | **0** | `点击"搜索"` |
| `memory` | 上次谁选对就记下来，重新验证后直接用 | **0** | 同一个目标第二次 |
| `recipe` | 录过的步骤序列直接回放 | **0** | 重复性任务 |
| `lexical` | 本地字符 bigram 打分 + 可点击性先验 | **<1 ms** | 高置信时才直接执行 |
| `jev` | 在 ≤8 个候选里做封闭选择 | ~2 s | 本地说不准时 |
| `handoff` | 返回候选表，交回调用方的 LLM | 0 | 兜底 |

每一级都**如实报告自己在第几级、置信度多少**：

```bash
$ scu decide --app com.apple.finder --goal '点击"搜索"'
{"ok": true, "tier": "exact", "targetRef": "3netay", "targetName": "搜索",
 "confidence": 1.0, "confidenceGate": "high", "recommendedAction": "act"}
```

### 3. 记忆让重复任务归零

```bash
# 第一次：本地打分说不准 → 走 JEV 或交给你自己的 LLM
$ scu decide --app com.apple.finder --goal "回到上一个文件夹"
{"ok": false, "tier": "handoff", "confidence": 0.149,
 "bestGuess": {"ref": "3akzfa", "name": "共享文件夹"},
 "candidates": [ ... ]}

# 你选对了，告诉它一次
$ scu remember --app com.apple.finder --goal "回到上一个文件夹" --ref mkq0ob
{"ok": true, "remembered": {"goal": "回到上一个文件夹", "ref": "mkq0ob", "name": "返回"}}

# 之后：零模型、98ms
$ scu decide --app com.apple.finder --goal "回到上一个文件夹"
{"ok": true, "tier": "memory", "targetName": "返回", "confidence": 0.99}
```

JEV 高置信命中时也会**自动写进记忆**，不需要手动 remember。

---

## 实测：本地打分到底多准

17 条**改写过的中文指令**（不是元素标签原文），纯本地路径：

- **top-1 准确率 13/17 = 76.5%**（冷启动，无记忆）
- 高置信（gate=high）的判定 **全部正确**（样本小，但趋势明确）
- 本地打分耗时 **中位 0.5 ms**

失败的 4 条全是语义缺口，且**全部被如实标成 `gate=low/medium`**：

| 指令 | 正确 | 选中 |
|---|---|---|
| 回到上一个文件夹 | 返回 | 共享文件夹（conf 0.15） |
| 往前面走一页 | 前进 | 群组（conf 0.0） |
| 搜一下文件 | 搜索 | 共享文件夹（conf 0.10） |
| 点击"编辑标签" | 编辑标签 | 标签（conf 0.21） |

注意：76% 里只有少数是**高置信**的，其余虽然猜对了但 `gate` 是 low，会被交给下一级。这是故意的 —— 猜对但不敢确定，不如交出去。

准确率会随窗口内容变化（同一条指令在不同 Finder 视图下结果不同），所以请以**你自己机器上跑出来的数字**为准。

**这是刻意设计的**：本地打分不追求全对，它负责「高置信直接执行、低置信如实上报」。剩下的交给 JEV 或你的 LLM。诚实地上报不确定，比假装确定有用得多。

跑自己的基准：

```bash
python3 bench/run.py
```

**先跑 `scu doctor`**：`accessibilityUsable` 必须是 `true`。只是 `accessibility: true` 不够 —— 见下面的已知限制。

---

## 安装

前置：macOS 13+、Xcode Command Line Tools、Python 3.8+。

```bash
git clone https://github.com/zhangyinglong3550/stable-computer-use
cd stable-computer-use
cd runtime && swift build -c release && cd ..
./cli/scu doctor
```

`doctor` 里 `accessibility` 必须是 `true`。不是的话：**系统设置 → 隐私与安全性 → 辅助功能**，勾选你的终端（Terminal / iTerm / VS Code）。

装技能到各 Agent：

```bash
./scripts/install.sh
```

---

## 命令

```bash
scu doctor                                  # 权限与二进制自检
scu apps                                    # 列出有窗口的 app
scu snapshot --app Finder                   # AX 树，带稳定 ref
scu snapshot --app Finder --json            # 同上，结构化

scu click --app Finder --ref 3netay         # 按 ref 点击（推荐）
scu click --app Finder --text "搜索"        # 按名字点击
scu click --app Finder --ref R --via ax     # 走 AXPress，不动鼠标、不抢焦点
scu type  --app TextEdit --text "hello"
scu key   --app Finder --key "super+n"
scu scroll --app Safari --ref R --direction down --pages 2
scu set   --app TextEdit --ref R --value "全文替换"

scu verify --app Finder --ref 3netay        # 执行前校验：还在吗？可点吗？位置在哪？
scu shot  --app Finder --out /tmp/f.png     # 窗口矩形截图

scu decide --app Finder --goal '点击"搜索"'
scu do     --app Finder --goal '点击"搜索"'  # decide + act 一次做完
scu remember --app Finder --goal G --ref R  # 教它一次，下次零成本

scu recipe save NAME < steps.json
scu recipe run  NAME --app Finder
scu recipe list

scu bench --app Finder --runs 20
```

所有命令输出 JSON，带统一的 `reasonCode` 和 exit code。

---

## ref 为什么"稳定"

ref 不是数组下标，是**祖先路径签名**的哈希：

```
signature = join(祖先的 "角色|前48字文字") + "/" + "角色|自己的文字"
ref       = base36(fnv1a64(signature))[:6]
```

所以树里插入了新元素、别人家的节点变了，**你的 ref 不变**。同签名兄弟节点用 `#2#3` 消歧。

实测：Finder 连续两次快照，**150/150 个 ref 完全一致，0 个标签漂移**。

按 ref 操作时重新走一遍树再定位 —— 所以 ref 永远指向**当前的**那个元素，不会点到已经变成别的东西的位置。

---

## 精度从哪来

比"选得准"更重要的是**执行前校验**：

| 手段 | 说明 |
|---|---|
| 稳定 ref | 跨快照不变，不是下标 |
| **可点祖先解析** | 文字节点自己点不动，自动解析到最近的可点祖先。Finder 侧边栏就是一例：Text 不可点，可点的是祖先 `Cell` |
| 执行前校验 | `enabled` 为假直接拒绝；ref 不在当前树里报 `stale_ref` |
| AX 优先，鼠标兜底 | 控件优先走 `AXPress`（不动鼠标、不抢焦点）；普通元素才合成鼠标事件 |
| 脏字符清洗 | 真实 app 的标题里塞零宽字符（Chrome 窗口标题实测一堆 `\u200b`），不清洗会污染匹配 |
| 绝不丢候选 | 词法信号弱时用可点击性兜底，**预筛永不返空** —— 否则正确答案永久出局 |

---

## JEV 是可选的加速器，不是依赖

没配 `TYPESAFE_API_KEY` 时不会报错：`decide` 走到 `handoff`，把候选表原样交回，由你自己的 LLM 决策。

```bash
export TYPESAFE_API_KEY=...
```

**关于「JEV 能加速」这个说法，需要修正**：JEV 官方 benchmark 是 ~180ms（美西服务端算力），从国内实测 **1.2–4.4s**（中位 2.1s）。所以它的价值是**更可靠的决策 + 更低成本（约 $0.00004/次）**，不是快。

真正让它快的是把它放在第 5 级 —— 只有前面四级都搞不定时才付这个成本。

---

## 已知限制（诚实版）

| 限制 | 说明 |
|---|---|
| **Electron app 可能没有 AX 树** | 飞书、Sublime 有时 `AXWindows` 返回 0 个窗口。需要 app 自己打开 `AXManualAccessibility`。兜底是截图 + 坐标 |
| **矩形截图会串窗口** | `scu shot` 用 `screencapture -R`，盖在目标窗口上的其他窗口会被拍进去。跨 Space / 多屏时可能拍到别的内容。需要纯净窗口图得走 ScreenCaptureKit（要一个 .app 上下文） |
| **无文字容器排最后** | 兜底候选优先给有文字的元素，纯图标按钮可能选不中，用 ref 或坐标 |
| **鼠标点击需要窗口在前台** | `--via ax` 可以不动鼠标不抢焦点，但不是所有控件都支持 AXPress |
| **`AXIsProcessTrusted()` 会骗人** | 返回 `true` 不代表真能读。另外**不要**用系统级的 `kAXFocusedApplicationAttribute` 当健康探针 —— 实测正常状态下它也会稳定返回 `-25204`，是假阴性。`scu doctor` 已改成对具体 app 做探针，看 `accessibilityUsable` |
| **长时间无操作 / 显示器休眠后 AX 会无响应** | 症状：所有 app 的窗口都变成 app 元素本身（没有位置/尺寸），旧二进制也会卡住。回到机器后自行恢复。工具会报 `ax_cannot_complete`(exit 10) 而不是崩溃 |
| 窗口最小化 / 在别的 Space 时可能取不到 | 这时返回 `no_window`，不是崩溃。先把窗口调出来 |
| **只做 macOS** | 别的平台 AX/UIA 语义差太多，硬套一个抽象是负担 |

---

## 与其它项目的关系

这个赛道已经很挤，stable-computer-use 的差异点只有两个：**公开延迟基准**和**六级快路径 + 记忆**。

| 项目 | 差异 |
|---|---|
| [open-computer-use](https://github.com/iFurySt/open-computer-use) | 跨三平台，MCP 形态，功能更全 |
| [macos-harness](https://github.com/browser-use/macos-harness) | 同为 Python 每步一命令，更薄，无决策层 |
| [agent-desktop](https://github.com/lahfir/agent-desktop) | Rust，有常驻 command host，保留原生 AX 对象 |
| [Peekaboo](https://github.com/openclaw/Peekaboo) | Swift，截图与检查能力最全，带可选 agent |

如果你要的是"最全的功能"，用它们。如果你要的是"每步最少的模型调用 + 可对比的延迟数字"，用这个。

---

## 开发

```
cli/scu                     单文件 Python CLI（纯标准库）
runtime/Sources/scu-ax/     Swift AX 助手（批量读、稳定 ref、输入合成）
skill/SKILL.md               给 Agent 的一页说明书
bench/run.py                 延迟 + 准确率基准
docs/design.md               设计取舍与实测数据
```

### 测试

```bash
./scripts/test.sh
```

分两层：

| 层 | 文件 | 需要权限 | 说明 |
|---|---|---|---|
| 单元 | `tests/test_unit.py` | ❌ | 26 条，覆盖文本清洗、打分器（含"预筛绝不返空"回归）、置信度、记忆、exit code |
| 集成 | `tests/test_integration.py` | ✅ | 14 条，真读 AX：ref 唯一性与跨快照稳定性、零宽字符清洗、target_ref 可解析、verify、decide 各层、记忆闭环、截图 |

集成测试在 AX 不可用（没授权 / 锁屏 / 显示器休眠）时**整体跳过而不是失败**，所以 CI 里也不会红。

单独跑：

```bash
python3 tests/test_unit.py
python3 tests/test_integration.py
```

---

## English

**stable-computer-use** gives any AI agent precise macOS computer-use by reading the
accessibility tree instead of pixels. Every element gets a **stable ref**
(a hash of its ancestor path, not an array index), and actions reference that ref.

- **Fast**: batched AX attribute reads make snapshots ~3x faster than
  reading attributes one at a time (Finder 153ms → 52ms). End-to-end snapshot
  p50 is 51–105ms depending on the app.
- **Precise**: stable refs, nearest-clickable-ancestor resolution, pre-action
  verification, and zero-width character sanitization.
- **Cheap by default**: a six-tier decision ladder — `exact`, `memory`,
  `recipe`, `lexical`, `jev`, `handoff`. Only reaches for a model when local
  signals are weak, and always reports which tier it used.
- **Optional JEV**: works without an API key by handing candidates back to
  your own LLM.

Requires macOS 13+, Xcode CLT, Python 3.8+. Grant Accessibility permission to
your terminal, then `./cli/scu doctor`.

---

MIT License.
