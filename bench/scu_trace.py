"""解析并汇总 SCU_TRACE=1 打出的 JSON 行。

一步对应一次对外的 act / actAndWait。非法行跳过并计数，不中断其余行。
只依赖标准库，不读 AX、不启 Swift。
"""

from __future__ import annotations

import json
from typing import Any

FIELDS = (
    "step",
    "action",
    "tier",
    "resolve_ms",
    "deliver_ms",
    "wait_ms",
    "verify_ms",
    "total_ms",
    "wait_exit",
)
SEGMENTS = ("resolve_ms", "deliver_ms", "wait_ms", "verify_ms")
MS_FIELDS = SEGMENTS + ("total_ms",)
TIERS = frozenset({"ax", "pid", "mouse"})
WAIT_EXITS = frozenset({"changed", "timeout"})


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _is_int(value: Any) -> bool:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    return float(value).is_integer()


def _validate(obj: Any) -> tuple[dict | None, str | None]:
    if not isinstance(obj, dict):
        return None, "type"
    if any(key not in obj for key in FIELDS):
        return None, "missing"
    step = obj["step"]
    if not _is_int(step) or step < 0:
        return None, "step"
    action = obj["action"]
    if not isinstance(action, str) or action.strip() == "":
        return None, "action"
    if obj["tier"] not in TIERS:
        return None, "tier"
    if obj["wait_exit"] not in WAIT_EXITS:
        return None, "wait_exit"
    ms: dict[str, float] = {}
    for key in MS_FIELDS:
        value = obj[key]
        if not _is_number(value) or value < 0:
            return None, "ms"
        ms[key] = float(value)
    return {
        "step": int(step),
        "action": action,
        "tier": obj["tier"],
        "wait_exit": obj["wait_exit"],
        **ms,
    }, None


def parse_trace(text: str) -> dict:
    """把一段 JSON 行解析成 steps。空白行忽略；其余非法行计入 invalid。"""
    steps: list[dict] = []
    invalid: list[dict] = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        if raw.strip() == "":
            continue
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            invalid.append({"line": lineno, "reason": "json"})
            continue
        step, reason = _validate(obj)
        if reason:
            invalid.append({"line": lineno, "reason": reason})
            continue
        steps.append(step)
    return {"steps": steps, "invalid_count": len(invalid), "invalid": invalid}


def _zero_segments() -> dict[str, float]:
    return {key: 0.0 for key in SEGMENTS}


def summarize_trace(text: str) -> dict:
    """一次运行：每步耗时、总耗时、各段占比、timeout 步数占比。"""
    parsed = parse_trace(text)
    steps = parsed["steps"]
    segments = _zero_segments()
    total = 0.0
    timeout_steps = 0
    for step in steps:
        total += step["total_ms"]
        if step["wait_exit"] == "timeout":
            timeout_steps += 1
        for key in SEGMENTS:
            segments[key] += step[key]
    if total > 0:
        ratios = {key: segments[key] / total for key in SEGMENTS}
    else:
        ratios = _zero_segments()
    count = len(steps)
    return {
        "steps": steps,
        "invalid_count": parsed["invalid_count"],
        "invalid": parsed["invalid"],
        "step_count": count,
        "total_ms": total,
        "segments_ms": segments,
        "segment_ratios": ratios,
        "timeout_steps": timeout_steps,
        "timeout_ratio": (timeout_steps / count) if count else 0.0,
    }


def _span(values: list[float]) -> dict:
    if not values:
        return {"mean": None, "max": None, "min": None}
    return {
        "mean": sum(values) / len(values),
        "max": max(values),
        "min": min(values),
    }


def _run_succeeded(run: dict) -> bool:
    """有有效步，且没有一步因 timeout 返回。

    非法行只计 invalid_count，不单独把这次运行判失败。
    空运行（没有任何有效步）不算成功。
    """
    return run["step_count"] > 0 and run["timeout_steps"] == 0


def summarize_runs(texts: list[str]) -> dict:
    """多次运行：各段与总耗时的均值/最大/最小，以及成功率。"""
    runs = [summarize_trace(text) for text in texts]
    successes = sum(1 for run in runs if _run_succeeded(run))
    count = len(runs)
    return {
        "runs": runs,
        "run_count": count,
        "total_ms": _span([run["total_ms"] for run in runs]),
        "segments_ms": {
            key: _span([run["segments_ms"][key] for run in runs]) for key in SEGMENTS
        },
        "successes": successes,
        "success_rate": (successes / count) if count else None,
    }
