"""wdl_bench wrapper — new, no prior legacy script existed.

Based on benchpress/config/jobs_wdl.yml (`folly_single_core` job,
benchmark: wdl_bench) and packages/wdl_bench/run.sh (per-core numactl-
pinned folly micro-benchmarks, aggregated via aggregate_result.py).
wdl_bench jobs live in a separate registry file from the default
benchmarks.yml/jobs.yml, so benchpress_cli.py must be invoked with
`-b config/benchmarks_wdl.yml` to resolve them.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any, Dict, List

_WRAPPERS_DIR = Path(__file__).resolve().parent
if str(_WRAPPERS_DIR) not in sys.path:
    sys.path.insert(0, str(_WRAPPERS_DIR))

from base_wrapper import BaseWrapper


class WdlBenchWrapper(BaseWrapper):
    JOB_NAME = "folly_single_core"
    WORKLOAD_NAME = "wdl_bench"

    def get_job_name(self) -> str:
        return self.JOB_NAME

    def get_workload_name(self) -> str:
        return self.WORKLOAD_NAME

    def get_benchpress_global_args(self) -> List[str]:
        dcperf_root = self.config.get("dcperf_root")
        benchmarks_wdl = Path(dcperf_root) / "benchpress" / "config" / "benchmarks_wdl.yml" if dcperf_root else None
        jobs_wdl = Path(dcperf_root) / "benchpress" / "config" / "jobs_wdl.yml" if dcperf_root else None
        args: List[str] = []
        if benchmarks_wdl:
            args += ["-b", str(benchmarks_wdl)]
        if jobs_wdl:
            args += ["-j", str(jobs_wdl)]
        return args

    def parse_output(self, stdout: str) -> Dict[str, Any]:
        parsed: Dict[str, Any] = {}
        # aggregate_result.py output, e.g. "throughput: 123456 ops/sec"
        match = re.search(r"throughput[:\s]+([\d.]+)", stdout, re.IGNORECASE)
        if match:
            parsed["throughput"] = float(match.group(1))
        match = re.search(r"latency[:\s]+([\d.]+)\s*ns", stdout, re.IGNORECASE)
        if match:
            parsed["latency_ns"] = float(match.group(1))
        return parsed

    def get_kpis(self, parsed: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "throughput": parsed.get("throughput", 0.0),
            "latency_ns": parsed.get("latency_ns", 0.0),
        }

    def get_csv_schema(self) -> List[str]:
        return ["throughput", "latency_ns"]


def main() -> int:
    wrapper = WdlBenchWrapper()
    return wrapper.run()


if __name__ == "__main__":
    raise SystemExit(main())
