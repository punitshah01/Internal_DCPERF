"""Abstract base class for all DCPerf workload wrappers.

Every concrete wrapper (django, feedsim, mediawiki, spark, video,
tao_bench, health_check, wdl_bench) inherits ``BaseWrapper`` and only
implements the workload-specific hooks. The base class owns the WLC
contract gates (CLI args, results.json, "Output Directory:" marker) and
the fixed execution flow:

    parse_args -> validate_config -> collect_metadata -> setup_telemetry
    -> pre_run (os tuning) -> run_workload (benchpress run.py -j <job>)
    -> parse_output -> calculate_kpis -> write_csv -> write_json
    -> stop_telemetry -> print_summary
"""

from __future__ import annotations

import argparse
import platform
import signal
import socket
import subprocess
import sys
from abc import ABC, abstractmethod
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent
DCPERF_SCRIPTS_ROOT = SCRIPT_DIR.parent
if str(DCPERF_SCRIPTS_ROOT) not in sys.path:
    sys.path.insert(0, str(DCPERF_SCRIPTS_ROOT))

from modules.config_manager import ConfigManager
from modules.core_scaler import get_online_cores, get_total_cores
from modules.emon_manager import EmonManager
from modules.logger_setup import get_logger
from modules.os_tuner import apply_all as apply_all_os_tuning
from modules.perf_collector import PerfCollector
from modules.result_manager import ResultManager

# Module-level global so the signal handler can reach the running
# benchpress subprocess regardless of which wrapper instance started it.
_current_proc: Optional[subprocess.Popen] = None
_active_wrapper: Optional["BaseWrapper"] = None


def _signal_dispatch(signum, frame):
    if _active_wrapper is not None:
        _active_wrapper.handle_signal(signum, frame)
    raise SystemExit(130)


signal.signal(signal.SIGINT, _signal_dispatch)
signal.signal(signal.SIGTERM, _signal_dispatch)


class BaseWrapper(ABC):
    """Base class implementing the shared WLC-compliant execution flow."""

    def __init__(self, argv: Optional[List[str]] = None):
        global _active_wrapper

        self.logger = get_logger(self.get_workload_name(), DCPERF_SCRIPTS_ROOT / "logs")
        self.args = self._build_arg_parser().parse_args(argv)

        config_path = DCPERF_SCRIPTS_ROOT / "config" / "setup_config.yaml"
        self.config_manager = ConfigManager(config_path, self.logger)
        self.config: Dict[str, Any] = self.config_manager.load()

        results_base = Path(self.config.get("results_base_dir") or (DCPERF_SCRIPTS_ROOT / "results"))
        self.result_manager = ResultManager(results_base, self.logger)

        self.emon_manager = EmonManager(self.config, self.logger, dry_run=self.args.dry_run)
        self.perf_collector = PerfCollector(self.config, self.logger, dry_run=self.args.dry_run)

        self.run_dir: Optional[Path] = None
        self._emon_process: Optional[subprocess.Popen] = None
        self._rows: List[Dict[str, Any]] = []

        _active_wrapper = self

    # ------------------------------------------------------------------
    # Abstract methods every wrapper must implement
    # ------------------------------------------------------------------

    @abstractmethod
    def get_job_name(self) -> str:
        """Return the benchpress job name (from jobs.yml/jobs_wdl.yml)."""

    @abstractmethod
    def get_workload_name(self) -> str:
        """Return the short workload identifier used for result dir naming."""

    @abstractmethod
    def parse_output(self, stdout: str) -> Dict[str, Any]:
        """Parse raw benchpress stdout into a dict of extracted fields."""

    @abstractmethod
    def get_kpis(self, parsed: Dict[str, Any]) -> Dict[str, Any]:
        """Derive the final KPI dict (numeric) from parse_output()'s result."""

    @abstractmethod
    def get_csv_schema(self) -> List[str]:
        """Return the ordered list of config+KPI column names for results.csv."""

    # ------------------------------------------------------------------
    # CLI contract (Gate A)
    # ------------------------------------------------------------------

    @classmethod
    def _build_arg_parser(cls) -> argparse.ArgumentParser:
        parser = argparse.ArgumentParser(description=f"{cls.__name__} DCPerf wrapper")
        parser.add_argument("--dry-run", "-dr", action="store_true", help="Show commands without executing")
        parser.add_argument("--emon", "-e", action="store_true", help="Enable EMON telemetry collection")
        parser.add_argument("--core-view", "-cv", action="store_true", help="Enable EMON core view")
        parser.add_argument("--uncore-view", "-uv", action="store_true", help="Enable EMON uncore view")
        parser.add_argument("--detailed-view", "-dv", action="store_true", help="Enable EMON detailed/thread view")
        parser.add_argument("--experiment", default="", help="Experiment name injected by WLC (default: '')")
        parser.add_argument("--orch-run-id", default="", help="Orchestrator run id injected by WLC (default: '')")
        parser.add_argument("--metric", choices=["emon", "perf", "none"], default="none", help="Telemetry collection mode")
        parser.add_argument("--runs", type=int, default=None, help="Number of runs (default from config)")
        parser.add_argument("--cores", type=int, default=None, help="Number of cores to enable before running")
        cls.add_arguments(parser)
        return parser

    @classmethod
    def add_arguments(cls, parser: argparse.ArgumentParser) -> None:
        """Hook for subclasses to add workload-specific CLI arguments."""

    # ------------------------------------------------------------------
    # Execution flow steps
    # ------------------------------------------------------------------

    def validate_config(self) -> None:
        """Default no-op; subclasses override to require() workload-specific keys."""

    def pre_install_hook(self) -> bool:
        """Called by dcperf_master_setup before `benchpress_cli.py install <job>`.

        No-op by default. Subclasses override to patch install scripts or
        verify/install system prerequisites before install runs.
        """
        return True

    def collect_metadata(self) -> Dict[str, Any]:
        """Minimal system metadata snapshot (hostname, cpu, cores, kernel, os, timestamp)."""
        return {
            "hostname": socket.gethostname(),
            "cpu_model": self._read_cpu_model(),
            "total_cores": get_total_cores(),
            "online_cores": len(get_online_cores()),
            "kernel": platform.release(),
            "os": platform.platform(),
            "timestamp": datetime.now().isoformat(),
            "experiment": self.args.experiment,
            "orch_run_id": self.args.orch_run_id,
        }

    @staticmethod
    def _read_cpu_model() -> str:
        try:
            with open("/proc/cpuinfo", encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    if line.lower().startswith("model name"):
                        return line.split(":", 1)[1].strip()
        except OSError:
            pass
        return "Unknown"

    def setup_telemetry(self, emon_output_file: str) -> None:
        if self.args.metric == "emon" or self.args.emon:
            self._emon_process = self.emon_manager.start_emon(emon_output_file)

    def pre_run(self) -> Dict[str, Any]:
        """Apply the workload-specific OS tuning profile and record it.

        Subclasses that need extra pre-run steps (patches, prerequisite
        checks, dataset prep) should override pre_run(), do their own work,
        then call super().pre_run() to still get tuning applied/recorded.
        """
        tuning_results = apply_all_os_tuning(self.get_workload_name(), self.config, self.logger, self.args.dry_run)
        if self.run_dir is not None:
            self.result_manager.save_metrics(self.run_dir, {"os_tuning": tuning_results})
        return tuning_results

    def post_run(self) -> None:
        """Hook for post-run cleanup; no-op by default. Spark overrides this."""

    def get_benchpress_global_args(self) -> List[str]:
        """Optional `-b <benchmarks_file>` / `-j <jobs_file>` overrides.

        Base default: none (use benchpress's built-in benchmarks.yml/jobs.yml).
        Subclasses whose job lives in an alternate registry (e.g. wdl_bench,
        which is defined in benchmarks_wdl.yml/jobs_wdl.yml) override this.
        """
        return []

    def run_benchpress(self, job: str, extra_args: List[str]) -> Tuple[int, str, str]:
        """Run `python <dcperf_root>/benchpress_cli.py [-b file] [-j file] run <job> <extra_args>`.

        DCPerf has no standalone run.py/install.py — the real entry point is
        benchpress_cli.py, with `-b`/`-j` as *global* registry-override flags
        (not a job selector) and `run`/`install <job>` as the subcommand
        with the job name as a positional argument.
        """
        global _current_proc

        dcperf_root = self.config.get("dcperf_root")
        if not dcperf_root:
            raise RuntimeError("dcperf_root is not configured; cannot locate benchpress_cli.py")

        cli = Path(dcperf_root) / "benchpress_cli.py"
        cmd = [sys.executable, str(cli)] + self.get_benchpress_global_args() + ["run", job] + extra_args

        self.logger.info("base_wrapper: run_benchpress: %s", " ".join(cmd))
        if self.args.dry_run:
            return 0, "[dry-run] benchpress not executed", ""

        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
        except OSError as exc:
            self.logger.error("base_wrapper: failed to launch benchpress: %s", exc)
            return 1, "", str(exc)

        _current_proc = proc
        try:
            stdout, stderr = proc.communicate()
        finally:
            _current_proc = None

        return proc.returncode, stdout, stderr

    def stop_telemetry(self) -> None:
        if self._emon_process is not None:
            self.emon_manager.stop_emon(self._emon_process)
            self._emon_process = None

    def print_summary(self, status: str, kpis: Dict[str, Any]) -> None:
        self.logger.info(
            "base_wrapper: %s finished status=%s kpis=%s",
            self.get_workload_name(), status, kpis,
        )
        if self.run_dir is not None:
            print(f"Output Directory: {self.run_dir.resolve()}")

    # ------------------------------------------------------------------
    # Signal / failure safety
    # ------------------------------------------------------------------

    def handle_signal(self, signum, frame) -> None:
        """Stop EMON, kill tracked subprocess, write partial results, exit cleanly."""
        global _current_proc

        self.logger.warning("base_wrapper: received signal %s, cleaning up", signum)
        try:
            self.stop_telemetry()
        except Exception:
            pass

        if _current_proc is not None and _current_proc.poll() is None:
            try:
                _current_proc.terminate()
                _current_proc.wait(timeout=10)
            except Exception:
                try:
                    _current_proc.kill()
                except Exception:
                    pass
            _current_proc = None

        if self.run_dir is not None:
            try:
                self.result_manager.write_json_results(
                    self.run_dir,
                    {"orch_run_id": self.args.orch_run_id, "rows": self._rows},
                )
            except Exception:
                pass
            print(f"Output Directory: {self.run_dir.resolve()}")

    # ------------------------------------------------------------------
    # Top-level orchestration
    # ------------------------------------------------------------------

    def run(self) -> int:
        """Execute the full parse->run->report flow. Returns a process exit code."""
        self.validate_config()
        metadata = self.collect_metadata()

        self.run_dir = self.result_manager.create_run_dir(self.get_workload_name())
        self.result_manager.write_system_metadata(self.run_dir, metadata)

        status = "FAIL"
        kpis: Dict[str, Any] = {}
        stdout = stderr = ""
        returncode = 1

        try:
            self.setup_telemetry(str(self.run_dir / "emon" / "emon.dat"))
            self.pre_run()

            extra_args: List[str] = []
            returncode, stdout, stderr = self.run_benchpress(self.get_job_name(), extra_args)

            self.result_manager.save_stdout(self.run_dir, stdout)
            self.result_manager.save_stderr(self.run_dir, stderr)
            self.result_manager.save_command(self.run_dir, " ".join(sys.argv))

            parsed = self.parse_output(stdout)
            kpis = self.get_kpis(parsed)
            status = "PASS" if returncode == 0 else "FAIL"
        except Exception as exc:
            self.logger.error("base_wrapper: run failed: %s", exc)
            status = "FAIL"
        finally:
            self.stop_telemetry()
            try:
                self.post_run()
            except Exception as exc:
                self.logger.error("base_wrapper: post_run failed: %s", exc)

            row = dict(metadata)
            row.update(kpis)
            row["status"] = status
            self._rows.append({"system": metadata, "params": {}, "kpis": kpis, "status": status})

            try:
                self.result_manager.write_csv_row(self.run_dir, row)
            except Exception as exc:
                self.logger.error("base_wrapper: FAILED to write results.csv: %s", exc)
                raise

            self.result_manager.write_json_results(
                self.run_dir,
                {"orch_run_id": self.args.orch_run_id, "rows": self._rows},
            )
            self.result_manager.save_metrics(self.run_dir, kpis)
            self.print_summary(status, kpis)

        return 0 if status == "PASS" else 1
