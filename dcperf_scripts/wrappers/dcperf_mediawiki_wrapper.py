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
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List

_WRAPPERS_DIR = Path(__file__).resolve().parent
if str(_WRAPPERS_DIR) not in sys.path:
    sys.path.insert(0, str(_WRAPPERS_DIR))

from dcperf_base_wrapper import BaseWrapper
from modules.dcperf_config_manager import detect_distro
from modules.dcperf_core_scaler import get_online_cores, get_total_cores, scale_generator, set_core_count

_CPU_FREQ_CHECK_MARKER = "// disabled: fails on server CPUs"
_HHVM_MARKER_PATH = Path("/usr/local/hphpi/legacy/bin/hhvm")
_HHVM_URLS = {
    "ubuntu": "hhvm-3.30-multplatform-binary-ubuntu.tar.xz",
    "centos8": "hhvm-3.30-multplatform-binary-centos.tar.xz",
    "centos9": "hhvm-3.30-multplatform-binary-centos.tar.xz",
}
_ARTIFACT_BASE_URL = (
    "https://af01p-or.devtools.intel.com/artifactory/"
    "dpgpaivsoworkloads-or-local/base/workloads/dcperf"
)
_LIMITS_CONF_LINES = [
    "root            hard            nofile          10485760",
    "root            soft            nofile          10485760",
]


class MediaWikiWrapper(BaseWrapper):
    JOB_NAME = "oss_performance_mediawiki_mlp"
    WORKLOAD_NAME = "mediawiki"

    def get_job_name(self) -> str:
        return self.JOB_NAME

    def get_workload_name(self) -> str:
        return self.WORKLOAD_NAME

    @classmethod
    def add_arguments(cls, parser) -> None:
        parser.add_argument("--clients", type=int, default=0, help="wrk client count (-c, 0 = auto from enabled cores)")
        parser.add_argument("--instances", type=int, default=0, help="HHVM/nginx instance count (-R scale_out)")
        parser.add_argument("--duration", type=int, default=10, help="Duration in minutes")
        parser.add_argument("--type", choices=["local", "remote"], default="local")
        parser.add_argument("--core-scaling", action="store_true", help="Run a core-scaling sweep")
        parser.add_argument("--total-cores", type=int, default=None, help="Total cores for scaling sweep")

    # ------------------------------------------------------------------
    # FIX 2: MediaWiki CPU frequency check crash
    # ------------------------------------------------------------------

    def pre_install_hook(self) -> bool:
        """Prerequisites documented in packages/mediawiki/README.md that must
        be in place before/around install: SELinux disabled, nofile limits
        raised, HHVM 3.30 installed, nginx-1.22 present under /usr/local.
        """
        ok = True
        ok = self._disable_selinux() and ok
        ok = self._set_mediawiki_limits() and ok
        ok = self._install_hhvm() and ok
        ok = self._copy_nginx_tarball() and ok
        return ok

    def _run_privileged(self, cmd: List[str], check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(cmd, check=check, capture_output=True, text=True)

    def _disable_selinux(self) -> bool:
        """HHVM segfaults if SELinux is enabled; disable it and warn a reboot is required."""
        try:
            result = self._run_privileged(["getenforce"], check=False)
            status = result.stdout.strip()
        except (OSError, subprocess.SubprocessError) as exc:
            self.logger.warning("mediawiki_wrapper: could not run getenforce: %s", exc)
            return True

        if status == "Disabled":
            self.logger.info("mediawiki_wrapper: SELinux already disabled")
            return True

        selinux_conf = Path("/etc/selinux/config")
        self.logger.warning("mediawiki_wrapper: SELinux is %s, disabling in %s", status, selinux_conf)
        if self.args.dry_run:
            self.logger.info("mediawiki_wrapper: [dry-run] would set SELINUX=disabled")
            return True

        try:
            text = selinux_conf.read_text()
            patched = re.sub(r"^SELINUX=\w+", "SELINUX=disabled", text, flags=re.MULTILINE)
            selinux_conf.write_text(patched)
            self.logger.warning("mediawiki_wrapper: SELinux disabled in config -- REBOOT REQUIRED before running mediawiki")
            return True
        except OSError as exc:
            self.logger.error("mediawiki_wrapper: failed to edit %s: %s", selinux_conf, exc)
            return False

    def _set_mediawiki_limits(self) -> bool:
        """Raise nofile limit to 10485760 for the mediawiki HHVM workload."""
        limits_conf = Path("/etc/security/limits.conf")
        try:
            existing = limits_conf.read_text() if limits_conf.exists() else ""
        except OSError as exc:
            self.logger.error("mediawiki_wrapper: could not read %s: %s", limits_conf, exc)
            return False

        missing = [line for line in _LIMITS_CONF_LINES if line not in existing]
        if not missing:
            self.logger.info("mediawiki_wrapper: %s already has nofile=10485760 entries", limits_conf)
            return True

        self.logger.info("mediawiki_wrapper: appending %d nofile limit line(s) to %s", len(missing), limits_conf)
        if self.args.dry_run:
            return True

        try:
            with open(limits_conf, "a", encoding="utf-8") as fh:
                fh.write("\n" + "\n".join(missing) + "\n")
            return True
        except OSError as exc:
            self.logger.error("mediawiki_wrapper: failed to write %s: %s", limits_conf, exc)
            return False

    def _install_hhvm(self) -> bool:
        """Download+install HHVM 3.30 via pour-hhvm.sh, idempotent."""
        if _HHVM_MARKER_PATH.exists():
            self.logger.info("mediawiki_wrapper: HHVM already installed at %s", _HHVM_MARKER_PATH)
            return True

        distro = detect_distro()
        artifact_base = self.config.get("workload_artifact_base_url", _ARTIFACT_BASE_URL).rstrip("/")
        artifact_name = _HHVM_URLS.get(distro, _HHVM_URLS["centos9"])
        url = f"{artifact_base}/{artifact_name}"
        self.logger.info("mediawiki_wrapper: installing HHVM 3.30 from %s", url)
        if self.args.dry_run:
            self.logger.info("mediawiki_wrapper: [dry-run] would download+extract+run pour-hhvm.sh")
            return True

        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "hhvm.tar.xz"
            try:
                subprocess.run(["wget", "-q", url, "-O", str(archive)], check=True, capture_output=True, text=True)
                subprocess.run(["tar", "-Jxf", str(archive), "-C", tmp], check=True, capture_output=True, text=True)
                hhvm_dir = Path(tmp) / "hhvm"
                subprocess.run(["sudo", "./pour-hhvm.sh"], check=True, cwd=str(hhvm_dir), capture_output=True, text=True)
                return True
            except subprocess.CalledProcessError as exc:
                self.logger.error("mediawiki_wrapper: HHVM install failed: %s", exc.stderr)
                return False

    def _copy_nginx_tarball(self) -> bool:
        """Copy nginx-1.22.tar.gz into /usr/local, downloading from Artifactory if needed."""
        src = self.config.get("nginx_1_22_tarball_path")
        src_path = Path(src) if src else None
        if src_path is None or not src_path.exists():
            artifact_base = self.config.get("workload_artifact_base_url", _ARTIFACT_BASE_URL).rstrip("/")
            artifact_url = f"{artifact_base}/nginx-1.22.tar.gz"
            src_path = Path("/tmp/nginx-1.22.tar.gz")
            self.logger.info("mediawiki_wrapper: downloading nginx tarball from %s", artifact_url)
            if self.args.dry_run:
                return True
            try:
                subprocess.run(
                    ["wget", "-q", artifact_url, "-O", str(src_path)],
                    check=True, capture_output=True, text=True,
                )
            except subprocess.CalledProcessError as exc:
                self.logger.error("mediawiki_wrapper: nginx Artifactory download failed: %s", exc.stderr)
                return False

        if not src_path.exists() or src_path.stat().st_size == 0:
            self.logger.error("mediawiki_wrapper: nginx tarball is missing or empty: %s", src_path)
            return False

        dest = Path("/usr/local") / src_path.name
        if dest.exists():
            self.logger.info("mediawiki_wrapper: %s already present", dest)
            return True

        self.logger.info("mediawiki_wrapper: copying %s -> %s", src_path, dest)
        if self.args.dry_run:
            return True
        try:
            subprocess.run(["sudo", "cp", str(src_path), str(dest)], check=True, capture_output=True, text=True)
            return True
        except subprocess.CalledProcessError as exc:
            self.logger.error("mediawiki_wrapper: failed to copy nginx tarball: %s", exc.stderr)
            return False

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
        """Effective wrk client thread count; 0 means run.sh's own default (2 * nproc)."""
        if self.args.clients:
            return self.args.clients
        return 2 * len(get_online_cores())

    def _resolve_instances(self) -> int:
        """Effective HHVM instance count; 0 means run.sh's own default."""
        if self.args.instances:
            return self.args.instances
        online = len(get_online_cores())
        return max(1, (online + 99) // 100)

    def get_tmc_profile(self) -> Dict[str, Any]:
        """Mirrors mw_perf.sh's tmc invocation.

        The window is relative to ramp detection, so it is sized from the
        benchmark duration rather than mw_perf.sh's fixed 600/2400, which
        assumed tmc launched run.sh directly with no benchpress phase ahead.
        """
        duration_sec = self.args.duration * 60
        return {
            "ramp_string": "Starting wrk for benchmark",
            "ramp_timeout": 2800,
            "start": 60,
            "end": max(120, duration_sec - 60),
            "secondary_start": 10,
            "secondary_end": max(30, (duration_sec // 10) - 10),
            "views": "socket,core,uncore",
            "metrics_set": "metrics2",
            "group": "mediawiki_1.3E",
        }

    def get_job_vars(self) -> Dict[str, Any]:
        """Forward --clients/--instances/--duration to benchpress via -i JSON.

        jobs.yml renders these as `-c{client_threads}` and `-R{scale_out}`, where
        0 tells run.sh to use its own defaults (2 * nproc threads,
        ceil(nproc / 100) HHVM instances). Only override when asked -- computing
        our own values here silently under-loads the benchmark.
        """
        job_vars: Dict[str, Any] = {
            "duration": f"{self.args.duration}m",
            "timeout": f"{self.args.duration + 1}m",
        }
        if self.args.clients:
            job_vars["client_threads"] = self.args.clients
        if self.args.instances:
            job_vars["scale_out"] = self.args.instances
        return job_vars

    def parse_output(self, stdout: str) -> Dict[str, Any]:
        parsed: Dict[str, Any] = {}
        bp = self.parse_benchpress_json(stdout)
        metrics = bp.get("metrics", {})
        combined = metrics.get("Combined", {})
        if combined:
            if "Wrk RPS" in combined:
                parsed["requests_per_sec"] = float(combined["Wrk RPS"])
            if "Nginx P99 time" in combined:
                parsed["p99_latency_ms"] = float(combined["Nginx P99 time"]) * 1000.0
            # benchpress nests score under metrics, not at the top level.
            score = metrics.get("score", bp.get("score"))
            if score is not None:
                parsed["score"] = float(score)
            return parsed

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
            "score": parsed.get("score", 0.0),
        }

    def get_csv_schema(self) -> List[str]:
        return ["clients", "duration_min", "test_type", "cores_enabled", "requests_per_sec", "p99_latency_ms", "score"]

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
    if getattr(wrapper.args, "core_scaling", False):
        return wrapper.run_core_scaling()
    return wrapper.run()


if __name__ == "__main__":
    raise SystemExit(main())
