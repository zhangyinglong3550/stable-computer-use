---
name: stable-mac
description: 操作 macOS 桌面 app（通过无障碍树，不靠截图猜坐标）。当任务需要点击 app 里的按钮、填写输入框、读窗口内容、按快捷键、滚动、或任何"只有图形界面才能做"的事情时使用。读/写文件、跑命令、用 API 能解决的，不要用这个。
---

# stable-mac

用 AX 树操作 macOS app。每个元素有稳定 `ref`，按 `ref` 操作，不算坐标。

命令都在 `smac`，输出全是 JSON。没设 PATH 就用 `./cli/smac`。

## 先检查

```bash
smac doctor
```

`accessibility` 必须是 `true`。不是的话请用户去 **系统设置 → 隐私与安全性 → 辅助功能** 勾选终端，然后重新运行。不要假装能操作。

## 基本循环

```bash
smac snapshot --app "Finder"        # 1. 看：元素表 + ref
smac click --app "Finder" --ref 3netay   # 2. 做
smac snapshot --app "Finder"        # 3. 再看：确认真的变了
```

动作不返回结果，**必须重新 snapshot 确认**。别假设点成功了。

## 选元素：先问 decide，别自己猜

```bash
smac decide --app "Finder" --goal '点击"搜索"'
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
smac remember --app "Finder" --goal "回到上一个文件夹" --ref mkq0ob
```

教一次，以后这个目标就是 `tier=memory`、98ms、零模型。**重复任务不做这一步是浪费。**

## 精准操作要点

- **优先 `--ref`**，其次 `--text`，最后才坐标
- **控件优先 `--via ax`**：走 AXPress，不动鼠标也不抢焦点，用户能继续干自己的事
- **动作前 `verify`**：`smac verify --app A --ref R` → 还在吗、enabled 吗、位置变了吗
- **`stale_ref` 不是错误，是提示**：重新 snapshot 拿新 ref 再重试
- **文字节点自动解析到祖先**：Snapshot JSON 里 `target_ref` 已经是最近的可点祖先，`smac click --ref` 用 `ref` 也行（内部会解析）

## 常用命令

```bash
smac apps                                  # 有哪些 app 有窗口
smac snapshot --app "Chrome" --json        # 结构化（默认是给人看的文本）
smac click --app A --ref R [--via ax] [--button right] [--count 2]
smac type  --app A --text "..."
smac key   --app A --key "super+s"
smac scroll --app A --ref R --direction down --pages 2
smac set   --app A --ref R --value "..."   # 直接写值，比打字快
smac shot  --app A --out /tmp/a.png        # 窗口截图（兜底用）
smac recipe list                           # 录过的步骤序列
```

## 什么时候别用它

- 能用 shell / Python / curl 完成的，**别点界面**
- 能用 app 自己的 CLI 或 API 的，先用那个
- 纯文字处理不要开 app

这个工具是给"只有 GUI 才能做"的事情用的。

## 出错怎么办

| reasonCode | 含义 | 处理 |
|---|---|---|
| `app_not_found` | app 没开或名字不对 | `smac apps` 看真实名字 / bundle id |
| `no_window` | app 没窗口 | 可能被最小化了，请用户打开 |
| `stale_ref` | ref 过期 | 重新 snapshot |
| `disabled` | 元素被禁用 | 先让它可用（比如先勾选某选项） |
| `text_not_found` | 没有这个文字 | 先 snapshot 看真实文字 |
| `empty_snapshot` | 这个 app 没暴露 AX 树 | Electron 类 app 常见，改用 `smac shot` + 坐标 |
| `ax_cannot_complete` | AX 返回 -25204 | **屏幕锁了或不是活动 GUI 会话**。请用户解锁后重试，别硬试 |
| `no_window` | app 没可用窗口 | 窗口被最小化或在别的 Space，请用户调出来 |

先跑 `smac doctor`。`accessibility` 为 `true` 但 `accessibilityUsable` 为 `false` 时，工具实际不可用 —— 不要假设能操作。

Electron app（飞书、Slack、Sublime 等）常常没有 AX 树。遇到 `empty_snapshot` 就承认，走截图兜底，别硬试。
