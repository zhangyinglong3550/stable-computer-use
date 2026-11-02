#!/usr/bin/env python3
"""SCU_TRACE 行的解析、校验与汇总。不碰 AX。

    python3 tests/test_trace.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRACE = ROOT / "bench" / "scu_trace.py"
RUN = ROOT / "bench" / "run.py"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


trace = load("scu_trace", TRACE)
bench = load("scu_bench_run", RUN)


def line(**overrides) -> str:
    row = {
        "step": 1,
        "action": "click",
        "tier": "ax",
        "resolve_ms": 10,
        "deliver_ms": 2,
        "wait_ms": 30,
        "verify_ms": 4,
        "total_ms": 50,
        "wait_exit": "changed",
    }
    row.update(overrides)
    return json.dumps(row, ensure_ascii=False)


class TestParseValid(unittest.TestCase):
    def test_parses_one_step(self):
        got = trace.parse_trace(line() + "\n")
        self.assertEqual(got["invalid_count"], 0)
        self.assertEqual(len(got["steps"]), 1)
        step = got["steps"][0]
        self.assertEqual(step["step"], 1)
        self.assertEqual(step["action"], "click")
        self.assertEqual(step["tier"], "ax")
        self.assertEqual(step["wait_exit"], "changed")
        self.assertEqual(step["resolve_ms"], 10.0)
        self.assertEqual(step["deliver_ms"], 2.0)
        self.assertEqual(step["wait_ms"], 30.0)
        self.assertEqual(step["verify_ms"], 4.0)
        self.assertEqual(step["total_ms"], 50.0)

    def test_accepts_ax_pid_mouse_and_unicode_action(self):
        text = "\n".join(
            line(step=i, tier=tier, action="点击")
            for i, tier in enumerate(("ax", "pid", "mouse"), start=1)
        )
        got = trace.parse_trace(text)
        self.assertEqual([s["tier"] for s in got["steps"]], ["ax", "pid", "mouse"])
        self.assertEqual(got["steps"][0]["action"], "点击")
        self.assertEqual(got["invalid_count"], 0)


class TestInvalidLines(unittest.TestCase):
    def test_missing_field_is_skipped_and_counted(self):
        raw = json.dumps({"step": 1, "action": "click", "tier": "ax"})
        got = trace.parse_trace(line(step=2) + "\n" + raw + "\n" + line(step=3))
        self.assertEqual(got["invalid_count"], 1)
        self.assertEqual([s["step"] for s in got["steps"]], [2, 3])
        self.assertEqual(got["invalid"][0]["reason"], "missing")

    def test_bad_json_is_skipped_and_counted(self):
        got = trace.parse_trace("not-json\n" + line())
        self.assertEqual(got["invalid_count"], 1)
        self.assertEqual(len(got["steps"]), 1)
        self.assertEqual(got["invalid"][0]["reason"], "json")

    def test_non_object_json_is_skipped(self):
        got = trace.parse_trace("[1, 2]\n" + line())
        self.assertEqual(got["invalid_count"], 1)
        self.assertEqual(got["invalid"][0]["reason"], "type")
        self.assertEqual(len(got["steps"]), 1)

    def test_illegal_tier_is_skipped(self):
        got = trace.parse_trace(line(tier="keyboard") + "\n")
        self.assertEqual(got["invalid_count"], 1)
        self.assertEqual(got["steps"], [])
        self.assertEqual(got["invalid"][0]["reason"], "tier")

    def test_illegal_wait_exit_is_skipped(self):
        got = trace.parse_trace(line(wait_exit="error") + "\n")
        self.assertEqual(got["invalid_count"], 1)
        self.assertEqual(got["steps"], [])
        self.assertEqual(got["invalid"][0]["reason"], "wait_exit")

    def test_enum_is_case_sensitive(self):
        got = trace.parse_trace(line(tier="AX", wait_exit="Changed"))
        self.assertEqual(got["invalid_count"], 1)
        self.assertEqual(got["steps"], [])
        self.assertEqual(got["invalid"][0]["reason"], "tier")

    def test_negative_ms_is_invalid(self):
        got = trace.parse_trace(line(wait_ms=-1))
        self.assertEqual(got["invalid_count"], 1)
        self.assertEqual(got["steps"], [])
        self.assertEqual(got["invalid"][0]["reason"], "ms")

    def test_blank_lines_are_ignored(self):
        got = trace.parse_trace("\n\n" + line() + "\n\n")
        self.assertEqual(got["invalid_count"], 0)
        self.assertEqual(len(got["steps"]), 1)


class TestSummarize(unittest.TestCase):
    def test_normal_segments_total_and_ratios(self):
        text = "\n".join([
            line(step=1, resolve_ms=10, deliver_ms=20, wait_ms=30, verify_ms=40,
                 total_ms=100, wait_exit="changed"),
            line(step=2, action="type", tier="pid", resolve_ms=1, deliver_ms=2,
                 wait_ms=3, verify_ms=4, total_ms=20, wait_exit="timeout"),
        ])
        got = trace.summarize_trace(text)
        self.assertEqual(got["step_count"], 2)
        self.assertEqual(got["invalid_count"], 0)
        self.assertEqual(got["total_ms"], 120.0)
        self.assertEqual(got["segments_ms"]["resolve_ms"], 11.0)
        self.assertEqual(got["segments_ms"]["deliver_ms"], 22.0)
        self.assertEqual(got["segments_ms"]["wait_ms"], 33.0)
        self.assertEqual(got["segments_ms"]["verify_ms"], 44.0)
        self.assertAlmostEqual(got["segment_ratios"]["resolve_ms"], 11 / 120)
        self.assertAlmostEqual(got["segment_ratios"]["deliver_ms"], 22 / 120)
        self.assertAlmostEqual(got["segment_ratios"]["wait_ms"], 33 / 120)
        self.assertAlmostEqual(got["segment_ratios"]["verify_ms"], 44 / 120)
        self.assertEqual(got["timeout_steps"], 1)
        self.assertAlmostEqual(got["timeout_ratio"], 0.5)
        self.assertEqual(got["steps"][0]["resolve_ms"], 10.0)
        self.assertEqual(got["steps"][1]["action"], "type")
        self.assertEqual(got["steps"][1]["wait_ms"], 3.0)
        self.assertEqual(got["steps"][1]["wait_exit"], "timeout")

    def test_all_timeout(self):
        text = "\n".join([
            line(step=1, wait_exit="timeout", total_ms=10),
            line(step=2, wait_exit="timeout", total_ms=30, tier="mouse"),
        ])
        got = trace.summarize_trace(text)
        self.assertEqual(got["timeout_steps"], 2)
        self.assertEqual(got["timeout_ratio"], 1.0)
        self.assertEqual(got["total_ms"], 40.0)
        self.assertEqual(got["step_count"], 2)

    def test_empty_input(self):
        got = trace.summarize_trace("")
        self.assertEqual(got["steps"], [])
        self.assertEqual(got["invalid_count"], 0)
        self.assertEqual(got["step_count"], 0)
        self.assertEqual(got["total_ms"], 0.0)
        self.assertEqual(got["timeout_steps"], 0)
        self.assertEqual(got["timeout_ratio"], 0.0)
        for key in ("resolve_ms", "deliver_ms", "wait_ms", "verify_ms"):
            self.assertEqual(got["segments_ms"][key], 0.0)
            self.assertEqual(got["segment_ratios"][key], 0.0)

    def test_whitespace_only_is_empty(self):
        got = trace.summarize_trace("\n  \n\t\n")
        self.assertEqual(got["step_count"], 0)
        self.assertEqual(got["invalid_count"], 0)
        self.assertEqual(got["total_ms"], 0.0)

    def test_only_invalid_lines(self):
        got = trace.summarize_trace("{}\nnope\n")
        self.assertEqual(got["step_count"], 0)
        self.assertEqual(got["invalid_count"], 2)
        self.assertEqual(got["total_ms"], 0.0)
        self.assertEqual(got["timeout_ratio"], 0.0)

    def test_zero_total_ratios_are_zero(self):
        got = trace.summarize_trace(
            line(resolve_ms=5, deliver_ms=0, wait_ms=0, verify_ms=0, total_ms=0))
        self.assertEqual(got["segments_ms"]["resolve_ms"], 5.0)
        self.assertEqual(got["segment_ratios"]["resolve_ms"], 0.0)
        self.assertEqual(got["total_ms"], 0.0)


class TestMultiRun(unittest.TestCase):
    def test_mean_max_min_and_success_rate(self):
        fast = line(step=1, resolve_ms=1, deliver_ms=1, wait_ms=1, verify_ms=1,
                    total_ms=10, wait_exit="changed")
        slow = "\n".join([
            line(step=1, resolve_ms=5, deliver_ms=5, wait_ms=80, verify_ms=10,
                 total_ms=100, wait_exit="timeout"),
            line(step=2, resolve_ms=0, deliver_ms=0, wait_ms=0, verify_ms=0,
                 total_ms=50, wait_exit="changed"),
        ])
        mid = line(step=1, resolve_ms=4, deliver_ms=4, wait_ms=4, verify_ms=4,
                   total_ms=40, wait_exit="changed")
        got = trace.summarize_runs([fast, slow, mid])
        self.assertEqual(got["run_count"], 3)
        self.assertEqual(got["total_ms"]["min"], 10.0)
        self.assertEqual(got["total_ms"]["max"], 150.0)
        self.assertAlmostEqual(got["total_ms"]["mean"], (10 + 150 + 40) / 3)
        self.assertEqual(got["segments_ms"]["wait_ms"]["min"], 1.0)
        self.assertEqual(got["segments_ms"]["wait_ms"]["max"], 80.0)
        self.assertAlmostEqual(got["segments_ms"]["wait_ms"]["mean"], (1 + 80 + 4) / 3)
        self.assertEqual(got["segments_ms"]["resolve_ms"]["min"], 1.0)
        self.assertEqual(got["segments_ms"]["resolve_ms"]["max"], 5.0)
        self.assertEqual(got["successes"], 2)
        self.assertAlmostEqual(got["success_rate"], 2 / 3)
        self.assertEqual(len(got["runs"]), 3)
        self.assertEqual(got["runs"][1]["timeout_ratio"], 0.5)
        self.assertEqual(got["runs"][0]["total_ms"], 10.0)

    def test_all_timeout_run_success_rate_zero(self):
        text = line(wait_exit="timeout", total_ms=5)
        got = trace.summarize_runs([text, text])
        self.assertEqual(got["success_rate"], 0.0)
        self.assertEqual(got["successes"], 0)
        self.assertEqual(got["runs"][0]["timeout_ratio"], 1.0)

    def test_empty_runs(self):
        got = trace.summarize_runs([])
        self.assertEqual(got["run_count"], 0)
        self.assertEqual(got["runs"], [])
        self.assertIsNone(got["success_rate"])
        self.assertEqual(got["successes"], 0)
        self.assertIsNone(got["total_ms"]["mean"])
        self.assertIsNone(got["total_ms"]["max"])
        self.assertIsNone(got["total_ms"]["min"])
        for key in ("resolve_ms", "deliver_ms", "wait_ms", "verify_ms"):
            self.assertIsNone(got["segments_ms"][key]["mean"])

    def test_empty_string_run_is_not_success(self):
        got = trace.summarize_runs([""])
        self.assertEqual(got["run_count"], 1)
        self.assertEqual(got["success_rate"], 0.0)
        self.assertEqual(got["successes"], 0)
        self.assertEqual(got["runs"][0]["step_count"], 0)

    def test_invalid_lines_do_not_by_themselves_fail_the_run(self):
        text = line(wait_exit="changed", total_ms=8) + "\nnot-json\n"
        got = trace.summarize_runs([text])
        self.assertEqual(got["runs"][0]["invalid_count"], 1)
        self.assertEqual(got["success_rate"], 1.0)


class TestBenchHook(unittest.TestCase):
    def test_summarize_trace_files(self):
        text = line(total_ms=10, wait_exit="changed") + "\n"
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "run1.jsonl"
            p.write_text(text, encoding="utf-8")
            got = bench.summarize_trace_files([str(p)])
        self.assertEqual(got["run_count"], 1)
        self.assertEqual(got["success_rate"], 1.0)
        self.assertEqual(got["total_ms"]["max"], 10.0)

    def test_cli_trace_file_prints_json_without_running_bench(self):
        text = line(total_ms=7, wait_exit="timeout") + "\n"
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "t.jsonl"
            p.write_text(text, encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, str(RUN), "--trace-file", str(p)],
                capture_output=True,
                text=True,
                env={**os.environ, "SCU_AX_BIN": "/nonexistent/scu-ax"},
            )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertEqual(data["run_count"], 1)
        self.assertEqual(data["success_rate"], 0.0)
        self.assertEqual(data["total_ms"]["mean"], 7.0)
        self.assertNotIn("快照延迟", proc.stdout)
        self.assertNotIn("端到端准确率", proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
