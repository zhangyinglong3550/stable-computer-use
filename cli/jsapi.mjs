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

import fs from "node:fs";
import net from "node:net";
import { fileURLToPath, pathToFileURL } from "node:url";

const SOCK = process.env.SCU_SOCK || `/tmp/scu-${process.getuid()}.sock`;
const TIMEOUT = Number(process.env.SCU_JS_TIMEOUT || 30000);

let rpcCount = 0;

/** 单调钟。trace 与 act 的耗时都走这里，不用 Date.now()。 */
function monoNs() {
  return process.hrtime.bigint();
}

function nsToMs(ns) {
  return Number(ns) / 1e6;
}

function traceEnabled() {
  return process.env.SCU_TRACE === "1";
}

// act() 进行中时，rpc 把 daemon 的 trace 片段放进这个数组，而不是立刻写 stderr。
// 一步可能含多次 RPC（找目标的快照 + actAndWait），对外只出一行。
let traceHold = null;
let standaloneStep = 0;

function emitTraceLine(ev) {
  const line = { ...ev };
  if (line.step == null) {
    line.step = standaloneStep;
    standaloneStep += 1;
  }
  process.stderr.write(JSON.stringify(line) + "\n");
}

/**
 * 从 daemon 返回值里拿掉 trace。
 * enabled 为假：不产生 stderr 行，结果对象没有 trace。
 * hold 有值：片段留给当前这一步合并，不在这里写 stderr。
 * 不修改入参。
 */
export function peelTrace(payload, { enabled = false, hold = null } = {}) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return { payload, lines: [] };
  }
  if (!Object.prototype.hasOwnProperty.call(payload, "trace")) {
    return { payload, lines: [] };
  }
  const events = Array.isArray(payload.trace)
    ? payload.trace.filter((e) => e && typeof e === "object" && !Array.isArray(e))
    : [];
  const clean = { ...payload };
  delete clean.trace;
  if (!enabled) return { payload: clean, lines: [] };
  if (hold) {
    hold.push(...events);
    return { payload: clean, lines: [] };
  }
  return { payload: clean, lines: events };
}

export function tierFromVia(via) {
  if (via === "mouse" || via === "daemon-mouse" || via === "keyboard") return "mouse";
  if (via === "pid" || via === "pid-mouse" || via === "pid-wheel") return "pid";
  return "ax";
}

/**
 * daemon 没带回 trace（例如 daemon 启动时没设 SCU_TRACE）时，用结果里原有的
 * actMs / waitedMs / changed 补分段。这些数来自 Date，只是退路。
 * text_not_found / cache_miss 没有 changed，这里不会标成 timeout。
 */
export function fallbackFromActResult(result) {
  if (!result || typeof result !== "object") return null;
  const out = {};
  if (result.actMs != null) out.deliverMs = Number(result.actMs) || 0;
  if (result.waitedMs != null) out.waitMs = Number(result.waitedMs) || 0;
  if (result.changed === true) out.waitExit = "changed";
  else if (result.changed === false && result.waitedMs != null) out.waitExit = "timeout";
  if (typeof result.via === "string") out.tier = tierFromVia(result.via);
  return out;
}

/**
 * 把一步里的 daemon 片段和 JS 侧快照合成一行。
 * extraResolveMs / extraSnapshots 用来装 act() 的 diff_before / diff_after。
 * wait_exit 只有 changed 或 timeout；没有等待概念的失败不写这个字段。
 */
export function composeStepTrace(input) {
  const events = Array.isArray(input.daemonEvents) ? input.daemonEvents : [];
  let resolve = Number(input.jsResolveMs) || 0;
  let deliver = 0;
  let wait = Number(input.jsWaitMs) || 0;
  let verify = 0;
  let snapshots = Number(input.jsSnapshots) || 0;
  let tier = "ax";
  let waitExit = input.waitExit === "changed" || input.waitExit === "timeout" ? input.waitExit : null;
  let usedDaemon = false;
  for (const ev of events) {
    if (!ev || typeof ev !== "object") continue;
    usedDaemon = true;
    resolve += Number(ev.resolve_ms) || 0;
    deliver += Number(ev.deliver_ms) || 0;
    wait += Number(ev.wait_ms) || 0;
    verify += Number(ev.verify_ms) || 0;
    snapshots += Number(ev.snapshots) || 0;
    if (ev.tier === "ax" || ev.tier === "pid" || ev.tier === "mouse") tier = ev.tier;
    if (ev.wait_exit === "changed" || ev.wait_exit === "timeout") waitExit = ev.wait_exit;
  }
  if (!usedDaemon) {
    deliver += Number(input.jsDeliverMs) || 0;
    const fb = input.fallback;
    if (fb && typeof fb === "object") {
      deliver += Number(fb.deliverMs) || 0;
      wait += Number(fb.waitMs) || 0;
      if (fb.tier === "ax" || fb.tier === "pid" || fb.tier === "mouse") tier = fb.tier;
      if (!waitExit && (fb.waitExit === "changed" || fb.waitExit === "timeout")) {
        waitExit = fb.waitExit;
      }
    }
  }
  resolve += Number(input.extraResolveMs) || 0;
  snapshots += Number(input.extraSnapshots) || 0;
  const total = (Number(input.totalMs) || 0) + (Number(input.extraResolveMs) || 0);
  const line = {
    step: input.step,
    action: input.action,
    tier,
    resolve_ms: Math.round(resolve),
    deliver_ms: Math.round(deliver),
    wait_ms: Math.round(wait),
    verify_ms: Math.round(verify),
    total_ms: Math.round(total),
    snapshots,
  };
  if (waitExit) line.wait_exit = waitExit;
  return line;
}

/**
 * waitFor 一轮轮询的归属：快照和 sleep 都算 wait，不算 resolve。
 * snapshots 仍加 1（这一轮有一次快照）。sleepMs 省略时只计快照。
 */
export function attributeWaitPoll(snapshotMs, sleepMs = 0) {
  return {
    resolveMs: 0,
    waitMs: (Number(snapshotMs) || 0) + (Number(sleepMs) || 0),
    snapshots: 1,
  };
}

/** _findTarget 的那次快照算 resolve，不算 wait。 */
export function attributeFindSnapshot(snapshotMs) {
  return {
    resolveMs: Number(snapshotMs) || 0,
    waitMs: 0,
    snapshots: 1,
  };
}

/** label/value 里含 text 的可见元素个数。空 text 不算命中。 */
export function countTextHits(elements, text) {
  if (!text) return 0;
  let n = 0;
  for (const e of elements || []) {
    if (`${e.label || ""} ${e.value || ""}`.includes(text)) n += 1;
  }
  return n;
}

/**
 * 第一次子串命中。有 actions 用 ref（优先 target_ref）；没有则用 rect 中心，
 * 让 daemon 往上找可点祖先。没有可用矩形时退回 ref。
 */
export function findTargetMatch(elements, text) {
  const hit = (elements || []).find((e) =>
    `${e.label || ""} ${e.value || ""}`.includes(text));
  if (!hit) return null;
  if (hit.actions?.length) return { ref: hit.target_ref || hit.ref };
  if (hit.rect && hit.rect.w > 0 && hit.rect.h > 0) {
    return { x: hit.rect.x + hit.rect.w / 2, y: hit.rect.y + hit.rect.h / 2 };
  }
  return { ref: hit.target_ref || hit.ref };
}

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
          const parsed = JSON.parse(buf);
          const { payload, lines } = peelTrace(parsed, {
            enabled: traceEnabled(),
            hold: traceHold,
          });
          for (const ev of lines) emitTraceLine(ev);
          done(null, payload);
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

/** 把一次快照压成"ref -> 摘要"，用于 diff。全量树留在 daemon，客户端只存这份。 */
function summarize(snap) {
  const elements = new Map();
  for (const e of snap.elements || []) {
    elements.set(e.ref, {
      role: e.role || "",
      label: e.label || "",
      value: e.value || "",
      enabled: e.enabled !== false,
      // ref 的签名里含 value，值一变 ref 就变 —— 用"角色 + 左上角"配对识别同一个元素
      anchor: e.rect ? `${e.role}|${Math.round(e.rect.x)}|${Math.round(e.rect.y)}` : `${e.role}|${e.ref}`,
    });
  }
  return { window: snap.window || "", elements };
}

function clip(s, n = 40) {
  const t = String(s ?? "").replace(/\s+/g, " ").trim();
  return t.length > n ? t.slice(0, n) + "…" : t;
}

function shortRole(role) {
  return (role || "").replace(/^AX/, "");
}

/** 只要变化：新增 / 消失 / 值变化。这是"观察"的最小单位。 */
function diffSummary(prev, next, limit = 12) {
  if (!prev) {
    return {
      first: true, added: next.elements.size, removed: 0, changed: 0,
      total: next.elements.size, truncated: false, lines: [],
      windowChanged: null,
    };
  }
  const added = [];
  const removed = [];
  const changed = [];
  for (const [ref, e] of next.elements) {
    const old = prev.elements.get(ref);
    if (!old) {
      added.push({ ref, ...e });
    } else if (old.label !== e.label || old.value !== e.value || old.enabled !== e.enabled) {
      changed.push({ ref, before: old, after: e });
    }
  }
  for (const [ref, e] of prev.elements) if (!next.elements.has(ref)) removed.push({ ref, ...e });

  // ref 会随 value 变。把"角色相同、左上角相同"的删+增配对成一次修改，
  // 否则打字会显示成整块元素被替换，看不出改了什么。
  const removedByAnchor = new Map();
  for (const x of removed) {
    const list = removedByAnchor.get(x.anchor) || [];
    list.push(x);
    removedByAnchor.set(x.anchor, list);
  }
  const addedLeft = [];
  for (const x of added) {
    const bucket = removedByAnchor.get(x.anchor);
    if (bucket && bucket.length) {
      const old = bucket.shift();
      changed.push({ ref: x.ref, oldRef: old.ref, before: old, after: x });
    } else {
      addedLeft.push(x);
    }
  }
  const removedLeft = [...removedByAnchor.values()].flat();
  added.length = 0;
  removed.length = 0;
  added.push(...addedLeft);
  removed.push(...removedLeft);

  const lines = [];
  for (const x of added.slice(0, limit)) {
    lines.push(`+ [${x.ref}] ${shortRole(x.role)}${x.label ? ": " + clip(x.label) : ""}`);
  }
  for (const x of removed.slice(0, limit)) {
    lines.push(`- [${x.ref}] ${shortRole(x.role)}${x.label ? ": " + clip(x.label) : ""}`);
  }
  for (const x of changed.slice(0, limit)) {
    const bits = [];
    if (x.before.label !== x.after.label) {
      bits.push(`label ${clip(x.before.label, 24) || "∅"} → ${clip(x.after.label, 24) || "∅"}`);
    }
    if (x.before.value !== x.after.value) {
      bits.push(`value ${clip(x.before.value, 24) || "∅"} → ${clip(x.after.value, 24) || "∅"}`);
    }
    if (x.before.enabled !== x.after.enabled) {
      bits.push(`enabled ${x.before.enabled} → ${x.after.enabled}`);
    }
    const tag = x.oldRef && x.oldRef !== x.ref ? `[${x.oldRef}→${x.ref}]` : `[${x.ref}]`;
    lines.push(`~ ${tag} ${bits.join(", ")}`);
  }
  const total = added.length + removed.length + changed.length;
  return {
    first: false,
    added: added.length, removed: removed.length, changed: changed.length, total,
    truncated: total > lines.length,
    lines,
    windowChanged: prev.window !== next.window
      ? { from: prev.window, to: next.window }
      : null,
  };
}

function formatDiff(d, windowTitle) {
  const head = d.first
    ? `# 没有基线，这是全量（${d.added} 个元素）`
    : `# diff +${d.added} -${d.removed} ~${d.changed}${d.windowChanged ? ` | window ${d.windowChanged.from || "∅"} → ${d.windowChanged.to || "∅"}` : ""}`;
  return [head, ...d.lines, d.first ? "" : `# window: ${windowTitle || ""}`]
    .filter((x) => x !== "").join("\n");
}

class App {
  constructor(name) {
    this.name = name;
    this._lastState = null;
  }

  /**
   * 取状态。默认返回紧凑文本；{json:true} 返回原始结构。
   * {diff:true} 只返回相对上次 state/act 的变化 —— 观察成本从"整棵树"降到"几行"。
   */
  async state(opts = {}) {
    const snap = await rpc({
      cmd: "snapshot", app: this.name, max: opts.max ?? 4000,
      actions: opts.actions !== false,
    });
    if (snap.ok === false) throw new Error(`state failed: ${snap.reasonCode || "unknown"}`);
    const current = summarize(snap);
    if (opts.diff) {
      const d = diffSummary(this._lastState, current);
      this._lastState = current;
      return opts.json ? { ...snap, diff: d } : formatDiff(d, snap.window);
    }
    this._lastState = current;
    return opts.json ? snap : renderState(snap);
  }

  async click(target) {
    // 支持 click("ref") 简写
    if (typeof target === "string") target = { ref: target };
    if (!target || (!target.ref && (target.x == null || target.y == null))) {
      throw new Error("click 需要 {ref} 或 {x,y}");
    }
    // via: "ax"(默认) | "pid"(定向投递，不动光标) | "mouse"(系统鼠标，会动光标)
    // space: "screen"(默认) | "window"
    const req = { cmd: "click", app: this.name, ...target };
    if (target.space && !req.space) req.space = target.space;
    const r = await rpc(req);
    if (!r.ok) throw new Error(`click failed: ${r.reasonCode || "failed"} ${r.hint || ""}`.trim());
    return r;
  }

  async type(text, opts = {}) {
    const r = await rpc({ cmd: "type", app: this.name, text, ...opts });
    if (!r.ok) throw new Error(`type failed: ${r.reasonCode || "failed"} ${r.hint || ""}`.trim());
    return r;
  }

  async key(chord, opts = {}) {
    // 默认定向投递（不抢焦点）。需要真键盘时传 { activate: true }。
    const r = await rpc({ cmd: "key", app: this.name, key: chord, ...opts });
    if (!r.ok) throw new Error(`key failed: ${r.reasonCode || "failed"} ${r.hint || ""}`.trim());
    return r;
  }

  /**
   * 动作 + 等界面变化，一步到位。
   * 返回 { ok, changed, waitedMs, verification } —— changed=false 说明动作可能没生效，
   * verification.state === "unverified" 说明没有读回证据，别报成功。
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
      ...(opts.ref ? { ref: opts.ref } : {}),
    });
    if (r.ok === false) throw new Error(`typeAndWait failed: ${r.reasonCode}`);
    return r;
  }

  async keyAndWait(chord, opts = {}) {
    const r = await rpc({
      cmd: "actAndWait", app: this.name, key: chord, timeoutMs: opts.timeoutMs ?? 1500,
      ...(opts.activate ? { activate: true } : {}),
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

  /**
   * 一次调用跑完一串动作，失败即停，返回紧凑报告。
   *
   * 这是"少回合"的核心：一步一条命令要 N 次模型往返，这里只要 1 次。
   * 每个动作默认带 wait（actAndWait），所以结果里直接有 changed / verification，
   * 不需要再单独发一条 snapshot 去确认。
   *
   *   await app.act([
   *     { op: "click", text: "文件传输助手" },   // 也可以 ref / x+y
   *     { op: "expect", text: "文件传输助手" },   // 等界面出现这段文字
   *     { op: "set", ref: "abc", value: "你好", requireVerified: true },
   *     { op: "key", key: "Return" },
   *     { op: "expect", text: "你好", timeoutMs: 2000 },
   *   ]);
   */
  _noteResolve(ms, snaps = 0) {
    if (!this._traceAcc) return;
    this._traceAcc.resolveMs += ms;
    this._traceAcc.snapshots += snaps;
  }

  _noteDeliver(ms) {
    if (!this._traceAcc) return;
    this._traceAcc.deliverMs += ms;
  }

  _noteWait(ms, snaps = 0) {
    if (!this._traceAcc) return;
    this._traceAcc.waitMs += ms;
    this._traceAcc.snapshots += snaps;
  }

  _noteWaitExit(v) {
    if (!this._traceAcc) return;
    if (v === "changed" || v === "timeout") this._traceAcc.waitExit = v;
  }

  async act(steps, opts = {}) {
    if (!Array.isArray(steps)) throw new Error("act 需要步骤数组");
    const stopOnError = opts.stopOnError !== false;
    const waitMs = opts.waitTimeoutMs ?? 800;
    const wantDiff = opts.diff !== false;
    const traceOn = traceEnabled();
    const indexBase = Number.isInteger(opts.indexBase) && opts.indexBase >= 0 ? opts.indexBase : 0;
    const started = monoNs();
    // diff_before：act 开头那次快照。归到第一步的 resolve_ms，让多出来的快照可见。
    let diffBeforeMs = 0;
    let before = null;
    if (wantDiff) {
      const tDiff = monoNs();
      before = summarize(await this._snapshot());
      diffBeforeMs = nsToMs(monoNs() - tDiff);
    }
    const results = [];
    const built = [];
    let failedAt = null;

    for (let i = 0; i < steps.length; i++) {
      const step = steps[i] ?? {};
      const held = [];
      const prevHold = traceHold;
      if (traceOn) {
        this._traceAcc = { resolveMs: 0, deliverMs: 0, waitMs: 0, snapshots: 0, waitExit: null };
        traceHold = held;
      }
      const t0 = monoNs();
      let r;
      try {
        r = await this._step(step, waitMs);
      } catch (e) {
        r = { ok: false, reasonCode: "js_error", message: e?.message || String(e) };
      } finally {
        if (traceOn) traceHold = prevHold;
      }
      const stepMs = nsToMs(monoNs() - t0);
      const acc = this._traceAcc;
      this._traceAcc = null;
      // 只留报告需要的字段：整份 daemon 响应会把上下文撑爆
      const index = indexBase + i;
      const slim = { index, op: step.op, ms: Math.round(stepMs), ok: r.ok === true };
      if (r.via) slim.via = r.via;
      if (r.action) slim.action = r.action;
      if (r.changed !== undefined) slim.changed = r.changed;
      if (r.verification) {
        slim.verification = r.verification.state === "verified"
          ? "verified"
          : `unverified${r.verification.reason ? `(${r.verification.reason})` : ""}`;
      }
      if (r.ok !== true) slim.reasonCode = r.reasonCode || "unknown";
      results.push(slim);
      if (traceOn) {
        built.push({
          step: index,
          action: step.op || "unknown",
          daemonEvents: held,
          jsResolveMs: acc?.resolveMs || 0,
          jsDeliverMs: acc?.deliverMs || 0,
          jsWaitMs: acc?.waitMs || 0,
          jsSnapshots: acc?.snapshots || 0,
          waitExit: acc?.waitExit || null,
          // 没有 daemon 片段时才用 actMs/waitedMs 兜底，避免和 JS 侧计时叠在一起。
          fallback: held.length ? null : fallbackFromActResult(r),
          extraResolveMs: 0,
          extraSnapshots: 0,
          totalMs: stepMs,
        });
      }
      if (stopOnError && r.ok === false) {
        failedAt = i;
        break;
      }
    }

    let diff = null;
    let diffAfterMs = 0;
    let sawAfter = false;
    let emitted = false;
    // diff_before 算在第一步，diff_after 算在最后一步（只有一步时两边叠在同一行）。
    // diff_after 失败时也要把已经跑完的步骤写出去，否则基线会丢整段 trace。
    const emitBuilt = () => {
      if (!traceOn || emitted || !built.length) return;
      emitted = true;
      built[0].extraResolveMs += diffBeforeMs;
      if (wantDiff) built[0].extraSnapshots += 1;
      const last = built[built.length - 1];
      last.extraResolveMs += diffAfterMs;
      if (sawAfter) last.extraSnapshots += 1;
      for (const b of built) emitTraceLine(composeStepTrace(b));
    };
    try {
      if (wantDiff) {
        const tDiff = monoNs();
        const after = summarize(await this._snapshot());
        diffAfterMs = nsToMs(monoNs() - tDiff);
        sawAfter = true;
        diff = diffSummary(before, after);
        this._lastState = after;
      }
      emitBuilt();
      return {
        ok: failedAt === null,
        failedAt,
        elapsedMs: Math.round(nsToMs(monoNs() - started)),
        diff,
        steps: results,
      };
    } finally {
      emitBuilt();
    }
  }

  /** 内部：拿一次原始快照。 */
  async _snapshot() {
    const snap = await rpc({ cmd: "snapshot", app: this.name, max: 4000, actions: true });
    if (snap.ok === false) throw new Error(`snapshot failed: ${snap.reasonCode || "unknown"}`);
    return snap;
  }

  async _step(step, waitMs) {
    switch (step.op) {
      case "click": {
        let target;
        if (step.ref) {
          target = { ref: step.ref };
        } else if (step.text) {
          target = await this._findTarget(step.text);
          if (!target) return { ok: false, reasonCode: "text_not_found", text: step.text };
        } else {
          target = { x: step.x, y: step.y };
        }
        return rpc({
          cmd: "actAndWait", app: this.name, ...target,
          space: step.space, via: step.via, mouse: step.via === "mouse",
          button: step.button, count: step.count,
          timeoutMs: step.waitTimeoutMs ?? waitMs,
        });
      }
      case "type":
        return rpc({
          cmd: "actAndWait", app: this.name, text: step.text, ref: step.ref,
          timeoutMs: step.waitTimeoutMs ?? waitMs,
        });
      case "key":
        return rpc({
          cmd: "actAndWait", app: this.name, key: step.key,
          activate: step.activate === true,
          timeoutMs: step.waitTimeoutMs ?? waitMs,
        });
      case "set": {
        const t = monoNs();
        const r = await rpc({ cmd: "set", app: this.name, ref: step.ref, value: step.value });
        this._noteDeliver(nsToMs(monoNs() - t));
        if (step.requireVerified && r.verification?.state !== "verified") {
          return { ...r, ok: false, reasonCode: "value_not_verified" };
        }
        return r;
      }
      case "scroll": {
        const t = monoNs();
        const r = await rpc({
          cmd: "scroll", app: this.name, ref: step.ref,
          direction: step.direction ?? "down", pages: step.pages ?? 1,
        });
        this._noteDeliver(nsToMs(monoNs() - t));
        return r;
      }
      case "expect": {
        const timeout = step.timeoutMs ?? 3000;
        let hit;
        let what;
        if (typeof step.countGreaterThan === "number") {
          const n0 = step.countGreaterThan;
          hit = await this.waitFor(
            (elements) => countTextHits(elements, step.text) > n0,
            { timeoutMs: timeout },
          );
          what = `text=${step.text} count>${n0}`;
        } else if (step.window) {
          hit = await this.waitFor(
            (_, snap) => (snap.window || "").includes(step.window),
            { timeoutMs: timeout },
          );
          what = `window=${step.window}`;
        } else {
          hit = await this._waitForText(step.text, timeout, step.absent === true);
          what = `text=${step.text}`;
        }
        return hit
          ? { ok: true, verification: { state: "verified", source: "expect " + what } }
          : { ok: false, reasonCode: "expect_timeout", expect: what };
      }
      case "sleep": {
        const t = monoNs();
        await new Promise((r) => setTimeout(r, step.ms ?? 100));
        this._noteWait(nsToMs(monoNs() - t));
        return { ok: true };
      }
      default:
        return { ok: false, reasonCode: "unknown_op", op: step.op };
    }
  }

  /**
   * 按文字找一个可操作的落点。
   * 有动作就直接点 ref；纯文字节点（Finder 侧栏那种）就用它 rect 的中心做坐标命中，
   * 让 daemon 往上找可点祖先 —— 和 CLI 的 click --text 行为一致。
   */
  async _findTarget(text) {
    const t = monoNs();
    const snap = await rpc({ cmd: "snapshot", app: this.name, max: 4000, actions: true });
    // 失败也算一次快照：IPC 已经发生了。找目标算 resolve，不算 wait。
    const found = attributeFindSnapshot(nsToMs(monoNs() - t));
    this._noteResolve(found.resolveMs, found.snapshots);
    if (snap.ok === false) return null;
    return findTargetMatch(snap.elements, text);
  }

  /** 等界面出现/消失某段文字。用轮询替代 sleep(2000)。 */
  async _waitForText(text, timeoutMs, absent) {
    if (!text) return false;
    return this.waitFor((elements) => {
      const hit = elements.some((e) => `${e.label || ""} ${e.value || ""}`.includes(text));
      return hit !== absent;
    }, { timeoutMs });
  }

  /** 等某个条件成立：fn(elements) -> boolean */
  async waitFor(fn, opts = {}) {
    const timeoutMs = opts.timeoutMs ?? 3000;
    const deadline = monoNs() + BigInt(timeoutMs) * 1_000_000n;
    while (monoNs() < deadline) {
      const tSnap = monoNs();
      const snap = await rpc({ cmd: "snapshot", app: this.name, max: 4000, actions: false });
      const snapMs = nsToMs(monoNs() - tSnap);
      if (snap.ok !== false && fn(snap.elements || [], snap)) {
        // 命中这一轮没有 sleep，快照本身仍算 wait。
        const part = attributeWaitPoll(snapMs, 0);
        this._noteWait(part.waitMs, part.snapshots);
        this._noteWaitExit("changed");
        return true;
      }
      const tSleep = monoNs();
      await new Promise((r) => setTimeout(r, 80));
      const part = attributeWaitPoll(snapMs, nsToMs(monoNs() - tSleep));
      this._noteWait(part.waitMs, part.snapshots);
    }
    this._noteWaitExit("timeout");
    return false;
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
  countTextHits,
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

/** argv 入口和本模块是不是同一个文件。两边都 realpath，避免符号链接把直接 node 启动判成非 CLI。 */
export function cliEntryMatches(entry, moduleUrl = import.meta.url) {
  if (!entry) return false;
  try {
    return fs.realpathSync(entry) === fs.realpathSync(fileURLToPath(moduleUrl));
  } catch {
    return false;
  }
}

function runningAsCli() {
  return cliEntryMatches(process.argv[1]);
}

if (runningAsCli()) {
  main().catch((e) => {
    console.error("js error:", e?.message || e);
    process.exit(1);
  });
}
