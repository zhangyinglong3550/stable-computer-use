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

**常驻 daemon 已经做了**：复用活元素缓存 + 可见区过滤，动作命中缓存时是微秒级；CLI 端到端仍有一次进程启动（~60ms），100ms 级已经比模型层快两个数量级。

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

### 9.1 Codex 是否合成键鼠事件（待核实）

提交 [`ec4c352`](https://github.com/zhangyinglong3550/stable-computer-use/commit/ec4c352)（2026-10-27 16:33，北京时间）拆二进制时，观察到的导入符号是：

```
SkyComputerUseService 导入符号：
  AXUIElementPerformAction / SetAttributeValue / CopyElementAtPosition / CopyAttributeValue...
  CGEventGetFlags   ← 只用来读修饰键状态

  ✗ 没有 CGEventPost
  ✗ 没有 CGEventPostToPid
  ✗ 没有 IOHIDPostEvent
```

整个 CUA 包、`codex` 主程序、ChatGPT 主程序当时都查过，这几处都没有上述三个投递符号。仓库没有记录拆的是哪个版本。上一个提交 `8266604` 里还没有这段观察。

**待核实，不要把上面写成结论。** 「没有这几个导入符号」推不出「不合成鼠标键盘事件、全部通过无障碍动作完成」：事件可以走 NSEvent 转换或私有接口投递。官方来源查不到。OpenAI 博客和 ChatGPT Learn 文档只说用自己的光标看、点、打字，以及可以和剪贴板交互，没有说明底层是 AX 动作还是合成事件。

**说法 A（本仓库）**

- 提交 [`ec4c352`](https://github.com/zhangyinglong3550/stable-computer-use/commit/ec4c352)，2026-10-27 16:33（北京时间）。
- 内容就是上面的符号观察：没有 `CGEventPost` / `CGEventPostToPid` / `IOHIDPostEvent`，有 AX 动作相关符号。

**说法 B（第三方逆向，都不是官方）**

- [waku 文档](https://github.com/egoist/waku/blob/6d433e87/docs/sky-macos-accessibility-reverse-engineering.md)：分析 `@oai/sky` 0.6.2，服务版本 26.727.1000550。文档首次提交 2026-08-04（北京时间）；链接固定在 `6d433e87`，那次提交是 2026-08-12（北京时间）。说法是坐标点击先构造 NSEvent，再转成 CGEvent，带上窗口 ID，「posted directly to the target PID」；键盘通过 `SynthesizedEvent` 生成按 PID 投递的事件；后台焦点靠 `SyntheticAppFocusEnforcer` 加 event tap。作者自己标注这部分是「语义重建，不是源码」，具体用哪个投递函数没有写明。
- [paralym/codex-computer-use-cli](https://github.com/paralym/codex-computer-use-cli)：README 日期 2026-05-02。同时写了「没有 `CGEventPost` 符号」和「用 `SyntheticAppFocusEnforcer`、`NSEvent.mouseEvent(windowNumber:)` 做可信投递」。
- [vtomnet 的字符串分析](https://github.com/vtomnet/codex-cua-tea/blob/main/SkyComputerUseService.md)：2026-04-17。说它 “uses event taps and synthetic CGEvent input”。
- [openai/codex issue #53861](https://github.com/openai/codex/issues/53861)：用户在 2026-10-14（北京时间）提交，作者标记为 NONE，不是 OpenAI 员工。报告说 `CGGetEventTapList` 显示 SkyComputerUseService 持有 3–5 个按进程的键盘 tap，二进制里有 `keyboardEventTap`、`SystemFocusStealPreventer`。

复查办法：在 Mac 上对当前安装的服务版本用 `nm` / `otool` 复查导入符号；在 Codex 执行后台操作时用 `CGGetEventTapList` 看它有没有装 event tap。核实之前，符号观察只是观察。

### 9.2 三层策略

| 层 | 手段 | 是否打扰用户 |
|---|---|---|
| 元素操作 | `AXUIElementPerformAction`（AXPress/AXOpen/AXConfirm） | 否 |
| 坐标操作 | `AXUIElementCopyElementAtPosition` → 向上找可按祖先 → AXPress | 否 |
| 坐标操作（`--via pid`） | `CGEventPostToPid` 定向鼠标事件 | 否 |
| 文本写入 | `AXUIElementSetAttributeValue`（AXSelectedText / AXValue） | 否 |
| 文本写入（`--via pid`） | `CGEventPostToPid` 定向键盘事件 | 否（可能被拒） |
| 滚动 | `AXScrollUpByPage` 等动作；没有就定向滚轮 | 否 |
| 组合键 | 找 `AXMenuItemCmdChar` + `AXMenuItemCmdModifiers` 匹配的菜单项并 AXPress；否则定向投递 | 否 |
| 兜底 | `CGEvent` 系统事件流 | **是**，必须显式授权 |

### 9.3 实测过的两件事

**① 后台 AXPress 真的能工作。** 飞书不是前台 app，直接对它发 AXPress，
搜索模态被打开了，鼠标没动、前台 app 没变。

**② `CGEvent.postToPid` 的鼠标事件有效，键盘事件看 app。**
发给飞书 pid 一个 ⌘K：鼠标位置前后完全一致（说明 `postToPid` 有效），
但飞书毫无反应 —— 键盘事件必须 app 活跃才生效。鼠标事件则被 Finder 后台窗口接收
（实测点到了窗口内的关闭按钮）。

所以：鼠标 `--via pid` 是可靠的静默路径；键盘 `--via pid` 只能算"尽力投递"，
结果一律 `unverified(synthetic_input)`。真要保证键盘落地，走菜单项或显式接管。
这是 app 层的约束，不是 API 的。

### 9.4 结果契约：ok 与 verification 是两件事

| 字段 | 含义 |
|---|---|
| `ok` | 动作被接受并执行（无硬错误）。坐标动作若 AX 返回失败但界面确实变了，也会置 true，原始错误进 `providerError` |
| `verification.state` | `verified`（有读回证据）/ `unverified`（没有） |
| `verification.reason` | `value_readback` / `ui_changed`；或 `synthetic_input` / `clipboard_paste` / `value_mismatch` / `value_unchanged` / `axpress_unasserted` / `ui_unchanged` / `provider_unavailable` |

合成输入永远不会因为"界面变了"升级成 verified：变了不等于输入落到了目标控件。


### 9.5 一个必须澄清的边界：不抢焦点 ≠ 界面上看不见

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

### 9.6 接管的两个门槛

```bash
--take-over                  # 1. 显式授权
--idle-seconds 2             # 2. 用户至少空闲这么久
```

`--idle-seconds` 用 `CGEventSource.secondsSinceLastEventType(.combinedSessionState, ...)`
取键盘/鼠标/滚动/修饰键里最近的一次事件。

默认 **2 秒**：用户停下手的 2 秒内不会去抢。这比"检测到用户在用就永远不做"实用 ——
Agent 总能等到空隙。

拒绝时给出可分流的原因：`needs_takeover`(11) / `user_active`(12) / `no_ax_action_at_point`(13)。

### 9.7 状态条为什么在 daemon 进程里

屏幕上那条 `scu · click / verified · via ax` 是 daemon 自己开的无边框 NSPanel，
不是独立 app。三个理由：

1. **浮窗不需要 TCC**。显示本身不要任何权限；把窗口搬进独立 .app 不会少一次授权，只会多一次安装。
2. **独立 .app 的成本在签名/安装/SMAppService**，收益是权限隔离 —— 但 scu 的权限本来就在调用方进程
   （终端 / agent），helper 拿不拿 AX 权限对这条窗没有任何影响。
3. **展示不能拖慢调用**：HUD 更新发生在 `writeLine` 之后（响应已写回 socket），完全异步。

代价是 daemon 主线程要跑 `NSApplication.run()`，socket accept 循环挪到后台串行队列。
实测动作耗时不变（`actMs` 2ms，`waitedMs` 45–50ms，与加 HUD 前一致）。

副作用（好的）：daemon 有 runloop 之后，`NSWorkspace` 的 app 列表通知也正常了。
不过 `sysctl` 兜底仍然保留 —— `SCU_HUD=0` 时 daemon 是纯后台进程，没有 runloop。

上面第 1 点「浮窗不需要 TCC」只描述**已经在跑**的这条纯展示状态条。下面的 Esc 监听是另一项权限，而且还没做。

### 9.8 计划中：Codex 式小窗口与 Esc 取消（尚未实现）

计划把操作时的状态条换成 Codex 式小窗口，显示「正在操作你的电脑 · 按 Esc 取消」。Esc 用全局键盘监听，需要 macOS 的「输入监控」权限。**这是计划中 / 即将加入的行为，当前代码没有实现，不要当成现有功能。** 现在的状态条没有 Esc 取消，也不会为此申请权限。`SCU_HUD=0` 仍可关闭状态条（CI / 无 WindowServer）；`SCU_HUD_POS=bottom` 贴屏幕底部。

| 问题 | 计划中的行为 |
|---|---|
| 什么时候弹系统授权提示 | 只在小窗口的 Esc 取消功能开启时 |
| 授权在哪 | 系统设置 → 隐私与安全性 → 输入监控 |
| 用户拒绝之后 | 只是不能用 Esc 取消，其他操作照常 |
| Esc 会不会被吃掉 | 不会。Esc 只监听、不拦截，因此也会到达前台应用 |
| 取消何时生效 | 只在两步之间。正在执行的单个 AX 调用不能被打断 |
| 取消后的返回 | `cancelled`，并带上已完成的步数 |

## 10. 截图为什么不走 ScreenCaptureKit

SCK 需要真正的 app 生命周期 + 主 runloop。在纯 CLI 进程里调用会直接崩：

```
Assertion failed: (did_initialize), function CGS_REQUIRE_INIT
```

这就是 Codex 要单独打包一个签名 `.app` 的原因。

本项目的 `scu shot` 不在 CLI 进程里调 SCK。能解析到窗口 ID 时用 `screencapture -x -o -l <windowID>`：按窗口抓，不受 Space 和遮挡影响。窗口 ID 来自 `winid`，按 pid + 几何在 `CGWindowList(optionAll)` 里找（`optionAll` 才能看到别的 Space 上的窗口）。没有窗口 ID 时才退回 `screencapture -R <窗口矩形>`。`-R` 拍的是屏幕区域，矩形里盖在上面的其他窗口会被拍进去，跨 Space / 多屏时可能拍到别的内容；响应里的 `note` 会说明只有这条退路才会这样。

截图只做兜底。

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
| ScreenCaptureKit | 需要 .app 上下文，和"单文件 CLI"的定位冲突 |
| 独立 helper.app | 权限隔离只在「把工具分发给别人」时才值钱；当前形态（调用方授权 + daemon 展示）已够用 |
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

## 13. SCU_TRACE 口径

`SCU_TRACE=1` 时，调用方进程的 stderr 上每一步一行 JSON。口径如下。

1. 一步等于 `act` 数组里的一个操作，或一次单独的 `actAndWait`，不是一次 `act` 调用。`step` 从 0 开始；按 `indexBase` 续号时，结果里的 `index` 仍和 trace 里的 `step` 对齐。
2. `wait_exit` 是可选字段，只在真的进入等待时才有，值为 `changed`、`timeout` 或 `cancelled`。`text_not_found`、`cache_miss` 这类没进入等待的失败没有它。`cancelled` 表示等待被取消提前结束，不是超时；它不进超时命中率的分母。
3. `snapshots` 是附加字段，记这一步里做了几次快照。
4. `target` 只在 `SCU_TRACE=1` 时出现，内容是文字点击命中的节点名，可能是会话名或消息文字，含用户界面上的文字，写到 stderr。贴到群里、报告或 issue 之前要先检查并脱敏。

`resolve_ms` 是找目标的时间，包括取快照和定位，`actAndWait` 动作前那次轻量快照（`wait_before`）记在这里。`deliver_ms` 是把动作投递出去的时间。`wait_ms` 是等到界面变化或超时的整段时间，轮询快照和中间的等待都算在里面。`verify_ms` 是校验写入或核对结果的时间。

取消与 `wait_exit` 的关系：一步的动作已经投递、取消打断的是这一步的等待时，该步算已完成（`completedSteps` 包含它），照常输出一行 trace，`wait_exit` 记 `cancelled`。取消发生在某步动作送出之前时，该步不执行，不输出 trace，不计入 `completedSteps`，也不算超时。`completedSteps` 和 trace 只按 daemon 确认的写投递计数：JS 本地拦下的结果（带 `local:true`）不参与 daemon 计数比较。

### runId 判定表

写请求（`click` / `set` / `type` / `key` / `scroll` / `act` / `actAndWait` / `activate`）在找目标之前按 `runId` 判定；只读请求（`snapshot` / `ping`）不拦，只带标记。

| 请求 | runId | daemon 行为 | 响应 |
|---|---|---|---|
| 单独命令行写命令 | 不带 | 正常执行 | 正常结果 |
| 写命令 | 等于当前 runId，当前 run 未取消 | 正常执行 | 正常结果 |
| 写命令 | 等于当前 runId，当前 run 已取消 | 不执行 | `{"ok":false,"status":"cancelled","completedSteps":n}` |
| 写命令 | 不等于当前 runId（过期） | 不执行 | `{"ok":false,"reasonCode":"stale_run"}` |
| 只读请求 | 不带 / 等于当前未取消 | 正常执行 | 正常结果 |
| 只读请求 | 等于当前 runId，当前 run 已取消 | 正常执行 | 正常结果 + `runCancelled:true` |
| 只读请求 | 不等于当前 runId（过期） | 正常执行 | 正常结果 + `runStale:true` |

`socketLoop` 串行处理请求，`begin_run` 换号只能发生在两次请求之间，所以一次 `actAndWait` 内部的 runId 不会中途变化，入口判定即可覆盖它的整个等待循环。

取消的 `reason`（`reasonCode`）只有两个取值：`cancelled`（当前 run 被取消）和 `stale_run`（runId 过期）。两者在结果里的 `status` 都是 `"cancelled"`，不新增别的 status；`stale_run` 不参与 `completedSteps` 计数，因为 daemon 根本没执行。

`cancel` 对跨进程的调用方只在两次请求之间生效。为了不让 `expect` 的轮询白等到超时，daemon 对带 `runId` 的**只读**请求照常执行、照常返回结果，只在响应上多带 `runCancelled` / `runStale`。JS 侧据此停止等待：`act` 内返回 `status: "cancelled"`，不记成 `expect_timeout`。

脚本级 API 的取消统一抛 `CancelledError`：`scu.waitFor`、`scu.sleep` 和每个写 API（含 `scu.activate`）在发现 `cancelled` / `stale_run` 时抛出，不再返回 `false` / `undefined` 让脚本继续跑。`scu js` 顶层捕获后向 stdout 输出 `{"ok":false,"status":"cancelled","completedSteps":n}`（`stale_run` 时多带 `reasonCode`），退出码 `130`。普通脚本错误仍是 stderr + 退出码 `1`，参数错误退出码 `2`。`act()` 不抛，仍按上面的结果契约返回 `status: "cancelled"`。

降级：`SCU_HUD=0`（CI / 无 WindowServer）时 daemon 退出 AppKit、socket 循环直接占用主线程，进程内的 Esc 监听没有 runloop 可跑。这种模式下只剩「调用之间的取消」：另一个连接发来的 `cancel` 排在正在执行的 `actAndWait` 之后，只能在两次 RPC 之间生效，进不了它的等待轮询。等待阶段能被提前打断，依赖同进程另一线程调用 `requestCancel()`（HUD 开着时的 Esc 监听就是这么用的）。Esc 监听必须留在 daemon 进程里，不能做成单独进程再发 socket `cancel`。socket 上的 `cancel` 只有带了当前 `runId` 才置位；缺 `runId` 或对不上当前 run 时不改标记（`reasonCode: "run_mismatch"`），避免晚到的旧 run 把新 run 取消掉。
