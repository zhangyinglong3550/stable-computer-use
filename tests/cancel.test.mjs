/**
 * 取消机制的纯逻辑测试。不连 daemon、不碰 AX。
 *
 * 前 6 个用例移植自 PR #2 的 tests/cancel.test.mjs，但改用 PR #4 的 CancelRun /
 * runActSteps，断言按「一步 = act 数组里的一次操作」的口径改写：
 * 投递之后的取消算完成并出一行 trace（wait_exit=cancelled）；投递之前被拒的步
 * 不执行、不出 trace、不计入 completedSteps、也不算超时。
 *
 *   node --test tests/cancel.test.mjs
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  CancelRun, CancelledError, carriesRunId, composeStepTrace, fallbackFromActResult, gateRpc,
  isGuardedCmd, isWriteCmd, runActSteps, withRunId,
} from "../cli/jsapi.mjs";

/** 按给定次数执行，返回记录到的 op 列表。 */
function recorder() {
  const calls = [];
  return {
    calls,
    exec(step) {
      calls.push(step.op);
      return { ok: true, via: "ax" };
    },
  };
}

test("取消之后后续步骤不执行，并带回已完成次数", async () => {
  const gate = new CancelRun();
  gate.beginRun();
  const rec = recorder();

  const out = await runActSteps(
    [{ op: "click" }, { op: "type" }, { op: "key" }],
    gate,
    { ...rec, onAfter(i, _step, _r, g) { if (i === 0) g.cancel(); } },
  );

  assert.deepEqual(rec.calls, ["click"]);
  assert.equal(out.ok, false);
  assert.equal(out.status, "cancelled");
  assert.equal(out.cancelled, true);
  assert.equal(out.completedSteps, 1);
  assert.equal(out.failedAt, 1);
  assert.deepEqual(out.steps.map((s) => s.reasonCode), [undefined, "cancelled", "cancelled"]);
  // 被取消的步没有执行，也没有 trace 行。
  assert.deepEqual(out.traceSteps.map((t) => t.step), [0]);
});

test("取消是粘性的：之后每一次都不执行，completedSteps 不再增加", async () => {
  const gate = new CancelRun();
  gate.beginRun();
  const rec = recorder();

  await runActSteps([{ op: "click" }, { op: "type" }], gate, rec);
  assert.equal(gate.completedSteps, 2);
  gate.cancel();

  const third = await runActSteps([{ op: "key" }], gate, rec);
  const fourth = await runActSteps([{ op: "scroll" }], gate, rec);

  assert.deepEqual(rec.calls, ["click", "type"]);
  assert.equal(gate.completedSteps, 2);
  assert.equal(third.status, "cancelled");
  assert.equal(third.completedSteps, 2);
  assert.equal(fourth.status, "cancelled");
  assert.equal(fourth.completedSteps, 2);
  assert.ok(third.steps.every((s) => s.reasonCode === "cancelled"));
  assert.deepEqual(third.traceSteps, []);
});

test("新一次运行清除取消状态和计数", async () => {
  const gate = new CancelRun();
  const first = gate.beginRun();
  const rec = recorder();

  await runActSteps([{ op: "click" }], gate, rec);
  gate.cancel();
  const blocked = await runActSteps([{ op: "type" }], gate, rec);
  assert.deepEqual(rec.calls, ["click"]);
  assert.equal(blocked.completedSteps, 1);

  const again = gate.beginRun();
  assert.equal(again.runId, first.runId + 1);
  assert.equal(gate.cancelled, false);
  assert.equal(gate.completedSteps, 0);

  const ok = await runActSteps([{ op: "type" }], gate, rec);
  assert.deepEqual(rec.calls, ["click", "type"]);
  assert.equal(ok.ok, true);
  assert.equal(gate.completedSteps, 1);
  assert.equal(gate.cancelled, false);
  assert.ok(!("cancelled" in ok));
});

test("尚未执行任何步骤时取消，completedSteps 为 0 且步骤不跑", async () => {
  const gate = new CancelRun();
  gate.beginRun();
  gate.cancel();
  const rec = recorder();

  const out = await runActSteps([{ op: "click" }], gate, rec);

  assert.deepEqual(rec.calls, []);
  assert.equal(out.completedSteps, 0);
  assert.equal(out.status, "cancelled");
  assert.deepEqual(out.traceSteps, []);
});

test("失败或抛错的步骤不算完成，也不因此变成取消", async () => {
  const gate = new CancelRun();
  gate.beginRun();

  const failed = await runActSteps([{ op: "click" }], gate, {
    exec() { return { ok: false, reasonCode: "stale_ref" }; },
  });
  assert.equal(failed.ok, false);
  assert.equal(failed.steps[0].reasonCode, "stale_ref");
  assert.equal(gate.completedSteps, 0);
  assert.equal(gate.cancelled, false);

  const thrown = await runActSteps([{ op: "type" }], gate, {
    exec() { throw new Error("boom"); },
  });
  assert.equal(thrown.steps[0].reasonCode, "js_error");
  assert.equal(gate.completedSteps, 0);
  assert.equal(gate.cancelled, false);
});

test("重复标记取消仍然粘住，beginRun 之后才能再执行", async () => {
  const gate = new CancelRun();
  gate.beginRun();
  gate.cancel();
  gate.cancel();
  const rec = recorder();

  const blocked = await runActSteps([{ op: "click" }], gate, rec);
  assert.deepEqual(rec.calls, []);
  assert.equal(blocked.status, "cancelled");

  gate.beginRun();
  const ok = await runActSteps([{ op: "click" }], gate, rec);
  assert.deepEqual(rec.calls, ["click"]);
  assert.equal(ok.ok, true);
  assert.equal(gate.completedSteps, 1);
});

test("写命令、snapshot、ping 带 runId；begin_run / cancel / signature 不带", () => {
  const gate = new CancelRun();
  gate.beginRun();
  const runId = gate.runId;

  for (const cmd of ["click", "set", "type", "key", "scroll", "paste", "act", "actAndWait"]) {
    assert.equal(isWriteCmd(cmd), true, cmd);
    const req = withRunId({ cmd, app: "Finder" }, runId);
    assert.equal(req.runId, runId, cmd);
    assert.equal(req.cmd, cmd);
    assert.equal(req.app, "Finder");
  }
  // snapshot / ping 带 runId 只为接收 runCancelled / runStale；activate 是 guarded 但不计投递。
  for (const cmd of ["snapshot", "ping", "activate"]) {
    assert.equal(isWriteCmd(cmd), false, cmd);
    assert.equal(carriesRunId(cmd), true, cmd);
    assert.equal(withRunId({ cmd }, runId).runId, runId, cmd);
  }
  assert.equal(isGuardedCmd("activate"), true);
  assert.equal(isGuardedCmd("snapshot"), false);
  assert.equal(isGuardedCmd("click"), true);
  for (const cmd of ["signature", "begin_run", "cancel"]) {
    assert.equal(isWriteCmd(cmd), false, cmd);
    assert.equal("runId" in withRunId({ cmd }, runId), false, cmd);
  }
  // 不改入参。
  const original = { cmd: "click", app: "Finder" };
  withRunId(original, runId);
  assert.equal("runId" in original, false);
  // 没有 runId 时原样返回：单独的命令行命令不带。
  const standalone = { cmd: "click" };
  assert.equal(withRunId(standalone, undefined), standalone);
});

test("等待阶段取消：已投递的步算完成，trace 的 wait_exit 是 cancelled 不是 timeout", async () => {
  const gate = new CancelRun();
  gate.beginRun();
  let traced = null;

  const out = await runActSteps([{ op: "click" }, { op: "type" }], gate, {
    exec(_step, i) {
      if (i === 0) {
        gate.noteWriteOk();
        return { ok: true, via: "ax", changed: true };
      }
      // daemon 的 completedSteps 从 1 涨到 2：动作已经发出，取消打断的是等待。
      return {
        ok: false, status: "cancelled", completedSteps: 2, via: "pid",
        actMs: 5, waitedMs: 120,
        _traced: { held: [], acc: { waitExit: "cancelled" }, stepMs: 125 },
      };
    },
    onTrace(info) {
      if (info.index === 1) traced = info.result._traced.acc;
    },
  });

  assert.equal(out.status, "cancelled");
  assert.equal(out.completedSteps, 2);
  assert.deepEqual(out.traceSteps.map((t) => t.step), [0, 1]);
  assert.equal(traced.waitExit, "cancelled");

  // act() 用 fallback 的 actMs / waitedMs 补分段，wait_exit 由取消标记给出。
  const line = composeStepTrace({
    step: 1,
    action: "type",
    totalMs: 125,
    waitExit: traced.waitExit,
    fallback: fallbackFromActResult({
      ok: false, status: "cancelled", actMs: 5, waitedMs: 120, via: "pid",
    }),
  });
  assert.equal(line.wait_exit, "cancelled");
  assert.equal(line.deliver_ms, 5);
  assert.equal(line.wait_ms, 120);
  assert.equal(line.tier, "pid");
});

test("投递之前被取消：写命令不发往 daemon，也不进 completedSteps", async () => {
  const gate = new CancelRun();
  gate.beginRun();
  gate.noteWriteOk();
  gate.noteStepCompleted();
  gate.cancel();

  for (const cmd of ["click", "set", "type", "key", "scroll", "paste", "act", "actAndWait", "activate"]) {
    const adm = gateRpc(gate, cmd);
    assert.equal(adm.send, false, cmd);
    assert.equal(adm.result.status, "cancelled");
    assert.equal(adm.result.completedSteps, 1);
    assert.equal(adm.result.local, true, cmd);
  }
  for (const cmd of ["snapshot", "state", "ping", "signature"]) {
    assert.equal(gateRpc(gate, cmd).send, true, cmd);
  }
  assert.equal(gate.completedSteps, 1);

  const out = await runActSteps([{ op: "click" }], gate, {
    exec() { throw new Error("不应执行"); },
  });
  assert.equal(out.completedSteps, 1);
  assert.deepEqual(out.traceSteps, []);
});

// ---------------- 阻塞 B：completedSteps / trace 只认 daemon 确认的投递 ----------------

test("阻塞 B 复现（评审原文）：前面是成功的 expect，后面写步在本地被拦不算已投递", async () => {
  const gate = new CancelRun();
  gate.beginRun();

  const out = await runActSteps([{ op: "expect" }, { op: "click" }], gate, {
    exec(_step, i, g) {
      if (i === 0) return { ok: true };
      g.cancel();
      return g.stickyResult();
    },
  });

  assert.equal(out.status, "cancelled");
  // expect 完成算 1 步；被本地拦下的 click 没有投递，不能再算。
  assert.equal(out.completedSteps, 1);
  assert.deepEqual(out.traceSteps.map((t) => t.step), [0]);
  assert.equal(gate.seenDaemon, 0);
  assert.equal(out.steps[1].reasonCode, "cancelled");
});

test("阻塞 B 情形一：前面是成功的 sleep，后面写步本地被拦不算已投递", async () => {
  const gate = new CancelRun();
  gate.beginRun();
  const ran = [];

  const out = await runActSteps([{ op: "sleep" }, { op: "click" }], gate, {
    exec(step, i, g) {
      ran.push(step.op);
      if (i === 0) return { ok: true };
      g.cancel();
      return g.stickyResult();
    },
  });

  assert.deepEqual(ran, ["sleep", "click"]);
  assert.equal(out.completedSteps, 1);
  assert.deepEqual(out.traceSteps.map((t) => t.step), [0]);
  assert.equal(gate.seenDaemon, 0);
});

test("阻塞 B 情形二：已投递的 click 后接被取消的 sleep，不再多算一步或一行 trace", async () => {
  const gate = new CancelRun();
  gate.beginRun();

  const out = await runActSteps([{ op: "click" }, { op: "sleep" }], gate, {
    exec(_step, i, g) {
      if (i === 0) {
        g.noteWriteOk();
        return { ok: true, via: "ax", changed: true };
      }
      g.cancel();
      return g.stickyResult();
    },
  });

  assert.equal(out.completedSteps, 1);
  assert.deepEqual(out.traceSteps.map((t) => t.step), [0]);
  assert.equal(gate.seenDaemon, 1);
  assert.equal(out.steps[1].reasonCode, "cancelled");
});

// ---------------- 阻塞 A：过期 runId ----------------

test("过期 run 的写按 cancelled 承载 stale_run，不计数、不出 trace，后续写本地拦住", async () => {
  const gate = new CancelRun();
  gate.beginRun();

  const out = await runActSteps([{ op: "expect" }, { op: "click" }, { op: "type" }], gate, {
    exec(_step, i) {
      if (i === 0) return { ok: true };
      // daemon 对过期 runId 的固定响应：不执行。
      return { ok: false, reasonCode: "stale_run" };
    },
  });

  assert.equal(out.ok, false);
  assert.equal(out.status, "cancelled");
  assert.equal(out.reasonCode, "stale_run");
  assert.equal(out.cancelled, true);
  // expect 完成的 1 步保留；过期的写没有执行，不能算。
  assert.equal(out.completedSteps, 1);
  assert.equal(gate.seenDaemon, 0);
  assert.deepEqual(out.traceSteps.map((t) => t.step), [0]);
  assert.deepEqual(out.steps.map((s) => s.reasonCode), [undefined, "stale_run", "stale_run"]);

  // 同一 run 内保持：后续写不再发往 daemon，reason 仍是 stale_run。
  const adm = gateRpc(gate, "click");
  assert.equal(adm.send, false);
  assert.equal(adm.result.status, "cancelled");
  assert.equal(adm.result.reasonCode, "stale_run");
  assert.equal(adm.result.completedSteps, 1);
  // 本地拦下的结果带 local 标记，runActSteps 不会拿它去撞 daemon 计数。
  assert.equal(adm.result.local, true);
});

test("stale 状态的新 run 会清掉过期标记", () => {
  const gate = new CancelRun();
  gate.beginRun();
  gate.markStale();
  assert.equal(gate.cancelled, true);
  assert.equal(gate.stale, true);
  assert.equal(gate.stickyResult().reasonCode, "stale_run");

  const started = gate.beginRun();
  assert.equal(started.runId, 2);
  assert.equal(gate.cancelled, false);
  assert.equal(gate.stale, false);
  assert.equal(gate.stickyResult().reasonCode, "cancelled");
  assert.equal(gateRpc(gate, "click").send, true);
});

test("CancelledError 携带 status / reasonCode / completedSteps", () => {
  const gate = new CancelRun();
  gate.beginRun();
  gate.noteStepCompleted();
  const plain = new CancelledError({ completedSteps: gate.completedSteps });
  assert.equal(plain.name, "CancelledError");
  assert.equal(plain.status, "cancelled");
  assert.equal(plain.ok, false);
  assert.equal(plain.reasonCode, "cancelled");
  assert.equal(plain.completedSteps, 1);
  assert.ok(plain instanceof Error);

  const stale = new CancelledError({ reasonCode: "stale_run", completedSteps: 2 });
  assert.equal(stale.status, "cancelled");
  assert.equal(stale.reasonCode, "stale_run");
  assert.equal(stale.completedSteps, 2);
});
