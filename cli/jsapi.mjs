/**
 * scu code mode 运行时。
 *
 * 目的：让 Agent **写一段代码** 一次跑完 N 个动作，而不是一步一条命令。
 * 一步一条命令每步要付一次进程启动（Python 75ms / Node 20ms），
 * 而一条代码里每个动作只要 ~0.7ms。这是 Codex 用 code_mode 的全部理由。
 *
 * 用法：
 *   scu js script.mjs
 *   scu js -e 'const app = await scu.getApp("Finder"); await app.click({ref:"abc"})'
 *
 * API（尽量贴近 Codex 的写法）：
 *   const app = await scu.getApp("Finder")      // 名字 / bundle id 都行
 *   await app.state()                            // 紧凑文本树，直接 console.log
 *   await app.click({ref})                       // AX 动作，不动鼠标
 *   await app.click({x, y})                      // 命中测试 -> AXPress
 *   await app.click({x, y, mouse: true})         // 真鼠标（会激活窗口）
 *   await app.type("你好")                       // 优先 AX 直写
 *   await app.key("super+s")                     // 菜单项优先，否则真键盘
 *   await app.set(ref, "value")
 *   await app.shot("/tmp/a.png")
 *   await scu.activate("Finder")
 */

import net from "node:net";
import { pathToFileURL } from "node:url";

const SOCK = process.env.SCU_SOCK || `/tmp/scu-${process.getuid()}.sock`;
const TIMEOUT = Number(process.env.SCU_JS_TIMEOUT || 30000);

let rpcCount = 0;

function rpc(req) {
  rpcCount++;
  return new Promise((resolve, reject) => {
    const sock = net.createConnection(SOCK);
    let buf = "";
    const done = (err, val) => {
      sock.destroy();
      err ? reject(err) : resolve(val);
    };
    sock.setEncoding("utf8");
    sock.setTimeout(TIMEOUT, () => done(new Error(`rpc timeout: ${req.cmd}`)));
    sock.on("connect", () => sock.write(JSON.stringify(req) + "\n"));
    sock.on("data", (d) => {
      buf += d;
      if (buf.includes("\n")) {
        try {
          done(null, JSON.parse(buf));
        } catch (e) {
          done(e);
        }
      }
    });
    sock.on("error", reject);
  });
}

function renderState(snap) {
  const els = snap.elements || [];
  const byDepth = [];
  const lines = [];
  for (const e of els) {
    const pad = "  ".repeat(Math.min(e.depth ?? 0, 14));
    let line = `${pad}[${e.ref}] ${(e.role || "").replace(/^AX/, "")}`;
    if (e.label) line += `: ${String(e.label).slice(0, 70)}`;
    if (e.value && e.value !== e.label) line += ` (value: ${String(e.value).slice(0, 40)})`;
    if (e.enabled === false) line += " [disabled]";
    if (e.actions?.length) line += `  <${[...e.actions].sort().join(", ")}>`;
    lines.push(line);
  }
  const head = `# ${snap.app || ""} [${snap.bundle || ""}] window: ${snap.window || ""}`;
  return [head, ...lines, `# ${els.length} elements`].join("\n");
}

class App {
  constructor(name) {
    this.name = name;
  }

  /** 取状态。默认返回紧凑文本；{json:true} 返回原始结构。 */
  async state(opts = {}) {
    const snap = await rpc({
      cmd: "snapshot", app: this.name, max: opts.max ?? 4000,
      actions: opts.actions !== false,
    });
    if (snap.ok === false) throw new Error(`state failed: ${snap.reasonCode || "unknown"}`);
    return opts.json ? snap : renderState(snap);
  }

  async click(target) {
    // 支持 click("ref") 简写
    if (typeof target === "string") target = { ref: target };
    if (!target || (!target.ref && (target.x == null || target.y == null))) {
      throw new Error("click 需要 {ref} 或 {x,y}");
    }
    const req = { cmd: "click", app: this.name, ...target };
    const r = await rpc(req);
    if (!r.ok) throw new Error(`click failed: ${r.reasonCode} ${r.hint || ""}`.trim());
    return r;
  }

  async type(text) {
    const r = await rpc({ cmd: "type", app: this.name, text });
    if (!r.ok) throw new Error(`type failed: ${r.reasonCode} ${r.hint || ""}`.trim());
    return r;
  }

  async key(chord) {
    const r = await rpc({ cmd: "key", app: this.name, key: chord });
    if (!r.ok) throw new Error(`key failed: ${r.reasonCode} ${r.hint || ""}`.trim());
    return r;
  }

  /**
   * 动作 + 等界面变化，一步到位。
   * 返回 { ok, changed, waitedMs } —— changed=false 说明动作可能没生效。
   * 这是替代「动作后截图给模型看」的关键：30-120ms 的遍历 vs 1-3s 的视觉判断。
   */
  async clickAndWait(target, opts = {}) {
    if (typeof target === "string") target = { ref: target };
    const r = await rpc({
      cmd: "actAndWait", app: this.name, timeoutMs: opts.timeoutMs ?? 1500, ...target,
    });
    if (r.ok === false) throw new Error(`clickAndWait failed: ${r.reasonCode}`);
    return r;
  }

  async typeAndWait(text, opts = {}) {
    const r = await rpc({
      cmd: "actAndWait", app: this.name, text, timeoutMs: opts.timeoutMs ?? 1200,
    });
    if (r.ok === false) throw new Error(`typeAndWait failed: ${r.reasonCode}`);
    return r;
  }

  async keyAndWait(chord, opts = {}) {
    const r = await rpc({
      cmd: "actAndWait", app: this.name, key: chord, timeoutMs: opts.timeoutMs ?? 1500,
    });
    if (r.ok === false) throw new Error(`keyAndWait failed: ${r.reasonCode}`);
    return r;
  }

  async signature() {
    const r = await rpc({ cmd: "signature", app: this.name });
    if (r.ok === false) throw new Error(`signature failed: ${r.reasonCode}`);
    return r.signature;
  }

  async set(ref, value) {
    const r = await rpc({ cmd: "set", app: this.name, ref, value });
    if (!r.ok) throw new Error(`set failed: ${r.reasonCode}`);
    return r;
  }

  /** 截图。走 CLI 的 screencapture 路径，返回文件路径。 */
  async shot(out) {
    const { spawnSync } = await import("node:child_process");
    const snap = await rpc({ cmd: "snapshot", app: this.name });
    if (snap.ok === false || !snap.elements?.length) throw new Error("shot: 拿不到窗口");
    const r = snap.elements[0].rect;
    if (!r) throw new Error("shot: 窗口没有几何信息");
    const res = spawnSync(
      "screencapture",
      ["-x", "-R", `${Math.round(r.x)},${Math.round(r.y)},${Math.round(r.w)},${Math.round(r.h)}`, out],
      { encoding: "utf8" }
    );
    if (res.status !== 0) throw new Error(`screencapture failed: ${res.stderr}`);
    return out;
  }
}

const appCache = new Map();

export const scu = {
  async getApp(name) {
    if (!appCache.has(name)) {
      const r = await rpc({ cmd: "snapshot", app: name, max: 1 });
      if (r.ok === false) throw new Error(`找不到 app: ${name} (${r.reasonCode})`);
      appCache.set(name, new App(name));
    }
    return appCache.get(name);
  },
  async activate(name) {
    const r = await rpc({ cmd: "activate", app: name });
    if (!r.ok) throw new Error(`activate failed: ${r.reasonCode}`);
    return r;
  },
  async ping() {
    return rpc({ cmd: "ping" });
  },
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
  log: (...a) => console.log(...a),
  get rpcCount() {
    return rpcCount;
  },
};

// ---------------- 脚本执行 ----------------

const argv = process.argv.slice(2);
globalThis.scu = scu;

async function main() {
  if (argv[0] === "-e") {
    const code = argv[1] ?? "";
    // 用动态 import 的 data: URL 执行，保留顶层 await
    const url = "data:text/javascript;base64," + Buffer.from(code).toString("base64");
    await import(url);
  } else if (argv[0]) {
    await import(pathToFileURL(argv[0]).href);
  } else {
    console.error("usage: scu js <file.mjs> | scu js -e '<code>'");
    process.exit(2);
  }
}

main().catch((e) => {
  console.error("js error:", e?.message || e);
  process.exit(1);
});
