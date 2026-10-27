#!/usr/bin/env python3
"""单元测试：不碰 AX，纯逻辑。

    python3 tests/test_unit.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCU = ROOT / "cli" / "scu"


def load_scu():
    """cli/scu 没有 .py 后缀，用 loader 加载。"""
    spec = importlib.util.spec_from_loader(
        "scu", importlib.machinery.SourceFileLoader("scu", str(SCU)))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


scu = load_scu()


class TestClean(unittest.TestCase):
    def test_strips_zero_width(self):
        # 实测 Chrome 窗口标题就是这个样子
        self.assertEqual(scu.clean("\u200b\u200c\u200d搜索\u200b"), "搜索")

    def test_strips_soft_hyphen_and_bom(self):
        self.assertEqual(scu.clean("\ufeffa\u00adb"), "ab")

    def test_nfkc_normalizes_width(self):
        # 全角转半角
        self.assertEqual(scu.clean("ＡＢＣ１２３"), "abc123")

    def test_lowercases_and_collapses_space(self):
        self.assertEqual(scu.clean("  Hello   World  "), "hello world")

    def test_none_and_empty(self):
        self.assertEqual(scu.clean(None), "")
        self.assertEqual(scu.clean(""), "")


class TestRank(unittest.TestCase):
    ELEMENTS = [
        {"ref": "a1", "role": "AXButton", "label": "搜索", "actions": ["AXPress"], "depth": 3},
        {"ref": "a2", "role": "AXButton", "label": "共享", "actions": ["AXPress"], "depth": 3},
        {"ref": "a3", "role": "AXStaticText", "label": None, "value": "下载", "depth": 6},
        {"ref": "a4", "role": "AXGroup", "label": None, "value": None, "depth": 2},
    ]

    def test_never_returns_empty_on_pure_nonsense_goal(self):
        """关键回归：预筛一旦返空，正确答案就永久出局。"""
        got = scu.rank("完全无关的胡话 zzzz", self.ELEMENTS, top_k=8)
        self.assertTrue(got, "rank 绝不能返回空列表")

    def test_never_returns_empty_on_empty_query(self):
        self.assertTrue(scu.rank("", self.ELEMENTS, top_k=4))

    def test_exact_label_wins(self):
        got = scu.rank("搜索", self.ELEMENTS)
        self.assertEqual(got[0]["ref"], "a1")

    def test_interactive_beats_static_text_on_tie(self):
        els = [
            {"ref": "s", "role": "AXStaticText", "label": "确定", "actions": [], "depth": 4},
            {"ref": "b", "role": "AXButton", "label": "确定", "actions": ["AXPress"], "depth": 4},
        ]
        self.assertEqual(scu.rank("确定", els)[0]["ref"], "b")

    def test_prefers_elements_with_text_in_backfill(self):
        """兜底候选必须优先有文字的，不能是一堆空容器。"""
        els = [
            {"ref": "empty1", "role": "AXGroup", "actions": ["AXPress"], "depth": 2},
            {"ref": "empty2", "role": "AXGroup", "actions": ["AXPress"], "depth": 2},
            {"ref": "texty", "role": "AXButton", "label": "保存", "actions": ["AXPress"], "depth": 5},
        ]
        got = scu.rank("不相干的目标 xyz", els, top_k=3)
        self.assertEqual(got[0]["ref"], "texty")


class TestConfidence(unittest.TestCase):
    def test_no_candidates_is_low(self):
        conf, gate = scu.confidence_of([])
        self.assertEqual(conf, 0.0)
        self.assertEqual(gate, "low")

    def test_clear_winner_is_high(self):
        ranked = [{"score": 1.0}, {"score": 0.0}]
        conf, gate = scu.confidence_of(ranked)
        self.assertEqual(gate, "high")

    def test_tie_is_not_high(self):
        ranked = [{"score": 0.8}, {"score": 0.8}]
        conf, gate = scu.confidence_of(ranked)
        self.assertNotEqual(gate, "high")

    def test_bounds(self):
        conf, _ = scu.confidence_of([{"score": 99.0}, {"score": 0.0}])
        self.assertLessEqual(conf, 1.0)
        self.assertGreaterEqual(conf, 0.0)


class TestExactMatch(unittest.TestCase):
    ELEMENTS = [
        {"ref": "x1", "role": "AXButton", "label": "搜索", "actions": ["AXPress"]},
        {"ref": "x2", "role": "AXStaticText", "label": "搜索", "actions": []},
        {"ref": "x3", "role": "AXButton", "label": "编辑标签", "actions": ["AXPress"]},
    ]

    def test_quoted_name_matches(self):
        got = scu._exact_match('点击"编辑标签"', self.ELEMENTS)
        self.assertIsNotNone(got)
        self.assertEqual(got["ref"], "x3")

    def test_ambiguous_label_prefers_actionable(self):
        got = scu._exact_match('点击"搜索"', self.ELEMENTS)
        self.assertEqual(got["ref"], "x1")

    def test_no_match_returns_none(self):
        self.assertIsNone(scu._exact_match("随便说点什么", self.ELEMENTS))


class TestExitCodes(unittest.TestCase):
    def test_known_codes(self):
        self.assertEqual(scu.exit_for({"ok": True}), 0)
        self.assertEqual(scu.exit_for({"ok": False, "reasonCode": "stale_ref"}), 5)
        self.assertEqual(scu.exit_for({"ok": False, "reasonCode": "disabled"}), 7)
        self.assertEqual(scu.exit_for({"ok": False, "reasonCode": "ax_cannot_complete"}), 10)

    def test_unknown_reason_is_1(self):
        self.assertEqual(scu.exit_for({"ok": False, "reasonCode": "wat"}), 1)


class TestMemory(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old = scu.MEMORY_PATH
        scu.MEMORY_PATH = Path(self.tmp.name) / "memory.jsonl"

    def tearDown(self):
        scu.MEMORY_PATH = self.old
        self.tmp.cleanup()

    def test_store_then_hit_by_ref(self):
        el = {"ref": "abc", "role": "AXButton", "label": "返回"}
        scu.memory_store("com.apple.finder", "回到上一个文件夹", el, source="test")
        live = [{"ref": "abc", "role": "AXButton", "label": "返回"}]
        hit = scu.memory_lookup("com.apple.finder", "回到上一个文件夹", live)
        self.assertIsNotNone(hit)
        self.assertEqual(hit["hit"], "ref")

    def test_falls_back_to_label_when_ref_gone(self):
        scu.memory_store("com.apple.finder", "g", {"ref": "old", "role": "AXButton", "label": "返回"},
                         source="test")
        live = [{"ref": "new", "role": "AXButton", "label": "返回"}]
        hit = scu.memory_lookup("com.apple.finder", "g", live)
        self.assertIsNotNone(hit)
        self.assertEqual(hit["hit"], "label")
        self.assertEqual(hit["element"]["ref"], "new")

    def test_miss_when_target_absent(self):
        scu.memory_store("com.apple.finder", "g", {"ref": "a", "role": "AXButton", "label": "返回"},
                         source="test")
        self.assertIsNone(scu.memory_lookup("com.apple.finder", "g", []))

    def test_scoped_by_app(self):
        scu.memory_store("app.one", "g", {"ref": "a", "role": "AXButton", "label": "返回"},
                         source="test")
        live = [{"ref": "a", "role": "AXButton", "label": "返回"}]
        self.assertIsNone(scu.memory_lookup("app.two", "g", live))


class TestUsefulTarget(unittest.TestCase):
    def test_text_counts(self):
        self.assertTrue(scu.useful_target({"label": "x"}))
        self.assertTrue(scu.useful_target({"value": "x"}))

    def test_bare_container_does_not(self):
        self.assertFalse(scu.useful_target({"role": "AXGroup"}))

    def test_actionable_counts(self):
        self.assertTrue(scu.useful_target({"role": "AXButton", "actions": ["AXPress"]}))


if __name__ == "__main__":
    unittest.main(verbosity=2)
