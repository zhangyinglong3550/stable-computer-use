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

## 默认写法：一次调用跑完整串

一步一条命令 = 一次进程启动 + 一次模型往返。连续动作必须写成一段 `scu js`，
再用 `app.act([...])` 包起来：失败即停、每步自带确认、返回紧凑报告。

```bash
scu js -e '
const app = await scu.getApp("Sublime Text");
const r = await app.act([
  { op: "key", key: "super+n" },
  { op: "type", text: "空山新雨后，天气晚来秋。" },
  { op: "key", key: "Return" },
  { op: "type", text: "明月松间照，清泉石上流。" },
]);
console.log(JSON.stringify({ ok: r.ok, failedAt: r.failedAt, ms: r.elapsedMs }));
'
```

实测：4 步（2 次点击 + 2 次 `expect`）**406ms**；10 次快照 660ms（含 Node 启动）。

### act 的步骤

| op | 参数 | 说明 |
|---|---|---|
| `click` | `ref` / `text` / `x,y` | `text` 先解析元素；纯文字节点自动退化成坐标命中 |
| `type` | `text`, `ref?` | AX 直写，失败转定向投递 |
| `key` | `key`, `activate?` | 菜单项优先，否则定向投递 |
| `set` | `ref`, `value`, `requireVerified?` | 整体赋值 + 读回 |
| `scroll` | `ref`, `direction`, `pages` | AX 滚动，否则定向滚轮 |
| `expect` | `text` 或 `window`, `timeoutMs` | 轮询到出现，**替代 sleep** |
| `sleep` | `ms` | 只有确实没有可观测信号时才用 |

返回 `{ok, failedAt, elapsedMs, steps:[{op, ok, ms, changed, verification}]}`。
`stopOnError: false` 可以不中断地跑完。

### 只看变化：diff

整棵树 260+ 个元素，真正变的常常只有一行。`act()` 默认带 diff，`state({diff:true})` 也只报变化：

```
# diff +0 -0 ~1
~ [ogu1g6→1nf6y4] value 你好，这是一段测试文本。 → 改过的内容
# window: diff-test.txt
```

- 只报新增 / 消失 / 值变化，每类最多 12 行，超出标 truncated
- ref 会随 value 变，所以按「角色 + 左上角」配对：打字显示成一次修改，而不是删除+新增
- `act()` 多两次快照（约 50ms），换掉一次整树观察 —— 通常更划算

### 发消息：发送前必须确认会话

```bash
scu js -e '
const app = await scu.getApp("com.tencent.WeWorkMac");
const r = await app.act([
  { op: "click", text: "文件传输助手" },
  { op: "expect", window: "文件传输助手", timeoutMs: 3000 },   // 先确认点对了人
  { op: "set", ref: "<输入框 ref>", value: "你好", requireVerified: true },
  { op: "key", key: "Return" },
  { op: "expect", text: "你好", timeoutMs: 3000 },             // 再确认发出去了
]);
if (!r.ok) throw new Error("第 " + r.failedAt + " 步失败");
'
```

点错会话的代价是发给别人，**不能只靠 `verification` 兜底**：发送前一定要 `expect` 会话标题。

### 已验证的片段

写多行文本（Sublime 这类没有 AX 树、只能定向键盘的编辑器也能跑）：

```js
const app = await scu.getApp("Sublime Text");
const lines = ["空山新雨后，天气晚来秋。", "明月松间照，清泉石上流。"];
const steps = [{ op: "key", key: "super+n" }];
lines.forEach((text, i) => {
  if (i) steps.push({ op: "key", key: "Return" });
  steps.push({ op: "type", text });
});
// 没有 AX 树的编辑器，界面签名不会变，等满默认 800ms 是浪费
const r = await app.act(steps, { waitTimeoutMs: 150 });
if (!r.ok) throw new Error(`第 ${r.failedAt} 步失败：${r.steps[r.failedAt].reasonCode}`);
```

切视图并验证（Finder 侧栏这种纯文字节点，`click` 会自动退化成坐标命中）：

```js
const f = await scu.getApp("Finder");
const r = await f.act([
  { op: "click", text: "下载" },
  { op: "expect", window: "下载", timeoutMs: 2000 },
]);
```

### 单条 CLI 只用于探索

`scu snapshot` / `scu click` 一条条发，只在第一次摸不清界面时用。
探明路径后立刻写成 `act` 脚本，否则每一步都要付一次模型往返。

### API

| 写法 | 作用 |
|---|---|
| **`await app.act([...])`** | **一次跑完整串，失败即停，返回报告（首选）** |
| `await app.waitFor(fn)` | 等条件成立，替代 sleep |
| `await scu.getApp("Finder")` | 绑定 app（名字或 bundle id） |
| `await app.state()` | 紧凑文本树，直接打印 |
| `await app.click({ref})` | AX 动作，不动鼠标不抢焦点 |
| `await app.click({x,y})` | 命中测试 → AXPress |
| `await app.click({x,y,via:"pid"})` | 定向投递，不动光标不抢焦点 |
| `await app.click({x,y,mouse:true})` | 真鼠标（会激活窗口） |
| `await app.type("你好")` | 优先 AX 直写 |
| `await app.key("super+s")` | 菜单项优先，否则定向投递（`{activate:true}` 才用真键盘） |
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

daemon 会显示一条浮动状态条（`scu · click` / `verified · via ax`），鼠标穿透、不抢焦点。
不想要就用 `SCU_HUD=0` 启动 daemon；`SCU_HUD_POS=bottom` 放屏幕底部。
它只是展示，别把它当成功判据 —— 判据只认 JSON 里的 `verification`。

```bash
scu apps                                  # 有哪些 app 有窗口
scu snapshot --app "Chrome" --json        # 结构化（默认是给人看的文本）
scu click --app A --ref R [--via ax|pid] [--button right] [--count 2]
scu click --app A --xy 100,50 [--space screen|window] [--via ax|pid|mouse]
scu type  --app A --text "..."            # AX 直写 → 失败自动定向投递
scu key   --app A --key "super+s"         # 菜单项 → 定向投递，都默认不抢焦点
scu scroll --app A --ref R --direction down --pages 2
scu set   --app A --ref R --value "..."   # 直接写值，比打字快，会读回校验
scu shot  --app A --out /tmp/a.png        # 窗口截图（兜底用）
scu recipe list                           # 录过的步骤序列
scu batch                                 # 从 stdin 读 JSONL，一个进程跑多条（最快）
```

### 坐标只有一种话

- `snapshot` 的 `rect` / `windowRect` / `windowOrigin` 都是**屏幕坐标**（左上原点），
  JSON 顶层 `coordinateSpace: "screen"` 说明这一点。
- `click --xy` 默认也吃屏幕坐标；传 `--space window` 时是**窗口内坐标**
  （原点 = 窗口左上角），由工具加窗口原点换算。输出里会回显 `coordinateSpace` 和 `screen`。
- `scu shot` 输出 `scale` 和 `actionFormula`：图像像素 ÷ scale = 窗口点。
  不要拿图像像素直接当坐标用。

### 三档投递：ax → pid → mouse

| 档位 | 行为 | 抢焦点/动光标 | 结果可信度 |
|---|---|---|---|
| `ax`（默认） | 无障碍动作（Press / SetValue / 滚动动作） | ❌ | `unverified(axpress_unasserted)`，靠 `--wait` 的 `changed` 判断 |
| `pid` | 定向投递到目标进程（`CGEventPostToPid`） | ❌ | `unverified(synthetic_input)`：app 可能因为没有 key window 丢事件 |
| `mouse` | 系统级事件流，真移动光标 | ✅ 需要 `--take-over` | `unverified(synthetic_input)` |

**读回校验**：`set` / `type`（走 AX 时）会读回值，返回
`verification: {state: "verified", source: "value_readback"}`。
其它形态是 `unverified`，带 `reason`（`synthetic_input` / `clipboard_paste` /
`value_mismatch` / `value_unchanged` / `axpress_unasserted` / `ui_unchanged`）。
**`ok: true` 不等于界面真的变了**；别把 `unverified` 当成功上报。

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
| `stale_ref` | ref 过期（元素被重建/换了窗口，`why` 会说是哪一个） | 重新 snapshot |
| `window_not_found` | `--space window` 但窗口几何读不到 | 用屏幕坐标重试，或确认窗口还在 |
| `invalid_key` | 键名/修饰键不认识 | 换标准键名（`Return`、`Escape`、`super+s`） |
| `disabled` | 元素被禁用 | 先让它可用（比如先勾选某选项） |
| `text_not_found` | 没有这个文字 | 先 snapshot 看真实文字 |
| `empty_snapshot` | 这个 app 没暴露 AX 树 | Electron 类 app 常见，改用 `scu shot` + 坐标 |
| `ax_cannot_complete` | AX 返回 -25204 | **屏幕锁了或不是活动 GUI 会话**。请用户解锁后重试，别硬试 |
| `no_window` | app 没可用窗口 | 窗口被最小化或在别的 Space，请用户调出来 |
| `no_accessible_windows` | AX 能读但所有窗口都是代理 | 显示器休眠 / 长时间无操作。请用户唤醒屏幕，别反复重试 |
| `needs_takeover` | 这一步会打断用户（`--via mouse` / 真键盘） | **不要绕**。换 AX 或 `--via pid`，或问用户 |
| `user_active` | 用户刚在操作 | 等一会儿重试，别抢 |

先跑 `scu doctor`。`accessibility` 为 `true` 但 `accessibilityUsable` 为 `false` 时，工具实际不可用 —— 不要假设能操作。

Electron app（飞书、Slack、Sublime 等）常常没有 AX 树。遇到 `empty_snapshot` 就承认，走截图兜底，别硬试。
