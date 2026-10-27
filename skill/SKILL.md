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

## 铁律：先问"能不能不用 GUI"

**顺序是：API/CLI → 只读 GUI → 写 GUI。** 能走 API 就走 API（飞书查消息用 `lark-cli`，网页用 `stable-chrome`），GUI 是最后手段。

### 不动鼠标、不抢焦点，但界面上会看得见

默认路径全是 AX：不动指针、不抢焦点、不激活 app。**但这不等于"看不见"** —— `AXPress` 执行的是 app 自己的逻辑，它可能弹模态窗、展开面板、刷新页面。

所以：

- **用户在用电脑时，不要做会改界面的操作**。先只读，等他停手
- **不要**随便做会激活窗口的动作。只有用户明确说"你直接操作吧/我不在用"时才做
- 做写操作前先 `state()` 看清楚，别猜
- 操作完不要假设成功，重新 `state()` 确认

## 用之前先看一眼

```bash
scu doctor
```

`accessibilityUsable` 必须是 `true`。只是 `accessibility: true` 不够。

## 默认写法：一段代码跑完

**不要一步一条命令。** 一条命令付一次进程启动（约 75ms），动作本身只要 0.16ms。

```bash
scu js -e '
const app = await scu.getApp("com.tencent.WeWorkMac");
const st = await app.state({json: true});          // 拿结构
const row = st.elements.find(e => (e.label||"").includes("文件传输助手") && e.rect);
await app.click({ x: row.rect.x + row.rect.w/2, y: row.rect.y + row.rect.h/2, mouse: true });
await scu.sleep(400);
await app.type("你好");
await app.key("Return");
'
```

## 默认用 code mode，别一步一条命令

一步一条命令，每条都要付一次进程启动（75ms）。**连续动作必须写成一段代码**，一次跑完：

```bash
scu js -e '
const app = await scu.getApp("com.apple.finder");
console.log(await app.state());        // 先看一眼
await app.click({ref: "abc123"});      // AX 动作，不动鼠标
await app.key("super+n");
console.log(await app.state());        // 再看一眼
'
```

每个动作 **0.16–0.7ms**，比逐个调用快两个数量级。

### API

| 写法 | 作用 |
|---|---|
| `await scu.getApp("Finder")` | 绑定 app（名字或 bundle id） |
| `await app.state()` | 紧凑文本树，直接打印 |
| `await app.click({ref})` | AX 动作，不动鼠标不抢焦点 |
| `await app.click({x,y})` | 命中测试 → AXPress |
| `await app.click({x,y,mouse:true})` | 真鼠标（会激活窗口） |
| `await app.type("你好")` | 优先 AX 直写 |
| `await app.key("super+s")` | 菜单项优先，否则真键盘 |
| `await app.set(ref, "v")` | 直接写值 |
| `await app.shot("/tmp/a.png")` | 截图（配合 `scu shot --crop` 只看一块） |
| `scu.sleep(ms)` / `scu.log(...)` | 等待 / 输出 |

## 看截图要"裁小"

整窗截图 412KB，裁一块只有 11KB。**模型看图的时间跟图大小成正比**，所以先裁再问：

```bash
scu shot --app X --out /tmp/a.png --crop 520,40,700,120   # x,y,w,h（图像像素）
scu shot --app X --out /tmp/a.png --scale 0.5              # 或者整体缩小
```

注意：`-R` 矩形截图会带上**盖在上面的其他窗口**，不是纯净窗口图。

## 也可以用 batch（JSONL）



一条命令起一个进程，每条有 ~60ms 启动地板。要连点几十下（比如拖滑块、连发消息），
把动作写成 JSONL 一次性喂进去：

```bash
scu batch <<'EOF'
{"cmd":"click","app":"Finder","ref":"abc123"}
{"cmd":"type","app":"Finder","text":"hello"}
{"cmd":"ping"}
EOF
```

一个进程跑完，每次动作 0.16–0.7ms。**这是唯一能做到"跟手"的用法。**

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
scu batch                                 # 从 stdin 读 JSONL，一个进程跑多条（最快）
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
