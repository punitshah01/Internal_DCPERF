"""mediawiki wrapper — refactored from mw_perf.py.

Preserves: clients/duration/type CLI knobs, core-scaling sweep loop.
Fixes:
  - Core-scaling instance-count bug: original used `nproc` (total logical
    CPUs) to compute wrk client instances; now uses
    len(get_online_cores()) so scaling steps that haven't enabled all
    cores yet compute the correct instance count.
  - collect_perf.sh / collect_ptat.sh calls replaced by modules.perf_collector.
  - check=False subprocess calls replaced by check=True + proper error paths.
"""

from __future__ import annotations

import re
import sys
import time
from pathlib import Path
from typing import Any, Dict, List

_WRAPPERS_DIR = Path(__file__).resolve().parent
if str(_WRAPPERS_DIR) not in sys.path:
    sys.path.insert(0, str(_WRAPPERS_DIR))

from base_wrapper import BaseWrapper
from modules.core_scaler import get_online_cores, get_total_cores, scale_generator, set_core_count

_CPU_FREQ_CHECK_MARKER = "// disabled: fails on server CPUs"


class MediaWikiWrapper(BaseWrapper):
    JOB_NAME = "oss_performance_mediawiki_mlp"
    WORKLOAD_NAME = "mediawiki"

    def get_job_name(self) -> str:
        return self.JOB_NAME

    def get_workload_name(self) -> str:
        return self.WORKLOAD_NAME

    @classmethod
    def add_arguments(cls, parser) -> None:
        parser.add_argument("--clients", type=int, default=0, help="wrk client count (0 = auto from enabled cores)")
        parser.add_argument("--duration", type=int, default=10, help="Duration in minutes")
        parser.add_argument("--type", choices=["local", "remote"], default="local")
        parser.add_argument("--core-scaling", action="store_true", help="Run a core-scaling sweep")
        parser.add_argument("--total-cores", type=int, default=None, help="Total cores for scaling sweep")

    # ------------------------------------------------------------------
    # FIX 2: MediaWiki CPU frequency check crash
    # ------------------------------------------------------------------

    def pre_run(self) -> Dict[str, Any]:
        self.apply_mediawiki_patches()
        return super().pre_run()

    def apply_mediawiki_patches(self) -> bool:
        """Patch oss-performance/base/SystemChecks.php to skip CheckCPUFreq().

        oss-performance crashes with `SystemChecks::CheckCPUFreq() ->
        HH\\invariant_violation` on server CPUs that don't expose the
        frequency-scaling sysfs files it expects. Comments out the call
        inside CheckAll(); idempotent — checks for the marker first.
        """
        dcperf_root = self.config.get("dcperf_root")
        if not dcperf_root:
            self.logger.error("mediawiki_wrapper: dcperf_root not configured, cannot patch SystemChecks.php")
            return False

        patch_file = Path(dcperf_root) / "oss-performance" / "base" / "SystemChecks.php"
        if not patch_file.exists():
            self.logger.warning("mediawiki_wrapper: %s not found, skipping CPU freq patch", patch_file)
            return True

        text = patch_file.read_text()
        if _CPU_FREQ_CHECK_MARKER in text:
            self.logger.info("mediawiki_wrapper: CheckCPUFreq patch already applied, skipping")
            return True

        if "self::CheckCPUFreq();" not in text:
            self.logger.warning("mediawiki_wrapper: CheckCPUFreq() call not found in %s, nothing to patch", patch_file)
            return True

        patched = text.replace(
            "self::CheckCPUFreq();",
            f"// self::CheckCPUFreq(); {_CPU_FREQ_CHECK_MARKER}",
        )

        self.logger.info("mediawiki_wrapper: patching CheckCPUFreq() out of %s", patch_file)
        if self.args.dry_run:
            self.logger.info("mediawiki_wrapper: [dry-run] would disable CheckCPUFreq() in CheckAll()")
            return True

        try:
            patch_file.write_text(patched)
            self.logger.info("mediawiki_wrapper: patched %s (CheckCPUFreq disabled)", patch_file)
            return True
        except OSError as exc:
            self.logger.error("mediawiki_wrapper: failed to patch %s: %s", patch_file, exc)
            return False

    def _resolve_clients(self) -> int:
        if self.args.clients:
            return self.args.clients
        # Bug fix: derive instance count from currently *enabled* cores,
        # not the OS-reported total logical CPU count (nproc).
        online = len(get_online_cores())
        return max(1, (online + 99) // 100)

    def parse_output(self, stdout: str) -> Dict[str, Any]:
        parsed: Dict[str, Any] = {}
        match = re.search(r"Requests/sec:\s*([\d.]+)", stdout)
        if match:
            parsed["requests_per_sec"] = float(match.group(1))
        match = re.search(r"99%\s+([\d.]+)ms", stdout)
        if match:
            parsed["p99_latency_ms"] = float(match.group(1))
        return parsed

    def get_kpis(self, parsed: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "requests_per_sec": parsed.get("requests_per_sec", 0.0),
            "p99_latency_ms": parsed.get("p99_latency_ms", 0.0),
        }

    def get_csv_schema(self) -> List[str]:
        return ["clients", "duration_min", "test_type", "cores_enabled", "requests_per_sec", "p99_latency_ms"]

    def run_core_scaling(self) -> int:
        total = self.args.total_cores or get_total_cores()
        step = self.config.get("core_step", 16)
        final_status = 0
        for cores in scale_generator(step, total, step):
            self.logger.info("mediawiki_wrapper: core-scaling step -> %s cores", cores)
            set_core_count(cores, self.logger, self.args.dry_run)
            if not self.args.dry_run:
                time.sleep(2)
            self.args.clients = 0  # force recompute from newly enabled cores
            rc = self.run()
            final_status = final_status or rc
        return final_status


def main() -> int:
    wrapper = MediaWikiWrapper()
    wrapper.args.clients = wrapper._resolve_clients() if wrapper.args.clients == 0 else wrapper.args.clients
    if getattr(wrapper.args, "core_scaling", False):
        return wrapper.run_core_scaling()
    return wrapper.run()


if __name__ == "__main__":
    raise SystemExit(main())
