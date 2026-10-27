#!/usr/bin/env python3
"""集成测试：真的去读 AX。

AX 不可用（没授权 / 锁屏 / 显示器休眠）时**整体跳过**，不报失败 ——
CI 或无权限环境下跑测试不应该红。

    python3 tests/test_integration.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCU = ROOT / "cli" / "scu"

# 按优先级找有真实窗口的 app
CANDIDATES = [
    "com.apple.finder",
    "com.google.Chrome",
    "com.apple.TextEdit",
    "com.apple.Safari",
    "com.apple.Preview",
]


def run(*argv: str, timeout: float = 30.0) -> tuple[dict, int]:
    proc = subprocess.run([sys.executable, str(SCU), *argv],
                          capture_output=True, text=True, timeout=timeout)
    try:
        return json.loads(proc.stdout.strip() or "{}"), proc.returncode
    except json.JSONDecodeError:
        return {"_raw": proc.stdout[:300], "_err": proc.stderr[:300]}, proc.returncode


def ax_available() -> bool:
    try:
        d, _ = run("doctor", timeout=20)
    except Exception:
        return False
    return bool(d.get("accessibilityUsable"))


def pick_app() -> str | None:
    d, _ = run("apps", timeout=30)
    live = {a["bundle"] for a in d.get("apps", []) if a.get("windows", 0) > 0}
    for c in CANDIDATES:
        if c in live:
            d2, code = run("snapshot", "--app", c, "--json", timeout=30)
            if code == 0 and d2.get("elements"):
                return c
    # 兜底：任何有窗口的 app
    for b in live:
        d2, code = run("snapshot", "--app", b, "--json", timeout=30)
        if code == 0 and d2.get("elements"):
            return b
    return None


AVAILABLE = ax_available()
APP = pick_app() if AVAILABLE else None


@unittest.skipUnless(AVAILABLE, "AX 不可用（未授权 / 锁屏 / 显示器休眠）")
class TestSnapshot(unittest.TestCase):
    def setUp(self):
        if not APP:
            self.skipTest("没有带窗口的 app 可用")

    def test_snapshot_shape(self):
        d, code = run("snapshot", "--app", APP, "--json")
        self.assertEqual(code, 0)
        self.assertTrue(d["elements"], "应该有元素")
        for e in d["elements"]:
            self.assertIn("ref", e)
            self.assertIn("role", e)
            self.assertRegex(e["ref"], r"^[0-9a-z]{6}(-\d+)?$")

    def test_refs_unique(self):
        d, _ = run("snapshot", "--app", APP, "--json")
        refs = [e["ref"] for e in d["elements"]]
        self.assertEqual(len(refs), len(set(refs)), "同一快照内 ref 必须唯一")

    def test_refs_stable_across_snapshots(self):
        a, _ = run("snapshot", "--app", APP, "--json")
        b, _ = run("snapshot", "--app", APP, "--json")
        refs_a = {e["ref"] for e in a["elements"]}
        refs_b = {e["ref"] for e in b["elements"]}
        if not refs_a or not refs_b:
            self.skipTest("快照为空")
        overlap = len(refs_a & refs_b) / max(len(refs_a), len(refs_b))
        self.assertGreater(overlap, 0.9,
                          f"两次快照 ref 重合率只有 {overlap:.0%}，稳定性有问题")

    def test_no_zero_width_in_labels(self):
        d, _ = run("snapshot", "--app", APP, "--json")
        bad = "\u200b\u200c\u200d\u200e\u200f\u2060\ufeff"
        for e in d["elements"]:
            for field in ("label", "value"):
                v = e.get(field) or ""
                self.assertFalse(any(c in v for c in bad),
                                 f"{e['ref']}.{field} 含零宽字符：{v[:40]!r}")

    def test_target_ref_resolves_to_actionable(self):
        d, _ = run("snapshot", "--app", APP, "--json")
        by_ref = {e["ref"]: e for e in d["elements"]}
        for e in d["elements"]:
            tr = e.get("target_ref")
            self.assertIn(tr, by_ref, f"target_ref {tr} 不在元素表里")


@unittest.skipUnless(AVAILABLE, "AX 不可用")
class TestVerify(unittest.TestCase):
    def setUp(self):
        if not APP:
            self.skipTest("没有带窗口的 app 可用")
        d, _ = run("snapshot", "--app", APP, "--json")
        self.elements = d.get("elements") or []

    def test_verify_existing_ref(self):
        if not self.elements:
            self.skipTest("空快照")
        ref = self.elements[0]["ref"]
        d, code = run("verify", "--app", APP, "--ref", ref)
        self.assertEqual(code, 0)
        self.assertTrue(d["ok"])

    def test_verify_bogus_ref(self):
        d, code = run("verify", "--app", APP, "--ref", "zzzzzz")
        self.assertEqual(code, 5)
        self.assertEqual(d["reasonCode"], "stale_ref")

    def test_act_with_bogus_ref_does_not_click(self):
        """act 走 stale_ref 分支时必须快速失败，且不产生任何真实输入。"""
        d, code = run("click", "--app", APP, "--ref", "zzzzzz")
        self.assertEqual(code, 5)
        self.assertEqual(d["reasonCode"], "stale_ref")


@unittest.skipUnless(AVAILABLE, "AX 不可用")
class TestDecide(unittest.TestCase):
    def setUp(self):
        if not APP:
            self.skipTest("没有带窗口的 app 可用")
        d, _ = run("snapshot", "--app", APP, "--json")
        self.elements = d.get("elements") or []
        self.state = tempfile.TemporaryDirectory()
        self.env = {**os.environ, "SCU_STATE": self.state.name}

    def tearDown(self):
        self.state.cleanup()

    def _decide(self, goal: str, *extra: str) -> dict:
        proc = subprocess.run(
            [sys.executable, str(SCU), "decide", "--app", APP, "--goal", goal, *extra],
            capture_output=True, text=True, env=self.env, timeout=40)
        return json.loads(proc.stdout.strip() or "{}")

    def test_exact_tier_on_quoted_label(self):
        labelled = [e for e in self.elements
                    if e.get("label") and len(e["label"]) <= 20
                    and (e.get("actions") or e.get("role") in ("AXButton",))]
        if not labelled:
            self.skipTest("没有带名字的按钮")
        target = labelled[0]
        d = self._decide(f'点击"{target["label"]}"')
        self.assertTrue(d["ok"])
        self.assertEqual(d["tier"], "exact")
        self.assertEqual(d["recommendedAction"], "act")

    def test_always_reports_tier_and_confidence(self):
        d = self._decide("随便一个说不清的目标 xyz")
        self.assertIn("tier", d)
        self.assertIn("confidence", d)
        self.assertIn(d["confidenceGate"], ("high", "medium", "low"))

    def test_handoff_carries_candidates_and_best_guess(self):
        d = self._decide("随便一个说不清的目标 xyz")
        if d.get("ok"):
            self.skipTest("这个目标意外命中了")
        self.assertTrue(d["candidates"], "降级必须带候选，不能只报失败")
        self.assertIn("bestGuess", d)

    def test_memory_roundtrip(self):
        if not self.elements:
            self.skipTest("空快照")
        # 挑一个带 label 的可点元素
        target = next((e for e in self.elements
                       if e.get("label") and (e.get("actions") or e.get("target_ref"))), None)
        if not target:
            self.skipTest("没有合适的元素")

        goal = "我自己编的一个目标 qwerty"
        proc = subprocess.run(
            [sys.executable, str(SCU), "remember", "--app", APP, "--goal", goal,
             "--ref", target["ref"]],
            capture_output=True, text=True, env=self.env, timeout=40)
        self.assertEqual(json.loads(proc.stdout)["ok"], True)

        d = self._decide(goal)
        self.assertTrue(d["ok"])
        self.assertEqual(d["tier"], "memory")
        self.assertEqual(d["memoryHit"], "ref")


@unittest.skipUnless(AVAILABLE, "AX 不可用")
class TestShot(unittest.TestCase):
    def setUp(self):
        if not APP:
            self.skipTest("没有带窗口的 app 可用")

    def test_shot_writes_file(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "shot.png"
            d, code = run("shot", "--app", APP, "--out", str(out))
            self.assertEqual(code, 0, d)
            self.assertTrue(out.is_file())
            self.assertGreater(out.stat().st_size, 1000)


class TestDoctorAlwaysRuns(unittest.TestCase):
    """不管有没有权限，doctor 都必须给出结构化结论而不是崩。"""

    def test_doctor_shape(self):
        d, _ = run("doctor", timeout=20)
        self.assertIn("accessibility", d)
        self.assertIn("accessibilityUsable", d)
        self.assertIn("ok", d)
        if not d["ok"]:
            self.assertIn("reasonCode", d)


if __name__ == "__main__":
    print(f"AX available: {AVAILABLE} | app: {APP}\n", file=sys.stderr)
    unittest.main(verbosity=2)
