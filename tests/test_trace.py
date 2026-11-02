#!/usr/bin/env python3
"""SCU_TRACE 与微信基线汇总的单元测试。不碰 AX。

    python3 tests/test_trace.py
"""

from __future__ import annotations

import contextlib
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import io
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCU = ROOT / "cli" / "scu"


def load(name: str, path: Path):
    loader = SourceFileLoader(name, str(path))
    spec = spec_from_loader(name, loader)
    mod = module_from_spec(spec)
    loader.exec_module(mod)
    return mod


scu = load("scu_for_trace", SCU)
stats = load("scu_trace_stats", ROOT / "bench" / "trace_stats.py")
bench = load("scu_bench_run", ROOT / "bench" / "run.py")


def _step(step, action, total, wait_exit=None):
    ev = {"step": step, "action": action, "tier": "ax", "total_ms": total,
          "resolve_ms": 1, "deliver_ms": 1, "wait_ms": 1, "verify_ms": 0, "snapshots": 1}
    if wait_exit is not None:
        ev["wait_exit"] = wait_exit
    return ev


def _run(ok, elapsed, wall, events):
    return {"ok": ok, "elapsed_ms": elapsed, "wall_ms": wall, "events": events}


def five_run_fixture():
    """成功 3 次。第 2 轮 click 失败（无 wait_exit），第 4 轮最后一个 expect 超时。"""
    def full(click, expect_a, type_ms, key, expect_b, expect_b_exit="changed"):
        return [
            _step(0, "click", click, "changed"),
            _step(1, "expect", expect_a, "changed"),
            _step(2, "type", type_ms, "changed"),
            _step(3, "key", key, "changed"),
            _step(4, "expect", expect_b, expect_b_exit),
        ]

    return [
        _run(True, 100, 110, full(10, 11, 12, 13, 14)),
        _run(False, 200, 210, [_step(0, "click", 50)]),  # text_not_found：没有 wait_exit
        _run(True, 300, 310, full(30, 31, 32, 33, 34)),
        _run(False, 400, 410, full(40, 41, 42, 43, 44, "timeout")),
        _run(True, 500, 510, full(20, 21, 22, 23, 24)),
    ]


class TestParseTrace(unittest.TestCase):
    def test_skips_non_json_and_non_trace(self):
        text = "\n".join([
            "skipped-offscreen: 12",
            "",
            '{"step": 0, "action": "click", "total_ms": 1}',
            "not json {{{",
            '{"ok": true, "walkMs": 2}',
            '{"step": 1, "action": "expect", "wait_exit": "timeout", "total_ms": 8}',
        ])
        events = stats.parse_trace_lines(text)
        self.assertEqual(len(events), 2)
        self.assertEqual(events[0]["action"], "click")
        self.assertEqual(events[1]["wait_exit"], "timeout")
        self.assertEqual(events[1]["total_ms"], 8)


class TestPeelTrace(unittest.TestCase):
    def setUp(self):
        self._old = os.environ.get("SCU_TRACE")
        os.environ.pop("SCU_TRACE", None)
        scu._trace_seq = 0

    def tearDown(self):
        if self._old is None:
            os.environ.pop("SCU_TRACE", None)
        else:
            os.environ["SCU_TRACE"] = self._old
        scu._trace_seq = 0

    def _sample(self):
        return {
            "ok": True,
            "walkMs": 11,
            "actMs": 4,
            "waitedMs": 9,
            "trace": [{
                "action": "click",
                "tier": "ax",
                "resolve_ms": 3,
                "deliver_ms": 1,
                "wait_ms": 9,
                "verify_ms": 0,
                "total_ms": 13,
                "wait_exit": "changed",
                "snapshots": 4,
            }],
        }

    def test_unset_drops_trace_and_keeps_the_rest(self):
        got = scu.peel_trace(self._sample())
        self.assertEqual(got, {"ok": True, "walkMs": 11, "actMs": 4, "waitedMs": 9})
        self.assertNotIn("trace", got)

    def test_unset_out_stdout_has_no_trace(self):
        out_buf, err_buf = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out_buf), contextlib.redirect_stderr(err_buf):
            scu.out(self._sample())
        body = json.loads(out_buf.getvalue())
        self.assertNotIn("trace", body)
        self.assertEqual(body["walkMs"], 11)
        self.assertEqual(body["actMs"], 4)
        self.assertEqual(body["waitedMs"], 9)
        self.assertEqual(body["ok"], True)
        self.assertEqual(err_buf.getvalue(), "")

    def test_set_strips_stdout_and_writes_stderr_line(self):
        os.environ["SCU_TRACE"] = "1"
        out_buf, err_buf = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out_buf), contextlib.redirect_stderr(err_buf):
            scu.out(self._sample())
        body = json.loads(out_buf.getvalue())
        self.assertNotIn("trace", body)
        self.assertEqual(body["walkMs"], 11)
        self.assertEqual(body["actMs"], 4)
        self.assertEqual(body["waitedMs"], 9)
        line = json.loads(err_buf.getvalue().strip())
        self.assertEqual(line["action"], "click")
        self.assertEqual(line["step"], 0)
        self.assertEqual(line["snapshots"], 4)
        self.assertEqual(line["wait_exit"], "changed")
        self.assertEqual(line["resolve_ms"], 3)

    def test_second_peel_does_not_emit_again(self):
        os.environ["SCU_TRACE"] = "1"
        err_buf = io.StringIO()
        with contextlib.redirect_stderr(err_buf):
            once = scu.peel_trace(self._sample())
            twice = scu.peel_trace(once)
        self.assertEqual(once, twice)
        self.assertEqual(err_buf.getvalue().count("\n"), 1)


class TestSummarize(unittest.TestCase):
    def test_five_runs_alignment_and_timeout_denominator(self):
        report = stats.summarize_runs(five_run_fixture(), expected=5)
        self.assertEqual(report["successes"], 3)
        self.assertEqual(report["success_rate"], 0.6)
        self.assertNotIn("p95", report)
        self.assertNotIn("p95", report["elapsed_ms"])
        self.assertEqual(report["elapsed_ms"], {"min": 100, "median": 300, "max": 500})
        self.assertEqual(report["wall_ms"], {"min": 110, "median": 310, "max": 510})

        labels = [(st["step"], st["action"], st["label"]) for st in report["steps"]]
        self.assertEqual(labels, [
            (0, "click", "5/5"),
            (1, "expect", "4/5"),
            (2, "type", "4/5"),
            (3, "key", "4/5"),
            (4, "expect", "4/5"),
        ])
        expects = [st for st in report["steps"] if st["action"] == "expect"]
        self.assertEqual(len(expects), 2)
        self.assertEqual(expects[0]["step"], 1)
        self.assertEqual(expects[1]["step"], 4)

        click = report["steps"][0]
        self.assertEqual(click["median_ms"], 30)
        self.assertEqual(click["mean_ms"], 30)
        # 4 个数，中位数是中间两个的平均：(21+31)/2
        self.assertEqual(expects[0]["median_ms"], 26)
        self.assertEqual(expects[0]["mean_ms"], 26)

        by_step = {(row["step"], row["action"]): row for row in report["timeouts"]}
        self.assertEqual(by_step[(0, "click")]["hits"], 0)
        self.assertEqual(by_step[(0, "click")]["denom"], 4)
        self.assertEqual(by_step[(1, "expect")]["hits"], 0)
        self.assertEqual(by_step[(1, "expect")]["denom"], 4)
        self.assertEqual(by_step[(4, "expect")]["hits"], 1)
        self.assertEqual(by_step[(4, "expect")]["denom"], 4)

    def test_text_not_found_is_outside_timeout_denominator(self):
        runs = [{
            "ok": False,
            "elapsed_ms": 1,
            "wall_ms": 2,
            "events": [
                {"step": 0, "action": "click", "total_ms": 5},
                {"step": 1, "action": "expect", "total_ms": 9, "wait_exit": "timeout"},
            ],
        }]
        report = stats.summarize_runs(runs, expected=5)
        self.assertEqual(report["successes"], 0)
        self.assertEqual(report["success_rate"], 0.0)
        self.assertEqual(report["steps"][0]["label"], "1/5")
        names = [(row["step"], row["action"]) for row in report["timeouts"]]
        self.assertEqual(names, [(1, "expect")])
        self.assertEqual(report["timeouts"][0]["hits"], 1)
        self.assertEqual(report["timeouts"][0]["denom"], 1)


class TestWechatScenarioOptIn(unittest.TestCase):
    def test_default_parser_does_not_select_wechat(self):
        args = bench.build_parser().parse_args([])
        self.assertIsNone(args.scenario)
        args = bench.build_parser().parse_args(["--latency-only"])
        self.assertIsNone(args.scenario)
        self.assertTrue(args.latency_only)

    def test_wechat_is_explicit(self):
        args = bench.build_parser().parse_args(["--scenario", "wechat"])
        self.assertEqual(args.scenario, "wechat")
        with self.assertRaises(SystemExit):
            bench.build_parser().parse_args(["--scenario", "finder"])

    def test_script_uses_act_and_wechat_bundle(self):
        self.assertEqual(bench.WECHAT_RUNS, 5)
        self.assertIn("com.tencent.xinWeChat", bench.WECHAT_JS)
        self.assertNotIn("WeWorkMac", bench.WECHAT_JS)
        self.assertIn("app.act", bench.WECHAT_JS)
        self.assertIn('op: "expect"', bench.WECHAT_JS)
        src = Path(bench.__file__).read_text()
        self.assertIn("bad_args", src)
        self.assertIn("visibleOnly", src)


class TestJsPureFunctions(unittest.TestCase):
    def test_find_target_peel_and_compose(self):
        node = "node"
        script = r"""
import { findTargetMatch, peelTrace, composeStepTrace, fallbackFromActResult } from "./cli/jsapi.mjs";

const first = findTargetMatch([
  { ref: "a", label: "其他", actions: ["AXPress"], rect: { x: 0, y: 0, w: 10, h: 10 } },
  { ref: "b", label: "文件传输助手", actions: ["AXPress"], target_ref: "b2",
    rect: { x: 0, y: 0, w: 10, h: 10 } },
  { ref: "c", label: "文件传输助手", actions: [], rect: { x: 10, y: 20, w: 30, h: 40 } },
], "文件");
if (!first || first.ref !== "b2") throw new Error("first substring should use ref, got " + JSON.stringify(first));

const center = findTargetMatch([
  { ref: "c", label: "文件传输助手", actions: [], target_ref: "anc",
    rect: { x: 10, y: 20, w: 30, h: 40 } },
], "文件传输助手");
if (!center || center.x !== 25 || center.y !== 40) {
  throw new Error("rect center, got " + JSON.stringify(center));
}

const zero = findTargetMatch([
  { ref: "z", label: "你好", actions: [], target_ref: "anc", rect: { x: 1, y: 1, w: 0, h: 4 } },
], "你好");
if (!zero || zero.ref !== "anc") throw new Error("zero width falls back to ref");

const original = { ok: true, walkMs: 3, actMs: 2, waitedMs: 5, trace: [{ action: "click", resolve_ms: 4 }] };
const off = peelTrace(original, { enabled: false });
if ("trace" in off.payload) throw new Error("trace leaked while disabled");
if (off.lines.length) throw new Error("stderr lines while disabled");
if (off.payload.ok !== true || off.payload.walkMs !== 3 || off.payload.actMs !== 2 || off.payload.waitedMs !== 5) {
  throw new Error("payload changed");
}
if (!original.trace) throw new Error("peel mutated the input");

const on = peelTrace(original, { enabled: true });
if ("trace" in on.payload) throw new Error("trace leaked while enabled");
if (on.lines.length !== 1 || on.lines[0].resolve_ms !== 4) throw new Error("missing line");
if (on.payload.actMs !== 2 || on.payload.waitedMs !== 5) throw new Error("fields dropped");

const merged = composeStepTrace({
  step: 0,
  action: "click",
  daemonEvents: [{ tier: "pid", resolve_ms: 10, deliver_ms: 2, wait_ms: 8, verify_ms: 1, snapshots: 2, wait_exit: "changed" }],
  jsResolveMs: 7,
  jsSnapshots: 1,
  extraResolveMs: 5,
  extraSnapshots: 2,
  totalMs: 40,
});
if (merged.resolve_ms !== 22) throw new Error("resolve " + merged.resolve_ms);
if (merged.snapshots !== 5) throw new Error("snaps " + merged.snapshots);
if (merged.total_ms !== 45) throw new Error("total " + merged.total_ms);
if (merged.tier !== "pid" || merged.wait_exit !== "changed") throw new Error("tier/exit");
if (merged.deliver_ms !== 2 || merged.wait_ms !== 8 || merged.verify_ms !== 1) throw new Error("phases");

const missed = composeStepTrace({
  step: 0,
  action: "click",
  totalMs: 4,
  jsResolveMs: 4,
  jsSnapshots: 1,
  fallback: fallbackFromActResult({ ok: false, reasonCode: "cache_miss" }),
});
if ("wait_exit" in missed) throw new Error("cache_miss must not be a timeout");

const timedOut = composeStepTrace({
  step: 3,
  action: "key",
  totalMs: 20,
  fallback: fallbackFromActResult({ ok: true, changed: false, waitedMs: 800, actMs: 5, via: "pid" }),
});
if (timedOut.wait_exit !== "timeout") throw new Error("wait timeout");
if (timedOut.wait_ms !== 800 || timedOut.deliver_ms !== 5 || timedOut.tier !== "pid") {
  throw new Error("fallback " + JSON.stringify(timedOut));
}

console.log("ok");
"""
        proc = subprocess.run(
            [node, "--input-type=module", "-e", script],
            cwd=ROOT, capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("ok", proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
