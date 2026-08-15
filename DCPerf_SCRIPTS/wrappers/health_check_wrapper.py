"""health_check wrapper — new, no prior legacy script existed.

Based on benchpress/config/jobs.yml (`health_check` job, roles
server/client) and packages/health_check/run.sh (iperf3 network checks +
sleepbench CPU/scheduling checks + mm-mem or loaded-latency memory
checks depending on architecture). KPI is PASS/FAIL per component rather
than a single numeric value.
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


class HealthCheckWrapper(BaseWrapper):
    JOB_NAME = "health_check"
    WORKLOAD_NAME = "health_check"

    def get_job_name(self) -> str:
        return self.JOB_NAME

    def get_workload_name(self) -> str:
        return self.WORKLOAD_NAME

    @classmethod
    def add_arguments(cls, parser) -> None:
        parser.add_argument("--role", choices=["server", "client"], default="server")
        parser.add_argument("--clients", default="", help="Comma-separated client IPs (server role only)")

    def run_benchpress(self, job: str, extra_args: List[str]):
        extra_args = ["-r", self.args.role] + extra_args
        return super().run_benchpress(job, extra_args)

    def parse_output(self, stdout: str) -> Dict[str, Any]:
        parsed: Dict[str, Any] = {
            "network_pass": bool(re.search(r"\bconnected\b", stdout, re.IGNORECASE))
            and not re.search(r"\bunable to connect\b|error", stdout, re.IGNORECASE),
            "cpu_pass": "error" not in stdout.lower(),
        }
        return parsed

    def get_kpis(self, parsed: Dict[str, Any]) -> Dict[str, Any]:
        network_pass = 1.0 if parsed.get("network_pass") else 0.0
        cpu_pass = 1.0 if parsed.get("cpu_pass") else 0.0
        return {
            "network_pass": network_pass,
            "cpu_pass": cpu_pass,
            "overall_pass": 1.0 if (network_pass and cpu_pass) else 0.0,
        }

    def get_csv_schema(self) -> List[str]:
        return ["role", "network_pass", "cpu_pass", "overall_pass"]


def main() -> int:
    wrapper = HealthCheckWrapper()
    return wrapper.run()


if __name__ == "__main__":
    raise SystemExit(main())
