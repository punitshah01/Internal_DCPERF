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
import subprocess
import sys
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

_ANSI_GREEN = "\033[32m"
_ANSI_YELLOW = "\033[33m"
_ANSI_CYAN = "\033[36m"
_ANSI_RESET = "\033[0m"


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

    cmd: List[str] = [sys.executable, str(DCPERF_RUN), "--run-only", "--workload", workload]

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

    elif workload == "video_transcode_bench":
        runtime = wl_cfg.get("runtime")
        if runtime:
            cmd += ["--runtime", str(runtime)]

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
    unknown = [w for w in workloads if w not in ALL_WORKLOADS]
    if unknown:
        print(
            f"[ERROR] Unknown workload(s): {', '.join(unknown)}\n"
            f"  Supported: {', '.join(ALL_WORKLOADS)}",
            file=sys.stderr,
        )
        sys.exit(1)


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
    for idx, workload in enumerate(workloads, 1):
        cmd = build_workload_command(workload, settings)
        print(
            f"{_ANSI_CYAN}[{idx}/{len(workloads)}] Workload: {workload}{_ANSI_RESET}\n"
            f"  Command: {' '.join(cmd)}"
        )

        if settings["dry_run"]:
            print(f"  {_ANSI_YELLOW}(dry-run — skipping execution){_ANSI_RESET}\n")
            continue

        try:
            result = subprocess.run(cmd, check=False)
            if result.returncode != 0:
                print(
                    f"  {_ANSI_YELLOW}[WARN] {workload} exited with code {result.returncode} — "
                    f"continuing to next workload.{_ANSI_RESET}\n"
                )
                any_fail = True
            else:
                print(f"  {_ANSI_GREEN}[OK] {workload} completed.{_ANSI_RESET}\n")
        except Exception as exc:  # noqa: BLE001
            print(f"  [ERROR] Failed to launch {workload}: {exc}", file=sys.stderr)
            any_fail = True

    if settings["dry_run"]:
        print(f"{_ANSI_CYAN}Dry-run complete. No workloads were executed.{_ANSI_RESET}")
        return 0

    if any_fail:
        print(f"\n{_ANSI_YELLOW}One or more workloads reported failures.{_ANSI_RESET}")
        return 1

    print(f"\n{_ANSI_GREEN}All workloads completed successfully.{_ANSI_RESET}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
