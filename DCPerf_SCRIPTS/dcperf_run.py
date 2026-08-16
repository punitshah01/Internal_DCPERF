#!/usr/bin/env python3
"""dcperf_run.py — single entry point for install + run + report.

Usage:
    python dcperf_run.py --all
    python dcperf_run.py --install-only
    python dcperf_run.py --run-only
    python dcperf_run.py --workload tao_bench
    python dcperf_run.py --dry-run --all
    python dcperf_run.py --resume
    python dcperf_run.py --emon --all
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import socket
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple, Type

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))
if str(SCRIPT_DIR / "wrappers") not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR / "wrappers"))

from modules.dcperf_config_manager import ConfigManager, detect_distro
from modules.dcperf_logger import get_logger
from modules.dcperf_result_manager import ResultManager, collect_dcperf_score

# Wrapper classes are imported via the `wrappers.` package path, but each
# wrapper module itself resolves its `BaseWrapper` base class through a
# bare (non-package) import of modules/wrappers/dcperf_base_wrapper.py —
# see the sys.path handling at the top of every wrappers/*.py file. Avoid a
# second, distinct `wrappers.dcperf_base_wrapper` import here so
# isinstance/class-identity stays consistent with the one actually used by
# the wrapper subclasses.
from wrappers.dcperf_django_wrapper import DjangoWrapper
from wrappers.dcperf_feedsim_wrapper import FeedsimWrapper
from wrappers.dcperf_health_check_wrapper import HealthCheckWrapper
from wrappers.dcperf_mediawiki_wrapper import MediaWikiWrapper
from wrappers.dcperf_spark_wrapper import SparkWrapper
from wrappers.dcperf_tao_bench_wrapper import TaoBenchWrapper
from wrappers.dcperf_video_transcode_wrapper import VideoWrapper
from wrappers.dcperf_wdl_bench_wrapper import WdlBenchWrapper

# Single source of truth: workload name -> wrapper class. Adding a new
# workload only requires one new entry here (plus its wrapper file).
WORKLOAD_REGISTRY: Dict[str, Type[Any]] = {
    "health_check": HealthCheckWrapper,
    "django_workload": DjangoWrapper,
    "feedsim": FeedsimWrapper,
    "mediawiki": MediaWikiWrapper,
    "spark_standalone": SparkWrapper,
    "video_transcode_bench": VideoWrapper,
    "tao_bench": TaoBenchWrapper,
    "wdl_bench": WdlBenchWrapper,
}

_INSTALL_MARKER_FILE = SCRIPT_DIR / "dcperf_install_state.txt"
_OS_PREREQS_MARKER_FILE = SCRIPT_DIR / "os_prereqs_installed.txt"
_shutdown_requested = False
_MIN_PYTHON = (3, 8)
_MIN_FREE_DISK_GB = 100

_ANSI_GREEN = "\033[32m"
_ANSI_YELLOW = "\033[33m"
_ANSI_RED = "\033[31m"
_ANSI_RESET = "\033[0m"


def _signal_handler(signum, frame):
    global _shutdown_requested
    print(f"\nReceived signal {signum}; finishing current workload then stopping...")
    _shutdown_requested = True


signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)


def _read_installed_jobs() -> List[str]:
    if not _INSTALL_MARKER_FILE.exists():
        return []
    return [line.strip() for line in _INSTALL_MARKER_FILE.read_text().splitlines() if line.strip()]


def _mark_installed(job_name: str) -> None:
    installed = set(_read_installed_jobs())
    installed.add(job_name)
    _INSTALL_MARKER_FILE.write_text("\n".join(sorted(installed)) + "\n")


def _unmark_installed(job_name: str) -> None:
    installed = set(_read_installed_jobs())
    installed.discard(job_name)
    _INSTALL_MARKER_FILE.write_text("\n".join(sorted(installed)) + "\n" if installed else "")


# ---------------------------------------------------------------------------
# Per-OS prerequisite installation (official README "Install Prerequisites")
# ---------------------------------------------------------------------------

_OS_PREREQ_COMMANDS: Dict[str, List[List[str]]] = {
    "centos8": [
        ["dnf", "install", "-y", "python38", "python38-pip", "git"],
        ["alternatives", "--set", "python3", "/usr/bin/python3.8"],
        ["pip-3.8", "install", "click", "pyyaml", "tabulate", "pandas"],
        ["dnf", "install", "-y", "epel-release"],
        ["dnf", "install", "-y", "dnf-command(config-manager)"],
        ["dnf", "config-manager", "--set-enabled", "PowerTools"],
    ],
    "centos9": [
        ["dnf", "install", "-y", "epel-release"],
        ["dnf", "install", "-y", "dnf-command(config-manager)"],
        ["dnf", "config-manager", "--set-enabled", "crb"],
        ["dnf", "install", "-y", "git", "python3-click", "python3-pyyaml", "python3-tabulate", "python3-pip", "xz-devel"],
        ["pip-3.9", "install", "pandas"],
    ],
    "ubuntu": [
        ["sudo", "apt", "update"],
        ["sudo", "apt", "install", "-y", "python3-pip", "git"],
        ["sudo", "pip3", "install", "click", "pyyaml", "tabulate", "pandas"],
    ],
}


def install_os_prerequisites(logger, dry_run: bool, resume: bool) -> bool:
    """Run the official per-OS prerequisite install sequence (README "Install
    Prerequisites" section) for CentOS Stream 8/9 or Ubuntu 22.04.

    Idempotent across master_setup invocations via a marker file, same
    pattern as _read_installed_jobs()/_mark_installed().
    """
    if resume and _OS_PREREQS_MARKER_FILE.exists():
        logger.info("master_setup: OS prerequisites already installed, skipping (--resume)")
        return True

    distro = detect_distro()
    commands = _OS_PREREQ_COMMANDS.get(distro)
    if commands is None:
        logger.warning("master_setup: unrecognized/unsupported OS (%s), skipping OS prerequisite install", distro)
        return True

    logger.info("master_setup: installing OS prerequisites for %s", distro)
    ok = True
    for cmd in commands:
        logger.info("master_setup: %s", " ".join(cmd))
        if dry_run:
            continue
        try:
            subprocess.run(cmd, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as exc:
            logger.error("master_setup: OS prerequisite command failed: %s: %s", " ".join(cmd), exc.stderr)
            ok = False

    if ok and not dry_run:
        _OS_PREREQS_MARKER_FILE.write_text(f"{distro}\n")
    return ok


def _check_benchmark_installer(dcperf_root: str, workload: str, logger) -> bool:
    """Fail early when the DCPerf checkout lacks the installer referenced by benchmarks.yml."""
    benchmark_file = Path(dcperf_root) / "benchpress" / "config" / "benchmarks.yml"
    if not benchmark_file.exists():
        logger.error("master_setup: benchmarks.yml is missing: %s", benchmark_file)
        return False

    expected = {
        "health_check": "packages/health_check/install_health_check.sh",
        "mediawiki": "packages/mediawiki/install_oss_performance_mediawiki.sh",
    }.get(workload)
    if expected is None:
        return True

    installer = Path(dcperf_root) / expected
    if installer.exists():
        return True

    logger.error(
        "master_setup: DCPerf checkout is incomplete for %s: missing %s. "
        "Update the DCPerf source checkout (not only DCPerf_SCRIPTS) before retrying.",
        workload, installer,
    )
    return False


# ---------------------------------------------------------------------------
# PART C: preflight checks
# ---------------------------------------------------------------------------

def _colorize(status: str) -> str:
    if not sys.stdout.isatty():
        return status
    color = {"PASS": _ANSI_GREEN, "WARN": _ANSI_YELLOW, "FAIL": _ANSI_RED}.get(status, "")
    return f"{color}{status}{_ANSI_RESET}" if color else status


def _check_python_version() -> Tuple[str, str]:
    ver = sys.version_info
    ver_str = f"{ver.major}.{ver.minor}.{ver.micro}"
    return ("PASS", ver_str) if (ver.major, ver.minor) >= _MIN_PYTHON else ("FAIL", ver_str)


def _check_sudo_access() -> Tuple[str, str]:
    try:
        result = subprocess.run(["sudo", "-n", "true"], capture_output=True, text=True)
        return ("PASS", "") if result.returncode == 0 else ("FAIL", "sudo -n true failed")
    except OSError as exc:
        return "FAIL", str(exc)


def _check_dcperf_root(config: Dict[str, Any]) -> Tuple[str, str]:
    root = config.get("dcperf_root")
    if not root or not Path(root).exists():
        return "FAIL", str(root or "not found")
    return "PASS", str(root)


def _check_path_exists(root: Optional[str], rel_path: str) -> Tuple[str, str]:
    if not root:
        return "FAIL", "dcperf_root unknown"
    path = Path(root) / rel_path
    return ("PASS", str(path)) if path.exists() else ("FAIL", f"{path} missing")


def _check_sep_available(config: Dict[str, Any]) -> Tuple[str, str]:
    sep_path = config.get("sep_path")
    if sep_path and (Path(sep_path) / "sep_vars.sh").exists():
        return "PASS", str(sep_path)
    return "WARN", f"{sep_path or '/opt/intel/sep'} missing"


def _check_internet() -> Tuple[str, str]:
    try:
        with socket.create_connection(("github.com", 443), timeout=5):
            return "PASS", ""
    except OSError as exc:
        return "WARN", str(exc)


def _check_free_disk(config: Dict[str, Any]) -> Tuple[str, str]:
    target = config.get("dcperf_root") or str(SCRIPT_DIR)
    free_gb = shutil.disk_usage(target).free / (1024 ** 3)
    status = "PASS" if free_gb >= _MIN_FREE_DISK_GB else "WARN"
    return status, f"{free_gb:.0f}GB available"


def _check_config_complete(config: Dict[str, Any]) -> Tuple[str, str]:
    required = ["emon_event_file", "emon_user", "spark_data_path", "db_client_ip", "video_dataset_path"]
    missing = [k for k in required if not config.get(k)]
    if missing:
        return "WARN", f"missing: {', '.join(missing)}"
    return "PASS", ""


def _check_proc_sys_writable() -> Tuple[str, str]:
    try:
        result = subprocess.run(
            ["sudo", "-n", "test", "-w", "/proc/sys/vm/drop_caches"],
            capture_output=True, text=True,
        )
        return ("PASS", "") if result.returncode == 0 else ("FAIL", "/proc/sys not writable via sudo")
    except OSError as exc:
        return "FAIL", str(exc)


def _check_thp_writable() -> Tuple[str, str]:
    thp_path = Path("/sys/kernel/mm/transparent_hugepage/enabled")
    if not thp_path.exists():
        return "WARN", "THP interface not present on this kernel"
    try:
        result = subprocess.run(["sudo", "-n", "test", "-w", str(thp_path)], capture_output=True, text=True)
        return ("PASS", "") if result.returncode == 0 else ("FAIL", f"{thp_path} not writable via sudo")
    except OSError as exc:
        return "FAIL", str(exc)


def _check_ulimit_n() -> Tuple[str, str]:
    try:
        import resource
        soft, _hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        return "INFO", str(soft)
    except Exception as exc:
        return "INFO", f"unknown ({exc})"


def _run_benchpress_system_check(config: Dict[str, Any], logger, dry_run: bool) -> Tuple[str, str]:
    """Run the official `./benchpress_cli.py system_check` and surface its output.

    This covers BIOS/NIC/BMC firmware, SELinux status, nvme-tcp module,
    THP, NUMA, Turbo Boost, memory speed, base frequency and SMT -- none of
    which our own ad hoc preflight checks duplicate or replace.
    """
    dcperf_root = config.get("dcperf_root")
    if not dcperf_root:
        return "WARN", "dcperf_root not configured, cannot run system_check"

    cli = Path(dcperf_root) / "benchpress_cli.py"
    if not cli.exists():
        return "WARN", f"{cli} not found"

    cmd = [sys.executable, str(cli), "system_check"]
    logger.info("preflight: %s", " ".join(cmd))
    if dry_run:
        return "PASS", "[dry-run] not executed"

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60, cwd=dcperf_root)
    except (subprocess.SubprocessError, OSError) as exc:
        return "WARN", f"system_check failed to run: {exc}"

    if result.stdout:
        print(result.stdout)
        logger.info("preflight: benchpress system_check output:\n%s", result.stdout)
    if result.returncode != 0:
        return "WARN", f"system_check exited {result.returncode}"
    return "PASS", ""


def run_preflight_checks(config: Dict[str, Any], logger, dry_run: bool) -> bool:
    """Print the DCPerf Preflight Check table; return False only if the user
    declines to continue after a FAIL (dry-run always continues).
    """
    dcperf_root = config.get("dcperf_root")
    rows: List[Tuple[str, str, str]] = []

    def add(name: str, status_value: Tuple[str, str]) -> None:
        status, detail = status_value
        rows.append((name, status, detail))

    add("Python version >= 3.8", _check_python_version())
    add("sudo access", _check_sudo_access())
    add("DCPerf root found", _check_dcperf_root(config))
    add("benchmarks.yml exists", _check_path_exists(dcperf_root, "benchpress/config/benchmarks.yml"))
    add("benchpress_cli.py exists", _check_path_exists(dcperf_root, "benchpress_cli.py"))
    add("SEP/EMON available", _check_sep_available(config))
    add("Internet connectivity", _check_internet())
    add("Free disk >= 100GB", _check_free_disk(config))
    add("config complete", _check_config_complete(config))
    add("/proc/sys writable (sudo)", _check_proc_sys_writable())
    add("/sys/kernel/mm/thp writable", _check_thp_writable())
    add("ulimit -n current value", _check_ulimit_n())
    add("benchpress system_check", _run_benchpress_system_check(config, logger, dry_run))

    name_width = max(len(r[0]) for r in rows) + 2
    print("=" * 64)
    print("DCPerf Preflight Check")
    print("-" * 64)
    for name, status, detail in rows:
        detail_str = f" {detail}" if detail else ""
        print(f"{name.ljust(name_width)}: {_colorize(status)}{detail_str}")
    print("=" * 64)

    any_fail = any(status == "FAIL" for _, status, _ in rows)
    for _, status, detail in rows:
        if status == "WARN":
            logger.warning("preflight: %s", detail)

    if any_fail:
        if dry_run:
            logger.warning("preflight: FAIL(s) detected but --dry-run set, continuing")
            return True
        answer = input("One or more preflight checks FAILED. Continue anyway? (y/n): ").strip().lower()
        return answer == "y"

    return True


def _install_workload(workload: str, wrapper_cls: Type[Any], config: Dict[str, Any], logger, dry_run: bool, resume: bool, force: bool = False) -> bool:
    job_name = wrapper_cls.JOB_NAME

    if force:
        logger.info("master_setup: Force reinstalling %s", workload)
        if not dry_run:
            _unmark_installed(job_name)
    elif resume and job_name in _read_installed_jobs():
        logger.info("master_setup: %s already installed, skipping (--resume)", workload)
        return True

    dcperf_root = config.get("dcperf_root")
    if not dcperf_root:
        logger.error("master_setup: dcperf_root not configured, cannot install %s", workload)
        return False

    if not _check_benchmark_installer(dcperf_root, workload, logger):
        return False

    # Workload-specific pre-install patches/prerequisite checks (FeedSim
    # gengetopt fallback, TaoBench packages, Spark prerequisite sequence...).
    hook_argv = ["--dry-run"] if dry_run else []
    if force:
        hook_argv.append("--force")
    try:
        hook_wrapper = wrapper_cls(hook_argv)
        if not hook_wrapper.pre_install_hook():
            logger.error("master_setup: pre_install_hook failed for %s", workload)
            return False
    except Exception as exc:
        logger.error("master_setup: pre_install_hook raised for %s: %s", workload, exc)
        return False

    cli = Path(dcperf_root) / "benchpress_cli.py"
    cmd = [sys.executable, str(cli), "install"]
    if force:
        cmd.append("-f")
    cmd.append(job_name)
    logger.info("master_setup: install: %s", " ".join(cmd))

    if dry_run:
        return True

    try:
        subprocess.run(cmd, check=True, start_new_session=True, cwd=dcperf_root)
        _mark_installed(job_name)
        return True
    except subprocess.CalledProcessError as exc:
        logger.error("master_setup: install failed for %s: %s", workload, exc)
        return False


def _run_workload(workload: str, wrapper_cls: Type[Any], extra_argv: List[str]) -> Dict[str, Any]:
    wrapper = wrapper_cls(extra_argv)
    if getattr(wrapper.args, "core_scaling", False) and hasattr(wrapper, "run_core_scaling"):
        rc = wrapper.run_core_scaling()
    else:
        rc = wrapper.run()

    status = "PASS" if rc == 0 else "FAIL"
    primary_kpi = "--"
    if wrapper._rows:
        kpis = wrapper._rows[-1].get("kpis", {})
        if kpis:
            first_key = next(iter(kpis))
            primary_kpi = f"{kpis[first_key]} {first_key}"

    return {
        "workload": workload,
        "status": status,
        "runs": len(wrapper._rows),
        "primary_kpi": primary_kpi,
        "output_dir": str(wrapper.run_dir) if wrapper.run_dir else "",
    }


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="DCPerf master install/run/report entry point")
    parser.add_argument("--all", action="store_true", help="Install and run every registered workload")
    parser.add_argument("--install-only", action="store_true", help="Only run benchpress install for selected workloads")
    parser.add_argument("--run-only", action="store_true", help="Only run selected workloads (skip install)")
    parser.add_argument("--workload", action="append", default=[], choices=list(WORKLOAD_REGISTRY.keys()), help="Select one workload (repeatable)")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without executing")
    parser.add_argument("--resume", action="store_true", help="Skip already-installed workloads")
    parser.add_argument("--emon", action="store_true", help="Enable EMON telemetry for all selected workloads")
    parser.add_argument("--force", "-f", action="store_true", help="Force reinstall: remove from dcperf_install_state.txt and pass -f to benchpress_cli.py install")
    return parser


def _selected_workloads(args: argparse.Namespace) -> List[str]:
    if args.workload:
        selected = list(args.workload)
    else:
        selected = list(WORKLOAD_REGISTRY.keys())

    # health_check always runs first, per contract.
    if "health_check" in selected:
        selected.remove("health_check")
    return ["health_check"] + selected


def main() -> int:
    args = build_arg_parser().parse_args()
    logger = get_logger("dcperf_master_setup", SCRIPT_DIR / "logs")

    config_manager = ConfigManager(SCRIPT_DIR / "config" / "dcperf_config.yaml", logger)
    config = config_manager.load()

    if not run_preflight_checks(config, logger, args.dry_run):
        logger.error("master_setup: preflight checks failed and user declined to continue")
        return 1

    do_install = args.all or args.install_only
    do_run = args.all or args.run_only or (not args.install_only)

    if do_install:
        if not install_os_prerequisites(logger, args.dry_run, args.resume):
            logger.error("master_setup: OS prerequisite installation failed")
            return 1

    workloads = _selected_workloads(args)
    result_manager = ResultManager(
        Path(config.get("results_base_dir") or (SCRIPT_DIR / "results")), logger,
    )

    all_results: List[Dict[str, Any]] = []

    for workload in workloads:
        if _shutdown_requested:
            logger.warning("master_setup: shutdown requested, stopping before %s", workload)
            break

        wrapper_cls = WORKLOAD_REGISTRY[workload]

        if do_install:
            ok = _install_workload(workload, wrapper_cls, config, logger, args.dry_run, args.resume, args.force)
            if not ok and not args.dry_run:
                all_results.append({"workload": workload, "status": "FAIL", "runs": 0, "primary_kpi": "install failed"})
                continue
            if not do_run:
                all_results.append({"workload": workload, "status": "PASS", "runs": 0, "primary_kpi": "installed"})

        if not do_run:
            continue

        extra_argv: List[str] = []
        if args.dry_run:
            extra_argv.append("--dry-run")
        if args.emon:
            extra_argv.append("--emon")

        result = _run_workload(workload, wrapper_cls, extra_argv)
        all_results.append(result)

    dcperf_score: Dict[str, Any] = {}
    if do_run and not args.dry_run:
        dcperf_score = collect_dcperf_score(config.get("dcperf_root"), logger)

    result_manager.write_summary(all_results, dcperf_score)
    print(f"Results Directory: {result_manager.base_results_dir / result_manager.timestamp}")

    any_fail = any(r.get("status") != "PASS" for r in all_results)
    return 1 if any_fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
