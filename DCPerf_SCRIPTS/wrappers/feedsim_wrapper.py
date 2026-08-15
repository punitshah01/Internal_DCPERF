"""feedsim wrapper — refactored from fs_perf.py.

Preserves: --instances, core-scaling sweep loop.
Fixes: collect_perf.sh call replaced by modules.perf_collector; check=False
subprocess calls replaced by base_wrapper's check=True + proper error paths.
"""

from __future__ import annotations

import re
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

# FIX 1: gengetopt-2.23 mirror fallback chain (in download-URL preference order).
_GENGETOPT_MIRRORS = [
    "https://ftpmirror.gnu.org/gengetopt/gengetopt-2.23.tar.xz",
    "https://ftp.gnu.org/gnu/gengetopt/gengetopt-2.23.tar.xz",
]
_GENGETOPT_PATCH_MARKER = "# DCPERF_SCRIPTS_GENGETOPT_FALLBACK_APPLIED"


class FeedsimWrapper(BaseWrapper):
    JOB_NAME = "feedsim_autoscale"
    WORKLOAD_NAME = "feedsim"

    def get_job_name(self) -> str:
        return self.JOB_NAME

    def get_workload_name(self) -> str:
        return self.WORKLOAD_NAME

    @classmethod
    def add_arguments(cls, parser) -> None:
        parser.add_argument("--instances", type=int, default=1, help="Number of FeedSim instances")
        parser.add_argument("--core-scaling", action="store_true", help="Run a core-scaling sweep")
        parser.add_argument("--total-cores", type=int, default=None, help="Total cores for scaling sweep")

    # ------------------------------------------------------------------
    # FIX 1: FeedSim gengetopt download fallback
    # ------------------------------------------------------------------

    def pre_install_hook(self) -> bool:
        return self.pre_install_patch()

    def pre_install_patch(self) -> bool:
        """Patch packages/feedsim/install_feedsim.sh with a gengetopt mirror
        fallback chain before benchpress install runs.

        gengetopt-2.23 is required to build FeedSim; the upstream installer's
        single download URL is frequently unreachable. This patches in a
        try-next-mirror chain, plus a --no-check-certificate retry on the
        primary GNU mirror, before giving up with a clear error.
        """
        dcperf_root = self.config.get("dcperf_root")
        if not dcperf_root:
            self.logger.error("feedsim_wrapper: dcperf_root not configured, cannot patch install script")
            return False

        install_script = Path(dcperf_root) / "packages" / "feedsim" / "install_feedsim.sh"
        if not install_script.exists():
            self.logger.warning("feedsim_wrapper: %s not found, skipping gengetopt patch", install_script)
            return True

        text = install_script.read_text()
        if _GENGETOPT_PATCH_MARKER in text:
            self.logger.info("feedsim_wrapper: gengetopt fallback already patched, skipping")
            return True

        fallback_block = self._build_gengetopt_fallback_block()
        self.logger.info("feedsim_wrapper: patching gengetopt mirror fallback into %s", install_script)

        if self.args.dry_run:
            self.logger.info("feedsim_wrapper: [dry-run] would prepend gengetopt fallback block")
            return True

        try:
            install_script.write_text(fallback_block + "\n" + text)
            return True
        except OSError as exc:
            self.logger.error("feedsim_wrapper: failed to patch %s: %s", install_script, exc)
            return False

    @staticmethod
    def _build_gengetopt_fallback_block() -> str:
        return (
            f"{_GENGETOPT_PATCH_MARKER}\n"
            "# Auto-inserted by feedsim_wrapper.pre_install_patch(): gengetopt-2.23\n"
            "# mirror fallback chain (try 1 -> try 2 -> --no-check-certificate retry).\n"
            "_dcperf_scripts_fetch_gengetopt() {\n"
            f"  wget -q '{_GENGETOPT_MIRRORS[0]}' -O gengetopt-2.23.tar.xz && return 0\n"
            f"  wget -q '{_GENGETOPT_MIRRORS[1]}' -O gengetopt-2.23.tar.xz && return 0\n"
            f"  wget -q --no-check-certificate '{_GENGETOPT_MIRRORS[1]}' -O gengetopt-2.23.tar.xz && return 0\n"
            "  echo 'ERROR: gengetopt-2.23 download failed from all mirrors.' >&2\n"
            "  echo 'Manually download gengetopt-2.23.tar.xz and place it in the' >&2\n"
            "  echo 'current install working directory, then re-run install.' >&2\n"
            "  return 1\n"
            "}\n"
        )

    def _try_gengetopt_mirrors(self, dest: Path) -> bool:
        """Standalone Python fallback (used if the shell patch path is unavailable)."""
        attempts = [
            ["wget", "-q", _GENGETOPT_MIRRORS[0], "-O", str(dest)],
            ["wget", "-q", _GENGETOPT_MIRRORS[1], "-O", str(dest)],
            ["wget", "-q", "--no-check-certificate", _GENGETOPT_MIRRORS[1], "-O", str(dest)],
        ]
        for idx, cmd in enumerate(attempts, start=1):
            self.logger.info("feedsim_wrapper: gengetopt download attempt %s: %s", idx, " ".join(cmd))
            if self.args.dry_run:
                continue
            try:
                subprocess.run(cmd, check=True, capture_output=True, text=True)
                if dest.exists() and dest.stat().st_size > 0:
                    self.logger.info("feedsim_wrapper: gengetopt downloaded via mirror %s", idx)
                    return True
            except subprocess.CalledProcessError:
                continue
        if not self.args.dry_run:
            raise RuntimeError(
                "gengetopt-2.23 download failed from all 3 mirrors. "
                "Manually download it and place it under the FeedSim build downloads directory."
            )
        return True

    def pre_run(self) -> Dict[str, Any]:
        """Apply the FeedSim OS tuning profile (tune_feedsim, routed by base_wrapper)."""
        return super().pre_run()

    def parse_output(self, stdout: str) -> Dict[str, Any]:
        parsed: Dict[str, Any] = {}
        match = re.search(r"QPS[:\s]+([\d.]+)", stdout)
        if match:
            parsed["qps"] = float(match.group(1))
        match = re.search(r"p95[:\s]+([\d.]+)\s*ms", stdout, re.IGNORECASE)
        if match:
            parsed["p95_latency_ms"] = float(match.group(1))
        return parsed

    def get_kpis(self, parsed: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "qps": parsed.get("qps", 0.0),
            "p95_latency_ms": parsed.get("p95_latency_ms", 0.0),
        }

    def get_csv_schema(self) -> List[str]:
        return ["instances", "cores_enabled", "qps", "p95_latency_ms"]

    def run_core_scaling(self) -> int:
        total = self.args.total_cores or get_total_cores()
        step = self.config.get("core_step", 16)
        final_status = 0
        for cores in scale_generator(step, total, step):
            self.logger.info("feedsim_wrapper: core-scaling step -> %s cores", cores)
            set_core_count(cores, self.logger, self.args.dry_run)
            if not self.args.dry_run:
                time.sleep(2)
            rc = self.run()
            final_status = final_status or rc
        return final_status


def main() -> int:
    wrapper = FeedsimWrapper()
    if getattr(wrapper.args, "core_scaling", False):
        return wrapper.run_core_scaling()
    return wrapper.run()


if __name__ == "__main__":
    raise SystemExit(main())
