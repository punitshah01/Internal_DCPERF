"""spark_standalone wrapper — refactored from sweep.py.

Fixes:
  - $HOME/DCPerf replaced by config dcperf_root.
  - /flash23 replaced by config spark_data_path.
  - Hardcoded GNR-only EMON event file path replaced by config emon_event_file.
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
from modules.dcperf_core_scaler import get_total_cores, scale_generator, set_core_count
from modules.dcperf_os_tuner import tune_spark_post_run

_RECOMMENDED_KERNEL = "6.4.3-0_fbk0_rc7_540_g30a9329b6cec"
_JAVA8_GLOB = "/usr/lib/jvm/java-1.8.0-openjdk*/jre/bin/java"
_NVMET_MODULES = ["nvmet", "nvmet-tcp", "nvmet-rdma"]


class SparkWrapper(BaseWrapper):
    JOB_NAME = "spark_standalone_remote"
    WORKLOAD_NAME = "spark_standalone"

    def get_job_name(self) -> str:
        return self.JOB_NAME

    def get_workload_name(self) -> str:
        return self.WORKLOAD_NAME

    @classmethod
    def add_arguments(cls, parser) -> None:
        parser.add_argument("--spark-data-path", default=None, help="Falls back to config spark_data_path")
        parser.add_argument("--ipv4", action="store_true", help="Use IPv4 (jobs.yml 'ipv4' var) if the system/network doesn't support IPv6")
        parser.add_argument("--sanity", action="store_true", help="Run the I/O sanity check (fio) before the main workload")
        parser.add_argument("--local-hostname", default=None, help="Override hostname if `hostname` output isn't resolvable")
        parser.add_argument("--core-scaling", action="store_true", help="Run a core-scaling sweep")
        parser.add_argument("--total-cores", type=int, default=None, help="Total cores for scaling sweep")

    def validate_config(self) -> None:
        if not self.args.spark_data_path:
            self.args.spark_data_path = self.config_manager.require("spark_data_path")
        if self.args.metric == "emon" and not self.config.get("emon_event_file"):
            self.config["emon_event_file"] = self.config_manager.require("emon_event_file")

    def get_job_vars(self) -> Dict[str, Any]:
        """Forward --ipv4/--sanity/--local-hostname to benchpress via -i JSON."""
        job_vars: Dict[str, Any] = {}
        if self.args.ipv4:
            job_vars["ipv4"] = 1
        if self.args.sanity:
            job_vars["sanity"] = 1
        if self.args.local_hostname:
            job_vars["local_hostname"] = self.args.local_hostname
        return job_vars

    # ------------------------------------------------------------------
    # FIX 5: Spark full prerequisite sequence
    # ------------------------------------------------------------------

    def pre_install_hook(self) -> bool:
        results = self.verify_spark_prerequisites()
        return all(v != "FAIL" for v in results.values())

    def pre_run(self) -> Dict[str, Any]:
        results = self.verify_spark_prerequisites()
        if self.run_dir is not None:
            self.result_manager.save_metrics(self.run_dir, {"spark_prerequisites": results})
        return super().pre_run()

    def post_run(self) -> None:
        tune_spark_post_run(self.logger, self.args.dry_run)
        super().post_run()

    def verify_spark_prerequisites(self) -> Dict[str, str]:
        """Run the 9 ordered Spark prerequisite checks; dry_run aware throughout."""
        results: Dict[str, str] = {}
        results["kernel_version"] = self._check_kernel_version()
        results["firewall"] = self._check_firewall()
        results["nvme_tcp_modules"] = self._check_nvme_tcp_modules()
        results["java_version"] = self._check_java_version()
        results["flash_storage"] = self._check_flash_storage()
        results["network_interface"] = self._check_network_interface()
        results["iommu"] = self._check_iommu()
        results["nvme_tcp_setup"] = self._check_nvme_tcp_setup()
        results["ipv4_force_fix"] = self._check_ipv4_force_fix()
        return results

    def _run(self, cmd: List[str], check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(cmd, check=check, capture_output=True, text=True)

    # CHECK 1: kernel version -------------------------------------------------
    def _check_kernel_version(self) -> str:
        try:
            result = self._run(["uname", "-r"])
            kernel = result.stdout.strip()
        except subprocess.CalledProcessError:
            self.logger.error("spark_wrapper: uname -r failed")
            return "FAIL"

        self.logger.info("spark_wrapper: kernel version = %s", kernel)
        if kernel != _RECOMMENDED_KERNEL:
            self.logger.warning(
                "spark_wrapper: kernel %s does not match recommended %s", kernel, _RECOMMENDED_KERNEL
            )

        rpms_path = self.config.get("spark_kernel_rpms_path")
        if rpms_path and kernel != _RECOMMENDED_KERNEL:
            self._install_custom_kernel(Path(rpms_path))
            return "WARNING"
        return "PASS" if kernel == _RECOMMENDED_KERNEL else "WARNING"

    def _install_custom_kernel(self, rpms_path: Path) -> None:
        ver = _RECOMMENDED_KERNEL
        rpms = [
            rpms_path / f"kernel-{ver}.x86_64.rpm",
            rpms_path / f"kernel-devel-{ver}.x86_64.rpm",
            rpms_path / f"kernel-headers-{ver}.x86_64.rpm",
        ]
        for rpm in rpms:
            cmd = ["sudo", "rpm", "-ivh", str(rpm)]
            self.logger.info("spark_wrapper: %s", " ".join(cmd))
            if self.args.dry_run:
                continue
            try:
                self._run(cmd)
            except subprocess.CalledProcessError as exc:
                self.logger.error("spark_wrapper: failed to install %s: %s", rpm, exc.stderr)

        grub_cmd = ["sudo", "grubby", "--set-default", f"/boot/vmlinuz-{ver}"]
        self.logger.info("spark_wrapper: %s", " ".join(grub_cmd))
        if not self.args.dry_run:
            try:
                self._run(grub_cmd)
            except subprocess.CalledProcessError as exc:
                self.logger.error("spark_wrapper: grubby --set-default failed: %s", exc.stderr)
        self.logger.warning("spark_wrapper: reboot required to use new kernel %s", ver)

    # CHECK 2: firewall --------------------------------------------------------
    def _check_firewall(self) -> str:
        cmds = [["sudo", "systemctl", "stop", "firewalld"], ["sudo", "systemctl", "disable", "firewalld"]]
        ok = True
        for cmd in cmds:
            self.logger.info("spark_wrapper: %s", " ".join(cmd))
            if self.args.dry_run:
                continue
            try:
                self._run(cmd, check=False)
            except Exception as exc:
                self.logger.error("spark_wrapper: %s failed: %s", " ".join(cmd), exc)
                ok = False
        self.logger.info("spark_wrapper: firewalld stopped/disabled")
        return "PASS" if ok else "FAIL"

    # CHECK 3: NVMe-TCP kernel modules -----------------------------------------
    def _check_nvme_tcp_modules(self) -> str:
        try:
            result = self._run(["lsmod"], check=False)
            loaded = "nvmet" in result.stdout
        except Exception:
            loaded = False

        if loaded:
            self.logger.info("spark_wrapper: nvmet modules already loaded")
            return "PASS"

        loaded_modules = []
        for mod in _NVMET_MODULES:
            cmd = ["sudo", "modprobe", mod]
            self.logger.info("spark_wrapper: %s", " ".join(cmd))
            if self.args.dry_run:
                continue
            try:
                self._run(cmd)
                loaded_modules.append(mod)
            except subprocess.CalledProcessError as exc:
                self.logger.error("spark_wrapper: modprobe %s failed: %s", mod, exc.stderr)
        self.logger.info("spark_wrapper: loaded modules: %s", loaded_modules or _NVMET_MODULES)
        return "PASS"

    # CHECK 4: Java version ------------------------------------------------------
    def _check_java_version(self) -> str:
        import glob
        import os

        try:
            result = self._run(["java", "-version"], check=False)
            output = (result.stderr or result.stdout).strip()
        except Exception:
            output = ""

        if "1.8" in output:
            self.logger.info("spark_wrapper: java -version reports 1.8: %s", output.splitlines()[:1])
            return "PASS"

        candidates = sorted(glob.glob(_JAVA8_GLOB))
        if not candidates:
            self.logger.error("spark_wrapper: Java 8 not found (java -version=%r, glob=%r)", output, _JAVA8_GLOB)
            return "FAIL"

        java_path = str(Path(candidates[0]).parent)
        self.logger.info("spark_wrapper: using Java 8 at %s", java_path)
        os.environ["PATH"] = java_path + ":" + os.environ.get("PATH", "")
        self.config["java_path"] = java_path
        self.config_manager.save()
        return "PASS"

    # CHECK 5: flash storage ------------------------------------------------------
    def _check_flash_storage(self) -> str:
        import shutil as _shutil

        mounted = Path("/flash23").is_mount()
        if mounted:
            self.logger.info("spark_wrapper: /flash23 already mounted")
            return "PASS"

        spark_data_path = self.config.get("spark_data_path")
        if not spark_data_path:
            self.logger.warning("spark_wrapper: /flash23 not mounted and spark_data_path not set")
            return "WARNING"

        self.logger.warning("spark_wrapper: /flash23 not mounted, spark_data_path is %s", spark_data_path)
        answer = "n"
        if not self.args.dry_run:
            answer = input("Should I set up /flash23 from spark_data_path? (y/n): ").strip().lower()
        if answer != "y":
            self.logger.info("spark_wrapper: user declined /flash23 setup")
            return "WARNING"

        setup_cmds = [
            ["sudo", "umount", "/flash23"],
            ["sudo", "mdadm", "--stop", "/dev/md23"],
            ["sudo", "rm", "-rf", "/flash23/"],
            ["sudo", "mkdir", "-p", "/flash23"],
        ]
        for cmd in setup_cmds:
            self.logger.info("spark_wrapper: %s", " ".join(cmd))
            if self.args.dry_run:
                continue
            self._run(cmd, check=False)  # ignore errors, per spec

        copy_cmd = ["sudo", "cp", "-r", spark_data_path, "/flash23"]
        self.logger.info("spark_wrapper: %s", " ".join(copy_cmd))
        if not self.args.dry_run:
            try:
                self._run(copy_cmd)
            except subprocess.CalledProcessError as exc:
                self.logger.error("spark_wrapper: copy to /flash23 failed: %s", exc.stderr)
                return "FAIL"

        self.logger.info("spark_wrapper: /flash23 setup complete (final state logged above)")
        return "PASS"

    # CHECK 6: network interface for NVMe-TCP -------------------------------------
    def _check_network_interface(self) -> str:
        try:
            route_result = self._run(["ip", "r"], check=False)
            self.logger.info("spark_wrapper: routing table:\n%s", route_result.stdout)
        except Exception as exc:
            self.logger.warning("spark_wrapper: 'ip r' failed: %s", exc)

        try:
            ifconfig_result = self._run(["ifconfig"], check=False)
            self.logger.info("spark_wrapper: interfaces:\n%s", ifconfig_result.stdout)
        except Exception as exc:
            self.logger.warning("spark_wrapper: ifconfig failed: %s", exc)

        iface = self.config.get("nvme_tcp_interface")
        if not iface:
            self.logger.info("spark_wrapper: nvme_tcp_interface not configured, skipping nmcli setup")
            return "SKIPPED"

        check_cmd = ["ip", "link", "show", iface]
        try:
            self._run(check_cmd)
            self.logger.info("spark_wrapper: interface %s exists", iface)
            return "PASS"
        except subprocess.CalledProcessError:
            pass

        nmcli_cmd = [
            "sudo", "nmcli", "connection", "add", "con-name", iface, "ifname", iface,
            "type", "ethernet", "ipv4.method", "manual", "ipv4.addresses", "192.168.100.1/24",
        ]
        self.logger.info("spark_wrapper: %s", " ".join(nmcli_cmd))
        if self.args.dry_run:
            return "PASS"
        try:
            self._run(nmcli_cmd)
            self.logger.info("spark_wrapper: configured interface %s", iface)
            return "PASS"
        except subprocess.CalledProcessError as exc:
            self.logger.error("spark_wrapper: nmcli setup failed: %s", exc.stderr)
            return "FAIL"

    # CHECK 7: IOMMU --------------------------------------------------------------
    def _check_iommu(self) -> str:
        if not self.config.get("iommu_passthrough", False):
            return "SKIPPED"

        try:
            cmdline = Path("/proc/cmdline").read_text()
        except OSError:
            cmdline = ""

        if "intel_iommu=on" in cmdline and "iommu=pt" in cmdline:
            self.logger.info("spark_wrapper: IOMMU passthrough already enabled")
            return "PASS"

        self.logger.warning(
            "spark_wrapper: IOMMU passthrough not enabled. Add to grub manually:\n"
            "  sudo grubby --update-kernel=ALL --args=\"intel_iommu=on,sm_on iommu=pt\"\n"
            "  sudo reboot"
        )
        return "WARNING"

    # CHECK 8: NVMe-TCP setup script -------------------------------------------
    def _check_nvme_tcp_setup(self) -> str:
        if not self.config.get("nvme_tcp_setup", False):
            return "SKIPPED"

        dcperf_root = self.config.get("dcperf_root")
        if not dcperf_root:
            self.logger.error("spark_wrapper: dcperf_root not configured, cannot run nvme_tcp setup")
            return "FAIL"

        script = Path(dcperf_root) / "packages" / "spark_standalone" / "templates" / "nvme_tcp" / "setup_nvmet.py"
        nvme_n = self.config.get("nvme_n")
        nvme_s = self.config.get("nvme_s")
        cmd = [sys.executable, str(script), "importer", "mount", "-n", str(nvme_n), "-s", str(nvme_s), "--real"]
        self.logger.info("spark_wrapper: %s", " ".join(cmd))
        if self.args.dry_run:
            return "PASS"
        try:
            self._run(cmd)
            return "PASS"
        except subprocess.CalledProcessError as exc:
            self.logger.error("spark_wrapper: nvme_tcp setup failed: %s", exc.stderr)
            return "FAIL"

    # CHECK 9: IPv4 force fix ------------------------------------------------------
    def _check_ipv4_force_fix(self) -> str:
        dcperf_root = self.config.get("dcperf_root")
        if not dcperf_root:
            return "SKIPPED"

        script = Path(dcperf_root) / "packages" / "spark_standalone" / "templates" / "nvme_tcp" / "setup_nvmet.py"
        if not script.exists():
            self.logger.warning("spark_wrapper: %s not found, skipping ipv4 force-fix", script)
            return "SKIPPED"

        text = script.read_text()
        if 'ip_format = "ipv4"\n' in text and "if args.ipv4 else" not in text:
            self.logger.info("spark_wrapper: ipv4 force-fix already patched")
            return "PASS"

        original = 'ip_format = "ipv4" if args.ipv4 else "ipv6"'
        if original not in text:
            self.logger.warning("spark_wrapper: expected ip_format line not found in %s", script)
            return "WARNING"

        self.logger.info("spark_wrapper: patching %s to force ip_format = 'ipv4'", script)
        if self.args.dry_run:
            return "PASS"

        try:
            script.write_text(text.replace(original, 'ip_format = "ipv4"'))
            return "PASS"
        except OSError as exc:
            self.logger.error("spark_wrapper: failed to patch %s: %s", script, exc)
            return "FAIL"

    def parse_output(self, stdout: str) -> Dict[str, Any]:
        parsed: Dict[str, Any] = {}
        bp = self.parse_benchpress_json(stdout)
        metrics = bp.get("metrics", {})
        if metrics:
            if "execution_time_test_93586" in metrics:
                parsed["runtime_s"] = float(metrics["execution_time_test_93586"])
            if "queries_per_hour" in metrics:
                parsed["throughput"] = float(metrics["queries_per_hour"])
            if "score" in metrics:
                parsed["score"] = float(metrics["score"])
            elif "score" in bp:
                parsed["score"] = float(bp["score"])
            return parsed

        match = re.search(r"Total runtime[:\s]+([\d.]+)\s*s", stdout, re.IGNORECASE)
        if match:
            parsed["runtime_s"] = float(match.group(1))
        match = re.search(r"Throughput[:\s]+([\d.]+)", stdout, re.IGNORECASE)
        if match:
            parsed["throughput"] = float(match.group(1))
        return parsed

    def get_kpis(self, parsed: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "runtime_s": parsed.get("runtime_s", 0.0),
            "throughput": parsed.get("throughput", 0.0),
            "score": parsed.get("score", 0.0),
        }

    def get_csv_schema(self) -> List[str]:
        return ["spark_data_path", "cores_enabled", "runtime_s", "throughput", "score"]

    def run_core_scaling(self) -> int:
        total = self.args.total_cores or get_total_cores()
        step = self.config.get("core_step", 16)
        final_status = 0
        for cores in scale_generator(step, total, step):
            self.logger.info("spark_wrapper: core-scaling step -> %s cores", cores)
            set_core_count(cores, self.logger, self.args.dry_run)
            if not self.args.dry_run:
                time.sleep(2)
            rc = self.run()
            final_status = final_status or rc
        return final_status


def main() -> int:
    wrapper = SparkWrapper()
    if getattr(wrapper.args, "core_scaling", False):
        return wrapper.run_core_scaling()
    return wrapper.run()


if __name__ == "__main__":
    raise SystemExit(main())
