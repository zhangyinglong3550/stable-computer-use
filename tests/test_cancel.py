#!/usr/bin/env python3
"""取消粘性与 completedSteps 的纯逻辑测试。不碰 daemon / AX。

    python3 tests/test_cancel.py
"""

from __future__ import annotations

import json
import subprocess
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load(name: str, path: Path):
    loader = SourceFileLoader(name, str(path))
    spec = spec_from_loader(name, loader)
    mod = module_from_spec(spec)
    loader.exec_module(mod)
    return mod


stats = load("scu_trace_stats_cancel", ROOT / "bench" / "trace_stats.py")


class TestCancelSticky(unittest.TestCase):
    def test_between_steps_recovery_and_reads(self):
        script = r"""
import {
  CancelRun, gateRpc, isWriteCmd, runActSteps,
} from "./cli/jsapi.mjs";

const gate = new CancelRun();
const started = gate.beginRun();
if (started.completedSteps !== 0 || started.runId !== 1 || gate.cancelled) {
  throw new Error("beginRun should clear, got " + JSON.stringify(started));
}

const calls = [];
const mid = await runActSteps(
  [{ op: "click" }, { op: "type" }, { op: "key" }, { op: "scroll" }],
  gate,
  {
    exec(step) {
      calls.push(step.op);
      return { ok: true, via: "ax" };
    },
    // 第 2 步（index 1）完成后置位，第 3 步不得执行。
    onAfter(i, _step, _result, g) {
      if (i === 1) g.cancel();
    },
  },
);

if (calls.join(",") !== "click,type") {
  throw new Error("step 3 ran: " + calls.join(","));
}
if (mid.ok !== false || mid.status !== "cancelled" || mid.cancelled !== true) {
  throw new Error("cancel shape " + JSON.stringify(mid));
}
if (mid.completedSteps !== 2) throw new Error("completedSteps " + mid.completedSteps);
if (mid.failedAt !== 2) throw new Error("failedAt " + mid.failedAt);
if (!Array.isArray(mid.steps) || mid.steps.length !== 4) {
  throw new Error("steps missing");
}
if (mid.steps[0].ok !== true || mid.steps[0].index !== 0 || mid.steps[0].op !== "click") {
  throw new Error("step0 " + JSON.stringify(mid.steps[0]));
}
if (mid.steps[1].ok !== true || mid.steps[1].op !== "type") {
  throw new Error("step1 " + JSON.stringify(mid.steps[1]));
}
if (mid.steps[2].reasonCode !== "cancelled" || mid.steps[2].ok !== false || mid.steps[2].op !== "key") {
  throw new Error("step2 " + JSON.stringify(mid.steps[2]));
}
if (mid.steps[3].reasonCode !== "cancelled" || mid.steps[3].op !== "scroll") {
  throw new Error("step3 " + JSON.stringify(mid.steps[3]));
}
if (mid.traceSteps.map((t) => t.step).join(",") !== "0,1") {
  throw new Error("cancelled step leaked into trace " + JSON.stringify(mid.traceSteps));
}

// 只读不拦。state 走 snapshot，本来就不是写命令。
for (const cmd of ["snapshot", "state", "ping", "signature"]) {
  const adm = gateRpc(gate, cmd);
  if (!adm.send) throw new Error(cmd + " was blocked");
  if (isWriteCmd(cmd)) throw new Error(cmd + " must not be a write");
}
if (gate.completedSteps !== 2) throw new Error("read changed completedSteps");
for (const cmd of ["click", "type", "key", "set", "scroll", "actAndWait", "paste", "act"]) {
  const adm = gateRpc(gate, cmd);
  if (adm.send) throw new Error(cmd + " still sent after cancel");
  if (adm.result.status !== "cancelled" || adm.result.completedSteps !== 2 || adm.result.ok !== false) {
    throw new Error(cmd + " sticky " + JSON.stringify(adm.result));
  }
}

// begin_run 之后写操作恢复，计数归零。
const againId = gate.beginRun();
if (againId.runId !== 2 || gate.cancelled || gate.completedSteps !== 0) {
  throw new Error("beginRun did not recover");
}
const againCalls = [];
const again = await runActSteps([{ op: "click" }], gate, {
  exec(step) {
    againCalls.push(step.op);
    return { ok: true };
  },
});
if (againCalls.join(",") !== "click" || again.ok !== true) {
  throw new Error("did not recover " + JSON.stringify(again));
}
if ("cancelled" in again || "completedSteps" in again || "status" in again) {
  throw new Error("success shape changed " + JSON.stringify(again));
}
if (gate.completedSteps !== 1) throw new Error("recovered count " + gate.completedSteps);
if (!gateRpc(gate, "type").send) throw new Error("type still blocked after beginRun");

// indexBase 续号：上一段完成 1 步后取消，下一段的 step 从 completedSteps 接着数。
gate.cancel();
const cont = await runActSteps([{ op: "type" }, { op: "key" }], gate, {
  indexBase: gate.completedSteps,
  exec() { throw new Error("continued act should not execute"); },
});
if (cont.completedSteps !== 1) throw new Error("cont count " + cont.completedSteps);
if (cont.steps[0].index !== 1 || cont.steps[0].reasonCode !== "cancelled") {
  throw new Error("indexBase " + JSON.stringify(cont.steps));
}
if (cont.steps[1].index !== 2 || cont.steps[1].reasonCode !== "cancelled") {
  throw new Error("indexBase tail " + JSON.stringify(cont.steps[1]));
}
if (cont.traceSteps.length !== 0) throw new Error("cont leaked trace");
if (cont.failedAt !== 0) throw new Error("cont failedAt " + cont.failedAt);

// 两段都成功时，第二段 indexBase = 第一段完成数，trace step 对得上。
const lined = new CancelRun();
lined.beginRun();
const first = await runActSteps([{ op: "click" }, { op: "expect" }], lined, {
  exec() { return { ok: true }; },
});
if (lined.completedSteps !== 2 || first.traceSteps.map((t) => t.step).join(",") !== "0,1") {
  throw new Error("first segment " + lined.completedSteps);
}
const second = await runActSteps([{ op: "type" }], lined, {
  indexBase: lined.completedSteps,
  exec(step, _i, g) {
    g.noteWriteOk();
    return { ok: true };
  },
});
if (second.ok !== true || second.steps[0].index !== 2) {
  throw new Error("second segment index " + JSON.stringify(second.steps));
}
if (lined.completedSteps !== 3) throw new Error("lined count " + lined.completedSteps);
if (second.traceSteps[0].step !== 2) throw new Error("trace step " + JSON.stringify(second.traceSteps));

// 等待阶段取消：第 2 步已经投递，计入 completedSteps，但不出 trace。
const waitGate = new CancelRun();
waitGate.beginRun();
const waitedCalls = [];
const waited = await runActSteps([{ op: "click" }, { op: "type" }, { op: "key" }], waitGate, {
  exec(step, i, g) {
    waitedCalls.push(i);
    if (i === 0) {
      g.noteWriteOk();
      return { ok: true, via: "ax", changed: true };
    }
    // daemon 写计数从 1 变成 2，表示这次投递已经发生。
    return { ok: false, status: "cancelled", completedSteps: 2, via: "pid" };
  },
});
if (waitedCalls.join(",") !== "0,1") throw new Error("wait calls " + waitedCalls.join(","));
if (waited.completedSteps !== 2) throw new Error("wait count " + waited.completedSteps);
if (waited.steps[1].reasonCode !== "cancelled" || waited.steps[1].ok !== false) {
  throw new Error("wait step " + JSON.stringify(waited.steps[1]));
}
if (waited.steps[2].reasonCode !== "cancelled") throw new Error("tail not cancelled");
if (waited.traceSteps.length !== 1 || waited.traceSteps[0].step !== 0 || waited.traceSteps[0].action !== "click") {
  throw new Error("wait trace " + JSON.stringify(waited.traceSteps));
}
// 同一个 daemon 计数再观察一次，不能把步数加上两次。
const againObs = waitGate.observeDaemonCancel(2);
if (againObs.delivered !== false || waitGate.completedSteps !== 2) {
  throw new Error("observe double counted " + waitGate.completedSteps);
}

// 找目标之前就被拒：daemon 计数没涨，这一步不计入。
const early = new CancelRun();
early.beginRun();
early.noteWriteOk();
early.noteStepCompleted();
const denied = await runActSteps([{ op: "set" }], early, {
  exec() { return { ok: false, status: "cancelled", completedSteps: 1 }; },
});
if (denied.completedSteps !== 1) throw new Error("early count " + denied.completedSteps);
if (denied.traceSteps.length !== 0) throw new Error("early trace");
if (denied.steps[0].reasonCode !== "cancelled") throw new Error("early reason");

console.log("ok");
"""
        proc = subprocess.run(
            ["node", "--input-type=module", "-e", script],
            cwd=ROOT, capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("ok", proc.stdout)

    def test_omitted_cancelled_step_is_not_a_timeout(self):
        """被取消的步没有 trace 行，汇总不能把它算进 timeout 分母。"""
        events = [
            {"step": 0, "action": "click", "total_ms": 10, "wait_exit": "changed",
             "resolve_ms": 1, "deliver_ms": 1, "wait_ms": 1, "verify_ms": 0},
            {"step": 1, "action": "type", "total_ms": 12, "wait_exit": "changed",
             "resolve_ms": 1, "deliver_ms": 1, "wait_ms": 1, "verify_ms": 0},
        ]
        report = stats.summarize_runs(
            [{"ok": False, "elapsed_ms": 30, "wall_ms": 40, "events": events}],
            expected=5,
        )
        self.assertEqual([s["step"] for s in report["steps"]], [0, 1])
        self.assertTrue(all(row["step"] != 2 for row in report["timeouts"]))
        self.assertTrue(all(row["hits"] == 0 for row in report["timeouts"]))
        # 行里也不该出现 cancelled 标记；缺席就是缺席。
        blob = json.dumps(events)
        self.assertNotIn("cancelled", blob)


if __name__ == "__main__":
    unittest.main(verbosity=2)
