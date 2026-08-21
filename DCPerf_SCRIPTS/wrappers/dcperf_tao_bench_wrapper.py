"""TaoBench wrapper — full rewrite based on packages/tao_bench/README.md,
run.py, run_autoscale.py, run_standalone.py, install_tao_bench.sh.

Supports both `tao_bench_standalone` (validated, single machine) and
`tao_bench_autoscale` (experimental, multi-instance/multi-machine) jobs.
run_autoscale.py's run_server() prints the authoritative result JSON
(total_qps/fast_qps/slow_qps/hit_ratio/num_data_points/spawned_instances/
successful_instances/score) that benchpress wraps into its own
`Results Report:` JSON block, parsed here via base_wrapper's
parse_benchpress_json() helper.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Dict, List

_WRAPPERS_DIR = Path(__file__).resolve().parent
if str(_WRAPPERS_DIR) not in sys.path:
    sys.path.insert(0, str(_WRAPPERS_DIR))

from dcperf_base_wrapper import BaseWrapper
from modules.dcperf_core_scaler import get_total_cores, scale_generator, set_core_count

_TAO_BENCH_REQUIRED_PACKAGES = ["binutils-devel"]
_ZLIB_URL = "https://zlib.net/fossils/zlib-1.3.1.tar.gz"
_ZLIB_ARCHIVE_NAME = "zlib-zlib-1.3.1.tar.gz"

_ANSI_GREEN = "\033[32m"
_ANSI_YELLOW = "\033[33m"
_ANSI_RESET = "\033[0m"


def _mark(ok: bool) -> str:
    encoding = (getattr(sys.stdout, "encoding", None) or "").lower()
    symbol = ("\u2713" if ok else "\u26a0") if "utf" in encoding else ("OK" if ok else "WARN")
    if not sys.stdout.isatty():
        return symbol
    color = _ANSI_GREEN if ok else _ANSI_YELLOW
    return f"{color}{symbol}{_ANSI_RESET}"


# ---------------------------------------------------------------------------
# SECTION A: class definition
# ---------------------------------------------------------------------------

class TaoBenchWrapper(BaseWrapper):
    WORKLOAD_NAME = "tao_bench"

    # Used by dcperf_run.py for the install phase -- both standalone and
    # autoscale run jobs share the same installed binaries, so install
    # always targets tao_bench_autoscale regardless of --mode.
    JOB_NAME = "tao_bench_autoscale"
    JOB_NAME_STANDALONE = "tao_bench_standalone"
    JOB_NAME_AUTOSCALE = "tao_bench_autoscale"

    # From official README - expected result ranges.
    EXPECTED_HIT_RATIO_MIN = 0.88
    EXPECTED_HIT_RATIO_MAX = 0.90
    CPU_UTIL_TARGET = "70-80% overall, 15-20% user"

    def get_workload_name(self) -> str:
        return self.WORKLOAD_NAME

    # ------------------------------------------------------------------
    # SECTION B: CLI arguments
    # ------------------------------------------------------------------

    @classmethod
    def add_arguments(cls, parser) -> None:
        parser.add_argument(
            "--mode", choices=["standalone", "autoscale"], default="standalone",
            help="standalone=single machine (validated), autoscale=multi-instance (experimental)",
        )
        parser.add_argument(
            "--num-servers", type=int, default=None,
            help="Number of server instances. If None, auto-calculated from cores.",
        )
        parser.add_argument("--memsize", type=int, default=64, help="Memory size per server in GB")
        parser.add_argument("--test-time", type=int, default=300, help="Test duration in seconds (default 300)")
        parser.add_argument("--port-start", type=int, default=11211, help="Starting port number for servers")
        parser.add_argument(
            "--interface", type=str, default=None,
            help="Network interface name (autoscale mode only, not standalone)",
        )
        parser.add_argument("--core-scaling", action="store_true", help="Run a core-scaling sweep")
        parser.add_argument("--total-cores", type=int, default=None, help="Total cores for scaling sweep")

    # ------------------------------------------------------------------
    # SECTION C: pre-install check
    # ------------------------------------------------------------------

    def pre_install_hook(self) -> bool:
        return self.pre_install_check()

    def pre_install_check(self) -> bool:
        ok = True
        ok = self._install_system_packages() and ok
        ok = self._refresh_ca_trust() and ok
        ok = self._ensure_zlib_download() and ok
        return ok

    def _run_privileged(self, cmd: List[str]) -> bool:
        self.logger.info("tao_bench_wrapper: %s", " ".join(cmd))
        if self.args.dry_run:
            return True
        try:
            subprocess.run(cmd, check=True, capture_output=True, text=True)
            return True
        except subprocess.CalledProcessError as exc:
            self.logger.error("tao_bench_wrapper: command failed: %s: %s", " ".join(cmd), exc.stderr)
            return False

    def _install_system_packages(self) -> bool:
        return self._run_privileged(["sudo", "dnf", "install", "-y", *_TAO_BENCH_REQUIRED_PACKAGES])

    def _refresh_ca_trust(self) -> bool:
        ok = self._run_privileged(["sudo", "dnf", "update", "-y", "ca-certificates"])
        ok = self._run_privileged(["sudo", "update-ca-trust"]) and ok
        return ok

    def _ensure_zlib_download(self) -> bool:
        """Pre-seed folly's download cache; getdeps' upstream URL 404s because
        zlib.net moves non-current releases to /fossils/."""
        dcperf_root = self.config.get("dcperf_root")
        if not dcperf_root:
            self.logger.warning("tao_bench_wrapper: dcperf_root not configured, skipping zlib pre-seed")
            return True

        downloads_dir = Path(dcperf_root) / "benchmarks" / "tao_bench" / "build-folly" / "downloads"
        if not downloads_dir.exists() and not self.args.dry_run:
            try:
                downloads_dir.mkdir(parents=True, exist_ok=True)
            except OSError as exc:
                self.logger.error("tao_bench_wrapper: cannot create %s: %s", downloads_dir, exc)
                return False

        archive = downloads_dir / _ZLIB_ARCHIVE_NAME
        if archive.exists() and archive.stat().st_size > 0:
            self.logger.info("tao_bench_wrapper: zlib archive already present at %s", archive)
            return True

        self.logger.info("tao_bench_wrapper: %s missing/empty, downloading fallback", archive)
        if self.args.dry_run:
            self.logger.info("tao_bench_wrapper: [dry-run] would download %s -> %s", _ZLIB_URL, archive)
            return True

        try:
            subprocess.run(
                ["wget", _ZLIB_URL, "-O", str(archive)],
                check=True, capture_output=True, text=True,
            )
            self.logger.info("tao_bench_wrapper: Downloaded zlib fallback for folly build")
            return archive.exists() and archive.stat().st_size > 0
        except subprocess.CalledProcessError as exc:
            self.logger.error("tao_bench_wrapper: zlib download failed: %s", exc.stderr)
            return False

    # ------------------------------------------------------------------
    # SECTION D: OS tuning (pre_run) -- delegated to dcperf_os_tuner.tune_tao_bench()
    # via BaseWrapper.pre_run()'s apply_all() routing on get_workload_name().
    # Background daemon thread tails tao-bench server log to trigger EMON on ready signal.
    # ------------------------------------------------------------------

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._stop_tail_event = None
        self._tail_thread = None

    def pre_run(self) -> Dict[str, Any]:
        """Apply the TaoBench OS tuning profile (tune_tao_bench, routed by base_wrapper).
        Also spawn a daemon thread to tail the server log and write to a stable symlink.
        """
        dcperf_root = self.config.get("dcperf_root")
        if dcperf_root:
            self._setup_server_log_tail(dcperf_root)
        return super().pre_run()

    def _setup_server_log_tail(self, dcperf_root: str) -> None:
        """Spawn a daemon thread that tails the tao-bench-server-*.log file and writes
        new lines to a stable file at <dcperf_root>/tao-bench-server-active.log.
        TMC watches this stable file for the ramp_string signal.
        """
        active_log_path = Path(dcperf_root) / "tao-bench-server-active.log"
        if not self.args.dry_run:
            try:
                active_log_path.touch(exist_ok=True)
            except OSError as exc:
                self.logger.error(
                    "tao_bench_wrapper: Failed to create stable log at %s: %s",
                    active_log_path, exc,
                )
                return

        self._stop_tail_event = threading.Event()
        self._tail_thread = threading.Thread(
            target=self._tail_server_log,
            args=(dcperf_root, str(active_log_path)),
            daemon=True,
        )
        self._tail_thread.start()
        self.logger.info(
            "tao_bench_wrapper: Spawned daemon thread to tail server log -> %s",
            active_log_path,
        )

    def _tail_server_log(self, dcperf_root: str, active_log_path: str) -> None:
        """Daemon thread: poll for new tao-bench-server-*.log under benchmark_metrics_*/,
        then continuously tail it and write new lines to active_log_path.
        """
        metrics_glob_start = time.time()
        last_log_file = None
        poll_interval = 2.0  # seconds
        max_wait = 600.0  # max 10 minutes to find log file

        while not self._stop_tail_event.is_set():
            # Poll for new log files
            try:
                candidates = sorted(
                    Path(dcperf_root).glob("benchmark_metrics_*/tao-bench-server-1-*.log")
                )
                if candidates:
                    current_log = candidates[-1]  # newest
                    # Check if this is a new file (created after pre_run started)
                    if (
                        last_log_file is None
                        or current_log != last_log_file
                    ):
                        if current_log.stat().st_mtime > metrics_glob_start:
                            last_log_file = current_log
                            self.logger.info(
                                "tao_bench_wrapper: Found new server log: %s",
                                last_log_file,
                            )
                            break  # Found it, start tailing
                elif time.time() - metrics_glob_start > max_wait:
                    self.logger.warning(
                        "tao_bench_wrapper: No tao-bench-server-*.log found after %d seconds."
                        " Tail thread exiting.",
                        int(max_wait),
                    )
                    return
            except Exception as exc:
                self.logger.error(
                    "tao_bench_wrapper: Error polling for server log: %s",
                    exc,
                )
                if time.time() - metrics_glob_start > max_wait:
                    return

            if self._stop_tail_event.wait(poll_interval):
                return  # Stop signal received

        # Tail the log file
        if last_log_file is None:
            return

        try:
            last_pos = 0
            tail_interval = 0.5  # seconds
            while not self._stop_tail_event.is_set():
                try:
                    with open(last_log_file, "r", encoding="utf-8", errors="ignore") as f:
                        f.seek(last_pos)
                        lines = f.readlines()
                        if lines:
                            with open(active_log_path, "a", encoding="utf-8") as out_f:
                                out_f.writelines(lines)
                            last_pos = f.tell()
                except OSError as exc:
                    self.logger.debug(
                        "tao_bench_wrapper: Error reading server log: %s",
                        exc,
                    )
                
                if self._stop_tail_event.wait(tail_interval):
                    break  # Stop signal received
        except Exception as exc:
            self.logger.error(
                "tao_bench_wrapper: Tail thread error: %s",
                exc,
            )

    def post_run(self) -> None:
        """Stop the daemon tail thread before calling base_wrapper's post_run()."""
        if self._stop_tail_event is not None:
            self._stop_tail_event.set()
        if self._tail_thread is not None and self._tail_thread.is_alive():
            self._tail_thread.join(timeout=5.0)
        super().post_run()

    # ------------------------------------------------------------------
    # SECTION E: job execution
    # ------------------------------------------------------------------

    def get_job_name(self) -> str:
        if self.args.mode == "standalone":
            return self.JOB_NAME_STANDALONE
        self.logger.warning(
            "tao_bench_wrapper: NOTE: Only standalone mode has been validated in this automation. "
            "Autoscale mode may need additional configuration."
        )
        return self.JOB_NAME_AUTOSCALE

    def get_tmc_profile(self) -> Dict[str, Any]:
        """TaoBench collects EMON triggered by the server ready signal.
        The daemon thread in pre_run() creates a stable symlink that TMC watches;
        when the server writes the ready line to the log, TMC detects it and starts
        EMON collection for the actual test window.
        """
        dcperf_root = self.config.get("dcperf_root")
        ramp_log = str(Path(dcperf_root) / "tao-bench-server-active.log") if dcperf_root else None
        return {
            "ramp_log": ramp_log,
            "ramp_string": "All slow threads are created and running, waiting for requests.",
            "ramp_timeout": max(5 * self.args.memsize, 1200) + 120,
            "start": 0,
            "end": self.args.test_time + 60,
        }

    def get_job_vars(self) -> Dict[str, Any]:
        job_vars: Dict[str, Any] = {
            "memsize": str(self.args.memsize),
            "test_time": str(self.args.test_time),
            "port_number_start": str(self.args.port_start),
        }
        if self.args.num_servers:
            job_vars["num_servers"] = str(self.args.num_servers)
        if self.args.interface and self.args.mode == "autoscale":
            job_vars["interface_name"] = self.args.interface
        if self.args.interface and self.args.mode == "standalone":
            self.logger.warning("tao_bench_wrapper: --interface is ignored in standalone mode")
        return job_vars

    # ------------------------------------------------------------------
    # SECTION F: output parsing
    # ------------------------------------------------------------------

    def parse_output(self, stdout: str) -> Dict[str, Any]:
        parsed: Dict[str, Any] = {}

        # Step 1+2: benchpress's structured "Results Report:" JSON block.
        bp = self.parse_benchpress_json(stdout)
        metrics = bp.get("metrics", {})
        if metrics:
            parsed["total_qps"] = metrics.get("total_qps")
            parsed["fast_qps"] = metrics.get("fast_qps")
            parsed["slow_qps"] = metrics.get("slow_qps")
            parsed["hit_ratio"] = metrics.get("hit_ratio")
            parsed["num_data_points"] = metrics.get("num_data_points")
            parsed["spawned_instances"] = metrics.get("spawned_instances")
            parsed["successful_instances"] = metrics.get("successful_instances")
            parsed["score"] = metrics.get("score", None)

            # Step 3: validate results.
            spawned = parsed.get("spawned_instances") or 0
            successful = parsed.get("successful_instances") or 0
            num_data_points = parsed.get("num_data_points") or 0
            hit_ratio = parsed.get("hit_ratio")

            expected_data_points = 58 * spawned
            if expected_data_points and num_data_points < expected_data_points * 0.9:
                self.logger.warning(
                    "tao_bench_wrapper: Only %s data points, expected ~%s. Run may be incomplete.",
                    num_data_points, expected_data_points,
                )
            if hit_ratio is not None and not (self.EXPECTED_HIT_RATIO_MIN <= hit_ratio <= self.EXPECTED_HIT_RATIO_MAX):
                self.logger.warning(
                    "tao_bench_wrapper: Hit ratio %.3f outside expected range [%s-%s]. Check memsize configuration.",
                    hit_ratio, self.EXPECTED_HIT_RATIO_MIN, self.EXPECTED_HIT_RATIO_MAX,
                )
            if successful < spawned:
                self.logger.error(
                    "tao_bench_wrapper: Only %s/%s instances succeeded.", successful, spawned,
                )

            return parsed

        # Step 4: regex fallback if JSON not found (e.g. dry-run stdout).
        match = re.search(r'"total_qps":\s*([\d.]+)', stdout)
        if match:
            parsed["total_qps"] = float(match.group(1))
        match = re.search(r'"hit_ratio":\s*([\d.]+)', stdout)
        if match:
            parsed["hit_ratio"] = float(match.group(1))
        match = re.search(r'"score":\s*([\d.]+)', stdout)
        if match:
            parsed["score"] = float(match.group(1))
        return parsed

    # ------------------------------------------------------------------
    # SECTION G: KPI calculation
    # ------------------------------------------------------------------

    def get_kpis(self, parsed: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "total_qps": parsed.get("total_qps", 0),
            "fast_qps": parsed.get("fast_qps", 0),
            "slow_qps": parsed.get("slow_qps", 0),
            "hit_ratio": parsed.get("hit_ratio", 0),
            "num_data_points": parsed.get("num_data_points", 0),
            "spawned_instances": parsed.get("spawned_instances", 0),
            "successful_instances": parsed.get("successful_instances", 0),
            "score": parsed.get("score", None),
            "mode": self.args.mode,
            "memsize_gb": self.args.memsize,
            "test_time_sec": self.args.test_time,
        }

    # ------------------------------------------------------------------
    # SECTION H: CSV schema
    # ------------------------------------------------------------------

    def get_csv_schema(self) -> List[str]:
        return [
            # System metadata
            "timestamp", "hostname", "cpu_model", "logical_cores", "os_distro", "kernel_version",
            # Run identity
            "run_id", "experiment", "orch_run_id",
            # Workload config
            "workload", "mode", "memsize_gb", "test_time_sec", "port_start", "num_servers_requested", "job_name",
            # KPIs
            "total_qps", "fast_qps", "slow_qps", "hit_ratio", "num_data_points",
            "spawned_instances", "successful_instances", "score",
            # Run outcome
            "status", "return_code", "duration_seconds", "output_directory",
            # EMON
            "emon_enabled", "emon_output_path",
        ]

    # ------------------------------------------------------------------
    # SECTION J: summary output
    # ------------------------------------------------------------------

    def print_summary(self, status: str, kpis: Dict[str, Any]) -> None:
        bar = "=" * 66
        thin = "-" * 66

        hit_ratio = kpis.get("hit_ratio") or 0
        hit_ok = self.EXPECTED_HIT_RATIO_MIN <= hit_ratio <= self.EXPECTED_HIT_RATIO_MAX
        spawned = kpis.get("spawned_instances", 0) or 0
        successful = kpis.get("successful_instances", 0) or 0
        instances_ok = successful == spawned and spawned > 0
        expected_data_points = 58 * spawned
        data_points = kpis.get("num_data_points", 0) or 0
        data_points_ok = expected_data_points == 0 or data_points >= expected_data_points * 0.9

        cpu_util = (self._cpu_monitor_result or {}).get("avg_overall_pct")
        cpu_within = (self._cpu_monitor_result or {}).get("within_target")

        lines = [
            bar,
            "TaoBench Results",
            f"Mode: {self.args.mode}",
            bar,
            f"Total QPS        : {kpis.get('total_qps', 0):,.0f}",
            f"Fast QPS         : {kpis.get('fast_qps', 0):,.0f}",
            f"Slow QPS         : {kpis.get('slow_qps', 0):,.0f}",
            f"Hit Ratio        : {hit_ratio:.3f} [EXPECTED: {self.EXPECTED_HIT_RATIO_MIN}-{self.EXPECTED_HIT_RATIO_MAX}] {_mark(hit_ok)}",
            f"Data Points      : {data_points:.0f} [EXPECTED: ~{expected_data_points:.0f}] {_mark(data_points_ok)}",
            f"Instances        : {successful}/{spawned} successful",
            f"DCPerf Score     : {kpis.get('score')}",
            thin,
        ]
        if cpu_util is not None:
            lines.append(f"CPU Utilization  : {cpu_util}% [TARGET: {self.CPU_UTIL_TARGET}] {_mark(bool(cpu_within))}")
        lines.append(f"Test Duration    : {self.args.test_time}s")
        lines.append(f"Output Directory : {self.run_dir}")
        lines.append(bar)

        text = "\n".join(lines)
        print(text)
        self.logger.info("tao_bench_wrapper: %s", text)
        if self.run_dir is not None:
            print(f"Output Directory: {self.run_dir.resolve()}")

    def run_core_scaling(self) -> int:
        total = self.args.total_cores or get_total_cores()
        step = self.config.get("core_step", 16)
        final_status = 0
        for cores in scale_generator(step, total, step):
            self.logger.info("tao_bench_wrapper: core-scaling step -> %s cores", cores)
            set_core_count(cores, self.logger, self.args.dry_run)
            if not self.args.dry_run:
                time.sleep(2)
            rc = self.run()
            final_status = final_status or rc
        return final_status

    def execute(self) -> int:
        if getattr(self.args, "core_scaling", False):
            return self.run_core_scaling()
        return self.run()


# ---------------------------------------------------------------------------
# SECTION K: standalone entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    wrapper = TaoBenchWrapper()
    raise SystemExit(wrapper.execute())

