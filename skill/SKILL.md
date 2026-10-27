---
name: stable-computer-use
description: 操作 macOS 桌面 app（通过无障碍树，不靠截图猜坐标）。当任务需要点击 app 里的按钮、填写输入框、读窗口内容、按快捷键、滚动、或任何"只有图形界面才能做"的事情时使用。读/写文件、跑命令、用 API 能解决的，不要用这个。
---

# stable-computer-use

用 AX 树操作 macOS app。每个元素有稳定 `ref`，按 `ref` 操作，不算坐标。

命令都在 `scu`，输出全是 JSON。没设 PATH 就用 `./cli/scu`。

## 先检查

```bash
scu doctor
```

`accessibility` 必须是 `true`。不是的话请用户去 **系统设置 → 隐私与安全性 → 辅助功能** 勾选终端，然后重新运行。不要假装能操作。

## 铁律：不要打扰用户

**他的鼠标和焦点属于他，不属于你。**

- 默认路径全是 AX，不动鼠标、不抢焦点、不激活 app —— 就这样用
- **不要**随便加 `--take-over`。只有用户明确说"你直接操作吧/我不在用"时才加
- 被 `needs_takeover` / `user_active` 拒绝时，**不要绕过去**：换个 AX 路径，或者问用户
- `no_ax_action_at_point` 说明这个坐标是自绘区域，先问用户能不能接管，别自己决定

```bash
scu click --app X --ref R          # ✅ 默认
scu click --app X --xy 100,200     # ✅ 命中测试，仍不动鼠标
scu click --app X --xy 100,200 --via mouse --take-over   # ⚠️ 会打断用户，先问
```

## 基本循环

```bash
scu snapshot --app "Finder"        # 1. 看：元素表 + ref
scu click --app "Finder" --ref 3netay   # 2. 做
scu snapshot --app "Finder"        # 3. 再看：确认真的变了
```

动作不返回结果，**必须重新 snapshot 确认**。别假设点成功了。

## 选元素：先问 decide，别自己猜

```bash
scu decide --app "Finder" --goal '点击"搜索"'
```

它会告诉你走到了哪一级（`tier`）、置信度、以及目标 ref：

| tier | 含义 | 你要做的 |
|---|---|---|
| `exact` / `memory` / `recipe` | 本地确定命中，0 成本 | 直接用 `targetRef` |
| `lexical` + `gate=high` | 本地打分很有把握 | 用 `targetRef` |
| `lexical` + `gate=medium/low` | 本地不确定 | 看 `candidates` 自己选 |
| `jev` | JEV 选好了 | 用 `targetRef`；`gate` 不是 high 就先 verify |
| `handoff` | 本地说不准，交给你 | 从 `candidates` 里选一个 |

**`handoff` 也是有用信息**：`bestGuess` 是它的最佳猜测，`candidates` 是排序好的候选。别丢掉这些重新造轮子。

### 关键：你选完要教它

```bash
scu remember --app "Finder" --goal "回到上一个文件夹" --ref mkq0ob
```

教一次，以后这个目标就是 `tier=memory`、98ms、零模型。**重复任务不做这一步是浪费。**

## 精准操作要点

- **优先 `--ref`**，其次 `--text`，最后才坐标
- **控件优先 `--via ax`**：走 AXPress，不动鼠标也不抢焦点，用户能继续干自己的事
- **动作前 `verify`**：`scu verify --app A --ref R` → 还在吗、enabled 吗、位置变了吗
- **`stale_ref` 不是错误，是提示**：重新 snapshot 拿新 ref 再重试
- **文字节点自动解析到祖先**：Snapshot JSON 里 `target_ref` 已经是最近的可点祖先，`scu click --ref` 用 `ref` 也行（内部会解析）

## 常用命令

```bash
scu apps                                  # 有哪些 app 有窗口
scu snapshot --app "Chrome" --json        # 结构化（默认是给人看的文本）
scu click --app A --ref R [--via ax] [--button right] [--count 2]
scu type  --app A --text "..."
scu key   --app A --key "super+s"
scu scroll --app A --ref R --direction down --pages 2
scu set   --app A --ref R --value "..."   # 直接写值，比打字快
scu shot  --app A --out /tmp/a.png        # 窗口截图（兜底用）
scu recipe list                           # 录过的步骤序列
```

## 什么时候别用它

- 能用 shell / Python / curl 完成的，**别点界面**
- 能用 app 自己的 CLI 或 API 的，先用那个
- 纯文字处理不要开 app

这个工具是给"只有 GUI 才能做"的事情用的。

## 出错怎么办

| reasonCode | 含义 | 处理 |
|---|---|---|
| `app_not_found` | app 没开或名字不对 | `scu apps` 看真实名字 / bundle id |
| `no_window` | app 没窗口 | 可能被最小化了，请用户打开 |
| `stale_ref` | ref 过期 | 重新 snapshot |
| `disabled` | 元素被禁用 | 先让它可用（比如先勾选某选项） |
| `text_not_found` | 没有这个文字 | 先 snapshot 看真实文字 |
| `empty_snapshot` | 这个 app 没暴露 AX 树 | Electron 类 app 常见，改用 `scu shot` + 坐标 |
| `ax_cannot_complete` | AX 返回 -25204 | **屏幕锁了或不是活动 GUI 会话**。请用户解锁后重试，别硬试 |
| `no_window` | app 没可用窗口 | 窗口被最小化或在别的 Space，请用户调出来 |
| `no_accessible_windows` | AX 能读但所有窗口都是代理 | 显示器休眠 / 长时间无操作。请用户唤醒屏幕，别反复重试 |
| `needs_takeover` | 该动作会打断用户 | **不要绕**。换 AX 路径，或问用户 |
| `user_active` | 用户刚在操作 | 等一会儿重试，别抢 |

先跑 `scu doctor`。`accessibility` 为 `true` 但 `accessibilityUsable` 为 `false` 时，工具实际不可用 —— 不要假设能操作。

Electron app（飞书、Slack、Sublime 等）常常没有 AX 树。遇到 `empty_snapshot` 就承认，走截图兜底，别硬试。
