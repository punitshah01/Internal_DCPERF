"""OS tuning helpers extracted from dj_perf.py, fs_perf.py, mw_perf.py,
sweep.py, vt_script.py (tcp_tw_reuse, THP mode, drop_caches,
compact_memory, ulimit -n were copy-pasted across all 5 scripts).

Module-level functions only, every one dry_run aware and logging the
exact command before running it. No hardcoded values — all tunable
parameters come in as arguments.
"""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any, Dict, List


def _write_sysctl(path: str, value: str, logger, dry_run: bool) -> bool:
    cmd = f"echo {value} | sudo tee {path}"
    logger.info("os_tuner: %s", cmd)
    if dry_run:
        return True
    try:
        subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True)
        return True
    except subprocess.CalledProcessError as exc:
        logger.error("os_tuner: command failed (%s): %s", path, exc.stderr)
        return False


def drop_caches(logger, dry_run: bool = False) -> bool:
    """Drop page/dentry/inode caches (echo 3 > /proc/sys/vm/drop_caches)."""
    return _write_sysctl("/proc/sys/vm/drop_caches", "3", logger, dry_run)


def compact_memory(logger, dry_run: bool = False) -> bool:
    """Compact kernel memory (echo 1 > /proc/sys/vm/compact_memory)."""
    cmd = "sync; echo 1 | sudo tee /proc/sys/vm/compact_memory"
    logger.info("os_tuner: %s", cmd)
    if dry_run:
        return True
    try:
        subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True)
        return True
    except subprocess.CalledProcessError as exc:
        logger.error("os_tuner: compact_memory failed: %s", exc.stderr)
        return False


def set_thp(mode: str, logger, dry_run: bool = False) -> bool:
    """Set transparent hugepage mode: 'never' | 'always' | 'madvise'."""
    if mode not in ("never", "always", "madvise"):
        logger.error("os_tuner: invalid THP mode %r", mode)
        return False
    return _write_sysctl(
        "/sys/kernel/mm/transparent_hugepage/enabled", mode, logger, dry_run
    )


def set_tcp_reuse(logger, dry_run: bool = False) -> bool:
    """Enable TCP time-wait socket reuse."""
    return _write_sysctl("/proc/sys/net/ipv4/tcp_tw_reuse", "1", logger, dry_run)


def set_file_limits(limit: int, logger, dry_run: bool = False) -> bool:
    """Raise the open-file-descriptor ulimit for the current shell session."""
    cmd = f"ulimit -n {limit}"
    logger.info("os_tuner: %s", cmd)
    if dry_run:
        return True
    try:
        subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True)
        return True
    except subprocess.CalledProcessError as exc:
        logger.error("os_tuner: set_file_limits failed: %s", exc.stderr)
        return False


def _generic_tuning(logger, dry_run: bool = False, thp_mode: str = "madvise", file_limit: int = 655350) -> Dict[str, bool]:
    return {
        "drop_caches": drop_caches(logger, dry_run),
        "compact_memory": compact_memory(logger, dry_run),
        "set_thp": set_thp(thp_mode, logger, dry_run),
        "set_tcp_reuse": set_tcp_reuse(logger, dry_run),
        "set_file_limits": set_file_limits(file_limit, logger, dry_run),
    }


# ---------------------------------------------------------------------------
# Part B additions
# ---------------------------------------------------------------------------

def clear_tmp(logger, dry_run: bool = False, config: Dict[str, Any] = None) -> bool:
    """Run `rm -rf /tmp/*`. Only runs if config['clear_tmp'] is True; warns first."""
    config = config or {}
    if not config.get("clear_tmp", False):
        logger.info("os_tuner: clear_tmp skipped (config.clear_tmp is not true)")
        return True

    logger.warning("os_tuner: clearing /tmp/* — this deletes ALL files under /tmp")
    cmd = "rm -rf /tmp/*"
    logger.info("os_tuner: %s", cmd)
    if dry_run:
        return True
    try:
        subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True)
        return True
    except subprocess.CalledProcessError as exc:
        logger.error("os_tuner: clear_tmp failed: %s", exc.stderr)
        return False


def setup_hosts_file(entries: List[str], logger, dry_run: bool = False) -> bool:
    """Append 'ip hostname' entries to /etc/hosts if not already present."""
    hosts_path = Path("/etc/hosts")
    success = True
    try:
        existing = hosts_path.read_text() if hosts_path.exists() else ""
    except OSError as exc:
        logger.error("os_tuner: could not read /etc/hosts: %s", exc)
        return False

    for entry in entries:
        entry = entry.strip()
        if not entry or entry in existing:
            logger.info("os_tuner: /etc/hosts already contains %r, skipping", entry)
            continue
        cmd = f"echo '{entry}' | sudo tee -a /etc/hosts"
        logger.info("os_tuner: %s", cmd)
        if dry_run:
            continue
        try:
            subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as exc:
            logger.error("os_tuner: failed to add hosts entry %r: %s", entry, exc.stderr)
            success = False
    return success


def setup_known_hosts(entries: List[str], logger, dry_run: bool = False) -> bool:
    """Append entries to /root/.ssh/known_hosts if not already present."""
    known_hosts_path = Path("/root/.ssh/known_hosts")
    try:
        existing = known_hosts_path.read_text() if known_hosts_path.exists() else ""
    except OSError as exc:
        logger.error("os_tuner: could not read %s: %s", known_hosts_path, exc)
        existing = ""

    success = True
    for entry in entries:
        entry = entry.strip()
        if not entry or entry in existing:
            logger.info("os_tuner: known_hosts already contains entry, skipping")
            continue
        cmd = f"echo '{entry}' | sudo tee -a {known_hosts_path}"
        logger.info("os_tuner: %s", cmd)
        if dry_run:
            continue
        try:
            subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as exc:
            logger.error("os_tuner: failed to add known_hosts entry: %s", exc.stderr)
            success = False
    return success


def restart_dns(logger, dry_run: bool = False) -> bool:
    """Restart dnsmasq and nscd, logging the result of each independently."""
    success = True
    for service in ("dnsmasq", "nscd"):
        cmd = f"sudo systemctl restart {service}"
        logger.info("os_tuner: %s", cmd)
        if dry_run:
            continue
        try:
            subprocess.run(cmd.split(), check=True, capture_output=True, text=True)
            logger.info("os_tuner: %s restarted", service)
        except subprocess.CalledProcessError as exc:
            logger.error("os_tuner: failed to restart %s: %s", service, exc.stderr)
            success = False
    return success


# ---------------------------------------------------------------------------
# FIX 6: workload-specific tuning profiles
# ---------------------------------------------------------------------------

def _sysctl_w(setting: str, value: str, logger, dry_run: bool) -> bool:
    """Apply one setting via `sysctl -w <setting>=<value>` (check=True, no os.system)."""
    cmd = ["sudo", "sysctl", "-w", f"{setting}={value}"]
    logger.info("os_tuner: %s", " ".join(cmd))
    if dry_run:
        return True
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
        return True
    except subprocess.CalledProcessError as exc:
        logger.error("os_tuner: sysctl -w %s failed: %s", setting, exc.stderr)
        return False


def tune_tao_bench(logger, dry_run: bool = False) -> Dict[str, str]:
    """Apply the TaoBench networking/backlog tuning profile, in order.

    Note: the upstream reference listed `netdev_max_backlog` twice —
    deduplicated here to a single setting.
    """
    logger.info("os_tuner: tune_tao_bench — netdev_max_backlog listed twice upstream, applying once")

    settings = [
        ("net.core.netdev_max_backlog", "524288"),
        ("net.core.somaxconn", "524288"),
        ("net.ipv4.tcp_max_syn_backlog", "524288"),
        ("net.ipv4.ip_local_port_range", "1024 65535"),
        ("net.ipv4.tcp_tw_reuse", "1"),
        ("kernel.nmi_watchdog", "0"),
        ("net.core.rmem_max", "134217728"),
        ("net.core.wmem_max", "134217728"),
        # tcp_rmem/tcp_wmem require 3 space-separated values (min default max),
        # not a single scalar -- a bare "134217728" is rejected/misconfigured by sysctl.
        ("net.ipv4.tcp_rmem", "4096 87380 134217728"),
        ("net.ipv4.tcp_wmem", "4096 87380 134217728"),
        ("net.ipv4.tcp_syncookies", "0"),
        ("net.ipv4.tcp_abort_on_overflow", "1"),
        ("vm.drop_caches", "3"),
    ]
    results: Dict[str, str] = {}
    for setting, value in settings:
        results[setting] = "PASS" if _sysctl_w(setting, value, logger, dry_run) else "FAIL"
    results["ulimit_n"] = "PASS" if set_file_limits(1000000, logger, dry_run) else "FAIL"
    return results


def tune_feedsim(logger, dry_run: bool = False) -> Dict[str, str]:
    """Apply the FeedSim pre-run tuning profile."""
    results = {
        "tcp_tw_reuse": "PASS" if set_tcp_reuse(logger, dry_run) else "FAIL",
        "thp_madvise": "PASS" if set_thp("madvise", logger, dry_run) else "FAIL",
        "drop_caches": "PASS" if drop_caches(logger, dry_run) else "FAIL",
        "compact_memory": "PASS" if compact_memory(logger, dry_run) else "FAIL",
        "ulimit_n": "PASS" if set_file_limits(655350, logger, dry_run) else "FAIL",
    }
    return results


def tune_spark(logger, dry_run: bool = False) -> Dict[str, str]:
    """Spark has no pre-run tuning — cache/tmp cleanup happens post-run only.

    See tune_spark_post_run(). Kept as a routing target so apply_all() has a
    consistent per-workload entry point.
    """
    logger.info("os_tuner: tune_spark — no pre-run tuning for Spark, see tune_spark_post_run()")
    return {}


def tune_spark_post_run(logger, dry_run: bool = False) -> Dict[str, str]:
    """Post-run cache/tmp cleanup for Spark. Call from spark_wrapper.post_run()."""
    logger.info("os_tuner: Post-run cache cleanup for Spark")
    cmd_rm = "rm -rf /tmp/*"
    logger.info("os_tuner: %s", cmd_rm)
    rm_ok = True
    if not dry_run:
        try:
            subprocess.run(cmd_rm, shell=True, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as exc:
            logger.error("os_tuner: tune_spark_post_run rm failed: %s", exc.stderr)
            rm_ok = False

    cmd_drop = "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches"
    logger.info("os_tuner: %s", cmd_drop)
    drop_ok = True
    if not dry_run:
        try:
            subprocess.run(cmd_drop, shell=True, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as exc:
            logger.error("os_tuner: tune_spark_post_run drop_caches failed: %s", exc.stderr)
            drop_ok = False

    compact_ok = compact_memory(logger, dry_run)

    return {
        "rm_tmp": "PASS" if rm_ok else "FAIL",
        "drop_caches": "PASS" if drop_ok else "FAIL",
        "compact_memory": "PASS" if compact_ok else "FAIL",
    }


def tune_video_transcode(logger, dry_run: bool = False) -> Dict[str, str]:
    """Apply the video_transcode_bench pre-run tuning profile."""
    return {
        "thp_madvise": "PASS" if set_thp("madvise", logger, dry_run) else "FAIL",
        "drop_caches": "PASS" if drop_caches(logger, dry_run) else "FAIL",
        "compact_memory": "PASS" if compact_memory(logger, dry_run) else "FAIL",
        "ulimit_n": "PASS" if set_file_limits(655350, logger, dry_run) else "FAIL",
    }


def tune_django(logger, dry_run: bool = False) -> Dict[str, str]:
    """Apply the django_workload pre-run tuning profile."""
    return {
        "tcp_tw_reuse": "PASS" if set_tcp_reuse(logger, dry_run) else "FAIL",
        "thp_madvise": "PASS" if set_thp("madvise", logger, dry_run) else "FAIL",
        "drop_caches": "PASS" if drop_caches(logger, dry_run) else "FAIL",
        "compact_memory": "PASS" if compact_memory(logger, dry_run) else "FAIL",
        "ulimit_n": "PASS" if set_file_limits(655350, logger, dry_run) else "FAIL",
    }


# Workload name -> tuning function routing table for apply_all().
_WORKLOAD_TUNING_ROUTES = {
    "tao_bench": tune_tao_bench,
    "tao_bench_standalone": tune_tao_bench,
    "feedsim": tune_feedsim,
    "spark_standalone": tune_spark,
    "video_transcode_bench": tune_video_transcode,
    "django_workload": tune_django,
}
_NO_TUNING_WORKLOADS = {"health_check", "wdl_bench"}


def apply_all(workload: str, config: Dict[str, Any], logger, dry_run: bool = False) -> Dict[str, Any]:
    """Route to the correct per-workload tuning profile and run it.

    "mediawiki" and any unrecognized workload fall back to the original
    generic profile (drop_caches/compact_memory/THP/tcp_reuse/file limits).
    """
    if workload in _NO_TUNING_WORKLOADS:
        logger.info("os_tuner: apply_all — no tuning needed for %r", workload)
        return {}

    tuning_fn = _WORKLOAD_TUNING_ROUTES.get(workload)
    if tuning_fn is not None:
        return tuning_fn(logger, dry_run)

    if workload != "mediawiki":
        logger.warning("os_tuner: apply_all — unknown workload %r, applying generic tuning", workload)

    thp_mode = config.get("thp_mode", "madvise")
    file_limit = config.get("file_limit", 655350)
    return _generic_tuning(logger, dry_run, thp_mode=thp_mode, file_limit=file_limit)
