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

    def test_coordinate_contract(self):
        """坐标只有一种话：snapshot 的矩形是屏幕坐标，且必须显式声明。"""
        d, _ = run("snapshot", "--app", APP, "--json")
        self.assertEqual(d.get("coordinateSpace"), "screen")
        self.assertIn("windowRect", d, "窗口矩形是动作坐标的基准，不能缺")
        self.assertIn("windowOrigin", d)
        wr = d["windowRect"]
        self.assertEqual(wr["x"], d["windowOrigin"]["x"])
        for e in d["elements"]:
            r = e.get("rect")
            if r:
                # 元素的坐标必须在屏幕空间里，能直接喂给 --xy
                self.assertIsInstance(r["x"], (int, float))
                self.assertIsInstance(r["y"], (int, float))

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
class TestNonIntrusive(unittest.TestCase):
    """核心契约：默认不激活目标 app、不移动鼠标、不抢焦点。"""

    def setUp(self):
        if not APP:
            self.skipTest("没有带窗口的 app 可用")

    def _mouse(self) -> tuple:
        out = subprocess.run(
            ["swift", "-e", "import Cocoa; print(\(NSEvent.mouseLocation.x)),\(NSEvent.mouseLocation.y))"],
            capture_output=True, text=True, timeout=120)
        try:
            return tuple(round(float(v), 1) for v in out.stdout.strip().split(","))
        except Exception:
            self.skipTest("拿不到鼠标位置")

    def test_hit_test_click_does_not_move_mouse(self):
        d, _ = run("snapshot", "--app", APP, "--json")
        els = d.get("elements") or []
        if not els or not els[0].get("rect"):
            self.skipTest("拿不到窗口几何")
        r = els[0]["rect"]
        # 窗口顶部 12px：几乎不可能有可执行元素，正好用来验证"失败但不打扰"
        xy = f"{int(r['x'] + r['w'] / 2)},{int(r['y'] + 12)}"
        before = self._mouse()
        run("click", "--app", APP, "--xy", xy)
        after = self._mouse()
        self.assertEqual(before, after, "命中测试点击不应该移动鼠标")

    def test_never_falls_back_to_context_menu(self):
        """回归：祖先回退绝不能选 AXShowMenu —— 那会弹出右键菜单。"""
        src = (ROOT / "runtime" / "Sources" / "scu-ax" / "main.swift").read_text(encoding="utf-8")
        # 找 preferred 那行，确认不含 AXShowMenu
        for line in src.splitlines():
            if "let preferred = [" in line:
                self.assertNotIn("AXShowMenu", line,
                                 "pressable 的动作回退列表里不能有 AXShowMenu")
                break
        else:
            self.fail("没找到 preferred 定义")

    def test_takeover_requires_explicit_opt_in(self):
        """不显式 --take-over 时，抢焦点的路径必须拒绝。"""
        d, code = run("click", "--app", APP, "--xy", "10,10", "--via", "mouse")
        self.assertEqual(code, 11)
        self.assertEqual(d["reasonCode"], "needs_takeover")

    def test_key_without_menu_item_uses_pid_route(self):
        """不是菜单项的组合键：默认定向投递（不抢焦点），且如实标 unverified。"""
        d, code = run("key", "--app", APP, "--key", "super+alt+shift+z")
        self.assertEqual(code, 0, d)
        self.assertEqual(d.get("via"), "pid")
        self.assertEqual(d["verification"]["state"], "unverified")
        self.assertEqual(d["verification"]["reason"], "synthetic_input")

    def test_key_global_route_still_requires_takeover(self):
        """要真键盘（系统事件流）时，仍然必须显式接管。"""
        d, code = run("key", "--app", APP, "--key", "super+alt+shift+z", "--via", "mouse")
        self.assertEqual(code, 11)
        self.assertEqual(d["reasonCode"], "needs_takeover")

    def test_user_active_blocks_takeover(self):
        """用户刚操作过就拒绝接管，且给出可读原因。"""
        d, code = run("click", "--app", APP, "--xy", "10,10", "--via", "mouse",
                      "--take-over", "--idle-seconds", "9999")
        # 要么因为用户活跃被挡（12），要么已经空闲到离谱则走到别处；前者才是常态
        self.assertIn(code, (12, 13, 14))
        if code == 12:
            self.assertEqual(d["reasonCode"], "user_active")
            self.assertIn("idleSeconds", d)


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
            # 图像像素 → 动作坐标的换算必须由工具给出，别让调用方猜
            self.assertIn("scale", d)
            self.assertIn("actionFormula", d)
            self.assertEqual(d.get("coordinateSpace"), "screen")


class TestDoctorAlwaysRuns(unittest.TestCase):
    """不管有没有权限，doctor 都必须给出结构化结论而不是崩。"""

    def test_doctor_shape(self):
        d, _ = run("doctor", timeout=20)
        self.assertIn("accessibility", d)
        self.assertIn("accessibilityUsable", d)
        self.assertIn("ok", d)
        if not d["ok"]:
            self.assertIn("reasonCode", d)


@unittest.skipUnless(AVAILABLE, "AX 不可用")
class TestCodeMode(unittest.TestCase):
    """code mode：一段代码跑完整串动作，这是最快的用法。"""

    def setUp(self):
        if not APP:
            self.skipTest("没有带窗口的 app 可用")

    def _js(self, code: str) -> tuple[str, str, int]:
        proc = subprocess.run(
            [sys.executable, str(SCU), "js", "-e", code],
            capture_output=True, text=True, timeout=90)
        return proc.stdout, proc.stderr, proc.returncode

    def test_state_returns_text(self):
        out, err, code = self._js(
            f'const a = await scu.getApp("{APP}"); console.log(await a.state());')
        self.assertEqual(code, 0, err)
        self.assertIn("[", out, "state() 应该返回带 ref 的文本树")

    def test_multiple_reads_in_one_process(self):
        out, err, code = self._js(
            f'const a = await scu.getApp("{APP}");\n'
            'for (let i=0;i<5;i++) await a.state();\n'
            'console.log("rpc=" + scu.rpcCount);')
        self.assertEqual(code, 0, err)
        # 1 次 getApp + 5 次 state
        self.assertIn("rpc=6", out)

    def test_unknown_app_raises(self):
        out, err, code = self._js(
            'await scu.getApp("definitely.not.installed.app")')
        self.assertNotEqual(code, 0)
        self.assertIn("找不到 app", err)

    def test_js_error_does_not_kill_daemon(self):
        """脚本报错很正常；daemon 必须活着，下一个请求照常工作。"""
        self._js('throw new Error("boom")')
        out, err, code = self._js('console.log(JSON.stringify(await scu.ping()))')
        self.assertEqual(code, 0, err)
        self.assertIn('"ok":true', out.replace(" ", ""))

    def test_act_expect_window(self):
        """act 的 expect 能等到当前窗口，且只读、无副作用。"""
        d, _ = run("snapshot", "--app", APP, "--json")
        title = d.get("window") or ""
        if not title:
            self.skipTest("窗口没有标题")
        out, err, code = self._js(
            f'const a = await scu.getApp("{APP}");\n'
            f'const r = await a.act([{{op:"expect",window:{json.dumps(title)},timeoutMs:1500}}]);\n'
            'console.log(JSON.stringify({ok:r.ok,failedAt:r.failedAt,steps:r.steps.length}));')
        self.assertEqual(code, 0, err)
        self.assertIn('"ok":true', out.replace(" ", ""))

    def test_act_stops_on_first_error(self):
        """失败即停：第二步不该被执行。"""
        out, err, code = self._js(
            f'const a = await scu.getApp("{APP}");\n'
            'const r = await a.act([{op:"click",ref:"zzzzzz"},{op:"sleep",ms:10}]);\n'
            'console.log(JSON.stringify({ok:r.ok,failedAt:r.failedAt,steps:r.steps.length}));')
        self.assertEqual(code, 0, err)
        compact = out.replace(" ", "")
        self.assertIn('"failedAt":0', compact)
        self.assertIn('"steps":1', compact)


@unittest.skipUnless(AVAILABLE, "AX 不可用")
class TestChangeDetection(unittest.TestCase):
    """动作后判断"界面变没变"，代替截图确认。"""

    def setUp(self):
        if not APP:
            self.skipTest("没有带窗口的 app 可用")

    def _js(self, code: str):
        return subprocess.run([sys.executable, str(SCU), "js", "-e", code],
                              capture_output=True, text=True, timeout=90)

    def test_signature_stable_when_idle(self):
        p = self._js(
            f'const a = await scu.getApp("{APP}");\n'
            'const s1 = await a.signature(); const s2 = await a.signature();\n'
            'console.log(s1 === s2 ? "SAME" : "DIFF");')
        self.assertIn("SAME", p.stdout, p.stderr)

    def test_wait_reports_fields(self):
        p = self._js(
            f'const a = await scu.getApp("{APP}");\n'
            'const r = await a.keyAndWait("Escape", {timeoutMs: 300});\n'
            'console.log(JSON.stringify({changed: r.changed,'
            ' hasWaited: typeof r.waitedMs === "number",'
            ' hasVerification: !!r.verification, via: r.via}));')
        self.assertIn("changed", p.stdout, p.stderr)
        self.assertIn("hasWaited", p.stdout)
        self.assertIn("hasVerification", p.stdout)


if __name__ == "__main__":
    print(f"AX available: {AVAILABLE} | app: {APP}\n", file=sys.stderr)
    unittest.main(verbosity=2)
