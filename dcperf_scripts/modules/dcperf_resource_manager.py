"""Best-effort resource cleanup after each DCPerf workload run.

This is a second, independent safety net at the orchestration level
(wired into dcperf_run.py's _run_workload()), separate from the
per-workload OS-tuning baseline that wrappers/dcperf_base_wrapper.py +
modules/dcperf_os_tuner.py already capture/restore around pre_run()/
post_run(). That existing mechanism is untouched by this module. This
one additionally kills leftover workload daemons/ports, clears shared
memory and temp lock files, and re-asserts a small set of kernel
settings back to their pre-run values -- catching anything a crashed
or interrupted run left behind that the wrapper's own cleanup never
reached.

Real commands (pkill patterns, port release via fuser, sysctl restore,
ipcrm) were extracted from the same dj_perf.py/fs_perf.py/mw_perf.py/
sweep.py/vt_script.py lineage the rest of dcperf_scripts is built from.
"""

from __future__ import annotations

import atexit
import glob
import os
import re
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

_CLEANUP_TIMEOUT_SECONDS = 10
_THP_PROC_PATH = "/sys/kernel/mm/transparent_hugepage/enabled"

# vm.transparent_hugepage.enabled is not a real sysctl key -- THP is only
# controlled through this sysfs file, so it is special-cased in
# read_sysctl()/ResourceManager._restore_kernel_settings() below.
TRACKED_KERNEL_KEYS: List[str] = [
    "net.ipv4.tcp_tw_reuse",
    "vm.transparent_hugepage.enabled",
    "net.core.somaxconn",
    "net.ipv4.tcp_syncookies",
    "net.core.netdev_max_backlog",
]

# Per-workload daemon patterns to pkill after the run. Never touches other
# users' processes: pkill only matches within the caller's own reachable
# process set, and DCPerf only ever launches these as the current user.
_WORKLOAD_PROCESS_PATTERNS: Dict[str, List[List[str]]] = {
    "mediawiki": [["pkill", "nginx"], ["pkill", "hhvm"], ["pkill", "php-fpm"]],
    "feedsim": [["pkill", "-f", "feedsim"], ["pkill", "-f", "feed_server"]],
    "tao_bench": [["pkill", "-f", "tao_bench"], ["pkill", "memcached"]],
    "tao_bench_standalone": [["pkill", "-f", "tao_bench"], ["pkill", "memcached"]],
    "django_workload": [["pkill", "-f", "manage.py"], ["pkill", "uwsgi"], ["pkill", "memcached"]],
    "video_transcode_bench": [["pkill", "ffmpeg"]],
}

_WORKLOAD_PORTS: Dict[str, List[int]] = {
    "mediawiki": [80, 443, 9000],
    "feedsim": [11211, 8080],
    "tao_bench": [11211, 11212],
    "tao_bench_standalone": [11211, 11212],
    "django_workload": [8000, 11211],
}

_TEMP_FILE_PATTERNS = ["/tmp/dcperf_*.lock", "/tmp/dcperf_*.pid", "/tmp/dcperf_tmp_*"]


def _read_thp_mode(logger=None) -> Optional[str]:
    try:
        raw = Path(_THP_PROC_PATH).read_text().strip()
    except OSError:
        return None
    match = re.search(r"\[(\w+)\]", raw)
    return match.group(1) if match else None


def read_sysctl(key: str) -> Optional[str]:
    """Read one kernel setting: `sysctl -n <key>`, or the THP sysfs file."""
    if key == "vm.transparent_hugepage.enabled":
        return _read_thp_mode()
    try:
        result = subprocess.run(
            ["sysctl", "-n", key],
            capture_output=True,
            text=True,
            timeout=_CLEANUP_TIMEOUT_SECONDS,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.SubprocessError, OSError):
        pass
    return None


def _run(cmd: List[str]) -> int:
    """Run a cleanup command with a hard timeout, never raising."""
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=_CLEANUP_TIMEOUT_SECONDS
        ).returncode
    except subprocess.TimeoutExpired:
        return 124
    except OSError:
        return 127


class ResourceManager:
    """Context manager: kill/release everything a workload run may have left
    behind, exactly once, on normal exit, exception, or Ctrl+C."""

    def __init__(self, workload_name: str, config: Optional[Dict[str, Any]] = None):
        self.workload_name = workload_name
        self.config = config or {}
        self._processes: List[Tuple[Any, str]] = []
        self._ports: List[int] = []
        self._kernel_settings: Dict[str, Optional[str]] = {}
        self._emon_registered = False
        self._cleanup_done = False
        self._log: List[Tuple[str, str]] = []
        self._duration_sec = 0.0
        atexit.register(self.cleanup)

    def __enter__(self) -> "ResourceManager":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> bool:
        self.cleanup()
        return False  # never suppress exceptions

    # ------------------------------------------------------------------
    # Registration
    # ------------------------------------------------------------------

    def register_process(self, proc: Any, name: str) -> None:
        self._processes.append((proc, name))

    def register_port(self, port: int) -> None:
        self._ports.append(port)

    def register_kernel_setting(self, key: str, original_value: Optional[str]) -> None:
        self._kernel_settings[key] = original_value

    def register_emon(self) -> None:
        self._emon_registered = True

    # ------------------------------------------------------------------
    # Cleanup orchestration
    # ------------------------------------------------------------------

    def cleanup(self) -> None:
        if self._cleanup_done:
            return
        self._cleanup_done = True

        started = time.time()
        for step in (
            self._stop_emon,
            self._kill_processes,
            self._kill_workload_processes,
            self._release_ports,
            self._restore_kernel_settings,
            self._clean_shared_memory,
            self._clean_temp_files,
        ):
            try:
                step()
            except Exception as exc:  # noqa: BLE001 -- cleanup must never raise
                self._log.append(("fail", f"{step.__name__} crashed: {exc}"))
        self._duration_sec = time.time() - started
        self._print_cleanup_box()

    # ------------------------------------------------------------------
    # Step 1: EMON
    # ------------------------------------------------------------------

    def _stop_emon(self) -> None:
        if not self._emon_registered:
            return
        sep_path = self.config.get("sep_path") or (self.config.get("emon") or {}).get("sep_path") or "/opt/intel/sep"
        sep_vars = Path(str(sep_path)) / "sep_vars.sh"
        _run(["bash", "-lc", f"source {sep_vars} 2>/dev/null; emon -stop"])
        rc = _run(["pkill", "-f", "emon -collect"])
        if rc == 0:
            self._log.append(("ok", "EMON stopped"))
        elif rc == 1:
            self._log.append(("warn", "EMON was not running (ok)"))
        else:
            self._log.append(("fail", f"EMON stop failed (rc={rc})"))

    # ------------------------------------------------------------------
    # Step 2: explicitly registered processes
    # ------------------------------------------------------------------

    def _kill_processes(self) -> None:
        for proc, name in self._processes:
            if proc is None:
                continue
            try:
                if proc.poll() is not None:
                    self._log.append(("warn", f"{name} was not running (ok)"))
                    continue
                proc.terminate()
                try:
                    proc.wait(timeout=_CLEANUP_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    proc.kill()
                self._log.append(("ok", f"{name} killed"))
            except Exception as exc:
                self._log.append(("fail", f"{name} kill failed: {exc}"))

    # ------------------------------------------------------------------
    # Step 3: per-workload daemons by name/pattern
    # ------------------------------------------------------------------

    def _kill_workload_processes(self) -> None:
        if self.workload_name == "spark_standalone":
            self._stop_spark()
            return

        patterns = _WORKLOAD_PROCESS_PATTERNS.get(self.workload_name, [])
        killed: List[str] = []
        for cmd in patterns:
            label = cmd[-1]
            rc = _run(cmd)
            if rc == 0:
                killed.append(label)
            elif rc == 1:
                self._log.append(("warn", f"{label} was not running (ok)"))
            else:
                self._log.append(("fail", f"{label} cleanup failed (rc={rc})"))
        if killed:
            self._log.append(("ok", f"{' / '.join(killed)} killed"))

    def _stop_spark(self) -> None:
        spark_home = os.environ.get("SPARK_HOME")
        if not spark_home:
            self._log.append(("warn", "SPARK_HOME not set, stop-all.sh skipped (ok)"))
            return
        script = str(Path(spark_home) / "sbin" / "stop-all.sh")
        rc = _run([script])
        if rc == 0:
            self._log.append(("ok", "spark stop-all.sh completed"))
        else:
            self._log.append(("fail", f"spark stop-all.sh failed (rc={rc})"))

    # ------------------------------------------------------------------
    # Step 4: network ports
    # ------------------------------------------------------------------

    def _release_ports(self) -> None:
        ports = self._ports or _WORKLOAD_PORTS.get(self.workload_name, [])
        if not ports:
            return
        for port in ports:
            _run(["bash", "-lc", f"fuser -k {port}/tcp 2>/dev/null || true"])
        self._log.append(("ok", f"Ports {', '.join(str(p) for p in ports)} released"))

    # ------------------------------------------------------------------
    # Step 5: kernel settings
    # ------------------------------------------------------------------

    def _restore_kernel_settings(self) -> None:
        if not self._kernel_settings:
            return
        restored: List[str] = []
        for key, original in self._kernel_settings.items():
            if original is None:
                self._log.append(("warn", f"{key} original value unknown, skipped"))
                continue
            if key == "vm.transparent_hugepage.enabled":
                rc = _run(["bash", "-lc", f"echo {original} | sudo -n tee {_THP_PROC_PATH} >/dev/null"])
            else:
                rc = _run(["sudo", "-n", "sysctl", "-w", f"{key}={original}"])
            if rc == 0:
                restored.append(key)
            else:
                self._log.append(("fail", f"restore {key} failed (rc={rc})"))
        if restored:
            self._log.append(("ok", "Kernel settings restored"))

    # ------------------------------------------------------------------
    # Step 6: shared memory
    # ------------------------------------------------------------------

    def _clean_shared_memory(self) -> None:
        cmd = (
            "ipcs -m | awk 'NR>3 {print $2}' | xargs -r ipcrm -m; "
            "ipcs -s | awk 'NR>3 {print $2}' | xargs -r ipcrm -s"
        )
        rc = _run(["bash", "-lc", cmd])
        if rc == 0:
            self._log.append(("ok", "Shared memory cleaned"))
        else:
            self._log.append(("fail", f"Shared memory cleanup failed (rc={rc})"))

    # ------------------------------------------------------------------
    # Step 7: temp files / locks (never touches result directories)
    # ------------------------------------------------------------------

    def _clean_temp_files(self) -> None:
        removed_any = False
        for pattern in _TEMP_FILE_PATTERNS:
            for path in glob.glob(pattern):
                try:
                    p = Path(path)
                    if p.is_dir():
                        shutil.rmtree(p, ignore_errors=True)
                    else:
                        p.unlink(missing_ok=True)
                    removed_any = True
                except OSError as exc:
                    self._log.append(("fail", f"could not remove {path}: {exc}"))
        if removed_any:
            self._log.append(("ok", "Temp files removed"))
        else:
            self._log.append(("warn", "No temp files to remove (ok)"))

    # ------------------------------------------------------------------
    # Reporting
    # ------------------------------------------------------------------

    def _print_cleanup_box(self) -> None:
        symbol = {"ok": "\u2705", "warn": "\u26a0\ufe0f", "fail": "\u274c"}
        warn_count = sum(1 for state, _ in self._log if state == "warn")
        fail_count = sum(1 for state, _ in self._log if state == "fail")
        status = "COMPLETE" if fail_count == 0 else "INCOMPLETE"

        lines = [f"[CLEANUP] {self.workload_name} \u2014 Resource Release"]
        lines += [f"{symbol[state]} {message}" for state, message in self._log]
        lines.append(f"Status: {status}   Warnings: {warn_count}   Duration: {self._duration_sec:.1f}s")

        width = max(len(line) for line in lines) + 2
        top, mid, bot = "\u250c" + "\u2500" * width + "\u2510", "\u251c" + "\u2500" * width + "\u2524", "\u2514" + "\u2500" * width + "\u2518"
        print(top)
        print(f"\u2502 {lines[0].ljust(width - 1)}\u2502")
        print(mid)
        for line in lines[1:-1]:
            print(f"\u2502 {line.ljust(width - 1)}\u2502")
        print(mid)
        print(f"\u2502 {lines[-1].ljust(width - 1)}\u2502")
        print(bot)
