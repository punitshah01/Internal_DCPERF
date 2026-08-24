#!/usr/bin/env python3
"""run_workloads.py — master orchestrator that runs DCPerf workloads sequentially.

Primary configuration is read from run_workloads.config.yaml (same directory).
Copy from run_workloads.config.example.yaml if the file does not exist yet:

    cp dcperf_scripts/run_workloads.config.example.yaml \\
       dcperf_scripts/run_workloads.config.yaml

CLI flags are optional lightweight overrides on top of the config file.

Examples:
    # Interactive menu (no args)
    python run_workloads.py

    # Run all workloads with settings from config file
    python run_workloads.py --workload-list mediawiki,feedsim,tao_bench

    # Override: run only two workloads, skip EMON, dry-run
    python run_workloads.py --workload-list mediawiki,feedsim --no-emon --dry-run

    # Point to a custom config
    python run_workloads.py --config /path/to/my_config.yaml

    # Show the resolved configuration and exit
    python run_workloads.py --show-config
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

DEFAULT_CONFIG_PATH = SCRIPT_DIR / "run_workloads.config.yaml"
EXAMPLE_CONFIG_PATH = SCRIPT_DIR / "run_workloads.config.example.yaml"
DCPERF_RUN = SCRIPT_DIR / "dcperf_run.py"
DURATION_HISTORY_PATH = SCRIPT_DIR / "logs" / "run_workloads" / "workload_durations.json"

# Canonical workload names and their order when none is specified in config.
ALL_WORKLOADS: List[str] = [
    "mediawiki",
    "feedsim",
    "tao_bench",
    "video_transcode_bench",
    "django_workload",
    "spark_standalone",
]
CODECS: List[str] = ["svt", "aom", "x264"]
VIDEO_TRANSCODE_VARIANT_MAP: Dict[str, Dict[str, str]] = {
    "video_transcode_bench_short": {"workload": "video_transcode_bench", "runtime": "short"},
    "video_transcode_bench_medium": {"workload": "video_transcode_bench", "runtime": "medium"},
    "video_transcode_bench_long": {"workload": "video_transcode_bench", "runtime": "long"},
}
# The 5 benchmarks that make up the official DCPerf overall score.
CORE_SCORE_WORKLOADS = {"mediawiki", "feedsim", "tao_bench", "django_workload", "spark_standalone"}

_ANSI_GREEN = "\033[32m"
_ANSI_YELLOW = "\033[33m"
_ANSI_RED = "\033[31m"
_ANSI_CYAN = "\033[36m"
_ANSI_RESET = "\033[0m"
INTER_WORKLOAD_SLEEP_SECONDS = 120

LIVE_LOG_PATTERNS = [
    re.compile(p, re.IGNORECASE)
    for p in (
        r"output directory:",
        r"results report:",
        r"finished running",
        r"\|\s*error\s*\|",
        r"\|\s*warning\s*\|",
        r"\[warn\]|\[error\]|traceback|exception",
        r"dcperf preflight check",
        r"benchpress system_check\s*:\s*pass",
        r"emon_manager:",
    )
]
_ITERATION_RE = re.compile(r"Starting iteration (\d+)/(\d+)")
_PRINT_LOCK = threading.Lock()


# ---------------------------------------------------------------------------
# Terminal capability / box drawing
# ---------------------------------------------------------------------------

def _term_supports_unicode() -> bool:
    encoding = getattr(sys.stdout, "encoding", None) or ""
    if "utf" not in encoding.lower():
        return False
    try:
        "┌└─│▏█░".encode(encoding)
        return True
    except (UnicodeEncodeError, LookupError):
        return False


_UNICODE_OK = _term_supports_unicode()

_BOX_SINGLE = {"tl": "┌", "tr": "┐", "bl": "└", "br": "┘", "h": "─", "v": "│", "lt": "├", "rt": "┤"}
_BOX_DOUBLE = {"tl": "╔", "tr": "╗", "bl": "╚", "br": "╝", "h": "═", "v": "║", "lt": "╠", "rt": "╣"}
_BOX_ASCII = {"tl": "+", "tr": "+", "bl": "+", "br": "+", "h": "-", "v": "|", "lt": "+", "rt": "+"}


def _box_chars(double: bool) -> Dict[str, str]:
    if not _UNICODE_OK:
        return _BOX_ASCII
    return _BOX_DOUBLE if double else _BOX_SINGLE


def _vbar() -> str:
    return "│" if _UNICODE_OK else "|"


def render_box(lines: List[str], double: bool = False, min_width: int = 60, max_width: int = 80) -> str:
    """Render a bordered box around ``lines``. A line equal to '---' becomes
    a horizontal divider. The box auto-sizes to the longest content line,
    capped at ``max_width`` -- longer lines are truncated with an ellipsis."""
    chars = _box_chars(double)
    content_lines = [line for line in lines if line != "---"]
    inner_width = min(max([min_width - 4] + [len(line) for line in content_lines]), max_width - 4)

    def _fit(text: str) -> str:
        if len(text) <= inner_width:
            return text.ljust(inner_width)
        ellipsis = "\u2026" if _UNICODE_OK else "..."
        cut = max(inner_width - len(ellipsis), 0)
        return (text[:cut] + ellipsis) if cut else text[:inner_width]

    total_width = inner_width + 4
    out = [chars["tl"] + chars["h"] * (total_width - 2) + chars["tr"]]
    for line in lines:
        if line == "---":
            out.append(chars["lt"] + chars["h"] * (total_width - 2) + chars["rt"])
        else:
            out.append(f"{chars['v']} {_fit(line)} {chars['v']}")
    out.append(chars["bl"] + chars["h"] * (total_width - 2) + chars["br"])
    return "\n".join(out)


def _fmt_hms(seconds: float) -> str:
    seconds = max(0, int(seconds))
    hours, rem = divmod(seconds, 3600)
    minutes, secs = divmod(rem, 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


# ---------------------------------------------------------------------------
# Config loading (YAML — stdlib-safe with json fallback if PyYAML absent)
# ---------------------------------------------------------------------------

def _load_yaml(path: Path) -> Dict[str, Any]:
    """Load a YAML file.  Falls back to a simple key:value parser if PyYAML
    is not available (covers the rare case where the host has only stdlib)."""
    try:
        import yaml  # type: ignore[import]
        with open(path) as fh:
            return yaml.safe_load(fh) or {}
    except ModuleNotFoundError:
        pass

    # Minimal YAML parser: handles only the flat/nested structure we emit.
    result: Dict[str, Any] = {}
    stack: List[Any] = [result]
    indent_stack: List[int] = [-1]
    key_stack: List[str] = []

    with open(path) as fh:
        for raw_line in fh:
            line = raw_line.rstrip()
            stripped = line.lstrip()
            if not stripped or stripped.startswith("#"):
                continue
            indent = len(line) - len(stripped)
            # pop until we are back at the correct parent
            while indent <= indent_stack[-1]:
                indent_stack.pop()
                stack.pop()
                if key_stack:
                    key_stack.pop()

            if stripped.startswith("- "):
                val_raw = stripped[2:].strip()
                parent = stack[-1]
                if isinstance(parent, list):
                    parent.append(_parse_yaml_value(val_raw))
                else:
                    # list under a mapping key
                    last_key = next(reversed(parent))
                    if not isinstance(parent[last_key], list):
                        parent[last_key] = []
                    parent[last_key].append(_parse_yaml_value(val_raw))
                continue

            if ":" in stripped:
                key, _, val_raw = stripped.partition(":")
                key = key.strip()
                val_raw = val_raw.strip()
                parent = stack[-1]
                if isinstance(parent, dict):
                    if val_raw and not val_raw.startswith("#"):
                        parent[key] = _parse_yaml_value(val_raw)
                    else:
                        parent[key] = {}
                        stack.append(parent[key])
                        indent_stack.append(indent)
                        key_stack.append(key)

    return result


def _parse_yaml_value(raw: str) -> Any:
    raw = raw.strip().strip('"').strip("'")
    if raw in ("true", "True"):
        return True
    if raw in ("false", "False"):
        return False
    if raw in ("null", "~", ""):
        return None
    try:
        return int(raw)
    except ValueError:
        pass
    try:
        return float(raw)
    except ValueError:
        pass
    return raw


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Master orchestrator: run DCPerf workloads sequentially.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG_PATH,
        metavar="FILE",
        help=f"Path to YAML config file (default: {DEFAULT_CONFIG_PATH})",
    )
    parser.add_argument(
        "--workload-list",
        type=str,
        default=None,
        metavar="W1,W2,...",
        help="Comma-separated workloads to run (overrides config workload_order)",
    )
    parser.add_argument(
        "--no-emon",
        action="store_true",
        default=None,
        help="Disable EMON collection (overrides config global.no_emon)",
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=None,
        metavar="N",
        help="Number of runs per workload (overrides config global.iterations)",
    )
    parser.add_argument(
        "--experiment",
        type=str,
        default=None,
        metavar="NAME",
        help="Experiment name (overrides config global.experiment_name)",
    )
    parser.add_argument(
        "--session-prefix",
        type=str,
        default=None,
        metavar="PREFIX",
        help="Session name prefix (overrides config global.session_prefix)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print resolved commands without executing",
    )
    parser.add_argument(
        "--interactive",
        action="store_true",
        help="Force the interactive menu even when other flags are present",
    )
    parser.add_argument(
        "--show-config",
        action="store_true",
        help="Print the resolved configuration and exit",
    )
    parser.add_argument(
        "--verbose-child-logs",
        action="store_true",
        help="Show full live stdout/stderr from each dcperf_run.py child process (default)",
    )
    parser.add_argument(
        "--compact-child-logs",
        action="store_true",
        help="Show only progress, warnings, errors, and summary lines from child processes",
    )
    return parser


# ---------------------------------------------------------------------------
# Config resolution
# ---------------------------------------------------------------------------

def load_config(config_path: Path) -> Dict[str, Any]:
    if not config_path.exists():
        if config_path == DEFAULT_CONFIG_PATH:
            print(
                f"\n[ERROR] Config file not found: {config_path}\n"
                f"  Create it by copying the example template:\n"
                f"    cp {EXAMPLE_CONFIG_PATH} {DEFAULT_CONFIG_PATH}\n"
                f"  Then edit {DEFAULT_CONFIG_PATH} with your settings.\n",
                file=sys.stderr,
            )
        else:
            print(f"\n[ERROR] Config file not found: {config_path}\n", file=sys.stderr)
        sys.exit(1)
    return _load_yaml(config_path)


def resolve_settings(config: Dict[str, Any], args: argparse.Namespace) -> Dict[str, Any]:
    """Merge config with CLI overrides (CLI wins)."""
    g = config.get("global", {}) or {}

    # no_emon: config default is True (no emon); CLI --no-emon also sets True.
    if args.no_emon is not None:
        no_emon = args.no_emon
    else:
        no_emon = bool(g.get("no_emon", True))

    iterations = args.iterations if args.iterations is not None else int(g.get("iterations", 1))
    experiment = args.experiment if args.experiment is not None else str(g.get("experiment_name", "") or "")
    session_prefix = args.session_prefix if args.session_prefix is not None else str(g.get("session_prefix", "run") or "run")

    if args.workload_list:
        workloads = [w.strip() for w in args.workload_list.split(",") if w.strip()]
    else:
        raw_order = g.get("workload_order") or ALL_WORKLOADS
        workloads = [str(w) for w in raw_order]

    return {
        "no_emon": no_emon,
        "iterations": iterations,
        "experiment": experiment,
        "session_prefix": session_prefix,
        "workloads": workloads,
        "workload_cfg": config.get("workloads", {}) or {},
        "dry_run": args.dry_run,
    }


# ---------------------------------------------------------------------------
# Command building
# ---------------------------------------------------------------------------

def build_workload_command(workload: str, settings: Dict[str, Any], session_name: str) -> List[str]:
    """Return the argv list that invokes dcperf_run.py for a single workload."""
    wl_cfg = settings["workload_cfg"].get(workload, {}) or {}
    resolved_workload = VIDEO_TRANSCODE_VARIANT_MAP.get(workload, {}).get("workload", workload)
    variant_runtime = VIDEO_TRANSCODE_VARIANT_MAP.get(workload, {}).get("runtime")

    # -u: force the child interpreter fully unbuffered so live streaming
    # never stalls waiting on stdio buffering inside dcperf_run.py.
    cmd: List[str] = [sys.executable, "-u", str(DCPERF_RUN), "--run-only", "--workload", resolved_workload]

    if settings["dry_run"]:
        cmd.append("--dry-run")

    if not settings["no_emon"]:
        cmd.append("--emon")

    if settings["experiment"]:
        cmd += ["--experiment", settings["experiment"]]

    runs = settings["iterations"]
    if runs and runs > 0:
        # Pass to the wrapper via --runs (supported by BaseWrapper)
        cmd += ["--runs", str(runs)]

    # Workload-specific flags
    if workload == "mediawiki":
        instances = wl_cfg.get("instances")
        if instances:
            cmd += ["--instances", str(instances)]

    elif workload == "feedsim":
        instances = wl_cfg.get("instances")
        if instances:
            cmd += ["--instances", str(instances)]

    elif workload == "tao_bench":
        mode = wl_cfg.get("mode")
        if mode:
            cmd += ["--mode", str(mode)]

    elif resolved_workload == "video_transcode_bench":
        runtime = wl_cfg.get("runtime") or variant_runtime
        if runtime:
            cmd += ["--runtime", str(runtime)]
        if workload in VIDEO_TRANSCODE_VARIANT_MAP:
            cmd += ["--codecs", ",".join(CODECS)]

    # Generic extra_args (forwarded verbatim if workload supports them)
    extra_args_raw: Optional[str] = wl_cfg.get("extra_args")
    if extra_args_raw:
        import shlex
        cmd.extend(shlex.split(extra_args_raw))

    # Append session name hint via TMC alias so each workload run is uniquely
    # labelled even in the same experiment.
    cmd += ["--tmc-alias", session_name]

    return cmd


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate_workloads(workloads: List[str]) -> None:
    unknown = [
        w
        for w in workloads
        if VIDEO_TRANSCODE_VARIANT_MAP.get(w, {}).get("workload", w) not in ALL_WORKLOADS
    ]
    if unknown:
        supported = ALL_WORKLOADS + list(VIDEO_TRANSCODE_VARIANT_MAP.keys())
        print(
            f"[ERROR] Unknown workload(s): {', '.join(unknown)}\n"
            f"  Supported: {', '.join(supported)}",
            file=sys.stderr,
        )
        sys.exit(1)


def _find_latest_summary_json(min_mtime_epoch: float) -> Optional[Path]:
    summary_candidates = sorted(
        (SCRIPT_DIR / "results").glob("summary_*/run_summary.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    for candidate in summary_candidates:
        try:
            if candidate.stat().st_mtime >= (min_mtime_epoch - 1):
                return candidate
        except OSError:
            continue
    return None


def _extract_workload_summary(summary_path: Optional[Path], workload: str) -> Dict[str, Any]:
    if not summary_path or not summary_path.exists():
        return {}
    try:
        payload = json.loads(summary_path.read_text(encoding="utf-8"))
        results = payload.get("results", [])
        if not isinstance(results, list) or not results:
            return {}
        entry = next((row for row in results if row.get("workload") == workload), results[0])
        if not isinstance(entry, dict):
            return {}
        return entry
    except (OSError, json.JSONDecodeError):
        return {}


# ---------------------------------------------------------------------------
# Workload duration history (used to estimate the progress bar ETA)
# ---------------------------------------------------------------------------

def _load_duration_history() -> Dict[str, List[float]]:
    try:
        return json.loads(DURATION_HISTORY_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _save_duration_history(history: Dict[str, List[float]]) -> None:
    try:
        DURATION_HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
        DURATION_HISTORY_PATH.write_text(json.dumps(history, indent=2), encoding="utf-8")
    except OSError:
        pass


def _record_duration(history: Dict[str, List[float]], workload: str, duration_sec: float) -> None:
    samples = history.setdefault(workload, [])
    samples.append(duration_sec)
    history[workload] = samples[-5:]
    _save_duration_history(history)


def _estimate_duration(history: Dict[str, List[float]], workload: str) -> Optional[float]:
    samples = history.get(workload)
    if not samples:
        return None
    return sum(samples) / len(samples)


# ---------------------------------------------------------------------------
# Live progress bar
# ---------------------------------------------------------------------------

class ProgressBar:
    """In-place (\\r) progress line with elapsed time and an ETA derived from
    the historical average duration of this workload, when known."""

    _BAR_LEN = 24

    def __init__(self, idx: int, total: int, workload: str, estimate_sec: Optional[float]):
        self.idx = idx
        self.total = total
        self.workload = workload
        self.estimate_sec = estimate_sec
        self.iteration_label = ""
        self.start = time.time()
        self._stop_event = threading.Event()
        self._last_len = 0
        self._thread = threading.Thread(target=self._loop, daemon=True)

    def start_ticking(self) -> None:
        self._thread.start()

    def note_iteration(self, current: int, total: int) -> None:
        self.iteration_label = f" | Iter {current}/{total}"

    def _loop(self) -> None:
        while not self._stop_event.wait(1.0):
            self.render()

    def render(self) -> None:
        elapsed = time.time() - self.start
        if self.estimate_sec and self.estimate_sec > 0:
            pct = max(0, min(99, int(elapsed / self.estimate_sec * 100)))
            eta_str = _fmt_hms(max(0.0, self.estimate_sec - elapsed))
        else:
            pct = 0
            eta_str = "--:--:--"
        filled = int(self._BAR_LEN * pct / 100)
        fill_ch = "█" if _UNICODE_OK else "#"
        empty_ch = "░" if _UNICODE_OK else "-"
        bar = fill_ch * filled + empty_ch * (self._BAR_LEN - filled)
        line = (
            f"  Workload {self.idx}/{self.total}{self.iteration_label} | {bar} {pct:3d}% | "
            f"Elapsed: {_fmt_hms(elapsed)} | ETA: {eta_str}"
        )
        with _PRINT_LOCK:
            pad = max(0, self._last_len - len(line))
            sys.stdout.write("\r" + line + (" " * pad))
            sys.stdout.flush()
            self._last_len = len(line)

    def stop(self) -> None:
        self._stop_event.set()
        self._thread.join(timeout=2)
        with _PRINT_LOCK:
            sys.stdout.write("\r" + " " * self._last_len + "\r")
            sys.stdout.flush()


def _print_live(text: str, progress: Optional[ProgressBar]) -> None:
    with _PRINT_LOCK:
        if progress is not None:
            sys.stdout.write("\r" + " " * progress._last_len + "\r")
        sys.stdout.write(text + "\n")
        sys.stdout.flush()


# ---------------------------------------------------------------------------
# Terminal UI blocks
# ---------------------------------------------------------------------------

def _print_session_banner(settings: Dict[str, Any], experiment_label: str) -> None:
    lines = [
        "DCPerf Benchmark Orchestrator",
        "---",
        f"Experiment : {experiment_label}",
        f"Host       : {socket.gethostname()}",
        f"Workloads  : {', '.join(settings['workloads'])}",
        f"Date       : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        f"EMON       : {'disabled' if settings['no_emon'] else 'enabled'}",
    ]
    print(f"\n{_ANSI_CYAN}{render_box(lines, double=True)}{_ANSI_RESET}\n")


def _print_workload_header(idx: int, total: int, workload: str, settings: Dict[str, Any], session_name: str) -> None:
    wl_cfg = settings["workload_cfg"].get(workload, {}) or {}
    instances = wl_cfg.get("instances")
    iter_line = f"Iterations : {settings['iterations']}"
    if instances:
        iter_line += f"   Instances: {instances}"
    lines = [
        f"[{idx}/{total}] WORKLOAD: {workload}",
        "---",
        f"Session    : {session_name}",
        iter_line,
    ]
    print(f"\n{_ANSI_CYAN}{render_box(lines)}{_ANSI_RESET}")


def _describe_emon(
    emon_collected: bool, emon_status: str, emon_error: str, tmc_result_dir: str
) -> str:
    """One-line, accurate EMON/TMC state -- never a generic enabled/disabled."""
    if not emon_collected:
        return "disabled"
    if tmc_result_dir:
        return f"uploaded (tmc dir: {tmc_result_dir})"
    if emon_status == "SKIPPED":
        return f"raw data saved, EDP skipped ({emon_error})" if emon_error else "raw data saved (EDP skipped)"
    if emon_status == "FAILED":
        return f"failed ({emon_error})" if emon_error else "failed (see emon_raw/)"
    return "collected"


def _print_result_box(
    workload: str,
    status: str,
    duration_sec: float,
    kpi_str: str,
    cpu_str: str,
    output_dir: str,
    emon_str: str = "",
) -> None:
    ok = status == "PASS"
    mark = ("✅" if _UNICODE_OK else "[OK]") if ok else ("❌" if _UNICODE_OK else "[FAIL]")
    label = "COMPLETED" if ok else "FAILED"
    lines = [
        f"{mark} {workload} {label}",
        "---",
        f"Duration : {_fmt_hms(duration_sec)}    KPI : {kpi_str}",
        f"Status   : {status}    CPU : {cpu_str}",
    ]
    if emon_str:
        lines.append(f"EMON     : {emon_str}")
    lines.append(f"Results  : {output_dir or 'n/a'}")
    color = _ANSI_GREEN if ok else _ANSI_RED
    print(f"{color}{render_box(lines)}{_ANSI_RESET}\n")


def _print_final_summary_box(rows: List[Dict[str, Any]], total_duration_sec: float, experiment_label: str) -> None:
    if not rows:
        return
    headers = ("Workload", "Status", "KPI", "Duration")
    data: List[Tuple[str, str, str, str]] = []
    passed = 0
    for row in rows:
        status = str(row.get("status", "UNKNOWN"))
        if status == "PASS":
            passed += 1
        kpi = row.get("average_kpi") or row.get("primary_kpi") or "--"
        data.append((str(row.get("workload", "")), status, str(kpi), _fmt_hms(row.get("duration_sec", 0))))

    widths = [max(len(headers[i]), max((len(r[i]) for r in data), default=0)) for i in range(4)]
    sep = f" {_vbar()} "

    def _fmt_row(cells: Tuple[str, ...]) -> str:
        return sep.join(cell.ljust(widths[i]) for i, cell in enumerate(cells))

    total = len(rows)
    lines = [
        f"DCPerf Run Complete — Experiment: {experiment_label}",
        "---",
        _fmt_row(headers),
        "---",
    ]
    lines.extend(_fmt_row(row) for row in data)
    lines.append("---")
    lines.append(
        f"Total Duration: {_fmt_hms(total_duration_sec)}   Passed: {passed}/{total}   Failed: {total - passed}/{total}"
    )
    print(f"\n{_ANSI_CYAN}{render_box(lines, double=True)}{_ANSI_RESET}")


def _print_iteration_details(rows: List[Dict[str, Any]]) -> None:
    print(f"\n{_ANSI_CYAN}Iteration Details{_ANSI_RESET}")
    for row in rows:
        print(f"\n  {row.get('workload', '')}")
        iterations = row.get("iterations")
        if not isinstance(iterations, list) or not iterations:
            print(f"    Result dir : {row.get('output_dir') or 'n/a'}")
            print(f"    KPI/Score  : {row.get('primary_kpi', '--')}")
            continue
        for iter_idx, iteration in enumerate(iterations, 1):
            if not isinstance(iteration, dict):
                continue
            kpis = iteration.get("kpis", {})
            if isinstance(kpis, dict) and kpis:
                first_kpi = next(iter(kpis))
                score = f"{kpis.get(first_kpi)} {first_kpi}"
            else:
                score = "--"
            emon_state = _describe_emon(
                bool(iteration.get("emon_collected")),
                str(iteration.get("emon_status", "")),
                str(iteration.get("emon_error", "")),
                str(iteration.get("tmc_result_dir", "")),
            )
            print(f"    Iteration {iter_idx}: {iteration.get('status', 'UNKNOWN')} | Score: {score} | EMON: {emon_state}")
            print(f"      Result dir : {iteration.get('output_dir') or 'n/a'}")
            print(f"      Files      : {iteration.get('results_json') or 'n/a'}; {iteration.get('results_csv') or 'n/a'}")
            if iteration.get("emon_collected"):
                print(f"      EMON raw   : {iteration.get('emon_raw_dir') or 'n/a'}")
                print(f"      EMON proc  : {iteration.get('emon_processed_dir') or 'n/a'}")


def _maybe_print_dcperf_score(rows: List[Dict[str, Any]], dry_run: bool) -> None:
    if dry_run:
        return
    ran = {
        VIDEO_TRANSCODE_VARIANT_MAP.get(row.get("workload", ""), {}).get("workload", row.get("workload", ""))
        for row in rows
    }
    if not CORE_SCORE_WORKLOADS.issubset(ran):
        return

    from modules.dcperf_config_manager import ConfigManager
    from modules.dcperf_logger import get_logger
    from modules.dcperf_result_manager import collect_dcperf_score

    logger = get_logger("dcperf_master_setup", SCRIPT_DIR / "logs")
    dcperf_config = ConfigManager(SCRIPT_DIR / "config" / "dcperf_config.yaml", logger).load()
    score = collect_dcperf_score(dcperf_config.get("dcperf_root"), logger)
    per_benchmark = {k: v for k, v in score.items() if k not in ("overall", "raw_output")}
    if not per_benchmark:
        return

    lines = ["DCPerf Benchmark Scores", "---"]
    lines.extend(f"{name:<14}: {value}" for name, value in per_benchmark.items())
    overall = score.get("overall")
    if overall is not None:
        lines.append("---")
        lines.append(f"DCPerf Overall Score : {overall}")
    print(f"\n{_ANSI_CYAN}{render_box(lines, double=True)}{_ANSI_RESET}")


def _print_config_box(settings: Dict[str, Any]) -> None:
    rows = [
        ("experiment_name", settings["experiment"] or "(auto)"),
        ("iterations", str(settings["iterations"])),
        ("no_emon", str(settings["no_emon"]).lower()),
        ("session_prefix", settings["session_prefix"]),
        ("workload_order", ", ".join(settings["workloads"])),
    ]
    key_width = max(len(key) for key, _ in rows)
    lines = ["Active Configuration", "---"]
    lines.extend(f"{key.ljust(key_width)} {_vbar()} {value}" for key, value in rows)
    print(f"\n{render_box(lines)}\n")


# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------

def _prompt_menu_choice() -> str:
    while True:
        choice = input("Choice: ").strip()
        if choice in {"1", "2", "3", "4", "5"}:
            return choice
        print("Invalid choice. Please enter a number from 1 to 5.")


def _prompt_workload_selection(candidates: List[str]) -> List[str]:
    selected: List[str] = []
    while True:
        print("\nToggle workloads (comma-separated numbers), 'a' = all, 'c' = confirm, 'q' = cancel:")
        for i, w in enumerate(candidates, 1):
            mark = "x" if w in selected else " "
            print(f"  [{mark}] {i}. {w}")
        raw = input("> ").strip().lower()
        if raw == "q":
            return []
        if raw == "c":
            if selected:
                return [w for w in candidates if w in selected]
            print("No workloads selected yet.")
            continue
        if raw == "a":
            selected = list(candidates)
            continue

        tokens = [t.strip() for t in raw.split(",") if t.strip()]
        if not tokens:
            print("Please enter at least one number, 'a', 'c', or 'q'.")
            continue
        all_valid = True
        for token in tokens:
            if not token.isdigit() or not (1 <= int(token) <= len(candidates)):
                print(f"Invalid entry: {token!r}")
                all_valid = False
                continue
            workload = candidates[int(token) - 1]
            if workload in selected:
                selected.remove(workload)
            else:
                selected.append(workload)
        if not all_valid:
            continue


def _confirm(prompt: str) -> bool:
    while True:
        raw = input(f"{prompt} (y/n): ").strip().lower()
        if raw in ("y", "yes"):
            return True
        if raw in ("n", "no"):
            return False
        print("Please answer y or n.")


def _print_interactive_menu() -> None:
    bar = "━" * 38 if _UNICODE_OK else "=" * 38
    print(f"\n{_ANSI_CYAN}DCPerf Orchestrator — Interactive Mode{_ANSI_RESET}\n{bar}")
    print("[1] Run ALL workloads")
    print("[2] Select specific workloads")
    print("[3] Dry run (preview commands only)")
    print("[4] Show current config")
    print("[5] Exit")
    print(bar)


def run_interactive_menu(config: Dict[str, Any], settings: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Drive the interactive menu. Returns updated settings to execute, or
    None if the user chose to exit."""
    candidates = list(dict.fromkeys((config.get("global", {}) or {}).get("workload_order") or ALL_WORKLOADS))

    while True:
        _print_interactive_menu()
        choice = _prompt_menu_choice()

        if choice == "5":
            print("Exiting.")
            return None

        if choice == "4":
            _print_config_box(settings)
            continue

        if choice == "2":
            chosen = _prompt_workload_selection(candidates)
            if not chosen:
                continue
        else:
            chosen = candidates

        if not _confirm(f"Run {chosen}?"):
            continue

        new_settings = dict(settings)
        new_settings["workloads"] = chosen
        new_settings["dry_run"] = bool(settings["dry_run"] or choice == "3")
        return new_settings


# ---------------------------------------------------------------------------
# Live child streaming
# ---------------------------------------------------------------------------

def _should_emit_compact_line(line: str) -> bool:
    stripped = line.strip()
    if not stripped:
        return False
    return any(pattern.search(stripped) for pattern in LIVE_LOG_PATTERNS)


def _format_live_line(workload: str, line: str) -> str:
    """Prefix one master log line with the workload tag, without duplicating
    a tag the child process already printed."""
    stripped = line.lstrip()
    prefix = f"[{workload}]"
    return line if stripped.startswith(prefix) else f"{prefix} {line}"


def _terminate_process_tree(process: subprocess.Popen, force: bool) -> None:
    """Signal the child's whole process group (it was started with
    start_new_session=True, so this reaches its children too), falling back
    to the single tracked pid on platforms without killpg (e.g. Windows)."""
    if hasattr(os, "killpg"):
        try:
            os.killpg(process.pid, signal.SIGKILL if force else signal.SIGINT)
            return
        except (ProcessLookupError, PermissionError, OSError):
            pass
    try:
        process.kill() if force else process.terminate()
    except Exception:
        pass


def _stream_subprocess(
    cmd: List[str], workload: str, verbose: bool, progress: Optional[ProgressBar], log_fh
) -> Tuple[int, int]:
    """Stream a child process's stdout live, one line at a time, fully
    unbuffered, echoing each line with a wall-clock timestamp."""
    env = {**os.environ, "PYTHONUNBUFFERED": "1"}
    started = time.time()
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=1,
        universal_newlines=True,
        env=env,
        start_new_session=True,
    )

    emitted_count = 0
    in_summary_block = False
    assert process.stdout is not None
    try:
        for raw_line in iter(process.stdout.readline, ""):
            log_fh.write(raw_line)
            line = raw_line.rstrip("\n")
            stripped = line.strip()

            match = _ITERATION_RE.search(stripped)
            if match and progress is not None:
                progress.note_iteration(int(match.group(1)), int(match.group(2)))

            show = verbose
            if not verbose:
                if "=== ITERATION" in stripped or "=== ALL" in stripped:
                    in_summary_block = True
                    show = True
                elif in_summary_block:
                    show = True
                    if stripped and set(stripped) == {"="}:
                        in_summary_block = False
                elif _should_emit_compact_line(line):
                    show = True

            if show:
                ts = datetime.now().strftime("%H:%M:%S")
                _print_live(f"  [{ts}] {_format_live_line(workload, line)}", progress)
                emitted_count += 1
    except KeyboardInterrupt:
        _print_live(f"\n  {_ANSI_YELLOW}[WARN] Interrupted by user; stopping {workload}...{_ANSI_RESET}", progress)
        if process.poll() is None:
            _terminate_process_tree(process, force=False)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
            if process.poll() is None:
                _terminate_process_tree(process, force=True)
        raise
    finally:
        process.stdout.close()

    rc = process.wait()
    finished = time.time()
    if not verbose and emitted_count == 0:
        _print_live(f"  [{workload}] (workload produced no compact log lines; see full log)", progress)
    return rc, int(finished - started)


def _run_child_live(cmd: List[str], workload: str, verbose: bool, progress: Optional[ProgressBar]) -> Dict[str, Any]:
    """Run child command with live output streaming and full log capture."""
    logs_dir = SCRIPT_DIR / "logs" / "run_workloads"
    logs_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = logs_dir / f"{workload}_{stamp}.log"

    with open(log_path, "w", encoding="utf-8", errors="ignore") as log_fh:
        rc, duration_sec = _stream_subprocess(cmd, workload, verbose, progress, log_fh)

    _print_live(f"  [{workload}] Full log: {log_path}", progress)
    return {"returncode": rc, "duration_sec": duration_sec, "log_path": str(log_path)}


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

def _execute(settings: Dict[str, Any], args: argparse.Namespace) -> int:
    workloads = settings["workloads"]
    validate_workloads(workloads)

    experiment_label = settings["experiment"] or datetime.now().strftime("exp_%Y%m%d")
    _print_session_banner(settings, experiment_label)

    if not DCPERF_RUN.exists():
        print(f"[ERROR] dcperf_run.py not found at {DCPERF_RUN}", file=sys.stderr)
        return 1

    duration_history = _load_duration_history()
    verbose = args.verbose_child_logs or not args.compact_child_logs

    any_fail = False
    workload_results: List[Dict[str, Any]] = []
    run_started = time.time()

    for idx, workload in enumerate(workloads, 1):
        session_name = f"{settings['session_prefix']}_{workload}_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
        cmd = build_workload_command(workload, settings, session_name)
        _print_workload_header(idx, len(workloads), workload, settings, session_name)
        print(f"  Command: {' '.join(cmd)}")

        if settings["dry_run"]:
            print(f"  {_ANSI_YELLOW}(dry-run — skipping execution){_ANSI_RESET}\n")
            workload_results.append(
                {
                    "workload": workload,
                    "status": "DRYRUN",
                    "runs": settings["iterations"],
                    "primary_kpi": "--",
                    "duration_sec": 0,
                    "exit_code": 0,
                }
            )
            continue

        estimate = _estimate_duration(duration_history, workload)
        progress = ProgressBar(idx, len(workloads), workload, estimate)
        progress.start_ticking()
        launched_at = time.time()

        try:
            run_meta = _run_child_live(cmd, workload, verbose, progress)
        except KeyboardInterrupt:
            workload_results.append(
                {
                    "workload": workload,
                    "status": "INTERRUPTED",
                    "runs": 0,
                    "primary_kpi": "user interrupted",
                    "duration_sec": 0,
                    "exit_code": 130,
                }
            )
            print(f"\n{_ANSI_YELLOW}Run interrupted by user. Printing partial summary...{_ANSI_RESET}")
            _print_final_summary_box(workload_results, time.time() - run_started, experiment_label)
            return 130
        except Exception as exc:  # noqa: BLE001
            print(f"  [ERROR] Failed to launch {workload}: {exc}", file=sys.stderr)
            any_fail = True
            workload_results.append(
                {
                    "workload": workload,
                    "status": "FAIL",
                    "runs": 0,
                    "primary_kpi": "launcher error",
                    "duration_sec": 0,
                    "exit_code": 1,
                }
            )
            continue
        finally:
            progress.stop()

        result_rc = int(run_meta["returncode"])
        duration = int(run_meta["duration_sec"])
        _record_duration(duration_history, workload, duration)

        summary_path = _find_latest_summary_json(launched_at)
        extracted = _extract_workload_summary(
            summary_path, VIDEO_TRANSCODE_VARIANT_MAP.get(workload, {}).get("workload", workload)
        )
        status = extracted.get("status") or ("PASS" if result_rc == 0 else "FAIL")
        runs = extracted.get("runs", settings["iterations"])
        primary_kpi = extracted.get("primary_kpi", "--")
        average_kpi = extracted.get("average_kpi", "--")
        kpi_display = average_kpi if average_kpi and average_kpi != "--" else primary_kpi
        cpu_avg = extracted.get("cpu_avg_pct")
        cpu_str = f"{cpu_avg:.1f}% avg" if isinstance(cpu_avg, (int, float)) else "n/a"
        output_dir = extracted.get("output_dir", "")
        emon_str = _describe_emon(
            bool(extracted.get("emon_collected")),
            str(extracted.get("emon_status", "")),
            str(extracted.get("emon_error", "")),
            str(extracted.get("tmc_result_dir", "")),
        )

        if result_rc != 0:
            any_fail = True

        _print_result_box(workload, status, duration, kpi_display, cpu_str, output_dir, emon_str)

        workload_results.append(
            {
                "workload": workload,
                "status": status,
                "runs": runs,
                "primary_kpi": primary_kpi,
                "average_kpi": average_kpi,
                "output_dir": output_dir,
                "iterations": extracted.get("iterations", []),
                "duration_sec": duration,
                "exit_code": result_rc,
            }
        )

        if idx < len(workloads):
            print("  [INFO] Cooldown 5s before next workload...")
            try:
                time.sleep(5)
            except KeyboardInterrupt:
                print(f"\n{_ANSI_YELLOW}Run interrupted during cooldown. Printing partial summary...{_ANSI_RESET}")
                _print_final_summary_box(workload_results, time.time() - run_started, experiment_label)
                return 130
            print(f"{_ANSI_CYAN}Sleeping {INTER_WORKLOAD_SLEEP_SECONDS}s before next workload...{_ANSI_RESET}\n")
            try:
                time.sleep(INTER_WORKLOAD_SLEEP_SECONDS)
            except KeyboardInterrupt:
                print(f"\n{_ANSI_YELLOW}Run interrupted during inter-workload sleep. Printing partial summary...{_ANSI_RESET}")
                _print_final_summary_box(workload_results, time.time() - run_started, experiment_label)
                return 130

    total_duration = time.time() - run_started

    if settings["dry_run"]:
        _print_final_summary_box(workload_results, total_duration, experiment_label)
        print(f"\n{_ANSI_CYAN}Dry-run complete. No workloads were executed.{_ANSI_RESET}")
        return 0

    _print_final_summary_box(workload_results, total_duration, experiment_label)
    _print_iteration_details(workload_results)
    _maybe_print_dcperf_score(workload_results, settings["dry_run"])

    if any_fail:
        print(f"\n{_ANSI_YELLOW}One or more workloads reported failures.{_ANSI_RESET}")
        return 1

    print(f"\n{_ANSI_GREEN}All workloads completed successfully.{_ANSI_RESET}")
    return 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()

    config = load_config(args.config)
    settings = resolve_settings(config, args)

    if args.show_config:
        _print_config_box(settings)
        return 0

    if args.interactive or len(sys.argv) == 1:
        settings = run_interactive_menu(config, settings)
        if settings is None:
            return 0

    return _execute(settings, args)


if __name__ == "__main__":
    raise SystemExit(main())
