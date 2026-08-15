"""tao_bench wrapper — new, no prior legacy script existed.

Based on benchpress/config/jobs.yml (`tao_bench_autoscale` job) and
packages/tao_bench/run.py (internal server/client subcommands driven by
run_autoscale.py). Supports --role server|client for multi-machine
deployments per the workload's documented 3-machine (1 server + 2
clients) topology.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List

_WRAPPERS_DIR = Path(__file__).resolve().parent
if str(_WRAPPERS_DIR) not in sys.path:
    sys.path.insert(0, str(_WRAPPERS_DIR))

from base_wrapper import BaseWrapper
from modules.core_scaler import get_total_cores, scale_generator, set_core_count

_TAO_BENCH_REQUIRED_PACKAGES = ["binutils-devel"]
_ZLIB_URL = "https://zlib.net/fossils/zlib-1.3.1.tar.gz"
_ZLIB_ARCHIVE_NAME = "zlib-zlib-1.3.1.tar.gz"


class TaoBenchWrapper(BaseWrapper):
    JOB_NAME = "tao_bench_autoscale"
    WORKLOAD_NAME = "tao_bench"

    def get_job_name(self) -> str:
        return self.JOB_NAME

    def get_workload_name(self) -> str:
        return self.WORKLOAD_NAME

    @classmethod
    def add_arguments(cls, parser) -> None:
        parser.add_argument("--role", choices=["server", "client"], default="server")
        parser.add_argument("--core-scaling", action="store_true", help="Run a core-scaling sweep")
        parser.add_argument("--total-cores", type=int, default=None, help="Total cores for scaling sweep")

    # ------------------------------------------------------------------
    # FIX 3: TaoBench missing system packages / zlib download
    # ------------------------------------------------------------------

    def pre_install_hook(self) -> bool:
        return self.pre_install_check()

    def pre_install_check(self) -> bool:
        """Verify/install required system packages, refresh CA trust, and
        pre-seed the zlib download folly's build needs before install runs.
        """
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
        ok = self._run_privileged(["sudo", "dnf", "install", "-y", *_TAO_BENCH_REQUIRED_PACKAGES])
        return ok

    def _refresh_ca_trust(self) -> bool:
        ok = self._run_privileged(["sudo", "dnf", "update", "-y", "ca-certificates"])
        ok = self._run_privileged(["sudo", "update-ca-trust"]) and ok
        return ok

    def _ensure_zlib_download(self) -> bool:
        dcperf_root = self.config.get("dcperf_root")
        if not dcperf_root:
            self.logger.warning("tao_bench_wrapper: dcperf_root not configured, skipping zlib pre-seed")
            return True

        downloads_dir = Path(dcperf_root) / "benchmarks" / "tao_bench" / "build-folly" / "downloads"
        archive = downloads_dir / _ZLIB_ARCHIVE_NAME

        if archive.exists() and archive.stat().st_size > 0:
            self.logger.info("tao_bench_wrapper: zlib archive already present at %s", archive)
            return True

        self.logger.info("tao_bench_wrapper: zlib archive missing/empty, downloading to %s", archive)
        if self.args.dry_run:
            self.logger.info("tao_bench_wrapper: [dry-run] would download %s -> %s", _ZLIB_URL, archive)
            return True

        downloads_dir.mkdir(parents=True, exist_ok=True)
        try:
            subprocess.run(
                ["wget", _ZLIB_URL, "-O", str(archive)],
                check=True, capture_output=True, text=True,
            )
            return archive.exists() and archive.stat().st_size > 0
        except subprocess.CalledProcessError as exc:
            self.logger.error("tao_bench_wrapper: zlib download failed: %s", exc.stderr)
            return False

    def pre_run(self) -> Dict[str, Any]:
        """Apply the TaoBench OS tuning profile (tune_tao_bench, routed by base_wrapper)."""
        return super().pre_run()

    def run_benchpress(self, job: str, extra_args: List[str]):
        # tao_bench_autoscale is a multi-server-instance job; role selection
        # is passed through to benchpress's -r/--role flag.
        extra_args = ["-r", self.args.role] + extra_args
        return super().run_benchpress(job, extra_args)

    def parse_output(self, stdout: str) -> Dict[str, Any]:
        parsed: Dict[str, Any] = {}
        match = re.search(r"QPS[:\s]+([\d.]+)", stdout, re.IGNORECASE)
        if match:
            parsed["qps"] = float(match.group(1))
        match = re.search(r"p99[:\s]+([\d.]+)\s*us", stdout, re.IGNORECASE)
        if match:
            parsed["p99_latency_us"] = float(match.group(1))
        return parsed

    def get_kpis(self, parsed: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "qps": parsed.get("qps", 0.0),
            "p99_latency_us": parsed.get("p99_latency_us", 0.0),
        }

    def get_csv_schema(self) -> List[str]:
        return ["role", "cores_enabled", "qps", "p99_latency_us"]

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


def main() -> int:
    wrapper = TaoBenchWrapper()
    if getattr(wrapper.args, "core_scaling", False):
        return wrapper.run_core_scaling()
    return wrapper.run()


if __name__ == "__main__":
    raise SystemExit(main())
