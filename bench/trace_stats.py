"""SCU_TRACE 的纯汇总。不依赖 Swift / AX，Linux 上就能单测。

一行 trace 是一次对外动作（app.act 里的一步，或单独一次 actAndWait），不是 daemon
内部子操作。字段固定：step、action、tier、resolve_ms、deliver_ms、wait_ms、
verify_ms、total_ms，以及可选的 wait_exit（changed / timeout）和 snapshots。

timeout 只表示「时间用完仍未满足条件」。text_not_found、cache_miss 这类失败
没有 wait_exit，不进超时命中率的分母。两个 expect 用 step 序号分开，不按 action 合并。
"""

from __future__ import annotations

import json


def parse_trace_lines(text: str) -> list[dict]:
    """解析 stderr JSONL。

    跳过空行、非 JSON（例如 collect 写的 `skipped-offscreen: N`），
    以及不像 trace 的 JSON（没有 step 和 action）。
    """
    events: list[dict] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        if "step" not in obj or "action" not in obj:
            continue
        events.append(obj)
    return events


def _median(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    n = len(ordered)
    mid = n // 2
    if n % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2


def _mean(values: list[float]) -> float | None:
    if not values:
        return None
    return sum(values) / len(values)


def _stats(values: list[float]) -> dict:
    if not values:
        return {"min": None, "median": None, "max": None}
    return {"min": min(values), "median": _median(values), "max": max(values)}


def summarize_runs(runs: list[dict], *, expected: int = 5) -> dict:
    """汇总若干轮。

    每轮：``ok``、``elapsed_ms``（脚本内）、``wall_ms``（bench 子进程墙钟）、
    ``events``（这一轮的 trace 行）。

    成功率的分母是 ``expected``（默认 5），中途失败的轮次也算在内。
    每步按 ``(step, action)`` 对齐；某轮缺了这一步就体现在 ``n/expected``。
    n=5 不报 p95。
    """
    successes = sum(1 for run in runs if run.get("ok") is True)
    elapsed = [run["elapsed_ms"] for run in runs if isinstance(run.get("elapsed_ms"), (int, float))]
    wall = [run["wall_ms"] for run in runs if isinstance(run.get("wall_ms"), (int, float))]

    order: list[tuple] = []
    totals: dict[tuple, list[float]] = {}
    present: dict[tuple, int] = {}
    timeout_hits: dict[tuple, int] = {}
    timeout_denom: dict[tuple, int] = {}

    for run in runs:
        for ev in run.get("events") or []:
            if not isinstance(ev, dict):
                continue
            key = (ev.get("step"), ev.get("action"))
            if key not in present:
                order.append(key)
                totals[key] = []
                present[key] = 0
                timeout_hits[key] = 0
                timeout_denom[key] = 0
            present[key] += 1
            if isinstance(ev.get("total_ms"), (int, float)):
                totals[key].append(float(ev["total_ms"]))
            exit_ = ev.get("wait_exit")
            if exit_ in ("changed", "timeout"):
                timeout_denom[key] += 1
                if exit_ == "timeout":
                    timeout_hits[key] += 1

    steps = []
    for key in order:
        vals = totals[key]
        n = present[key]
        steps.append({
            "step": key[0],
            "action": key[1],
            "n": n,
            "of": expected,
            "label": f"{n}/{expected}",
            "median_ms": _median(vals),
            "mean_ms": _mean(vals),
        })

    timeouts = []
    for key in order:
        denom = timeout_denom[key]
        if denom <= 0:
            continue
        hits = timeout_hits[key]
        timeouts.append({
            "step": key[0],
            "action": key[1],
            "hits": hits,
            "denom": denom,
            "rate": hits / denom,
        })

    return {
        "runs": expected,
        "observed": len(runs),
        "successes": successes,
        "success_rate": (successes / expected) if expected else 0.0,
        "elapsed_ms": _stats(elapsed),
        "wall_ms": _stats(wall),
        "steps": steps,
        "timeouts": timeouts,
    }
