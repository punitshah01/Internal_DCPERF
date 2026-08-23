#!/usr/bin/env python3
"""run_workloads.py — master orchestrator that runs DCPerf workloads sequentially.

Primary configuration is read from run_workloads.config.yaml (same directory).
Copy from run_workloads.config.example.yaml if the file does not exist yet:

    cp dcperf_scripts/run_workloads.config.example.yaml \\
       dcperf_scripts/run_workloads.config.yaml

CLI flags are optional lightweight overrides on top of the config file.

Examples:
    # Run all workloads with settings from config file
    python run_workloads.py

    # Override: run only two workloads, skip EMON, dry-run
    python run_workloads.py --workload-list mediawiki,feedsim --no-emon --dry-run

    # Point to a custom config
    python run_workloads.py --config /path/to/my_config.yaml
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG_PATH = SCRIPT_DIR / "run_workloads.config.yaml"
EXAMPLE_CONFIG_PATH = SCRIPT_DIR / "run_workloads.config.example.yaml"
DCPERF_RUN = SCRIPT_DIR / "dcperf_run.py"

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

_ANSI_GREEN = "\033[32m"
_ANSI_YELLOW = "\033[33m"
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
                    last_key = list(parent.keys())[-1]
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
        "--verbose-child-logs",
        action="store_true",
        help="Show full live stdout/stderr from each dcperf_run.py child process",
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

def build_workload_command(workload: str, settings: Dict[str, Any]) -> List[str]:
    """Return the argv list that invokes dcperf_run.py for a single workload."""
    wl_cfg = settings["workload_cfg"].get(workload, {}) or {}
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    session_name = f"{settings['session_prefix']}_{workload}_{ts}"
    resolved_workload = VIDEO_TRANSCODE_VARIANT_MAP.get(workload, {}).get("workload", workload)
    variant_runtime = VIDEO_TRANSCODE_VARIANT_MAP.get(workload, {}).get("runtime")

    cmd: List[str] = [sys.executable, str(DCPERF_RUN), "--run-only", "--workload", resolved_workload]

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


def _render_final_table(rows: List[Dict[str, Any]]) -> None:
    if not rows:
        return
    headers = ["Workload", "Status", "Runs", "Primary KPI / Score", "Duration(s)", "Exit"]
    table_rows: List[List[str]] = []
    for row in rows:
        table_rows.append(
            [
                str(row.get("workload", "")),
                str(row.get("status", "UNKNOWN")),
                str(row.get("runs", "")),
                str(row.get("primary_kpi", "--")),
                str(row.get("duration_sec", "")),
                str(row.get("exit_code", "")),
            ]
        )

    widths = [len(h) for h in headers]
    for row in table_rows:
        for idx, cell in enumerate(row):
            widths[idx] = max(widths[idx], len(cell))

    def _fmt(cells: List[str]) -> str:
        return " | ".join(cell.ljust(widths[idx]) for idx, cell in enumerate(cells))

    bar = "-+-".join("-" * width for width in widths)
    print(f"\n{_ANSI_CYAN}Run Summary Table{_ANSI_RESET}")
    print(_fmt(headers))
    print(bar)
    for row in table_rows:
        print(_fmt(row))


def _should_emit_compact_line(line: str) -> bool:
    stripped = line.strip()
    if not stripped:
        return False
    return any(pattern.search(stripped) for pattern in LIVE_LOG_PATTERNS)


def _run_child_live(cmd: List[str], workload: str, verbose: bool) -> Dict[str, Any]:
    """Run child command with live output streaming and full log capture."""
    logs_dir = SCRIPT_DIR / "logs" / "run_workloads"
    logs_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = logs_dir / f"{workload}_{stamp}.log"

    started = time.time()
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    emitted_count = 0
    with open(log_path, "w", encoding="utf-8", errors="ignore") as log_fh:
        assert process.stdout is not None
        for raw_line in process.stdout:
            log_fh.write(raw_line)
            line = raw_line.rstrip("\n")
            if verbose:
                print(f"    [{workload}] {line}")
                emitted_count += 1
            elif _should_emit_compact_line(line):
                print(f"    [{workload}] {line}")
                emitted_count += 1

    rc = process.wait()
    finished = time.time()

    if not verbose and emitted_count == 0:
        print(f"    [{workload}] (workload produced no compact log lines; see full log)")

    print(f"    [{workload}] Full log: {log_path}")
    return {
        "returncode": rc,
        "duration_sec": int(finished - started),
        "log_path": str(log_path),
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()

    config = load_config(args.config)
    settings = resolve_settings(config, args)
    workloads = settings["workloads"]

    validate_workloads(workloads)

    experiment_label = settings["experiment"] or datetime.now().strftime("exp_%Y%m%d")
    print(
        f"\n{_ANSI_CYAN}DCPerf run_workloads.py{_ANSI_RESET}\n"
        f"  Workloads : {', '.join(workloads)}\n"
        f"  Iterations: {settings['iterations']}\n"
        f"  EMON      : {'disabled' if settings['no_emon'] else 'enabled'}\n"
        f"  Experiment: {experiment_label}\n"
        f"  Dry-run   : {settings['dry_run']}\n"
    )

    if not DCPERF_RUN.exists():
        print(f"[ERROR] dcperf_run.py not found at {DCPERF_RUN}", file=sys.stderr)
        return 1

    any_fail = False
    workload_results: List[Dict[str, Any]] = []
    for idx, workload in enumerate(workloads, 1):
        cmd = build_workload_command(workload, settings)
        print(
            f"{_ANSI_CYAN}[{idx}/{len(workloads)}] Workload: {workload}{_ANSI_RESET}\n"
            f"  Command: {' '.join(cmd)}"
        )

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

        try:
            launched_at = time.time()
            run_meta = _run_child_live(cmd, workload, args.verbose_child_logs)
            result_rc = int(run_meta["returncode"])
            duration = int(run_meta["duration_sec"])
            summary_path = _find_latest_summary_json(launched_at)
            extracted = _extract_workload_summary(summary_path, VIDEO_TRANSCODE_VARIANT_MAP.get(workload, {}).get("workload", workload))
            status = extracted.get("status") or ("PASS" if result_rc == 0 else "FAIL")
            runs = extracted.get("runs", settings["iterations"])
            primary_kpi = extracted.get("primary_kpi", "--")

            if result_rc != 0:
                print(
                    f"  {_ANSI_YELLOW}[WARN] {workload} exited with code {result_rc} — "
                    f"continuing to next workload.{_ANSI_RESET}\n"
                )
                any_fail = True
            else:
                print(f"  {_ANSI_GREEN}[OK] {workload} completed.{_ANSI_RESET}\n")

            workload_results.append(
                {
                    "workload": workload,
                    "status": status,
                    "runs": runs,
                    "primary_kpi": primary_kpi,
                    "duration_sec": duration,
                    "exit_code": result_rc,
                }
            )
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

        if idx < len(workloads):
            print(
                f"  {_ANSI_CYAN}Sleeping {INTER_WORKLOAD_SLEEP_SECONDS}s before next workload...{_ANSI_RESET}\n"
            )
            time.sleep(INTER_WORKLOAD_SLEEP_SECONDS)

    if settings["dry_run"]:
        _render_final_table(workload_results)
        print(f"{_ANSI_CYAN}Dry-run complete. No workloads were executed.{_ANSI_RESET}")
        return 0

    _render_final_table(workload_results)

    if any_fail:
        print(f"\n{_ANSI_YELLOW}One or more workloads reported failures.{_ANSI_RESET}")
        return 1

    print(f"\n{_ANSI_GREEN}All workloads completed successfully.{_ANSI_RESET}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
