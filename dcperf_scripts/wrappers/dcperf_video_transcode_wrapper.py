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
import tarfile
import time
from pathlib import Path
from typing import Any, Dict, List

_WRAPPERS_DIR = Path(__file__).resolve().parent
if str(_WRAPPERS_DIR) not in sys.path:
    sys.path.insert(0, str(_WRAPPERS_DIR))

from dcperf_base_wrapper import BaseWrapper
from modules.dcperf_core_scaler import get_total_cores, scale_generator, set_core_count

_DATASET_URL = (
    "https://af01p-or.devtools.intel.com/artifactory/"
    "dpgpaivsoworkloads-or-local/base/workloads/dcperf/cuts.tar.gz"
)


class VideoWrapper(BaseWrapper):
    # Used by dcperf_master_setup.py for the install phase -- a single
    # install job builds ffmpeg + all 3 encoders, so install is not
    # encoder-specific even though the run job name is (see get_job_name()).
    JOB_NAME = "video_transcode_bench_svt"
    WORKLOAD_NAME = "video_transcode_bench"
    VALID_CODECS = {"svt", "x264", "aom"}

    def get_job_name(self) -> str:
        # Run job name switches with the selected encoder (video_transcode_bench_svt
        # is the only one confirmed in the official README; x264/aom follow the
        # same naming convention in jobs.yml).
        return f"video_transcode_bench_{self.args.encoder}"

    def get_workload_name(self) -> str:
        return self.WORKLOAD_NAME

    @classmethod
    def add_arguments(cls, parser) -> None:
        # Not required=True: dcperf_run.py's install path instantiates this
        # wrapper with only --dry-run/--force (install builds all 3 encoders,
        # see JOB_NAME comment), so encoder/runtime must stay optional here.
        # Enforced instead in validate_config(), which only runs before run().
        parser.add_argument("--encoder", choices=["svt", "x264", "aom"], default=None)
        parser.add_argument(
            "--codecs",
            default=None,
            help="Comma-separated codec list (e.g. svt,aom,x264). If set, runs each codec sequentially.",
        )
        parser.add_argument("--runtime", choices=["short", "medium", "long"], default=None)
        parser.add_argument("--core-scaling", action="store_true", help="Run a core-scaling sweep")
        parser.add_argument("--total-cores", type=int, default=None, help="Total cores for scaling sweep")

    def _resolve_codecs(self) -> List[str]:
        if self.args.codecs:
            codecs = [c.strip() for c in self.args.codecs.split(",") if c.strip()]
            if not codecs:
                raise SystemExit("video_transcode_bench: --codecs is empty; provide at least one codec")
        elif self.args.encoder:
            codecs = [self.args.encoder]
        else:
            raise SystemExit("video_transcode_bench: provide --codecs or --encoder")

        invalid = [codec for codec in codecs if codec not in self.VALID_CODECS]
        if invalid:
            raise SystemExit(
                "video_transcode_bench: unsupported codec(s) "
                f"{', '.join(invalid)} (supported: svt,x264,aom)"
            )
        return codecs

    def validate_config(self) -> None:
        self._resolved_codecs = self._resolve_codecs()
        if not self.args.runtime:
            raise SystemExit("video_transcode_bench: --runtime is required (short|medium|long)")
        if not self.config.get("video_dataset_path"):
            self.config["video_dataset_path"] = self.config_manager.require("video_dataset_path")

    def pre_install_hook(self) -> bool:
        """Download/extract the dataset once at install time, not on every run."""
        if not self.config.get("video_dataset_path"):
            self.config["video_dataset_path"] = self.config_manager.require("video_dataset_path")
        return self.prepare_dataset()

    def is_install_satisfied(self) -> bool:
        return self._dataset_ready()

    def pre_run(self) -> Dict[str, Any]:
        if not self._dataset_ready():
            self.logger.error(
                "video_wrapper: dataset missing at %s -- run "
                "dcperf_run.py --install-only --workload video_transcode_bench first",
                self.config.get("video_dataset_path"),
            )
        return super().pre_run()

    def _dataset_ready(self) -> bool:
        dataset_path = self.config.get("video_dataset_path")
        if not dataset_path:
            return False
        cuts_dir = Path(dataset_path) / "cuts"
        return cuts_dir.exists() and any(cuts_dir.iterdir())

    def prepare_dataset(self) -> bool:
        """Download and extract the El Fuente (.y4m) dataset if not already present."""
        dataset_path = self.config.get("video_dataset_path")
        if not dataset_path:
            self.logger.warning("video_wrapper: video_dataset_path not configured, skipping dataset prep")
            return True

        dataset_dir = Path(dataset_path)
        cuts_dir = dataset_dir / "cuts"

        if cuts_dir.exists() and any(cuts_dir.iterdir()):
            self.logger.info("video_wrapper: Dataset already extracted, skipping")
            return True

        archive = dataset_dir / "cuts.tar.gz"
        archive_url = self.config.get("video_dataset_url") or _DATASET_URL
        if not archive.exists():
            self.logger.info("video_wrapper: downloading dataset archive from %s", archive_url)
            if self.args.dry_run:
                return True
            try:
                dataset_dir.mkdir(parents=True, exist_ok=True)
                subprocess.run(
                    ["wget", "-q", archive_url, "-O", str(archive)],
                    check=True, capture_output=True, text=True,
                )
            except subprocess.CalledProcessError as exc:
                self.logger.error("video_wrapper: dataset download failed: %s", exc.stderr)
                return False

        if archive.stat().st_size == 0:
            self.logger.error("video_wrapper: %s appears empty or corrupt (0 bytes)", archive)
            return False

        self.logger.info("video_wrapper: extracting %s into %s", archive, dataset_dir)
        if self.args.dry_run:
            self.logger.info("video_wrapper: [dry-run] dataset extraction not executed")
            return True

        try:
            with tarfile.open(archive, "r:gz") as tar:
                tar.extractall(dataset_dir, filter="data")
        except (OSError, tarfile.TarError) as exc:
            self.logger.error("video_wrapper: dataset extraction failed: %s", exc)
            return False

        if not any(cuts_dir.glob("*.y4m")):
            self.logger.error(
                "video_wrapper: extraction completed but no .y4m files found in %s. Check cuts.tar.gz contents.",
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

    def get_tmc_profile(self) -> Dict[str, Any]:
        """Mirrors vt_script.sh's tmc invocation."""
        return {
            "ramp_string": "start",
            "ramp_log": "/tmp/ffmpeg_log.txt",
            "ramp_timeout": 100,
            "lead_time": 200,
            "views": "thread,socket,core",
            "tools": "emon,sar",
            "group": "videotranscode_",
            "verbose": True,
        }

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

    def run(self) -> int:
        self.validate_config()
        final_status = 0
        original_encoder = self.args.encoder

        for idx, codec in enumerate(self._resolved_codecs, 1):
            self.args.encoder = codec
            self.logger.info(
                "video_wrapper: codec run %s/%s -> %s",
                idx,
                len(self._resolved_codecs),
                codec,
            )
            rc = super().run()
            final_status = final_status or rc

        self.args.encoder = original_encoder
        return final_status


def main() -> int:
    wrapper = VideoWrapper()
    if getattr(wrapper.args, "core_scaling", False):
        return wrapper.run_core_scaling()
    return wrapper.run()


if __name__ == "__main__":
    raise SystemExit(main())
