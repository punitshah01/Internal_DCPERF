"""Loads and persists DCPerf_SCRIPTS/config/dcperf_config.yaml.

Centralizes every value that used to be hardcoded across the 5 legacy
scripts (sep_path, emon_user, cores=288, db_client_ip, etc.). Missing
required values are asked for once, interactively, and saved back so
the same question is never repeated.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Optional, Tuple
import platform

import yaml


def detect_distro() -> str:
    """Return 'centos8', 'centos9', 'ubuntu', or 'unknown' from /etc/os-release.

    Used to select the correct per-OS prerequisite install sequence from the
    official DCPerf README (CentOS Stream 8/9 vs Ubuntu 22.04 differ).
    """
    os_release = Path("/etc/os-release")
    if not os_release.exists():
        return "unknown"

    try:
        content = os_release.read_text(encoding="utf-8", errors="ignore").lower()
    except OSError:
        return "unknown"

    if "ubuntu" in content:
        return "ubuntu"
    if "centos" in content or "rhel" in content or "rocky" in content or "almalinux" in content:
        if 'version_id="8' in content or "version_id=8" in content:
            return "centos8"
        if 'version_id="9' in content or "version_id=9" in content:
            return "centos9"
        return "centos9"  # default to the currently-supported CentOS variant
    return "unknown"


class ConfigManager:
    def __init__(self, config_path: Path, logger):
        self.config_path = Path(config_path)
        self.logger = logger
        self._config: Dict[str, Any] = {}

    # ------------------------------------------------------------------
    # Load / auto-detect
    # ------------------------------------------------------------------

    def load(self) -> Dict[str, Any]:
        """Read setup_config.yaml and auto-detect dcperf_root if it is null."""
        if self.config_path.exists():
            with open(self.config_path, "r", encoding="utf-8") as fh:
                self._config = yaml.safe_load(fh) or {}
        else:
            self.logger.warning("config_manager: %s not found, starting with empty config", self.config_path)
            self._config = {}

        if not self._config.get("dcperf_root"):
            detected = self._auto_detect_dcperf_root()
            if detected:
                self._config["dcperf_root"] = str(detected)
                self.logger.info("config_manager: auto-detected dcperf_root=%s", detected)
                self.save()
            else:
                self.logger.warning("config_manager: could not auto-detect dcperf_root")

        if not self._config.get("results_base_dir"):
            root = self._config.get("dcperf_root")
            if root:
                self._config["results_base_dir"] = str(Path(__file__).resolve().parent.parent / "results")

        derived_changed = False
        if not self._config.get("emon_user"):
            self._config["emon_user"] = "pshah"
            self.logger.info("config_manager: defaulted emon_user=pshah")
            derived_changed = True

        event_file = self._config.get("emon_event_file")
        detected = self._discover_emon_event_file(self._config.get("sep_path"))
        if detected and not event_file:
            self._config["emon_event_file"] = str(detected)
            self.logger.info("config_manager: auto-detected emon_event_file=%s", detected)
            derived_changed = True
        elif detected and Path(event_file).name != Path(detected).name:
            # A mismatched event file makes EMON discard every event and abort,
            # so a stale value from an earlier detection must not survive.
            self.logger.warning(
                "config_manager: configured emon_event_file=%s does not match this CPU; "
                "replacing with %s",
                event_file, detected,
            )
            self._config["emon_event_file"] = str(detected)
            derived_changed = True

        if not self._config.get("video_dataset_path") and self._config.get("dcperf_root"):
            self._config["video_dataset_path"] = str(
                Path(self._config["dcperf_root"])
                / "benchmarks" / "video_transcode_bench" / "datasets"
            )
            self.logger.info(
                "config_manager: defaulted video_dataset_path=%s",
                self._config["video_dataset_path"],
            )
            derived_changed = True

        if derived_changed:
            self.save()

        return self._config

    # (vendor, family, model) -> event-file alias, keyed by CPUID rather than
    # any OS/kernel string, which never carries the platform codename.
    _CPU_MODEL_ALIASES = {
        ("intel", 6, 143): "sapphirerapids",
        ("intel", 6, 207): "emeraldrapids",
        ("intel", 6, 173): "graniterapids",
        ("intel", 6, 174): "graniterapids",
        ("intel", 6, 175): "sierraforest",
        ("intel", 6, 221): "sierraforest",
        ("intel", 6, 204): "clearwaterforest",
        ("intel", 19, 1): "diamondrapids",
    }

    @staticmethod
    def _read_cpu_identity() -> Tuple[Optional[str], Optional[int], Optional[int]]:
        """Return (vendor, cpu family, model) from /proc/cpuinfo."""
        vendor = family = model = None
        try:
            with open("/proc/cpuinfo", encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    key, _, value = line.partition(":")
                    key = key.strip().lower()
                    value = value.strip()
                    if key == "vendor_id" and vendor is None:
                        vendor = "intel" if "intel" in value.lower() else value.lower()
                    elif key == "cpu family" and family is None:
                        family = int(value)
                    elif key == "model" and model is None:
                        model = int(value)
                    if vendor and family is not None and model is not None:
                        break
        except (OSError, ValueError):
            return None, None, None
        return vendor, family, model

    def _discover_emon_event_file(self, sep_path: Optional[str]) -> Optional[Path]:
        """Find the SEP event file matching this CPU.

        PNPWLS setup_emon.sh installs SEP and pyedp but does not select a
        platform event file. Selection is driven by CPUID; a wrong file makes
        EMON discard every event and fail PMU programming, so we return None
        rather than guessing when the CPU is unrecognised.
        """
        if not sep_path:
            return None
        edp_dir = Path(sep_path) / "config" / "edp"
        if not edp_dir.exists():
            return None

        vendor, family, model = self._read_cpu_identity()
        if vendor is None:
            self.logger.warning("config_manager: cannot read CPU identity, skipping event-file detection")
            return None

        alias = self._CPU_MODEL_ALIASES.get((vendor, family, model))
        if alias is None:
            self.logger.warning(
                "config_manager: unrecognised CPU (vendor=%s family=%s model=%s); "
                "set emon_event_file manually in dcperf_config.yaml",
                vendor, family, model,
            )
            return None

        candidates = sorted(edp_dir.glob("*server*events*.txt"))
        matching = [path for path in candidates if alias in path.name.lower().replace("_", "")]
        if not matching:
            self.logger.warning(
                "config_manager: no %s event file under %s; set emon_event_file manually",
                alias, edp_dir,
            )
            return None

        private = [path for path in matching if "private" in path.name.lower()]
        return private[0] if private else matching[0]

    def _auto_detect_dcperf_root(self) -> Optional[Path]:
        """Walk up from this file's location until benchpress/config/benchmarks.yml is found."""
        current = Path(__file__).resolve().parent
        for _ in range(6):
            marker = current / "benchpress" / "config" / "benchmarks.yml"
            if marker.exists():
                return current
            if current.parent == current:
                break
            current = current.parent
        return None

    # ------------------------------------------------------------------
    # Access
    # ------------------------------------------------------------------

    def get(self, key: str, default: Any = None) -> Any:
        return self._config.get(key, default)

    def require(self, key: str) -> str:
        """Return config[key], prompting once interactively if it is null/missing."""
        value = self._config.get(key)
        if value not in (None, ""):
            return value

        prompt = f"Enter value for required config key '{key}': "
        answer = input(prompt).strip()
        while not answer:
            answer = input(f"'{key}' cannot be empty. {prompt}").strip()

        self._config[key] = answer
        self.save()
        self.logger.info("config_manager: saved user-provided value for '%s'", key)
        return answer

    # ------------------------------------------------------------------
    # Persist
    # ------------------------------------------------------------------

    def save(self) -> None:
        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.config_path, "w", encoding="utf-8") as fh:
            yaml.safe_dump(self._config, fh, default_flow_style=False, sort_keys=False)
