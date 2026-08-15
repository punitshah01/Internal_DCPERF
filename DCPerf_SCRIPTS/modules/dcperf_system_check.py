"""Detect the host system before DCPerf installation or execution."""

from __future__ import annotations

import os
import platform
import re
import shutil
import socket
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

try:
    from .dcperf_logger import get_logger, log_section
except ImportError:  # Direct execution for the self-test.
    from dcperf_logger import get_logger, log_section


@dataclass
class SystemInfo:
    # CPU
    cpu_vendor: str = field()
    cpu_model: str = field()
    cpu_generation: str = field()
    physical_cores: int = field()
    logical_cores: int = field()
    numa_nodes: int = field()
    has_amx: bool = field()
    has_avx512: bool = field()
    has_avx2: bool = field()
    # Memory
    total_ram_gb: float = field()
    available_ram_gb: float = field()
    # Disk
    dcperf_disk_free_gb: float = field()
    # OS
    os_name: str = field()
    os_version: str = field()
    os_id: str = field()
    kernel_version: str = field()
    # Python
    python_version: str = field()
    python_path: str = field()
    # Connectivity
    has_internet: bool = field()
    has_sudo: bool = field()
    # Intel specific
    is_intel_spr: bool = field()
    is_intel_emr: bool = field()
    is_intel_gnr: bool = field()


def _read_file(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return ""


def _parse_key_value_file(content: str) -> Dict[str, str]:
    values: Dict[str, str] = {}
    for line in content.splitlines():
        if "=" not in line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip('"')
    return values


def _read_cpuinfo(logger) -> Tuple[str, str, Set[Tuple[str, str]], Set[str]]:
    content = _read_file(Path("/proc/cpuinfo"))
    if not content:
        logger.warning("/proc/cpuinfo is unavailable; using platform CPU fallbacks.")
        vendor = "Intel" if platform.processor().lower().find("intel") >= 0 else "Unknown"
        return vendor, platform.processor() or platform.machine(), set(), set()

    vendor_id = ""
    model_name = ""
    flags: Set[str] = set()
    core_pairs: Set[Tuple[str, str]] = set()
    processor: Dict[str, str] = {}

    for line in content.splitlines() + [""]:
        if line.strip() == "":
            if processor:
                physical_id = processor.get("physical id")
                core_id = processor.get("core id")
                if physical_id is not None and core_id is not None:
                    core_pairs.add((physical_id, core_id))
                processor = {}
            continue
        if ":" not in line:
            continue
        key, value = (part.strip() for part in line.split(":", 1))
        processor[key] = value
        if key == "vendor_id" and not vendor_id:
            vendor_id = value
        elif key == "model name" and not model_name:
            model_name = value
        elif key in ("flags", "Features"):
            flags.update(value.split())

    if vendor_id == "GenuineIntel":
        vendor = "Intel"
    elif vendor_id == "AuthenticAMD":
        vendor = "AMD"
    else:
        vendor = vendor_id or "Unknown"

    return vendor, model_name or platform.processor() or platform.machine(), core_pairs, flags


def _detect_generation(cpu_vendor: str, cpu_model: str) -> str:
    model_upper = cpu_model.upper()
    if cpu_vendor == "Intel":
        if any(code in model_upper for code in (
            "8490", "8480", "8470", "8460", "8452", "6448", "6438",
            "6430", "4416", "4410", "3408",
        )):
            return "Sapphire Rapids"
        if any(code in model_upper for code in (
            "8592", "8580", "8570", "8558", "6548", "6538", "6530",
            "4516", "4510", "3508",
        )):
            return "Emerald Rapids"
        if any(code in model_upper for code in ("6700", "6900", "9600", "9700")):
            return "Granite Rapids"
    elif cpu_vendor == "AMD":
        if "EPYC" in model_upper and "9005" in model_upper:
            return "Turin"
        if "EPYC" in model_upper and "9004" in model_upper:
            return "Genoa"
    return "Unknown"


def _detect_numa_nodes(logger) -> int:
    try:
        result = subprocess.run(
            ["numactl", "--hardware"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        logger.warning("numactl is unavailable; defaulting NUMA nodes to 1.")
        return 1

    match = re.search(r"available:\s*(\d+)\s+nodes?", result.stdout)
    if match:
        return int(match.group(1))
    logger.warning("numactl output did not report NUMA nodes; defaulting to 1.")
    return 1


def _windows_memory_bytes() -> Tuple[int, int]:
    if os.name != "nt":
        return 0, 0
    try:
        import ctypes

        class MemoryStatus(ctypes.Structure):
            _fields_ = [
                ("length", ctypes.c_ulong),
                ("memory_load", ctypes.c_ulong),
                ("total_phys", ctypes.c_ulonglong),
                ("avail_phys", ctypes.c_ulonglong),
                ("total_page_file", ctypes.c_ulonglong),
                ("avail_page_file", ctypes.c_ulonglong),
                ("total_virtual", ctypes.c_ulonglong),
                ("avail_virtual", ctypes.c_ulonglong),
                ("avail_extended_virtual", ctypes.c_ulonglong),
            ]

        status = MemoryStatus()
        status.length = ctypes.sizeof(MemoryStatus)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status))
        return status.total_phys, status.avail_phys
    except (AttributeError, OSError):
        return 0, 0


def _detect_memory(logger) -> Tuple[float, float]:
    values = _parse_key_value_file(_read_file(Path("/proc/meminfo")))
    if "MemTotal" in values and "MemAvailable" in values:
        total_kb = int(values["MemTotal"].split()[0])
        available_kb = int(values["MemAvailable"].split()[0])
        return round(total_kb / 1024 / 1024, 1), round(available_kb / 1024 / 1024, 1)

    total_bytes, available_bytes = _windows_memory_bytes()
    if total_bytes:
        logger.warning("/proc/meminfo is unavailable; using Windows memory API.")
        return round(total_bytes / 1024**3, 1), round(available_bytes / 1024**3, 1)

    logger.warning("Memory information is unavailable; defaulting RAM values to 0.")
    return 0.0, 0.0


def _detect_os(logger) -> Tuple[str, str, str]:
    values = _parse_key_value_file(_read_file(Path("/etc/os-release")))
    if values:
        return values.get("NAME", "Unknown"), values.get("VERSION_ID", "Unknown"), values.get("ID", "unknown").lower()

    logger.warning("/etc/os-release is unavailable; using platform OS fallbacks.")
    return platform.system() or "Unknown", platform.release() or "Unknown", (platform.system() or "unknown").lower()


def _check_internet(logger) -> bool:
    try:
        with socket.create_connection(("github.com", 443), timeout=5):
            return True
    except OSError as error:
        logger.warning("Internet connectivity check failed: %s", error)
        return False


def _check_sudo(logger) -> bool:
    try:
        result = subprocess.run(
            ["sudo", "-n", "true"],
            capture_output=True,
            check=False,
        )
    except OSError:
        logger.warning("sudo is unavailable; sudo access is not detected.")
        return False
    return result.returncode == 0


def _format_yes_no(value: bool) -> str:
    return "YES" if value else "NO"


def detect_system(logger) -> SystemInfo:
    """Detect and log the host system information used by DCPerf."""
    cpu_vendor, cpu_model, core_pairs, flags = _read_cpuinfo(logger)
    logical_cores = os.cpu_count() or 1
    physical_cores = len(core_pairs) or logical_cores
    if not core_pairs:
        logger.warning("Physical CPU topology is unavailable; using logical CPU count.")

    cpu_generation = _detect_generation(cpu_vendor, cpu_model)
    total_ram_gb, available_ram_gb = _detect_memory(logger)
    dcperf_root = Path(__file__).resolve().parents[2]
    disk_free_gb = round(shutil.disk_usage(dcperf_root).free / 1024**3, 1)
    numa_nodes = _detect_numa_nodes(logger)
    os_name, os_version, os_id = _detect_os(logger)
    kernel_version = platform.release()
    has_internet = _check_internet(logger)
    has_sudo = _check_sudo(logger)

    info = SystemInfo(
        cpu_vendor=cpu_vendor,
        cpu_model=cpu_model,
        cpu_generation=cpu_generation,
        physical_cores=physical_cores,
        logical_cores=logical_cores,
        numa_nodes=numa_nodes,
        has_amx="amx_tile" in flags,
        has_avx512="avx512f" in flags,
        has_avx2="avx2" in flags,
        total_ram_gb=total_ram_gb,
        available_ram_gb=available_ram_gb,
        dcperf_disk_free_gb=disk_free_gb,
        os_name=os_name,
        os_version=os_version,
        os_id=os_id,
        kernel_version=kernel_version,
        python_version=platform.python_version(),
        python_path=sys.executable,
        has_internet=has_internet,
        has_sudo=has_sudo,
        is_intel_spr=cpu_generation == "Sapphire Rapids",
        is_intel_emr=cpu_generation == "Emerald Rapids",
        is_intel_gnr=cpu_generation == "Granite Rapids",
    )

    log_section(logger, "SYSTEM DETECTION REPORT")
    logger.info("CPU Model : %s", info.cpu_model)
    logger.info("CPU Vendor : %s", info.cpu_vendor)
    logger.info("Generation : %s", info.cpu_generation)
    logger.info("Physical Cores: %s", info.physical_cores)
    logger.info("Logical Cores : %s", info.logical_cores)
    logger.info("NUMA Nodes : %s", info.numa_nodes)
    logger.info("AMX Support : %s", _format_yes_no(info.has_amx))
    logger.info("AVX-512 : %s", _format_yes_no(info.has_avx512))
    logger.info("Total RAM : %s GB", info.total_ram_gb)
    logger.info("Available RAM : %s GB", info.available_ram_gb)
    logger.info("Free Disk : %s GB (DCPerf partition)", info.dcperf_disk_free_gb)
    logger.info("OS : %s %s", info.os_name, info.os_version)
    logger.info("Kernel : %s", info.kernel_version)
    logger.info("Python : %s", info.python_version)
    logger.info("Internet : %s", "AVAILABLE" if info.has_internet else "NOT AVAILABLE")
    logger.info("Sudo Access : %s", _format_yes_no(info.has_sudo))

    log_section(logger, "WORKLOAD COMPATIBILITY HINTS")
    if info.total_ram_gb < 32:
        logger.warning("Spark Standalone requires 64 GB RAM on storage nodes.")
        logger.warning("TaoBench requires sufficient RAM for memcached instances.")
    if info.dcperf_disk_free_gb < 50:
        logger.warning(
            "Several workloads need 20-50 GB disk. Current free: %s GB",
            info.dcperf_disk_free_gb,
        )
    if not info.has_sudo:
        logger.warning("Sudo access not detected. Installation will likely fail.")
    if not info.has_internet:
        logger.warning(
            "No internet detected. All workload installers download from public URLs. "
            "Use --offline flag if you have a local mirror."
        )
    if info.is_intel_spr or info.is_intel_emr or info.is_intel_gnr:
        logger.info("Intel Xeon platform detected: %s", info.cpu_generation)
        logger.info("EMON/SEP tooling is supported on this platform.")

    return info


if __name__ == "__main__":
    from pathlib import Path

    log_dir = Path(__file__).parent.parent / "logs"
    logger = get_logger("dcperf_system_check_test", log_dir)
    info = detect_system(logger)
    assert info.logical_cores > 0, "logical_cores must be > 0"
    assert info.total_ram_gb > 0, "total_ram_gb must be > 0"
    assert info.dcperf_disk_free_gb > 0, "disk free must be > 0"
    assert info.os_name != "", "os_name must not be empty"
    assert info.python_version != "", "python_version must not be empty"
    print("system_check self-test: PASSED")
