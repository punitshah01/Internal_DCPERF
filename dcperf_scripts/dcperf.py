#!/usr/bin/env python3
"""Unified DCPerf CLI entry point."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from modules.dcperf_config_loader import ConfigError, WORKLOADS, load_config
from modules.dcperf_logger import get_logger
from modules.dcperf_os_tuner import drop_caches, set_thp
from modules.dcperf_system_check import detect_system

EXIT_SUCCESS = 0
EXIT_ERROR = 1
EXIT_CONFIG_ERROR = 2
EXIT_SYSTEM_CHECK_FAIL = 3


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dcperf", description="Unified DCPerf CLI")
    parser.add_argument(
        "--config",
        type=Path,
        default=SCRIPT_DIR / "config" / "dcperf_config.yaml",
        help="Path to unified DCPerf config file",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="Run one or more workloads")
    run.add_argument("--workload", action="append", choices=WORKLOADS, help="Workload to run (repeatable)")
    run.add_argument("--all", action="store_true", help="Run all supported workloads")
    run.add_argument("--iterations", type=int, help="Runs per workload")
    run.add_argument("--experiment", type=str, help="Experiment name")
    run.add_argument("--dry-run", action="store_true", help="Print resolved command and skip execution")
    run.add_argument("--emon", action="store_true", help="Enable EMON telemetry")
    run.add_argument("--upload-tmc", action="store_true", help="Enable EMON upload to TMC")

    check = sub.add_parser("check", help="Run system checks")
    check.add_argument("--strict", action="store_true", help="Fail if warnings are detected")

    tune = sub.add_parser("tune", help="Run OS tuning from config")
    tune.add_argument("--dry-run", action="store_true", help="Log actions without applying")

    sub.add_parser("list", help="List available workloads")

    results = sub.add_parser("results", help="Show results summary")
    results.add_argument("--experiment", required=True, help="Experiment name to summarize")

    config = sub.add_parser("config", help="Configuration helpers")
    config_group = config.add_mutually_exclusive_group(required=True)
    config_group.add_argument("--show", action="store_true", help="Show effective config")
    config_group.add_argument("--validate", action="store_true", help="Validate config")

    return parser


def _cli_overrides(args: argparse.Namespace) -> Dict[str, Any]:
    overrides: Dict[str, Any] = {}
    if getattr(args, "experiment", None):
        overrides["global.experiment_name"] = args.experiment
    if getattr(args, "dry_run", False):
        overrides["global.dry_run"] = True
    if getattr(args, "iterations", None) is not None:
        overrides["default_runs"] = args.iterations
    return overrides


def _resolve_workloads(args: argparse.Namespace, config: Dict[str, Any]) -> List[str]:
    if getattr(args, "all", False):
        return WORKLOADS.copy()
    if getattr(args, "workload", None):
        return list(args.workload)
    enabled = config.get("workloads", {}).get("enabled", [])
    return [str(w) for w in enabled]


def _run_command(args: argparse.Namespace, config: Dict[str, Any], logger) -> int:
    workloads = _resolve_workloads(args, config)
    if not workloads:
        raise ConfigError("No workloads selected. Use --workload, --all, or configure workloads.enabled")

    cmd: List[str] = [sys.executable, str(SCRIPT_DIR / "dcperf_run.py"), "--run-only"]
    for workload in workloads:
        cmd.extend(["--workload", workload])

    runs = args.iterations if args.iterations is not None else int(config.get("default_runs", 1))
    if runs <= 0:
        raise ConfigError("iterations/default_runs must be greater than zero")
    cmd.extend(["--runs", str(runs)])

    experiment = args.experiment or config.get("global", {}).get("experiment_name")
    if experiment:
        cmd.extend(["--experiment", str(experiment)])

    if args.dry_run or config.get("global", {}).get("dry_run"):
        cmd.append("--dry-run")
    if args.emon or config.get("emon", {}).get("enabled"):
        cmd.append("--emon")
    if args.upload_tmc or config.get("tmc", {}).get("enabled"):
        cmd.append("--upload-emon")

    logger.info("Executing: %s", " ".join(cmd))
    result = subprocess.run(cmd, check=False)
    if result.returncode != 0:
        logger.error("Run command failed with exit code %s", result.returncode)
    return result.returncode


def _check_command(args: argparse.Namespace, config: Dict[str, Any], logger) -> int:
    _ = config
    info = detect_system(logger)

    failures: List[str] = []
    warnings: List[str] = []

    if not info.has_sudo:
        failures.append("sudo access is required")
    if info.logical_cores <= 0:
        failures.append("logical core detection failed")
    if info.total_ram_gb <= 0:
        warnings.append("memory detection failed")
    if not info.has_internet:
        warnings.append("internet connectivity is unavailable")

    if args.strict and warnings:
        failures.extend(warnings)

    if failures:
        for failure in failures:
            logger.error("system_check: %s", failure)
        return EXIT_SYSTEM_CHECK_FAIL

    for warning in warnings:
        logger.warning("system_check: %s", warning)
    logger.info("system_check: PASS")
    return EXIT_SUCCESS


def _tune_command(args: argparse.Namespace, config: Dict[str, Any], logger) -> int:
    tuning_cfg = config.get("os_tuning", {})
    if not tuning_cfg.get("enabled", True):
        logger.info("os_tuning disabled in config")
        return EXIT_SUCCESS

    dry_run = args.dry_run or config.get("global", {}).get("dry_run", False)
    success = True

    thp_mode = tuning_cfg.get("thp", "madvise")
    success = set_thp(thp_mode, logger, dry_run=dry_run) and success

    if tuning_cfg.get("drop_caches", True):
        success = drop_caches(logger, dry_run=dry_run) and success

    if success:
        logger.info("OS tuning completed")
        return EXIT_SUCCESS

    logger.error("OS tuning failed")
    return EXIT_ERROR


def _list_command(config: Dict[str, Any], logger) -> int:
    enabled = set(config.get("workloads", {}).get("enabled", []))
    for workload in WORKLOADS:
        marker = "enabled" if workload in enabled else "disabled"
        logger.info("%s [%s]", workload, marker)
    return EXIT_SUCCESS


def _results_command(args: argparse.Namespace, config: Dict[str, Any], logger) -> int:
    base_dir = Path(config.get("global", {}).get("results_dir") or config.get("results_base_dir") or (SCRIPT_DIR / "results"))
    experiment = args.experiment.strip().lower().replace(" ", "_")

    if not base_dir.exists():
        logger.error("Results directory does not exist: %s", base_dir)
        return EXIT_ERROR

    summary: Dict[str, int] = {}
    for workload_dir in base_dir.iterdir():
        if not workload_dir.is_dir():
            continue
        exp_dir = workload_dir / experiment
        if not exp_dir.exists():
            continue
        sessions = [p for p in exp_dir.glob("session_*") if p.is_dir()]
        summary[workload_dir.name] = len(sessions)

    if not summary:
        logger.warning("No sessions found for experiment '%s' under %s", experiment, base_dir)
        return EXIT_SUCCESS

    logger.info("Results summary for experiment '%s'", experiment)
    for workload in sorted(summary):
        logger.info("%s: %d session(s)", workload, summary[workload])
    return EXIT_SUCCESS


def _config_command(args: argparse.Namespace, config: Dict[str, Any], logger) -> int:
    if args.show:
        print(yaml.safe_dump(config, sort_keys=False))
        return EXIT_SUCCESS
    if args.validate:
        logger.info("Config validation passed")
        return EXIT_SUCCESS
    return EXIT_ERROR


def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()

    try:
        config = load_config(args.config, cli_overrides=_cli_overrides(args))
    except FileNotFoundError:
        print(f"Configuration file not found: {args.config}", file=sys.stderr)
        return EXIT_CONFIG_ERROR
    except ConfigError as exc:
        print(f"Configuration error: {exc}", file=sys.stderr)
        return EXIT_CONFIG_ERROR
    except Exception as exc:  # noqa: BLE001
        print(f"Failed to load configuration: {exc}", file=sys.stderr)
        return EXIT_CONFIG_ERROR

    log_level = config.get("global", {}).get("log_level", "INFO")
    experiment = config.get("global", {}).get("experiment_name", "default")
    log_dir = Path(config.get("global", {}).get("results_dir", SCRIPT_DIR / "results")) / "logs"
    logger = get_logger("dcperf", log_dir, log_level=log_level, experiment=experiment)

    try:
        if args.command == "run":
            return _run_command(args, config, logger)
        if args.command == "check":
            return _check_command(args, config, logger)
        if args.command == "tune":
            return _tune_command(args, config, logger)
        if args.command == "list":
            return _list_command(config, logger)
        if args.command == "results":
            return _results_command(args, config, logger)
        if args.command == "config":
            return _config_command(args, config, logger)
    except ConfigError as exc:
        logger.error("Configuration error: %s", exc)
        return EXIT_CONFIG_ERROR
    except subprocess.SubprocessError as exc:
        logger.error("Command execution failed: %s", exc)
        return EXIT_ERROR
    except OSError as exc:
        logger.error("System error: %s", exc)
        return EXIT_ERROR
    except Exception as exc:  # noqa: BLE001
        logger.error("Unexpected error: %s", exc)
        return EXIT_ERROR

    return EXIT_ERROR


if __name__ == "__main__":
    raise SystemExit(main())
