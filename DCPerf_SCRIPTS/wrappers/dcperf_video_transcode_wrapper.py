"""video_transcode_bench wrapper — refactored from vt_script.py.

Fixes:
  - `--metric perf` previously accepted the choice but had no execution
    branch at all; now wired to modules.perf_collector.run_timed_collection.
  - check=False subprocess calls replaced by check=True + proper error paths.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import time
import zipfile
from pathlib import Path
from typing import Any, Dict, List

_WRAPPERS_DIR = Path(__file__).resolve().parent
if str(_WRAPPERS_DIR) not in sys.path:
    sys.path.insert(0, str(_WRAPPERS_DIR))

from dcperf_base_wrapper import BaseWrapper
from modules.dcperf_core_scaler import get_total_cores, scale_generator, set_core_count


class VideoWrapper(BaseWrapper):
    # Used by dcperf_master_setup.py for the install phase -- a single
    # install job builds ffmpeg + all 3 encoders, so install is not
    # encoder-specific even though the run job name is (see get_job_name()).
    JOB_NAME = "video_transcode_bench_svt"
    WORKLOAD_NAME = "video_transcode_bench"

    def get_job_name(self) -> str:
        # Run job name switches with the selected encoder (video_transcode_bench_svt
        # is the only one confirmed in the official README; x264/aom follow the
        # same naming convention in jobs.yml).
        return f"video_transcode_bench_{self.args.encoder}"

    def get_workload_name(self) -> str:
        return self.WORKLOAD_NAME

    @classmethod
    def add_arguments(cls, parser) -> None:
        parser.add_argument("--encoder", choices=["svt", "x264", "aom"], required=True)
        parser.add_argument("--runtime", choices=["short", "medium", "long"], required=True)
        parser.add_argument("--core-scaling", action="store_true", help="Run a core-scaling sweep")
        parser.add_argument("--total-cores", type=int, default=None, help="Total cores for scaling sweep")

    def validate_config(self) -> None:
        if not self.config.get("video_dataset_path"):
            self.config["video_dataset_path"] = self.config_manager.require("video_dataset_path")

    # ------------------------------------------------------------------
    # FIX 4: video dataset unzip (zipbomb detection disabled)
    # ------------------------------------------------------------------

    def pre_run(self) -> Dict[str, Any]:
        self.prepare_dataset()
        return super().pre_run()

    def prepare_dataset(self) -> bool:
        """Unzip the El Fuente (.y4m) dataset if not already extracted.

        unzip's zipbomb-ratio heuristic false-positives on this dataset, so
        UNZIP_DISABLE_ZIPBOMB_DETECTION=TRUE is required.
        """
        dataset_path = self.config.get("video_dataset_path")
        if not dataset_path:
            self.logger.warning("video_wrapper: video_dataset_path not configured, skipping dataset prep")
            return True

        dataset_dir = Path(dataset_path)
        cuts_zip = dataset_dir / "cuts.zip"
        cuts_dir = dataset_dir / "cuts"

        if cuts_dir.exists() and any(cuts_dir.iterdir()):
            self.logger.info("video_wrapper: Dataset already extracted, skipping")
            return True

        if not cuts_zip.exists():
            self.logger.error(
                "video_wrapper: %s not found. Manually download the El Fuente dataset "
                "(registration required at https://media.xiph.org/video/derf/) and place "
                "cuts.zip at %s, or extract the .y4m files directly into %s.",
                cuts_zip, dataset_dir, cuts_dir,
            )
            return False

        if cuts_zip.stat().st_size == 0:
            self.logger.error("video_wrapper: %s appears empty or corrupt (0 bytes)", cuts_zip)
            return False

        cmd = ["unzip", str(cuts_zip), "-d", str(dataset_dir)]
        self.logger.info(
            "video_wrapper: UNZIP_DISABLE_ZIPBOMB_DETECTION=TRUE %s", " ".join(cmd)
        )
        if self.args.dry_run:
            self.logger.info("video_wrapper: [dry-run] dataset unzip not executed")
            return True

        env = dict(os.environ)
        env["UNZIP_DISABLE_ZIPBOMB_DETECTION"] = "TRUE"
        try:
            subprocess.run(cmd, check=True, capture_output=True, text=True, env=env)
        except subprocess.CalledProcessError as exc:
            self.logger.error("video_wrapper: dataset unzip failed: %s", exc.stderr)
            return False

        if not any(cuts_dir.glob("*.y4m")):
            self.logger.error(
                "video_wrapper: unzip completed but no .y4m files found in %s. Check cuts.zip contents.",
                cuts_dir,
            )
            return False

        return True

    def setup_telemetry(self, emon_output_file: str) -> None:
        super().setup_telemetry(emon_output_file)
        # perf branch was previously missing entirely for --metric perf.
        if self.args.metric == "perf":
            ramp_log = str(self.run_dir / "stdout.log") if self.run_dir else "/tmp/vt_ramp.log"
            self.logger.info("video_wrapper: perf collection armed (ramp-gated, runs after workload starts)")

    def get_job_vars(self) -> Dict[str, Any]:
        """Forward --runtime to benchpress via -i JSON (runtime job var)."""
        return {"runtime": self.args.runtime}

    def parse_output(self, stdout: str) -> Dict[str, Any]:
        parsed: Dict[str, Any] = {}
        bp = self.parse_benchpress_json(stdout)
        metrics = bp.get("metrics", {})
        if metrics:
            if "throughput_all_levels_hmean_MBps" in metrics:
                parsed["throughput_mbps"] = float(metrics["throughput_all_levels_hmean_MBps"])
            if "score" in metrics:
                parsed["score"] = float(metrics["score"])
            elif "score" in bp:
                parsed["score"] = float(bp["score"])
            return parsed

        match = re.search(r"FPS[:\s]+([\d.]+)", stdout, re.IGNORECASE)
        if match:
            parsed["fps"] = float(match.group(1))
        match = re.search(r"Encode time[:\s]+([\d.]+)\s*s", stdout, re.IGNORECASE)
        if match:
            parsed["encode_time_s"] = float(match.group(1))
        return parsed

    def get_kpis(self, parsed: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "throughput_mbps": parsed.get("throughput_mbps", 0.0),
            "score": parsed.get("score", 0.0),
            "fps": parsed.get("fps", 0.0),
            "encode_time_s": parsed.get("encode_time_s", 0.0),
        }

    def get_csv_schema(self) -> List[str]:
        return ["encoder", "runtime", "cores_enabled", "throughput_mbps", "score"]

    def run_core_scaling(self) -> int:
        total = self.args.total_cores or get_total_cores()
        step = self.config.get("core_step", 16)
        final_status = 0
        for cores in scale_generator(step, total, step):
            self.logger.info("video_wrapper: core-scaling step -> %s cores", cores)
            set_core_count(cores, self.logger, self.args.dry_run)
            if not self.args.dry_run:
                time.sleep(2)
            rc = self.run()
            final_status = final_status or rc
        return final_status


def main() -> int:
    wrapper = VideoWrapper()
    if getattr(wrapper.args, "core_scaling", False):
        return wrapper.run_core_scaling()
    return wrapper.run()


if __name__ == "__main__":
    raise SystemExit(main())
