"""EMON (Intel SEP) telemetry lifecycle manager for DCPerf wrappers.

Mirrors the PNPWLS common/telemetry/emon.py + manager.py lifecycle
(start_collection/stop_collection/process_with_edp) but drives EMON
natively instead of shelling out to the external ``tmc`` tool that the
original dj_perf.py/fs_perf.py/mw_perf.py/sweep.py/vt_script.py scripts
depended on. Real commands (sep_vars.sh sourcing, ``emon -collect-edp``,
``rmmod sep``/``insmod sep.ko``) were extracted from those 5 scripts.
"""

from __future__ import annotations

import signal
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

# Module-level global so the signal handler can reach the running EMON
# process regardless of which EmonManager instance started it.
_emon_process: Optional[subprocess.Popen] = None


def _install_signal_handlers() -> None:
    """Register SIGINT/SIGTERM handlers that stop EMON before the process dies."""
    previous_sigint = signal.getsignal(signal.SIGINT)
    previous_sigterm = signal.getsignal(signal.SIGTERM)

    def _handler(signum, frame):
        global _emon_process
        if _emon_process is not None and _emon_process.poll() is None:
            try:
                _emon_process.terminate()
                _emon_process.wait(timeout=10)
            except Exception:
                try:
                    _emon_process.kill()
                except Exception:
                    pass
            _emon_process = None
        # Chain to whatever handler was previously installed (if any).
        if callable(previous_sigint) and signum == signal.SIGINT:
            previous_sigint(signum, frame)
        elif callable(previous_sigterm) and signum == signal.SIGTERM:
            previous_sigterm(signum, frame)
        raise SystemExit(130)

    signal.signal(signal.SIGINT, _handler)
    signal.signal(signal.SIGTERM, _handler)


_install_signal_handlers()


class EmonManager:
    """Drives EMON (SEP) start/stop/process lifecycle for one workload run.

    Args:
        config: dict with keys ``sep_path`` and ``emon_event_file`` (both
            required, no hardcoded fallback paths).
        logger: standard library Logger.
        dry_run: if True, every method logs/prints the command it would run
            and returns the same shape as the real-run path without
            executing anything.
    """

    def __init__(self, config: Dict[str, Any], logger, dry_run: bool = False):
        self.config = config
        self.logger = logger
        self.dry_run = dry_run
        emon_cfg = config.get("emon") or {}
        sep_path = config.get("sep_path") or emon_cfg.get("sep_path")
        self.sep_path = Path(sep_path) if sep_path else None
        self.event_file = config.get("emon_event_file") or emon_cfg.get("event_file")

    # ------------------------------------------------------------------
    # Availability / driver management
    # ------------------------------------------------------------------

    def is_available(self) -> bool:
        """Return True if SEP is installed and emon is resolvable."""
        if self.sep_path is None:
            self.logger.warning("emon_manager: sep_path not configured")
            return False
        sep_vars = self.sep_path / "sep_vars.sh"
        if not sep_vars.exists():
            self.logger.warning("emon_manager: sep_vars.sh not found at %s", sep_vars)
            return False
        try:
            direct = subprocess.run(["which", "emon"], capture_output=True, text=True)
            if direct.returncode == 0:
                return True
            sourced = subprocess.run(
                ["bash", "-lc", f"source {sep_vars} && command -v emon >/dev/null"],
                capture_output=True,
                text=True,
            )
            if sourced.returncode == 0:
                return True
        except OSError as exc:
            self.logger.warning("emon_manager: emon availability check failed: %s", exc)
            return False
        self.logger.warning("emon_manager: emon command not found after sourcing %s", sep_vars)
        return False

    @staticmethod
    def _looks_like_driver_error(output: str) -> bool:
        markers = (
            "sepint",
            "socperf",
            "driver",
            "module",
            "insmod",
            "rmmod",
            "problem accessing the sampling driver",
            "driver may need to be",
            "reinstalled with appropriate",
        )
        normalized = (output or "").lower()
        return any(marker in normalized for marker in markers)

    def _reload_drivers(self) -> bool:
        if self.sep_path is None:
            return False
        sep_src = self.sep_path / "sepdk" / "src"
        rmmod_script = sep_src / "rmmod-sep"
        insmod_script = sep_src / "insmod-sep"
        if not sep_src.exists() or not rmmod_script.exists() or not insmod_script.exists():
            self.logger.warning("emon_manager: SEP driver scripts not found under %s", sep_src)
            return False
        self.logger.warning("emon_manager: attempting SEP driver reload")
        try:
            # Use non-interactive sudo so this never blocks waiting for a
            # password prompt inside automated runs.
            rm = subprocess.run(
                ["sudo", "-n", str(rmmod_script)],
                check=False,
                capture_output=True,
                text=True,
                timeout=20,
            )
            if rm.returncode != 0 and rm.stderr:
                self.logger.warning("emon_manager: rmmod-sep returned %s: %s", rm.returncode, rm.stderr.strip())

            ins = subprocess.run(
                ["sudo", "-n", str(insmod_script)],
                check=False,
                capture_output=True,
                text=True,
                timeout=20,
            )
            if ins.returncode != 0:
                self.logger.warning("emon_manager: insmod-sep failed during reload: %s", ins.stderr)
                return False
            time.sleep(1)
            return True
        except subprocess.TimeoutExpired:
            self.logger.warning("emon_manager: SEP driver reload timed out")
            return False
        except OSError as exc:
            self.logger.warning("emon_manager: SEP driver reload failed: %s", exc)
            return False
        return True

    def load_sep_module(self) -> bool:
        """Insert the SEP kernel driver (insmod). Extracted from dj/fs/sweep/vt scripts."""
        if self.sep_path is None:
            self.logger.error("emon_manager: cannot load SEP module, sep_path not configured")
            return False

        insmod_cmd = ["sudo", "insmod", str(self.sep_path / "sep.ko")]
        self.logger.info("emon_manager: %s", " ".join(insmod_cmd))
        if self.dry_run:
            return True

        try:
            subprocess.run(insmod_cmd, check=True, capture_output=True, text=True)
            return True
        except subprocess.CalledProcessError as exc:
            self.logger.error("emon_manager: insmod failed: %s", exc.stderr)
            return False

    def unload_sep_module(self) -> bool:
        """Remove the SEP kernel driver (rmmod). Extracted from dj/fs/sweep/vt scripts."""
        if self.sep_path is None:
            self.logger.error("emon_manager: cannot unload SEP module, sep_path not configured")
            return False

        rmmod_cmd = ["sudo", "rmmod", "sep"]
        self.logger.info("emon_manager: %s", " ".join(rmmod_cmd))
        if self.dry_run:
            return True

        try:
            subprocess.run(rmmod_cmd, check=True, capture_output=True, text=True)
            return True
        except subprocess.CalledProcessError as exc:
            self.logger.error("emon_manager: rmmod failed: %s", exc.stderr)
            return False

    # ------------------------------------------------------------------
    # Start / stop collection
    # ------------------------------------------------------------------

    def start_emon(self, output_file: str) -> Optional[subprocess.Popen]:
        """Start ``emon -collect-edp`` in the background, tracked globally.

        Returns the Popen handle (real run) or a dry-run sentinel value
        that callers can still pass to ``stop_emon`` safely.
        """
        global _emon_process

        if self.sep_path is None:
            self.logger.error("emon_manager: cannot start EMON, sep_path not configured")
            return None

        sep_vars = self.sep_path / "sep_vars.sh"
        out_path = Path(output_file)
        out_path.parent.mkdir(parents=True, exist_ok=True)

        shell_cmd = f"source {sep_vars} && emon -collect-edp"
        self.logger.info("emon_manager: start_emon: %s > %s 2>&1", shell_cmd, out_path)

        if self.dry_run:
            self.logger.info("emon_manager: [dry-run] EMON collection not started")
            return None

        for attempt in range(2):
            try:
                log_handle = open(out_path, "w")
            except OSError as exc:
                self.logger.error("emon_manager: could not open EMON output file: %s", exc)
                return None

            try:
                proc = subprocess.Popen(
                    ["bash", "-lc", shell_cmd],
                    stdout=log_handle,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
            finally:
                log_handle.close()

            time.sleep(2)
            if proc.poll() is None:
                _emon_process = proc
                return proc

            error_text = ""
            try:
                if out_path.exists():
                    error_text = out_path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                error_text = ""

            self.logger.error(
                "emon_manager: EMON process exited immediately (rc=%s) on attempt %s",
                proc.returncode,
                attempt + 1,
            )
            if attempt == 0 and self._looks_like_driver_error(error_text):
                self.logger.warning("emon_manager: detected SEP driver issue, retrying after reload")
                if self._reload_drivers():
                    continue
            return None

        return None

    def stop_emon(self, process: Optional[subprocess.Popen]) -> bool:
        """Stop a running EMON collection, always safe to call (idempotent)."""
        global _emon_process

        if self.dry_run:
            self.logger.info("emon_manager: [dry-run] stop_emon called")
            return True

        if process is None:
            return True

        try:
            if process.poll() is None:
                # emon needs SIGINT to flush and close its data file cleanly.
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=10)
            return True
        except Exception as exc:
            self.logger.error("emon_manager: stop_emon failed: %s", exc)
            return False
        finally:
            if _emon_process is process:
                _emon_process = None

    # ------------------------------------------------------------------
    # Post-processing
    # ------------------------------------------------------------------

    def process_emon(self, emon_dat: str, output_dir: str) -> bool:
        """Run EDP post-processing on a raw EMON .dat file into output_dir."""
        if self.sep_path is None:
            self.logger.error("emon_manager: cannot process EMON data, sep_path not configured")
            return False

        out_dir = Path(output_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        edp_bin = self.sep_path / "bin64" / "edp"
        if not edp_bin.exists():
            self.logger.warning(
                "emon_manager: skipping EDP post-processing because %s is missing",
                edp_bin,
            )
            return False
        cmd = [str(edp_bin), str(emon_dat), "-o", str(out_dir)]

        self.logger.info("emon_manager: process_emon: %s", " ".join(cmd))
        if self.dry_run:
            return True

        try:
            subprocess.run(cmd, check=True, capture_output=True, text=True)
            return True
        except subprocess.CalledProcessError as exc:
            self.logger.error("emon_manager: EDP processing failed: %s", exc.stderr)
            return False
        except OSError as exc:
            self.logger.warning("emon_manager: unable to execute EDP (%s); skipping post-processing", exc)
            return False

    # ------------------------------------------------------------------
    # View resolution (mirrors PNPWLS resolve_emon_views)
    # ------------------------------------------------------------------

    def resolve_emon_views(
        self,
        core_view: bool = False,
        uncore_view: bool = False,
        detailed_view: bool = False,
    ) -> List[str]:
        """Return the EMON view list, with core view enabled by default."""
        views = ["core"]
        if core_view and "core" not in views:
            views.append("core")
        if uncore_view:
            views.append("uncore")
        if detailed_view:
            views.append("thread")
        return views
