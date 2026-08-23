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
import json
import platform
import re
import shlex
import shutil
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

from modules.dcperf_config_manager import ConfigManager
from modules.dcperf_core_scaler import get_online_cores, get_total_cores
from modules.dcperf_cpu_monitor import CpuMonitor
from modules.dcperf_emon_manager import EmonManager
from modules.dcperf_logger import get_logger
from modules.dcperf_os_tuner import apply_all as apply_all_os_tuning
from modules.dcperf_os_tuner import capture_baseline as capture_os_tuning_baseline
from modules.dcperf_os_tuner import restore_baseline as restore_os_tuning_baseline
from modules.dcperf_perf_collector import PerfCollector
from modules.dcperf_result_manager import ResultManager
from modules.dcperf_tmc import TmcRunner

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

        config_path = DCPERF_SCRIPTS_ROOT / "config" / "dcperf_config.yaml"
        self.config_manager = ConfigManager(config_path, self.logger)
        self.config: Dict[str, Any] = self.config_manager.load()

        self._apply_emon_flag_validation()

        results_base = Path(self.config.get("results_base_dir") or (DCPERF_SCRIPTS_ROOT / "results"))
        self.result_manager = ResultManager(results_base, self.logger)

        self.emon_manager = EmonManager(self.config, self.logger, dry_run=self.args.dry_run)
        self.perf_collector = PerfCollector(self.config, self.logger, dry_run=self.args.dry_run)
        self.tmc_runner = TmcRunner(self.config, self.logger, dry_run=self.args.dry_run)

        self.run_dir: Optional[Path] = None
        self._result_session = (
            f"corescaling_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
            if getattr(self.args, "core_scaling", False)
            else None
        )
        self._emon_output_file: Optional[Path] = None
        self._emon_process: Optional[subprocess.Popen] = None
        self._rows: List[Dict[str, Any]] = []
        self.cpu_monitor: Optional[CpuMonitor] = None
        self._cpu_monitor_result: Dict[str, Any] = {}
        self._tmc_result_dir: str = ""
        self._os_tuning_baseline: Optional[Dict[str, Optional[str]]] = None

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
        parser.add_argument("--socket-view", "-sv", action="store_true", help="Enable EMON socket view")
        parser.add_argument("--core-view", "-cv", action="store_true", help="Enable EMON core view (default)")
        parser.add_argument("--uncore-view", "-uv", action="store_true", help="Enable EMON uncore view")
        parser.add_argument("--detailed-view", "-dv", action="store_true", help="Enable EMON detailed/thread view")
        parser.add_argument("--experiment", default="", help="Experiment name injected by WLC (default: '')")
        parser.add_argument("--orch-run-id", default="", help="Orchestrator run id injected by WLC (default: '')")
        parser.add_argument("--metric", choices=["emon", "perf", "none"], default="none", help="Telemetry collection mode")
        parser.add_argument("--runs", type=int, default=None, help="Number of runs (default from config)")
        parser.add_argument("--cores", type=int, default=None, help="Number of cores to enable before running")
        parser.add_argument("--force", "-f", action="store_true", help="Force reinstall (passed through to benchpress_cli.py install -f)")
        tmc_group = parser.add_argument_group("TMC telemetry (EMON collection + upload)")
        tmc_group.add_argument("-ue", "--upload-emon", action="store_true", help="Collect EMON and upload to TMC (implies -e/--emon)")
        tmc_group.add_argument("--no-upload", action="store_true", help="Run tmc without uploading (drops -u)")
        tmc_group.add_argument("--emon-user", "-x", default=None, help="TMC upload user (default: emon_user from config)")
        tmc_group.add_argument("--tmc-alias", "-a", default=None, help="TMC session alias (default: <workload>_<timestamp>)")
        tmc_group.add_argument("--emon-start", "-S", type=int, default=None, help="EMON collection start offset in seconds")
        tmc_group.add_argument("--emon-end", "-E", type=int, default=None, help="EMON collection end offset in seconds")
        tmc_group.add_argument("--emon-views", "-w", default=None, help="TMC views, e.g. socket,core,uncore")
        tmc_group.add_argument("--tmc-metrics", "-Z", default=None, help="TMC metrics set, e.g. metrics2")
        tmc_group.add_argument("--tmc-group", "-G", default=None, help="TMC session group/prefix tag")
        tmc_group.add_argument("--tmc-tools", "-T", default=None, help="TMC tools, e.g. emon,sar or emon,iostat")
        tmc_group.add_argument("--ramp-timeout", "-rt", type=int, default=None, help="TMC ramp timeout in seconds")
        cls.add_arguments(parser)
        return parser

    @classmethod
    def add_arguments(cls, parser: argparse.ArgumentParser) -> None:
        """Hook for subclasses to add workload-specific CLI arguments."""

    def _apply_emon_flag_validation(self) -> None:
        """-ue implies -e; downgrade gracefully (log + disable) when the
        config needed for the requested telemetry level is missing."""
        if self.args.upload_emon:
            self.args.emon = True
        sep_path = self.config.get("sep_path") or (self.config.get("emon") or {}).get("sep_path")
        if self.args.upload_emon and not self.config.get("emon_user"):
            self.logger.error("base_wrapper: -ue requires emon_user in dcperf_config.yaml. Falling back to local EMON only.")
            self.args.upload_emon = False
        if self.args.emon and not sep_path:
            self.logger.error("base_wrapper: -e requires sep_path or emon.sep_path in dcperf_config.yaml. Skipping EMON collection.")
            self.args.emon = False
            self.args.upload_emon = False
            return
        if self.args.emon and not (Path(str(sep_path)) / "sep_vars.sh").exists():
            self.logger.error("base_wrapper: -e requires %s/sep_vars.sh. Skipping EMON collection.", sep_path)
            self.args.emon = False
            self.args.upload_emon = False

    # ------------------------------------------------------------------
    # Execution flow steps
    # ------------------------------------------------------------------

    def validate_config(self) -> None:
        """Default no-op; subclasses override to require() workload-specific keys."""

    def get_job_vars(self) -> Dict[str, Any]:
        """Job vars to forward to benchpress as `-i '{...}'` (jobs.yml template substitution).

        Default is empty (no override). Subclasses that collect CLI args
        meant to influence job behavior (duration, instances, db_addr,
        encoder level, etc.) MUST override this and return them here --
        collecting a CLI arg without returning it from get_job_vars() means
        it is silently discarded and benchpress runs with jobs.yml defaults.
        """
        return {}

    def pre_install_hook(self) -> bool:
        """Called by dcperf_master_setup before `benchpress_cli.py install <job>`.

        No-op by default. Subclasses override to patch install scripts or
        verify/install system prerequisites before install runs.
        """
        return True

    def is_install_satisfied(self) -> bool:
        """Return True when wrapper-managed install dependencies/data are present.

        This is intentionally read-only. Subclasses override it with cheap
        artifact checks so dcperf_run.py can skip unnecessary reinstall work.
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
        # TMC starts and uploads its own EMON collection around the workload.
        if self.args.upload_emon:
            return
        if self.args.metric == "emon" or self.args.emon:
            self._emon_output_file = Path(emon_output_file)
            self._emon_process = self.emon_manager.start_emon(emon_output_file)

    def pre_run(self) -> Dict[str, Any]:
        """Apply the workload-specific OS tuning profile and record it.

        Subclasses that need extra pre-run steps (patches, prerequisite
        checks, dataset prep) should override pre_run(), do their own work,
        then call super().pre_run() to still get tuning applied/recorded.
        """
        self._os_tuning_baseline = capture_os_tuning_baseline(self.get_workload_name(), self.logger)
        tuning_results = apply_all_os_tuning(self.get_workload_name(), self.config, self.logger, self.args.dry_run)
        if self.run_dir is not None:
            self.result_manager.save_metrics(self.run_dir, {"os_tuning": tuning_results})

        if not self.args.dry_run:
            self.cpu_monitor = CpuMonitor(self.get_workload_name(), self.logger)
            self.cpu_monitor.start()

        return tuning_results

    def post_run(self) -> None:
        """Hook for post-run cleanup. Restores pre-tuning OS settings, then stops
        the CPU monitor, before result writing.

        Subclasses that override this (e.g. Spark's post-run cache cleanup)
        must call super().post_run() to still get tuning restored and the CPU
        monitor stopped.
        """
        if self._os_tuning_baseline is not None:
            restore_results = restore_os_tuning_baseline(self._os_tuning_baseline, self.logger, self.args.dry_run)
            if self.run_dir is not None:
                self.result_manager.save_metrics(self.run_dir, {"os_tuning_restore": restore_results})
            self._os_tuning_baseline = None

        if self.cpu_monitor is not None:
            self._cpu_monitor_result = self.cpu_monitor.stop()
            self.cpu_monitor = None
            if self._cpu_monitor_result.get("within_target") is False:
                self.logger.warning("base_wrapper: %s", self._cpu_monitor_result.get("warning"))

    def get_benchpress_global_args(self) -> List[str]:
        """Optional `-b <benchmarks_file>` / `-j <jobs_file>` overrides.

        Base default: none (use benchpress's built-in benchmarks.yml/jobs.yml).
        Subclasses whose job lives in an alternate registry (e.g. wdl_bench,
        which is defined in benchmarks_wdl.yml/jobs_wdl.yml) override this.
        """
        return []

    def get_tmc_profile(self) -> Dict[str, Any]:
        """Per-workload TMC defaults, mirroring the baseline *_perf.sh scripts.

        Subclasses override to supply ramp_string/ramp_log and the collection
        window. CLI flags take precedence over anything returned here.
        """
        return {}

    def _resolve_tmc_profile(self) -> Dict[str, Any]:
        profile = dict(self.get_tmc_profile())
        overrides = {
            "ramp_timeout": self.args.ramp_timeout,
            "start": self.args.emon_start,
            "end": self.args.emon_end,
            "views": self.args.emon_views,
            "metrics_set": self.args.tmc_metrics,
            "group": self.args.tmc_group,
            "tools": self.args.tmc_tools,
            "user": self.args.emon_user,
        }
        profile.update({key: value for key, value in overrides.items() if value is not None})

        if self.args.emon_views:
            profile["views"] = self.args.emon_views
        else:
            views = [name for flag, name in (
                (self.args.socket_view, "socket"),
                (True, "core"),
                (self.args.uncore_view, "uncore"),
                (self.args.detailed_view, "thread"),
            ) if flag]
            profile["views"] = ",".join(views)

        alias = self.args.tmc_alias or (
            self.run_dir.name if self.run_dir is not None
            else f"{self.get_workload_name()}_{datetime.now().strftime('%m%d%Y%H%M%S')}"
        )
        profile["alias"] = alias
        profile["upload"] = not self.args.no_upload
        # -a must be a bare name: DCSO Metrics derives the trace name and its
        # server-side storage path from it. -d/-D are deliberately not set by
        # default -- tmc would then create <log_dir>/<alias> and the trace name
        # ends up duplicated. Only profiles that need them (spark) set log_dir.
        # benchpress pins its console handler to WARNING, so the workload's
        # output only reaches stdout as a trimmed summary at exit. benchpress.log
        # gets every line live, so that is what tmc must watch for the ramp marker.
        dcperf_root = self.config.get("dcperf_root")
        if dcperf_root and "ramp_log" not in profile:
            profile["ramp_log"] = str(Path(dcperf_root) / "benchpress.log")
        return profile

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
        cmd = [sys.executable, "-u", str(cli)] + self.get_benchpress_global_args() + ["run", job] + extra_args

        # benchpress.log is a single cumulative file (never rotated by benchpress
        # itself); truncate before every run so the copy captured after the run
        # holds only this run's output, from the very first line.
        self._reset_ramp_log(str(Path(dcperf_root) / "benchpress.log"))

        if self.args.upload_emon:
            if not self.args.dry_run and not self.tmc_runner.is_available():
                return 1, "", "tmc not found on PATH"
            profile = self._resolve_tmc_profile()
            inner = " ".join(shlex.quote(part) for part in cmd)
            # tmc runs from the results directory so its -d/-D stay relative;
            # benchpress still needs dcperf_root as its own working directory.
            inner = f"cd {shlex.quote(str(dcperf_root))} && {inner}"
            # Keep a full copy of the run next to the results; ramp detection
            # itself reads benchpress.log (see _resolve_tmc_profile).
            if self.run_dir is not None:
                workload_log = self.run_dir / "workload.log"
                inner = f"stdbuf -oL -eL bash -c {shlex.quote(inner)} 2>&1 | stdbuf -oL tee {shlex.quote(str(workload_log))}"
            tmc_cmd = self.tmc_runner.build_command(inner, **profile)
            tmc_cwd = str(self.run_dir) if self.run_dir is not None else dcperf_root
            rc, stdout, stderr = self._run_streamed(tmc_cmd, cwd=tmc_cwd)
            self._check_ramp_detection(stdout, profile)
            self._capture_tmc_result_dir(stdout)
            self._copy_benchpress_log(dcperf_root)
            return rc, stdout, stderr

        self.logger.info("base_wrapper: run_benchpress: %s", " ".join(cmd))
        if self.args.dry_run:
            return 0, "[dry-run] benchpress not executed", ""

        rc, stdout, stderr = self._run_streamed(cmd, cwd=dcperf_root)
        self._copy_benchpress_log(dcperf_root)
        return rc, stdout, stderr

    def _copy_benchpress_log(self, dcperf_root: Optional[str]) -> None:
        """Preserve benchpress's own log (every line from process start, unlike
        the WARNING-only console/tee capture) into the run directory.

        tmc's target_output.txt and our workload.log only contain what
        benchpress prints to stdout (WARNING+ and the final summary); the
        full per-line output from the moment benchpress started -- including
        everything before the ramp marker -- only ever lands in
        <dcperf_root>/benchpress.log. Without this copy that full record is
        lost (overwritten by the next run) and never reaches results/ or the
        uploaded trace.
        """
        if not dcperf_root or self.run_dir is None or self.args.dry_run:
            return
        src = Path(dcperf_root) / "benchpress.log"
        try:
            shutil.copy2(src, self.run_dir / "benchpress.log")
        except OSError as exc:
            self.logger.warning("base_wrapper: could not copy %s into run_dir: %s", src, exc)

    def _reset_ramp_log(self, ramp_log: Optional[str]) -> None:
        """Truncate the ramp log so tmc cannot match a previous run's marker."""
        if not ramp_log or self.args.dry_run:
            return
        try:
            path = Path(ramp_log)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("", encoding="utf-8")
            self.logger.info("base_wrapper: truncated ramp log %s", path)
        except OSError as exc:
            self.logger.warning("base_wrapper: could not truncate ramp log %s: %s", ramp_log, exc)

    def _capture_tmc_result_dir(self, stdout: str) -> None:
        """Record tmc's own output directory; it appends _1, _2... when -d exists."""
        match = re.search(r"Results stored at (\S+)", stdout)
        if not match:
            return
        reported = Path(match.group(1))
        # tmc prints the path relative to its own working directory (run_dir).
        if not reported.is_absolute() and self.run_dir is not None:
            reported = self.run_dir / reported
        self._tmc_result_dir = str(reported)
        if self.run_dir is not None and self.run_dir not in reported.parents:
            self.logger.warning(
                "base_wrapper: tmc stored its trace in %s, outside the run directory %s",
                self._tmc_result_dir, self.run_dir,
            )

    def _check_ramp_detection(self, stdout: str, profile: Dict[str, Any]) -> None:
        """Warn when tmc saw the ramp marker only at process exit.

        tmc anchors the EMON window on the marker, so a late detection means
        collection started after the workload finished and the trace is useless.
        """
        if "not find the requested string" in stdout or "Timed out" in stdout:
            self.logger.error(
                "base_wrapper: tmc never saw ramp marker %r -- EMON window did not "
                "align with the workload",
                profile.get("ramp_string"),
            )
        if "Target process already exited" in stdout:
            self.logger.error(
                "base_wrapper: tmc started EMON after the workload had already exited; "
                "the ramp marker was detected too late and the trace is not usable"
            )

    def _run_streamed(self, cmd: List[str], cwd: Optional[str] = None) -> Tuple[int, str, str]:
        """Run cmd, echoing output live while capturing it for KPI parsing."""
        global _current_proc

        printable = " ".join(shlex.quote(part) for part in cmd)
        self.logger.info("base_wrapper: exec: %s", printable)
        if self.args.dry_run:
            return 0, "[dry-run] not executed", ""

        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                start_new_session=True,
                cwd=cwd,
            )
        except OSError as exc:
            self.logger.error("base_wrapper: failed to launch %s: %s", cmd[0], exc)
            return 1, "", str(exc)

        _current_proc = proc
        captured: List[str] = []
        try:
            assert proc.stdout is not None
            for line in proc.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
                captured.append(line)
            proc.wait()
        finally:
            _current_proc = None

        return proc.returncode, "".join(captured), ""

    def stop_telemetry(self) -> None:
        if self._emon_process is not None:
            self.emon_manager.stop_emon(self._emon_process)
            self._emon_process = None
        emon_cfg = self.config.get("emon") or {}
        if (
            not self.args.upload_emon
            and (self.args.metric == "emon" or self.args.emon)
            and self.run_dir is not None
            and self._emon_output_file is not None
            and emon_cfg.get("post_process", True) is not False
        ):
            try:
                self.emon_manager.process_emon(
                    str(self._emon_output_file),
                    str(self.result_manager.get_emon_processed_dir(self.run_dir)),
                )
            except Exception as exc:  # noqa: BLE001
                self.logger.warning("base_wrapper: EMON post-processing skipped due to error: %s", exc)

    def _utilization_is_acceptable(self) -> bool:
        """Fail runs whose CPU utilization is far under the workload's target.

        A benchmark that idles produces plausible-looking but meaningless KPIs,
        so this is an error rather than the previous advisory warning.
        """
        avg = self._cpu_monitor_result.get("avg_overall_pct")
        if avg is None:
            return True
        floor = float(self.config.get("min_cpu_utilization_pct", 50.0))
        if avg >= floor:
            return True
        self.logger.error(
            "base_wrapper: CPU utilization averaged %.1f%%, below the %.0f%% floor for %s; "
            "the workload was not driven at load",
            avg, floor, self.get_workload_name(),
        )
        return False

    @staticmethod
    def _kpis_are_meaningful(kpis: Dict[str, Any]) -> bool:
        """True if at least one KPI is non-zero; an all-zero set means no run happened."""
        if not kpis:
            return False
        for value in kpis.values():
            try:
                if float(value) != 0.0:
                    return True
            except (TypeError, ValueError):
                if value:
                    return True
        return False

    def print_summary(self, status: str, kpis: Dict[str, Any]) -> None:
        self.logger.info(
            "base_wrapper: %s finished status=%s kpis=%s",
            self.get_workload_name(), status, kpis,
        )

        width = 64
        print("=" * width)
        print(f"{self.get_workload_name()} Run Summary")
        print("=" * width)
        print(f"{'Status'.ljust(28)}: {status}")
        print(f"{'Host'.ljust(28)}: {socket.gethostname()}")
        print(f"{'Telemetry'.ljust(28)}: {self._telemetry_mode()}")
        avg_util = self._cpu_monitor_result.get("avg_overall_pct")
        if avg_util is not None:
            print(f"{'CPU utilization'.ljust(28)}: {avg_util}%")
        if self._tmc_result_dir:
            print(f"{'TMC trace directory'.ljust(28)}: {self._tmc_result_dir}")
        if kpis:
            print("-" * width)
            print(f"{'KPI'.ljust(28)}  Value")
            print("-" * width)
            for name, value in kpis.items():
                print(f"{name.ljust(28)}: {value}")
        print("=" * width)
        if status != "PASS":
            print("Run did not pass -- check workload.log and stdout.log in the output directory.")
        if self.run_dir is not None:
            print(f"Output Directory: {self.run_dir.resolve()}")

    def _telemetry_mode(self) -> str:
        if self.args.upload_emon:
            return "tmc (upload)" if not self.args.no_upload else "tmc (no upload)"
        if self.args.metric == "emon" or self.args.emon:
            return "emon (local)"
        return self.args.metric

    # ------------------------------------------------------------------
    # benchpress result parsing (JSON "Results Report:" block)
    # ------------------------------------------------------------------

    def parse_benchpress_json(self, stdout: str) -> Dict[str, Any]:
        """Extract benchpress's structured `Results Report:` JSON blob from stdout.

        benchpress prints a JSON object (benchmark_name, metrics, score,
        run_id, timestamp, machines, ...) after a `Results Report:` marker
        line. This is the authoritative source for KPIs -- regexing raw
        tool-log text is fragile and often wrong. Returns {} if the marker
        or a parseable JSON object is not found (e.g. dry-run stdout).
        """
        marker = "Results Report:"
        idx = stdout.find(marker)
        if idx == -1:
            return {}
        tail = stdout[idx + len(marker):]
        brace_idx = tail.find("{")
        if brace_idx == -1:
            return {}
        try:
            obj, _ = json.JSONDecoder().raw_decode(tail[brace_idx:])
            return obj if isinstance(obj, dict) else {}
        except ValueError:
            self.logger.warning("base_wrapper: could not parse benchpress Results Report JSON")
            return {}

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

        if self._os_tuning_baseline is not None:
            try:
                restore_os_tuning_baseline(self._os_tuning_baseline, self.logger, self.args.dry_run)
            except Exception:
                pass
            self._os_tuning_baseline = None

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

        self.run_dir = self.result_manager.create_run_dir(
            self.get_workload_name(), self._result_session, experiment=self.args.experiment or None
        )
        self.result_manager.write_system_metadata(self.run_dir, metadata)

        status = "FAIL"
        kpis: Dict[str, Any] = {}
        stdout = stderr = ""
        returncode = 1

        try:
            emon_raw_dir = self.result_manager.get_emon_raw_dir(self.run_dir)
            self.setup_telemetry(str(emon_raw_dir / "emon.dat"))
            self.pre_run()

            extra_args: List[str] = []
            job_vars = self.get_job_vars()
            if job_vars:
                extra_args += ["-i", json.dumps(job_vars)]
            returncode, stdout, stderr = self.run_benchpress(self.get_job_name(), extra_args)

            self.result_manager.save_stdout(self.run_dir, stdout)
            self.result_manager.save_stderr(self.run_dir, stderr)
            self.result_manager.save_command(self.run_dir, " ".join(sys.argv))

            bp_json = self.parse_benchpress_json(stdout)
            run_id = bp_json.get("run_id")
            dcperf_root = self.config.get("dcperf_root")
            if run_id and dcperf_root:
                self.result_manager.copy_benchmark_metrics(dcperf_root, run_id, self.run_dir)

            parsed = self.parse_output(stdout)
            kpis = self.get_kpis(parsed)
            status = "PASS" if returncode == 0 else "FAIL"
            if status == "PASS" and not self.args.dry_run and not self._kpis_are_meaningful(kpis):
                self.logger.error(
                    "base_wrapper: %s exited 0 but produced no non-zero KPIs (%s); "
                    "the benchmark did not actually run",
                    self.get_workload_name(), kpis,
                )
                status = "FAIL"
        except Exception as exc:
            self.logger.error("base_wrapper: run failed: %s", exc)
            status = "FAIL"
        finally:
            self.stop_telemetry()
            try:
                self.post_run()
            except Exception as exc:
                self.logger.error("base_wrapper: post_run failed: %s", exc)

            if status == "PASS" and not self.args.dry_run and not self._utilization_is_acceptable():
                status = "FAIL"

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
                {
                    "orch_run_id": self.args.orch_run_id,
                    "tmc_result_dir": self._tmc_result_dir,
                    "rows": self._rows,
                },
            )
            metrics_payload = dict(kpis)
            if self._cpu_monitor_result:
                metrics_payload["cpu_utilization"] = self._cpu_monitor_result
            self.result_manager.save_metrics(self.run_dir, metrics_payload)

            if self.args.upload_emon and self._tmc_result_dir:
                self.result_manager.write_tmc_upload_log(
                    self.run_dir, f"tmc trace directory: {self._tmc_result_dir}"
                )

            try:
                self.result_manager.append_to_consolidated(
                    self.get_workload_name(), self._build_consolidated_row(metadata, kpis, status)
                )
            except Exception as exc:
                self.logger.warning("base_wrapper: could not update consolidated_results.xlsx: %s", exc)

            self.print_summary(status, kpis)

        return 0 if status == "PASS" else 1

    def _build_consolidated_row(self, metadata: Dict[str, Any], kpis: Dict[str, Any], status: str) -> Dict[str, Any]:
        """Assemble one consolidated_results.xlsx row from this run's metadata/KPIs."""
        primary_kpi_name = next(iter(kpis), None)
        return {
            "session_id": self.run_dir.name if self.run_dir is not None else "",
            "experiment": self.args.experiment or "",
            "timestamp": metadata.get("timestamp", ""),
            "host": metadata.get("hostname", ""),
            "kernel": metadata.get("kernel", ""),
            "cpu_model": metadata.get("cpu_model", ""),
            "core_count": metadata.get("online_cores", ""),
            "primary_kpi": kpis.get(primary_kpi_name, "") if primary_kpi_name else "",
            "kpi_unit": primary_kpi_name or "",
            "p50_latency_ms": kpis.get("p50_latency_ms", ""),
            "p99_latency_ms": kpis.get("p99_latency_ms", ""),
            "status": status,
            "emon_collected": bool(self.args.emon or self.args.upload_emon),
            "tmc_uploaded": bool(self.args.upload_emon and self._tmc_result_dir),
            "tmc_link": self._tmc_result_dir,
            "session_path": str(self.run_dir) if self.run_dir is not None else "",
            "notes": "",
        }
