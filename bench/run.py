#!/usr/bin/env python3
"""stable-mac 基准：延迟 + 端到端准确率。

用法：
  python3 bench/run.py                 # 全部
  python3 bench/run.py --latency-only
  python3 bench/run.py --app com.apple.finder

输出刻意做成 markdown 表格，可以直接贴进 README。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SMAC = ROOT / "cli" / "smac"

# (app, 指令, 期望目标名字里的关键子串)
# 指令是**改写过的自然说法**，不是元素标签原文 —— 这才反映真实用法
CASES: list[tuple[str, str, str]] = [
    ("com.apple.finder", '点击"搜索"', "搜索"),
    ("com.apple.finder", '点击"编辑标签"', "编辑标签"),
    ("com.apple.finder", '点击"共享"', "共享"),
    ("com.apple.finder", "回到上一个文件夹", "返回"),
    ("com.apple.finder", "往前面走一页", "前进"),
    ("com.apple.finder", "搜一下文件", "搜索"),
    ("com.apple.finder", "按大小排一下", "大小"),
    ("com.apple.finder", "按修改时间排序", "修改日期"),
    ("com.apple.finder", "换个分组方式", "群组"),
    ("com.apple.finder", "打开更多操作", "操作"),
    ("com.apple.finder", "看隔空投送", "隔空投送"),
    ("com.apple.finder", "打开文稿文件夹", "文稿"),
    ("com.apple.finder", "打开 iCloud 云盘", "iCloud"),
    ("com.apple.finder", "去下载文件夹", "下载"),
    ("com.apple.finder", "打开桌面", "桌面"),
    ("com.apple.finder", "打开应用程序", "应用程序"),
    ("com.apple.finder", "看最近用过的", "最近使用"),
]


def run(argv: list[str]) -> tuple[dict, float]:
    import time

    t0 = time.perf_counter()
    proc = subprocess.run([sys.executable, str(SMAC)] + argv,
                          capture_output=True, text=True)
    ms = (time.perf_counter() - t0) * 1000
    try:
        return json.loads(proc.stdout.strip() or "{}"), ms
    except json.JSONDecodeError:
        return {"ok": False, "reasonCode": "bad_output",
                "raw": proc.stdout[:200], "stderr": proc.stderr[:200]}, ms


def latency(apps: list[str], runs: int) -> None:
    print("### 快照延迟（`smac snapshot`，含进程启动）\n")
    print("| app | p50 | p95 | min | max |")
    print("|---|---|---|---|---|")
    for app in apps:
        d, _ = run(["bench", "--app", app, "--runs", str(runs)])
        if d.get("ok"):
            print(f"| `{app}` | **{d['p50']} ms** | {d['p95']} ms | {d['min']} ms | {d['max']} ms |")
        else:
            print(f"| `{app}` | 不可用（{d.get('reasonCode')}） | | | |")
    print()


def accuracy(apps: list[str]) -> None:
    print("### 端到端准确率（`smac decide --no-decider`，纯本地路径）\n")
    rows = []
    tier_count: dict[str, int] = {}
    hits = 0

    for app, goal, want in CASES:
        if app not in apps:
            continue
        d, ms = run(["decide", "--app", app, "--goal", goal, "--no-decider"])
        tier = d.get("tier", "?")
        tier_count[tier] = tier_count.get(tier, 0) + 1
        name = d.get("targetName") or ""
        ok = want in name
        hits += ok
        rows.append((app.replace("com.apple.", ""), goal, name[:24], "✅" if ok else "❌",
                     d.get("confidence"), d.get("confidenceGate"), round(ms)))

    print("| app | 指令 | 选中 | 对 | conf | gate | ms |")
    print("|---|---|---|---|---|---|---|")
    for r in rows:
        print(f"| {r[0]} | {r[1]} | {r[2]} | {r[3]} | {r[4]} | {r[5]} | {r[6]} |")
    total = len(rows)
    print(f"\n- 本地路径 top-1：**{hits}/{total} = {hits/total:.1%}**")
    print(f"- 走到的层级分布：{tier_count}")
    print("- 说明：本地打分不追求全对，它负责「高置信直接执行 + 低置信如实上报」。"
          "低置信的会升级到 JEV 或交回调用方 LLM。")
    print()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", action="append")
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--latency-only", action="store_true")
    ap.add_argument("--accuracy-only", action="store_true")
    args = ap.parse_args()

    apps = args.app or ["com.apple.finder", "com.google.Chrome", "com.electron.lark"]
    if not args.accuracy_only:
        latency(apps, args.runs)
    if not args.latency_only:
        accuracy(apps)
    return 0


if __name__ == "__main__":
    sys.exit(main())
