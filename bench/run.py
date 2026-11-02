#!/usr/bin/env python3
"""stable-computer-use 基准：延迟 + 端到端准确率。

用法：
  python3 bench/run.py                 # 全部（不含会真发消息的场景）
  python3 bench/run.py --latency-only
  python3 bench/run.py --app com.apple.finder
  python3 bench/run.py --scenario wechat

输出刻意做成 markdown 表格，可以直接贴进 README。
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SMAC = ROOT / "cli" / "scu"

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


def _load_trace_stats():
    path = Path(__file__).resolve().parent / "trace_stats.py"
    spec = importlib.util.spec_from_file_location("scu_trace_stats", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# 固定 5 次。不跟 --runs 走：那是延迟基准的次数，默认 10，不能拿来连发 10 条微信。
WECHAT_RUNS = 5

# 走 JS app.act，不走 `scu click --text`。
# daemon 在线时 click 不认 text，会返回 bad_args。这是已知问题，本场景不修。
#
# 最后一步不能是 `expect text:"你好"`：第 2 轮起会话里已经有历史「你好」，
# 一出现就会通过。改成打开会话后、打字和回车之前数一次可见节点个数 n0，
# 发出去之后等个数 > n0。可见列表有虚拟滚动，滚出屏幕的行不在树里，
# 所以看个数增加，不看「字符串是否出现」。
# 两段 act 拼成一份报告；第二段用 indexBase 接着编号，最后一步是
# expect countGreaterThan，这样 trace 仍按 0..4 对齐。
WECHAT_JS = r"""
const session = process.env.SCU_WECHAT_SESSION || "文件传输助手";
const text = process.env.SCU_WECHAT_TEXT || "你好";
const bundle = process.env.SCU_WECHAT_BUNDLE || "com.tencent.xinWeChat";
// 会话标题怎么确认：默认 expect window。Mac 上微信窗口标题不一定变成会话名，
// 先跑一次 `scu snapshot` 看窗口标题和会话标题分别落在哪，再改这两个环境变量。
//   SCU_WECHAT_EXPECT=window|text
//   SCU_WECHAT_EXPECT_TITLE=实际看到的标题（默认跟会话名一样）
const expectKind = process.env.SCU_WECHAT_EXPECT || "window";
const expectTitle = process.env.SCU_WECHAT_EXPECT_TITLE || session;
const t0 = process.hrtime.bigint();

function finish(report) {
  report.elapsedMs = Math.round(Number(process.hrtime.bigint() - t0) / 1e6);
  console.log(JSON.stringify(report));
}

const openSteps = [{ op: "click", text: session }];
if (expectKind === "text") {
  openSteps.push({ op: "expect", text: expectTitle, timeoutMs: 3000 });
} else {
  openSteps.push({ op: "expect", window: expectTitle, timeoutMs: 3000 });
}

const app = await scu.getApp(bundle);
const opened = await app.act(openSteps);
if (!opened.ok) {
  finish(opened);
} else {
  let n0 = null;
  let snapErr = null;
  try {
    const snap = await app.state({ json: true, actions: false });
    n0 = scu.countTextHits(snap.elements, text);
  } catch (e) {
    snapErr = e?.message || String(e);
  }
  if (snapErr) {
    finish({
      ok: false,
      failedAt: opened.steps.length,
      reasonCode: "snapshot_failed",
      detail: snapErr,
      steps: opened.steps,
    });
  } else {
    const sent = await app.act([
      { op: "type", text },
      { op: "key", key: "Return" },
      { op: "expect", text, countGreaterThan: n0, timeoutMs: 3000 },
    ], { indexBase: opened.steps.length });
    finish({
      ok: sent.ok === true,
      failedAt: sent.ok ? null : opened.steps.length + sent.failedAt,
      diff: sent.diff,
      n0,
      steps: opened.steps.concat(sent.steps),
    });
  }
}
"""


def _fmt_ms(v) -> str:
    if v is None:
        return "-"
    return f"{v:.1f}"


def wechat_payload() -> tuple[str, str]:
    """和 WECHAT_JS 用同一对环境变量，避免提示和实际发送的不是同一段文字。"""
    session = os.environ.get("SCU_WECHAT_SESSION") or "文件传输助手"
    text = os.environ.get("SCU_WECHAT_TEXT") or "你好"
    return session, text


def _print_wechat(report: dict, runs: list[dict], session: str, text: str) -> None:
    n = report["runs"]
    ok = report["successes"]
    rate = report["success_rate"]
    print(f"发送对象：{session}")
    print(f"文字：{text}")
    print(f"### 微信基线（{session} · {text}） n={n}\n")
    print("前置：微信已登录，主窗口可见，「文件传输助手」在可见列表里"
          "（snapshot 默认 visibleOnly）。bundle id 是 `com.tencent.xinWeChat`。")
    print("daemon 若在没设 `SCU_TRACE` 时已经在跑，分段里的 daemon 部分会退回"
          " `actMs` / `waitedMs`。真机基线先 `SCU_TRACE=1 scu daemon restart`。")
    print()
    print(f"- 成功率：**{ok}/{n} = {rate:.1%}**（`ok===true` / {n}，中途失败的轮次仍计入分母）")
    el = report["elapsed_ms"]
    wall = report["wall_ms"]
    print(f"- 脚本 elapsedMs：min {_fmt_ms(el['min'])} / 中位数 {_fmt_ms(el['median'])} / max {_fmt_ms(el['max'])}")
    print(f"- bench 墙钟：min {_fmt_ms(wall['min'])} / 中位数 {_fmt_ms(wall['median'])} / max {_fmt_ms(wall['max'])}")
    print()
    print("| step | op | n | total median | total mean | resolve | deliver | wait | verify |")
    print("|---|---|---|---|---|---|---|---|---|")
    for st in report["steps"]:
        print(f"| {st['step']} | {st['action']} | {st['label']} | "
              f"{_fmt_ms(st['median_ms'])} | {_fmt_ms(st['mean_ms'])} | "
              f"{_fmt_ms(st['median_resolve_ms'])} | {_fmt_ms(st['median_deliver_ms'])} | "
              f"{_fmt_ms(st['median_wait_ms'])} | {_fmt_ms(st['median_verify_ms'])} |")
    print()
    print("超时命中率（分母只含有 `wait_exit` 的步骤；`timeout` = 时间用尽。"
          "按 step + op 分开，两个 expect 不合并）：")
    if not report["timeouts"]:
        print("- （没有进入等待的步骤）")
    for row in report["timeouts"]:
        print(f"- {row['step']} {row['action']}：{row['hits']}/{row['denom']}")
    print()
    print("逐轮：")
    for i, run in enumerate(runs, start=1):
        mark = "ok" if run.get("ok") else "失败"
        extra = ""
        if not run.get("ok"):
            bits = []
            if run.get("failed_at") is not None:
                bits.append(f"failedAt={run['failed_at']}")
            if run.get("reason"):
                bits.append(str(run["reason"]))
            if bits:
                extra = " " + " ".join(bits)
        print(f"- 第 {i} 轮：{mark}{extra} "
              f"elapsedMs={_fmt_ms(run.get('elapsed_ms'))} wall={_fmt_ms(run.get('wall_ms'))} "
              f"steps={len(run.get('events') or [])}")
    print()


def scenario_wechat(confirm_send: bool = False) -> int:
    """在微信里打开「文件传输助手」并发「你好」，跑 5 次。

    会真的发出消息。必须同时带 `--scenario wechat` 和 `--confirm-send`。
    不带 `--confirm-send` 只打印将要发送的对象和文字，退出码非 0，不启动子进程。
    默认 `python3 bench/run.py` 不会进这里。

    前置条件（Mac）：
    - 微信已登录，主窗口可见
    - 「文件传输助手」在可见会话列表里。snapshot 默认 visibleOnly，
      滚出屏幕的行不在树里，点不到
    - bundle id 用 `com.tencent.xinWeChat`。skill 里的
      `com.tencent.WeWorkMac` 是企业微信，不要混用

    不用 `scu click --text`：daemon 在线时 daemon 的 click 不认 text，
    会返回 bad_args。这是已知问题，本任务不修。定位文字走 JS `app.act`
    的 `_findTarget`。

    第二步 expect 会话标题。微信窗口标题在 Mac 上不一定变成「文件传输助手」，
    默认仍按 SKILL 写成 expect window，需要先看一次快照再定。用
    `SCU_WECHAT_EXPECT=text` 改成在树里找这段文字，用
    `SCU_WECHAT_EXPECT_TITLE` 改成快照里实际的标题。

    发出去之后不等「出现你好」（历史消息会误判），等可见节点里含这段文字的
    个数比发送前多。snapshot 默认 visibleOnly，虚拟滚动出去的行不在个数里。
    """
    session, text = wechat_payload()
    if not confirm_send:
        print(f"将向 {session} 发送 {text} 共 {WECHAT_RUNS} 次，加 --confirm-send 才会执行")
        return 2
    print(f"发送对象：{session}")
    print(f"文字：{text}")
    stats = _load_trace_stats()
    runs: list[dict] = []
    for _ in range(WECHAT_RUNS):
        env = os.environ.copy()
        env["SCU_TRACE"] = "1"
        t0 = time.perf_counter()
        proc = subprocess.run(
            [sys.executable, str(SMAC), "js", "-e", WECHAT_JS],
            capture_output=True, text=True, env=env,
        )
        wall = (time.perf_counter() - t0) * 1000
        stdout = (proc.stdout or "").strip()
        try:
            result = json.loads(stdout) if stdout else {"ok": False, "reasonCode": "no_output"}
        except json.JSONDecodeError:
            result = {"ok": False, "reasonCode": "bad_output"}
        reason = None
        if result.get("ok") is not True:
            failed_at = result.get("failedAt")
            steps = result.get("steps") or []
            if isinstance(failed_at, int) and 0 <= failed_at < len(steps):
                reason = steps[failed_at].get("reasonCode")
            reason = reason or result.get("reasonCode")
        else:
            failed_at = None
        runs.append({
            "ok": result.get("ok") is True,
            "elapsed_ms": result.get("elapsedMs") if isinstance(result.get("elapsedMs"), (int, float)) else None,
            "wall_ms": wall,
            "events": stats.parse_trace_lines(proc.stderr or ""),
            "failed_at": failed_at,
            "reason": reason,
        })
    report = stats.summarize_runs(runs, expected=WECHAT_RUNS)
    _print_wechat(report, runs, session, text)
    return 0


def run(argv: list[str]) -> tuple[dict, float]:
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
    print("### 快照延迟（`scu snapshot`，含进程启动）\n")
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
    print("### 端到端准确率（`scu decide --no-decider`，纯本地路径）\n")
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


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", action="append")
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--latency-only", action="store_true")
    ap.add_argument("--accuracy-only", action="store_true")
    ap.add_argument(
        "--scenario",
        choices=["wechat"],
        default=None,
        help="显式基线场景。wechat 会在微信里真的发送消息，还要再加 --confirm-send",
    )
    ap.add_argument(
        "--confirm-send",
        action="store_true",
        help="和 --scenario wechat 一起用才会真的发送；不带则只打印对象和文字",
    )
    return ap


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    # 微信场景会真的发消息，和延迟/准确率默认跑法分开。
    if args.scenario == "wechat":
        return scenario_wechat(confirm_send=args.confirm_send)

    apps = args.app or ["com.apple.finder", "com.google.Chrome", "com.electron.lark"]
    if not args.accuracy_only:
        latency(apps, args.runs)
    if not args.latency_only:
        accuracy(apps)
    return 0


if __name__ == "__main__":
    sys.exit(main())
