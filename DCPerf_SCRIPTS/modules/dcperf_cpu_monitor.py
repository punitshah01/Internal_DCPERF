"""Lightweight background CPU utilization monitor for workload runs.

Samples /proc/stat every ``sample_interval_sec`` seconds on a daemon
thread while a workload runs, then reports whether the observed CPU
utilization falls within the target range documented in the official
DCPerf README for that workload.
"""

from __future__ import annotations

import threading
import time
from typing import Any, Dict, List, Optional, Tuple

# (overall_low, overall_high), optional user_pct range, optional window in
# minutes (None = use the entire run). Values are from the official DCPerf
# README's "Expected CPU Utilization" guidance.
_TARGETS: Dict[str, Dict[str, Any]] = {
    "tao_bench": {"overall": (70, 80), "user": (15, 20), "window_min": 10},
    "tao_bench_standalone": {"overall": (70, 80), "user": (15, 20), "window_min": 10},
    "feedsim": {"overall": (60, 75), "window_min": 5},
    "django_workload": {"overall": (90, 100), "window_min": None},
    "mediawiki": {"overall": (90, 100), "window_min": 10},
    "spark_standalone": {"overall": (55, 75), "window_min": None},
    "video_transcode_bench": {"overall": (85, 100), "window_min": None},
}


def _read_cpu_times() -> List[int]:
    """Read the aggregate 'cpu' line from /proc/stat as a list of ints."""
    with open("/proc/stat", encoding="utf-8") as fh:
        line = fh.readline()
    return [int(v) for v in line.split()[1:]]


def _compute_pct(prev: List[int], cur: List[int]) -> Tuple[float, float]:
    """Return (overall_busy_pct, user_pct) between two /proc/stat samples."""
    prev_idle = prev[3] + prev[4]
    cur_idle = cur[3] + cur[4]
    total_delta = sum(cur) - sum(prev)
    if total_delta <= 0:
        return 0.0, 0.0
    idle_delta = cur_idle - prev_idle
    overall_pct = 100.0 * (total_delta - idle_delta) / total_delta
    user_delta = (cur[0] + cur[1]) - (prev[0] + prev[1])
    user_pct = 100.0 * user_delta / total_delta
    return overall_pct, user_pct


class CpuMonitor:
    """Samples overall/user CPU utilization on a background thread."""

    def __init__(self, workload: str, logger, sample_interval_sec: int = 10):
        self.workload = workload
        self.logger = logger
        self.sample_interval_sec = sample_interval_sec
        self.samples: List[Dict[str, float]] = []
        self._thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()

    def start(self) -> None:
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._sample_loop, daemon=True)
        self._thread.start()

    def _sample_loop(self) -> None:
        try:
            prev = _read_cpu_times()
        except OSError as exc:
            self.logger.warning("cpu_monitor: /proc/stat unavailable, monitor disabled: %s", exc)
            return

        while not self._stop_event.wait(self.sample_interval_sec):
            try:
                cur = _read_cpu_times()
                overall_pct, user_pct = _compute_pct(prev, cur)
                self.samples.append({
                    "timestamp": time.time(),
                    "overall_pct": overall_pct,
                    "user_pct": user_pct,
                })
                prev = cur
            except OSError as exc:
                self.logger.warning("cpu_monitor: failed to read /proc/stat: %s", exc)

    def stop(self) -> Dict[str, Any]:
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=self.sample_interval_sec + 5)
            self._thread = None
        return self._summarize()

    def _summarize(self) -> Dict[str, Any]:
        target = _TARGETS.get(self.workload)

        if not self.samples:
            return {
                "samples": [],
                "avg_overall_pct": 0.0,
                "avg_user_pct": 0.0,
                "min_overall_pct": 0.0,
                "max_overall_pct": 0.0,
                "within_target": None,
                "target_range": None,
                "warning": None,
            }

        window_samples = self.samples
        if target and target.get("window_min"):
            cutoff = time.time() - target["window_min"] * 60
            windowed = [s for s in self.samples if s["timestamp"] >= cutoff]
            window_samples = windowed or self.samples

        overall_vals = [s["overall_pct"] for s in window_samples]
        user_vals = [s["user_pct"] for s in window_samples]
        avg_overall = sum(overall_vals) / len(overall_vals)
        avg_user = sum(user_vals) / len(user_vals)

        summary: Dict[str, Any] = {
            "samples": self.samples,
            "avg_overall_pct": round(avg_overall, 1),
            "avg_user_pct": round(avg_user, 1),
            "min_overall_pct": round(min(overall_vals), 1),
            "max_overall_pct": round(max(overall_vals), 1),
            "within_target": None,
            "target_range": None,
            "warning": None,
        }

        if not target:
            return summary

        lo, hi = target["overall"]
        summary["target_range"] = f"{lo}-{hi}%"

        if avg_overall < lo:
            summary["within_target"] = False
            summary["warning"] = (
                f"WARNING: CPU utilization {avg_overall:.1f}% is below target "
                f"{lo}-{hi}% for {self.workload}. Benchmark may not have run correctly."
            )
        elif avg_overall > hi:
            summary["within_target"] = False
            summary["warning"] = (
                f"INFO: CPU utilization {avg_overall:.1f}% is above typical target "
                f"{lo}-{hi}%. System may be overloaded."
            )
        else:
            summary["within_target"] = True

        return summary
