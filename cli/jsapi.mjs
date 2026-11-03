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

/** wait_exit 的合法取值。cancelled 表示等待被取消提前结束，不是超时。 */
const WAIT_EXITS = new Set(["changed", "timeout", "cancelled"]);

function isWaitExit(v) {
  return typeof v === "string" && WAIT_EXITS.has(v);
}

/**
 * 把一步里的 daemon 片段和 JS 侧快照合成一行。
 * extraResolveMs / extraSnapshots 用来装 act() 的 diff_before / diff_after。
 * wait_exit 只有 changed / timeout / cancelled；没有等待概念的失败不写这个字段。
 */
export function composeStepTrace(input) {
  const events = Array.isArray(input.daemonEvents) ? input.daemonEvents : [];
  let resolve = Number(input.jsResolveMs) || 0;
  let deliver = 0;
  let wait = Number(input.jsWaitMs) || 0;
  let verify = 0;
  let snapshots = Number(input.jsSnapshots) || 0;
  let tier = "ax";
  let waitExit = isWaitExit(input.waitExit) ? input.waitExit : null;
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
    if (isWaitExit(ev.wait_exit)) waitExit = ev.wait_exit;
  }
  if (!usedDaemon) {
    deliver += Number(input.jsDeliverMs) || 0;
    const fb = input.fallback;
    if (fb && typeof fb === "object") {
      deliver += Number(fb.deliverMs) || 0;
      wait += Number(fb.waitMs) || 0;
      if (fb.tier === "ax" || fb.tier === "pid" || fb.tier === "mouse") tier = fb.tier;
      if (!waitExit && isWaitExit(fb.waitExit)) waitExit = fb.waitExit;
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
  // 文字点击命中的节点名。只出现在 trace 行上，不进 stdout 结果。
  if (typeof input.target === "string" && input.target) line.target = input.target;
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

/**
 * 可取消的等待。取消标记置位后立刻结束，不等到 ms 用完。
 * 按至多 50ms 切片检查本地标记；daemonPoll 时每 100ms 再问一次 daemon，
 * 让另一个进程发来的 cancel 也能打断睡眠（跨进程取消只在请求之间生效）。
 */
async function cancellableSleep(ms, opts = {}) {
  const daemonPoll = opts.daemonPoll === true;
  const slice = daemonPoll ? 100 : 50;
  let left = Math.max(0, Number(ms) || 0);
  while (left > 0) {
    if (runGate.cancelled) return;
    const t = monoNs();
    await new Promise((r) => setTimeout(r, Math.min(left, slice)));
    left -= Math.max(1, nsToMs(monoNs() - t));
    if (!daemonPoll || left <= 0) continue;
    await pollRunCancelled();
  }
}

/**
 * 只读心跳。daemon 在带 runId 的响应上捎回 runCancelled，
 * 这里据此置位本地取消标记。daemon 不可用不算失败：睡眠继续。
 */
async function pollRunCancelled() {
  if (!(runGate.runId > 0)) return;
  try {
    await rpc({ cmd: "ping" }, 500);
  } catch {
    // 心跳失败不改变睡眠语义。
  }
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

function firstTextHit(elements, text) {
  return (elements || []).find((e) =>
    `${e.label || ""} ${e.value || ""}`.includes(text)) || null;
}

/**
 * 第一个包含这段文字的节点的名字。优先 label，没有 label 时用 value。
 * 没命中、或两个字段都空，返回 null（trace 不写 target）。
 */
export function hitTargetLabel(elements, text) {
  const hit = firstTextHit(elements, text);
  if (!hit) return null;
  const label = typeof hit.label === "string" ? hit.label.trim() : "";
  if (label) return label;
  const value = typeof hit.value === "string" ? hit.value.trim() : "";
  return value || null;
}

/**
 * 会改界面的 daemon 命令。snapshot / state / ping / signature 不在里面。
 * state 在 JS 里就是 snapshot，所以只读调用不会被取消粘性拦住。
 */
export function isWriteCmd(cmd) {
  return cmd === "act" || cmd === "actAndWait" || cmd === "type" || cmd === "key"
    || cmd === "click" || cmd === "paste" || cmd === "set" || cmd === "scroll";
}

/**
 * daemon 会按 runId 拦的命令：写命令 + activate（换前台应用也算写）。
 * activate 不计投递步数，只拦执行；所以单独用这个判断，不动 isWriteCmd 的计数口径。
 */
export function isGuardedCmd(cmd) {
  return isWriteCmd(cmd) || cmd === "activate";
}

/**
 * 哪些请求带 runId：guarded 命令（daemon 会按 runId 拦），以及 snapshot / ping
 * （等待轮询用：只读响应靠 runId 捎回 runCancelled / runStale，请求本身永远不被拦）。
 * begin_run / cancel 不带：它们不属于任何 run。
 */
export function carriesRunId(cmd) {
  return isGuardedCmd(cmd) || cmd === "snapshot" || cmd === "ping";
}

/**
 * 写命令带上当前 runId，daemon 只执行「带 runId 且等于当前 runId」的写请求，
 * runId 过期回 stale_run，当前 run 被取消回 cancelled。
 * snapshot / ping 也带，用来接收只读响应里的 runCancelled / runStale 标记。
 * 没有 runId 的写请求（单独的命令行命令）不受任何 run 的取消影响。
 * 返回新对象，不改入参。
 */
export function withRunId(req, runId) {
  if (!req || !carriesRunId(req.cmd)) return req;
  const id = Number(runId);
  if (!Number.isFinite(id)) return req;
  return { ...req, runId: id };
}

/**
 * 一个 run 的取消状态。不连接 daemon，测试可以直接 new。
 *
 * completedSteps 的一步 = act 数组里的一个操作，或一次单独的 actAndWait。
 * 和 trace 的 step 是同一个口径。indexBase 接着上一轮的 completedSteps 续号时，
 * 下一条 trace 的 step 就等于当前 completedSteps。
 *
 * seenDaemon 只跟踪 daemon 已投递的写命令次数，用来判断
 * “这次取消发生在投递之后的等待里”还是“找目标之前就被拒了”。
 * expect / sleep 不增加 seenDaemon，但完成了仍增加 completedSteps。
 */
export class CancelRun {
  constructor() {
    this.runId = 0;
    this.cancelled = false;
    this.stale = false;
    this.completedSteps = 0;
    this.seenDaemon = 0;
    this.inAct = 0;
  }

  beginRun() {
    this.runId += 1;
    this.cancelled = false;
    this.stale = false;
    this.completedSteps = 0;
    this.seenDaemon = 0;
    return { ok: true, runId: this.runId, completedSteps: 0 };
  }

  /** 置位。同一 run 内写操作粘住，直到下一次 beginRun。 */
  cancel() {
    this.cancelled = true;
    return this.stickyResult();
  }

  /**
   * daemon 说这个 runId 已经不是当前 run（别的进程 begin_run 了）。
   * 和取消一样粘住；结果仍用 status:"cancelled"，reasonCode 记 stale_run。
   */
  markStale() {
    this.cancelled = true;
    this.stale = true;
    return this.stickyResult();
  }

  /** 本地拦下的结果。local:true 表示没有发生 daemon 投递，不能按 daemon 计数。 */
  stickyResult() {
    const out = {
      ok: false,
      status: "cancelled",
      local: true,
      completedSteps: this.completedSteps,
    };
    out.reasonCode = this.stale ? "stale_run" : "cancelled";
    return out;
  }

  enterAct() {
    this.inAct += 1;
  }

  leaveAct() {
    this.inAct = Math.max(0, this.inAct - 1);
  }

  /** daemon 写命令成功返回。只动写计数，act 的步数由 runActSteps 记。 */
  noteWriteOk() {
    this.seenDaemon += 1;
  }

  noteStepCompleted() {
    this.completedSteps += 1;
  }

  /**
   * daemon 回了 status=cancelled。参数是 daemon 的已投递写步数。
   * 比 seenDaemon 大，说明这次投递已经发生（等待阶段被取消），这一步计入。
   * 同一个数字再观察一次不会重复加。
   */
  observeDaemonCancel(daemonCompletedSteps) {
    const n = Number(daemonCompletedSteps);
    const reported = Number.isFinite(n) ? n : this.seenDaemon;
    const delivered = reported > this.seenDaemon;
    this.seenDaemon = Math.max(this.seenDaemon, reported);
    this.cancelled = true;
    if (delivered) this.completedSteps += 1;
    return { delivered, completedSteps: this.completedSteps };
  }
}

/** 写命令（含 activate）在已取消/过期时不发往 daemon。只读命令始终 send。 */
export function gateRpc(gate, cmd) {
  if (!isGuardedCmd(cmd) || !gate.cancelled) return { send: true };
  return { send: false, result: gate.stickyResult() };
}

function slimFrom(index, step, r, ms) {
  const cancelled = r.status === "cancelled" || r.reasonCode === "cancelled"
    || r.reasonCode === "stale_run";
  const slim = {
    index,
    op: step?.op,
    ms: Math.round(Number(ms) || 0),
    ok: !cancelled && r.ok === true,
  };
  if (r.via) slim.via = r.via;
  if (r.action) slim.action = r.action;
  if (r.changed !== undefined) slim.changed = r.changed;
  if (r.verification && typeof r.verification === "object") {
    slim.verification = r.verification.state === "verified"
      ? "verified"
      : `unverified${r.verification.reason ? `(${r.verification.reason})` : ""}`;
  }
  if (cancelled) slim.reasonCode = r.reasonCode || "cancelled";
  else if (r.ok !== true) slim.reasonCode = r.reasonCode || "unknown";
  return slim;
}

/**
 * 纯逻辑跑一轮 act。exec 由调用方提供，这里不碰 socket。
 * 已取消的步（含等待阶段才返回 cancelled 的那一步）不进入 traceSteps。
 * completedSteps 与 trace 只认 daemon 确认的写投递：本地拦下的结果带 local:true，
 * 不参与 daemon 计数比较，避免前面有 expect / sleep 时把后面被拦的写算成已投递。
 * 返回里在取消时带 status / cancelled / completedSteps，并保留 steps、failedAt。
 */
export async function runActSteps(steps, gate, opts = {}) {
  const indexBase = Number.isInteger(opts.indexBase) && opts.indexBase >= 0 ? opts.indexBase : 0;
  const stopOnError = opts.stopOnError !== false;
  const exec = opts.exec;
  const results = [];
  const traceSteps = [];
  let failedAt = null;
  let sawCancel = false;
  let sawStale = false;

  const cancelReason = () => (gate.stale ? "stale_run" : "cancelled");

  const pushCancelled = (i, step) => {
    results.push({
      index: indexBase + i,
      op: step?.op,
      ms: 0,
      ok: false,
      reasonCode: cancelReason(),
    });
  };

  for (let i = 0; i < steps.length; i++) {
    const step = steps[i] ?? {};
    const index = indexBase + i;
    if (gate.cancelled) {
      sawCancel = true;
      if (gate.stale) sawStale = true;
      if (failedAt === null) failedAt = i;
      for (let j = i; j < steps.length; j++) pushCancelled(j, steps[j] ?? {});
      break;
    }
    const completedBefore = gate.completedSteps;
    const seenBefore = gate.seenDaemon;
    let r;
    try {
      r = await exec(step, i, gate);
    } catch (e) {
      r = { ok: false, reasonCode: "js_error", message: e?.message || String(e) };
    }
    if (!r || typeof r !== "object") r = { ok: false, reasonCode: "js_error" };

    if (r.status === "cancelled" || r.reasonCode === "stale_run") {
      sawCancel = true;
      const stale = r.reasonCode === "stale_run";
      if (stale) {
        sawStale = true;
        // 别的进程换 run 了：本 run 的后续写都按 stale_run 本地拦住。
        gate.markStale();
      }
      // 只有 daemon 确认的投递才算完成。本地拦下的结果（local:true，比如
      // expect / sleep 之后、_findTarget 的快照带回取消时 gateRpc 返回的）
      // 和 stale_run（daemon 根本没执行）都不参与 daemon 计数比较，
      // 否则前面完成过的 expect / sleep 会把后面被拦的写误判成已投递。
      const local = r.local === true || stale;
      const delivered = !local && gate.seenDaemon > seenBefore;
      const observed = local
        ? { delivered: false, completedSteps: gate.completedSteps }
        : gate.observeDaemonCancel(r.completedSteps);
      if (failedAt === null) failedAt = i;
      const ms = r._traced?.stepMs || 0;
      results.push(slimFrom(index, step, { ...r, ok: false, status: "cancelled" }, ms));
      if (delivered || observed.delivered) {
        // 投递已经发生、取消打断的是等待：这一步算完成，trace 带 wait_exit=cancelled。
        traceSteps.push({ step: index, action: step.op || "unknown" });
        if (opts.onTrace) await opts.onTrace({ i, index, step, result: r, ms });
      }
      for (let j = i + 1; j < steps.length; j++) pushCancelled(j, steps[j] ?? {});
      break;
    }

    const deliveredWrite = gate.seenDaemon > seenBefore;
    if ((r.ok === true || deliveredWrite) && gate.completedSteps === completedBefore) {
      gate.noteStepCompleted();
    }
    const ms = r._traced?.stepMs || 0;
    results.push(slimFrom(index, step, r, ms));
    traceSteps.push({ step: index, action: step.op || "unknown" });
    if (opts.onTrace) await opts.onTrace({ i, index, step, result: r, ms });
    if (stopOnError && r.ok !== true) {
      failedAt = i;
      break;
    }
    if (opts.onAfter) await opts.onAfter(i, step, r, gate);
    // 这一步已经完成。取消落在它和下一步之间：下一步不执行，也不打 trace。
    if (gate.cancelled && i + 1 < steps.length) {
      sawCancel = true;
      if (gate.stale) sawStale = true;
      if (failedAt === null) failedAt = i + 1;
      for (let j = i + 1; j < steps.length; j++) pushCancelled(j, steps[j] ?? {});
      break;
    }
  }

  const out = {
    ok: failedAt === null && !sawCancel,
    failedAt,
    steps: results,
    traceSteps,
  };
  if (sawCancel) {
    out.ok = false;
    out.status = "cancelled";
    out.cancelled = true;
    out.completedSteps = gate.completedSteps;
    // 不新增 status：过期 run 也是 cancelled，只换 reasonCode。
    if (sawStale) out.reasonCode = "stale_run";
  }
  return out;
}

const runGate = new CancelRun();

/**
 * 脚本级取消 / 过期。waitFor、sleep 和每个写 API 在发现取消（含 stale_run）时抛出，
 * 避免把 false / undefined 当成普通结果继续往下跑。act() 不抛，仍返回
 * status:"cancelled"，和 design.md 的口径一致。
 *
 * scu js 顶层捕获后输出 {ok:false,status:"cancelled",completedSteps:n}（stale 时
 * 多带 reasonCode:"stale_run"），退出码 130；其它异常仍是 stderr + 退出码 1。
 */
export class CancelledError extends Error {
  constructor({ reasonCode = "cancelled", completedSteps = 0 } = {}) {
    super(reasonCode === "stale_run" ? "cancelled (stale_run)" : "cancelled");
    this.name = "CancelledError";
    this.ok = false;
    this.status = "cancelled";
    this.reasonCode = reasonCode;
    this.completedSteps = completedSteps;
    this.cancelled = true;
  }
}

/** 由 run 当前状态构造取消错误。reasonCode 只有 cancelled / stale_run。 */
function cancelledError(gate = runGate) {
  return new CancelledError({
    reasonCode: gate.stale ? "stale_run" : "cancelled",
    completedSteps: gate.completedSteps,
  });
}

/** daemon / 本地拦下的结果若是取消（含 stale_run），抛 CancelledError；否则原样返回。 */
function throwIfCancelled(r) {
  if (r && (r.status === "cancelled" || r.reasonCode === "cancelled"
    || r.reasonCode === "stale_run")) {
    throw cancelledError(runGate);
  }
  return r;
}

/**
 * 第一次子串命中。有 actions 用 ref（优先 target_ref）；没有则用 rect 中心，
 * 让 daemon 往上找可点祖先。没有可用矩形时退回 ref。
 */
export function findTargetMatch(elements, text) {
  const hit = firstTextHit(elements, text);
  if (!hit) return null;
  if (hit.actions?.length) return { ref: hit.target_ref || hit.ref };
  if (hit.rect && hit.rect.w > 0 && hit.rect.h > 0) {
    return { x: hit.rect.x + hit.rect.w / 2, y: hit.rect.y + hit.rect.h / 2 };
  }
  return { ref: hit.target_ref || hit.ref };
}

function noteRpcOutcome(req, payload) {
  if (!payload || typeof payload !== "object") return payload;
  if (payload.runStale === true) {
    // daemon 在只读响应上捎回的过期标记：runId 已经被别的进程换掉了。
    // 请求照常拿到结果，但后续写命令本地不再发，等待轮询立刻停。
    runGate.markStale();
  } else if (payload.runCancelled === true) {
    // daemon 在只读响应上捎回的取消标记：这次请求照常返回了结果，但本 run 已取消。
    // 后续写命令本地就不再发；等待轮询（waitFor / expect / sleep）据此提前结束。
    runGate.cancelled = true;
  }
  if (payload.reasonCode === "stale_run") {
    // 过期 run 的写请求：daemon 没执行，也不能拿 daemon 的计数来比。
    // 对调用方仍按取消处理，只把 reason 换成 stale_run。
    runGate.markStale();
    return { ...payload, ok: false, status: "cancelled", reasonCode: "stale_run" };
  }
  if (payload.status === "cancelled") {
    runGate.observeDaemonCancel(payload.completedSteps);
    if (!payload.reasonCode) payload.reasonCode = "cancelled";
    return payload;
  }
  if (payload.ok === true && isWriteCmd(req.cmd)) {
    runGate.noteWriteOk();
    // 单独一次 actAndWait 自己就是一步。act() 里面的步由 runActSteps 记，避免加两次。
    if (runGate.inAct === 0 && req.cmd === "actAndWait") runGate.noteStepCompleted();
  }
  return payload;
}

function rpc(req, timeoutMs = TIMEOUT) {
  const gated = gateRpc(runGate, req.cmd);
  if (!gated.send) return Promise.resolve(gated.result);
  // 写操作带上当前 runId，daemon 才能判断这次取消是不是针对这个 run。
  const outbound = withRunId(req, runGate.runId);
  rpcCount++;
  return new Promise((resolve, reject) => {
    const sock = net.createConnection(SOCK);
    let buf = "";
    const done = (err, val) => {
      sock.destroy();
      err ? reject(err) : resolve(val);
    };
    sock.setEncoding("utf8");
    sock.setTimeout(timeoutMs, () => done(new Error(`rpc timeout: ${req.cmd}`)));
    sock.on("connect", () => sock.write(JSON.stringify(outbound) + "\n"));
    sock.on("data", (d) => {
      buf += d;
      if (buf.includes("\n")) {
        try {
          const parsed = JSON.parse(buf);
          // 被取消的步骤不出 trace 行。先剥掉 trace，且不写 stderr、不放进 hold。
          if (parsed && parsed.status === "cancelled") {
            const { payload } = peelTrace(parsed, { enabled: false });
            done(null, noteRpcOutcome(req, payload));
            return;
          }
          const { payload, lines } = peelTrace(parsed, {
            enabled: traceEnabled(),
            hold: traceHold,
          });
          for (const ev of lines) emitTraceLine(ev);
          done(null, noteRpcOutcome(req, payload));
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
    const r = throwIfCancelled(await rpc(req));
    if (!r.ok) throw new Error(`click failed: ${r.reasonCode || "failed"} ${r.hint || ""}`.trim());
    return r;
  }

  async type(text, opts = {}) {
    const r = throwIfCancelled(await rpc({ cmd: "type", app: this.name, text, ...opts }));
    if (!r.ok) throw new Error(`type failed: ${r.reasonCode || "failed"} ${r.hint || ""}`.trim());
    return r;
  }

  async key(chord, opts = {}) {
    // 默认定向投递（不抢焦点）。需要真键盘时传 { activate: true }。
    const r = throwIfCancelled(await rpc({ cmd: "key", app: this.name, key: chord, ...opts }));
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
    const r = throwIfCancelled(await rpc({
      cmd: "actAndWait", app: this.name, timeoutMs: opts.timeoutMs ?? 1500, ...target,
    }));
    if (r.ok === false) throw new Error(`clickAndWait failed: ${r.reasonCode}`);
    return r;
  }

  async typeAndWait(text, opts = {}) {
    const r = throwIfCancelled(await rpc({
      cmd: "actAndWait", app: this.name, text, timeoutMs: opts.timeoutMs ?? 1200,
      ...(opts.ref ? { ref: opts.ref } : {}),
    }));
    if (r.ok === false) throw new Error(`typeAndWait failed: ${r.reasonCode}`);
    return r;
  }

  async keyAndWait(chord, opts = {}) {
    const r = throwIfCancelled(await rpc({
      cmd: "actAndWait", app: this.name, key: chord, timeoutMs: opts.timeoutMs ?? 1500,
      ...(opts.activate ? { activate: true } : {}),
    }));
    if (r.ok === false) throw new Error(`keyAndWait failed: ${r.reasonCode}`);
    return r;
  }

  async signature() {
    const r = await rpc({ cmd: "signature", app: this.name });
    if (r.ok === false) throw new Error(`signature failed: ${r.reasonCode}`);
    return r.signature;
  }

  async set(ref, value) {
    const r = throwIfCancelled(await rpc({ cmd: "set", app: this.name, ref, value }));
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
    const built = [];
    // begin_run 在 scu js 进程启动时调一次，不在每次 act 里清标记。
    runGate.enterAct();
    let outcome;
    try {
      outcome = await runActSteps(steps, runGate, {
        indexBase,
        stopOnError,
        exec: async (step) => {
          const held = [];
          const prevHold = traceHold;
          if (traceOn) {
            this._traceAcc = {
              resolveMs: 0, deliverMs: 0, waitMs: 0, snapshots: 0, waitExit: null, target: null,
            };
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
          if (!r || typeof r !== "object") r = { ok: false, reasonCode: "js_error" };
          // 取消打断的是「动作已投递、正在等界面」：这一步算完成，trace 里
          // wait_exit 记 cancelled。投放前就被拒的取消不走到这里打 trace。
          if (acc && r.status === "cancelled") acc.waitExit = "cancelled";
          return { ...r, _traced: { held, acc, stepMs } };
        },
        // 投递之前就被取消的步不会走到这里，所以没有 trace 行，也不会被汇总成 timeout。
        onTrace: (info) => {
          if (!traceOn) return;
          const tr = info.result._traced || { held: [], acc: null, stepMs: 0 };
          const held = tr.held || [];
          const acc = tr.acc;
          built.push({
            step: info.index,
            action: info.step?.op || "unknown",
            daemonEvents: held,
            jsResolveMs: acc?.resolveMs || 0,
            jsDeliverMs: acc?.deliverMs || 0,
            jsWaitMs: acc?.waitMs || 0,
            jsSnapshots: acc?.snapshots || 0,
            waitExit: acc?.waitExit || null,
            target: acc?.target || null,
            // 没有 daemon 片段时才用 actMs/waitedMs 兜底，避免和 JS 侧计时叠在一起。
            fallback: held.length ? null : fallbackFromActResult(info.result),
            extraResolveMs: 0,
            extraSnapshots: 0,
            totalMs: tr.stepMs || 0,
          });
        },
      });
    } finally {
      runGate.leaveAct();
    }
    const results = outcome.steps;
    const failedAt = outcome.failedAt;

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
      const report = {
        ok: outcome.ok,
        failedAt,
        elapsedMs: Math.round(nsToMs(monoNs() - started)),
        diff,
        steps: results,
      };
      if (outcome.cancelled) {
        report.ok = false;
        report.status = "cancelled";
        report.cancelled = true;
        report.completedSteps = outcome.completedSteps;
        if (outcome.reasonCode) report.reasonCode = outcome.reasonCode;
      }
      return report;
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
          hit = await this._pollUntil(
            (elements) => countTextHits(elements, step.text) > n0,
            { timeoutMs: timeout },
          );
          what = `text=${step.text} count>${n0}`;
        } else if (step.window) {
          hit = await this._pollUntil(
            (_, snap) => (snap.window || "").includes(step.window),
            { timeoutMs: timeout },
          );
          what = `window=${step.window}`;
        } else {
          hit = await this._waitForText(step.text, timeout, step.absent === true);
          what = `text=${step.text}`;
        }
        if (hit === "cancelled") return runGate.stickyResult();
        return hit
          ? { ok: true, verification: { state: "verified", source: "expect " + what } }
          : { ok: false, reasonCode: "expect_timeout", expect: what };
      }
      case "sleep": {
        const t = monoNs();
        await cancellableSleep(step.ms ?? 100, { daemonPoll: true });
        this._noteWait(nsToMs(monoNs() - t));
        return runGate.cancelled ? runGate.stickyResult() : { ok: true };
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
    // 只在 SCU_TRACE=1（_traceAcc 存在）时记下命中节点的名字，不放进动作结果。
    const label = hitTargetLabel(snap.elements, text);
    if (label && this._traceAcc) this._traceAcc.target = label;
    return findTargetMatch(snap.elements, text);
  }

  /** 等界面出现/消失某段文字。用轮询替代 sleep(2000)。 */
  async _waitForText(text, timeoutMs, absent) {
    if (!text) return false;
    return this._pollUntil((elements) => {
      const hit = elements.some((e) => `${e.label || ""} ${e.value || ""}`.includes(text));
      return hit !== absent;
    }, { timeoutMs });
  }

  /**
   * 内部轮询：返回 true（命中）/ false（超时）/ "cancelled"（取消或过期）。
   * act 的 expect 用它，把 cancelled 归一成步骤状态而不是抛出。
   */
  async _pollUntil(fn, opts = {}) {
    const timeoutMs = opts.timeoutMs ?? 3000;
    const deadline = monoNs() + BigInt(timeoutMs) * 1_000_000n;
    while (monoNs() < deadline) {
      // 被取消就立刻结束：不睡满超时，也不把这一轮记成 timeout。
      if (runGate.cancelled) return "cancelled";
      const tSnap = monoNs();
      const snap = await rpc({ cmd: "snapshot", app: this.name, max: 4000, actions: false });
      const snapMs = nsToMs(monoNs() - tSnap);
      if (runGate.cancelled) {
        // 这次快照带回了取消 / 过期标记：这一轮照常算 wait，但不再判命中、不再等。
        const part = attributeWaitPoll(snapMs, 0);
        this._noteWait(part.waitMs, part.snapshots);
        return "cancelled";
      }
      if (snap.ok !== false && fn(snap.elements || [], snap)) {
        // 命中这一轮没有 sleep，快照本身仍算 wait。
        const part = attributeWaitPoll(snapMs, 0);
        this._noteWait(part.waitMs, part.snapshots);
        this._noteWaitExit("changed");
        return true;
      }
      const tSleep = monoNs();
      await cancellableSleep(80);
      const part = attributeWaitPoll(snapMs, nsToMs(monoNs() - tSleep));
      this._noteWait(part.waitMs, part.snapshots);
      if (runGate.cancelled) return "cancelled";
    }
    this._noteWaitExit("timeout");
    return false;
  }

  /**
   * 等某个条件成立：fn(elements) -> boolean。
   * 脚本里取消 / stale_run 时抛 CancelledError（不再返回 false 让脚本继续跑）。
   */
  async waitFor(fn, opts = {}) {
    const hit = await this._pollUntil(fn, opts);
    if (hit === "cancelled") throw cancelledError();
    return hit === true;
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
    const r = throwIfCancelled(await rpc({ cmd: "activate", app: name }));
    if (!r.ok) throw new Error(`activate failed: ${r.reasonCode}`);
    return r;
  },
  async ping() {
    return rpc({ cmd: "ping" });
  },
  /** 可取消的等待。取消 / stale_run 时抛 CancelledError，不返回 undefined 让脚本继续跑。 */
  async sleep(ms) {
    await cancellableSleep(ms, { daemonPoll: true });
    if (runGate.cancelled) throw cancelledError();
  },
  log: (...a) => console.log(...a),
  countTextHits,
  get rpcCount() {
    return rpcCount;
  },
};

// ---------------- 脚本执行 ----------------

const argv = process.argv.slice(2);
globalThis.scu = scu;

/**
 * 每个 scu js 进程启动时调一次，清掉 daemon 里上次运行留下的取消标记。
 * 失败必须抛出：runId 拿不到就没法把写请求绑到本次 run，取消机制会失效。
 * runId 必须是正整数：Number(null) === 0 / Number("abc") === NaN 都不能当合法值。
 * 调用方（main）捕获后以非 0 退出，不能只打一行 stderr 继续跑脚本。
 */
async function startRun() {
  runGate.beginRun();
  let r;
  try {
    r = await rpc({ cmd: "begin_run" });
  } catch (err) {
    throw new Error(`begin_run 失败：daemon 不可用（${err?.message || err}）`);
  }
  const runId = r?.runId;
  if (!r || r.ok !== true || typeof runId !== "number"
    || !Number.isInteger(runId) || runId <= 0) {
    throw new Error(`begin_run 失败：${r?.reasonCode || "bad_run_id"}`);
  }
  runGate.runId = runId;
  runGate.completedSteps = Number(r.completedSteps) || 0;
}

async function main() {
  await startRun();
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
    if (e && e.name === "CancelledError") {
      // 脚本里的 waitFor / sleep / 写 API 被取消或 stale_run：给调用方一个
      // 和 act 同形的终态，退出码 130（不是 1，用来和普通脚本错误区分）。
      const payload = {
        ok: false,
        status: "cancelled",
        completedSteps: Number(e.completedSteps) || 0,
      };
      if (e.reasonCode === "stale_run") payload.reasonCode = "stale_run";
      process.stdout.write(JSON.stringify(payload) + "\n");
      process.exit(130);
    }
    console.error("js error:", e?.message || e);
    process.exit(1);
  });
}
