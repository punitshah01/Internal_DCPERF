"""Linux ``perf`` collector — implements the missing collect_perf.sh contract.

dj_perf.py / fs_perf.py / mw_perf.py called ``bash collect_perf.sh <logs_dir>
<ramp_log_file> "<ramp_string>" <session_name> <perf_duration>
<perf_start_delay> &`` — a script that never existed in the repo. Based on
those call sites and the matching EMON ``-rs/-rt`` ramp-detection pattern
used elsewhere in the same scripts, the intended behavior was: wait for a
ramp marker string to appear in the workload's live log, wait an additional
start delay, then run ``perf record`` for a fixed duration into the run's
output directory.
"""

from __future__ import annotations

import shutil
import signal
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

_perf_process: Optional[subprocess.Popen] = None


def _install_signal_handlers() -> None:
    previous_sigint = signal.getsignal(signal.SIGINT)
    previous_sigterm = signal.getsignal(signal.SIGTERM)

    def _handler(signum, frame):
        global _perf_process
        if _perf_process is not None and _perf_process.poll() is None:
            try:
                _perf_process.terminate()
                _perf_process.wait(timeout=10)
            except Exception:
                try:
                    _perf_process.kill()
                except Exception:
                    pass
            _perf_process = None
        if callable(previous_sigint) and signum == signal.SIGINT:
            previous_sigint(signum, frame)
        elif callable(previous_sigterm) and signum == signal.SIGTERM:
            previous_sigterm(signum, frame)
        raise SystemExit(130)

    signal.signal(signal.SIGINT, _handler)
    signal.signal(signal.SIGTERM, _handler)


_install_signal_handlers()


class PerfCollector:
    """Runs ``perf record`` for a bounded window during a workload run."""

    def __init__(self, config: Dict[str, Any], logger, dry_run: bool = False):
        self.config = config
        self.logger = logger
        self.dry_run = dry_run

    def is_available(self) -> bool:
        """Return True if the ``perf`` binary is on PATH."""
        return shutil.which("perf") is not None

    def wait_for_ramp(self, ramp_log_file: str, ramp_string: str, timeout: int) -> bool:
        """Tail-follow ramp_log_file until ramp_string appears or timeout elapses.

        Replaces ``tmc -rl/-rs/-rt`` ramp detection used by the original scripts.
        """
        self.logger.info(
            "perf_collector: waiting for ramp marker %r in %s (timeout=%ss)",
            ramp_string, ramp_log_file, timeout,
        )
        if self.dry_run:
            return True

        deadline = time.time() + timeout
        path = Path(ramp_log_file)
        # Keep an open file handle and only read newly appended bytes each
        # iteration instead of re-reading the entire (growing) log file.
        fh = None
        try:
            while time.time() < deadline:
                if fh is None and path.exists():
                    try:
                        fh = open(path, errors="ignore")  # noqa: SIM115
                    except OSError:
                        pass
                if fh is not None:
                    try:
                        chunk = fh.read()
                        if chunk and ramp_string in chunk:
                            return True
                    except OSError:
                        pass
                time.sleep(1)
        finally:
            if fh is not None:
                fh.close()
        self.logger.warning("perf_collector: ramp marker not seen within timeout")
        return False

    def start_perf(
        self, target_pid: int, output_file: str, events: List[str]
    ) -> Optional[subprocess.Popen]:
        """Start ``perf record`` attached to target_pid (or system-wide if 0)."""
        global _perf_process

        out_path = Path(output_file)
        out_path.parent.mkdir(parents=True, exist_ok=True)

        cmd = ["perf", "record", "-g", "-o", str(out_path)]
        if events:
            cmd += ["-e", ",".join(events)]
        if target_pid:
            cmd += ["-p", str(target_pid)]
        else:
            cmd += ["-a"]

        self.logger.info("perf_collector: start_perf: %s", " ".join(cmd))
        if self.dry_run:
            return None

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        _perf_process = proc
        return proc

    def stop_perf(self, process: Optional[subprocess.Popen]) -> bool:
        """Send SIGINT so perf flushes perf.data cleanly, then wait for exit."""
        global _perf_process

        if self.dry_run:
            self.logger.info("perf_collector: [dry-run] stop_perf called")
            return True

        if process is None:
            return True

        try:
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=10)
            return True
        except Exception as exc:
            self.logger.error("perf_collector: stop_perf failed: %s", exc)
            return False
        finally:
            if _perf_process is process:
                _perf_process = None

    def run_timed_collection(
        self,
        output_file: str,
        ramp_log_file: str,
        ramp_string: str,
        duration: int,
        start_delay: int,
        events: Optional[List[str]] = None,
    ) -> Optional[subprocess.Popen]:
        """Full collect_perf.sh-equivalent flow: wait for ramp, delay, then record.

        Intended to be launched by the caller in a background thread/process
        so the workload command it is profiling can run concurrently.
        """
        self.wait_for_ramp(ramp_log_file, ramp_string, timeout=duration + start_delay + 60)
        if start_delay:
            self.logger.info("perf_collector: start delay %ss", start_delay)
            if not self.dry_run:
                time.sleep(start_delay)

        proc = self.start_perf(target_pid=0, output_file=output_file, events=events or [])
        if proc is None:
            return None

        if not self.dry_run:
            time.sleep(duration)
        self.stop_perf(proc)
        return proc

    def collect_results(self, run_dir: Path) -> Dict[str, Any]:
        """Summarize perf.data presence/size for the run directory."""
        run_dir = Path(run_dir)
        perf_data = run_dir / "perf.data"
        result: Dict[str, Any] = {
            "perf_data_path": str(perf_data),
            "perf_data_exists": perf_data.exists(),
        }
        if perf_data.exists():
            result["perf_data_size_bytes"] = perf_data.stat().st_size
        return result
