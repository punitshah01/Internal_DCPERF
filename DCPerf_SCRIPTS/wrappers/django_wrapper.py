"""django_workload wrapper — refactored from dj_perf.py.

Preserves: role/duration/db-client CLI knobs, core-scaling sweep loop.
Fixes: collect_perf.sh call replaced by modules.perf_collector; check=False
subprocess calls replaced by base_wrapper's check=True + proper error paths.
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
from modules.core_scaler import get_total_cores, scale_generator, set_core_count


class DjangoWrapper(BaseWrapper):
    JOB_NAME = "django_workload_default"
    WORKLOAD_NAME = "django_workload"

    def get_job_name(self) -> str:
        return self.JOB_NAME

    def get_workload_name(self) -> str:
        return self.WORKLOAD_NAME

    @classmethod
    def add_arguments(cls, parser) -> None:
        parser.add_argument("--role", choices=["db", "clientserver", "standalone"], default="clientserver")
        parser.add_argument("--duration", default="180s", help="Siege duration, e.g. 180s")
        parser.add_argument("--db-client-ip", default=None, help="DB client IP (falls back to config db_client_ip)")
        parser.add_argument("--core-scaling", action="store_true", help="Run a core-scaling sweep")
        parser.add_argument("--total-cores", type=int, default=None, help="Total cores for scaling sweep")

    def validate_config(self) -> None:
        if not self.args.db_client_ip:
            self.args.db_client_ip = self.config_manager.require("db_client_ip")

    def run_benchpress(self, job: str, extra_args: List[str]):
        extra_args = ["-r", self.args.role] + extra_args
        return super().run_benchpress(job, extra_args)

    def pre_run(self) -> Dict[str, Any]:
        """Apply the Django OS tuning profile (tune_django, routed by base_wrapper)."""
        return super().pre_run()

    def parse_output(self, stdout: str) -> Dict[str, Any]:
        parsed: Dict[str, Any] = {"raw_lines": stdout.count("\n")}
        # Siege summary line: "Transaction rate:      123.45 trans/sec"
        match = re.search(r"Transaction rate:\s*([\d.]+)\s*trans/sec", stdout)
        if match:
            parsed["qps"] = float(match.group(1))
        match = re.search(r"Response time:\s*([\d.]+)\s*secs", stdout)
        if match:
            parsed["p99_latency_ms"] = float(match.group(1)) * 1000.0
        return parsed

    def get_kpis(self, parsed: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "qps": parsed.get("qps", 0.0),
            "p99_latency_ms": parsed.get("p99_latency_ms", 0.0),
        }

    def get_csv_schema(self) -> List[str]:
        return ["role", "duration", "db_client_ip", "cores_enabled", "qps", "p99_latency_ms"]

    def run_core_scaling(self) -> int:
        total = self.args.total_cores or get_total_cores()
        step = self.config.get("core_step", 16)
        final_status = 0
        for cores in scale_generator(step, total, step):
            self.logger.info("django_wrapper: core-scaling step -> %s cores", cores)
            set_core_count(cores, self.logger, self.args.dry_run)
            if not self.args.dry_run:
                time.sleep(2)
            rc = self.run()
            final_status = final_status or rc
        return final_status


def main() -> int:
    wrapper = DjangoWrapper()
    if getattr(wrapper.args, "core_scaling", False):
        return wrapper.run_core_scaling()
    return wrapper.run()


if __name__ == "__main__":
    raise SystemExit(main())
