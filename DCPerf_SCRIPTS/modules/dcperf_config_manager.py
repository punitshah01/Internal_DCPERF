"""Loads and persists DCPerf_SCRIPTS/config/dcperf_config.yaml.

Centralizes every value that used to be hardcoded across the 5 legacy
scripts (sep_path, emon_user, cores=288, db_client_ip, etc.). Missing
required values are asked for once, interactively, and saved back so
the same question is never repeated.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Optional
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

        if not self._config.get("emon_event_file"):
            event_file = self._discover_emon_event_file(self._config.get("sep_path"))
            if event_file:
                self._config["emon_event_file"] = str(event_file)
                self.logger.info("config_manager: auto-detected emon_event_file=%s", event_file)
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

    def _discover_emon_event_file(self, sep_path: Optional[str]) -> Optional[Path]:
        """Find a platform event file using the installed SEP EDP directory.

        PNPWLS setup_emon.sh installs SEP and pyedp but does not select a
        platform event file. Prefer a platform-named private/server file,
        then fall back to the first server event file shipped by SEP.
        """
        if not sep_path:
            return None
        edp_dir = Path(sep_path) / "config" / "edp"
        if not edp_dir.exists():
            return None

        platform_name = platform.platform().lower()
        aliases = []
        if "granite" in platform_name or "6700" in platform_name or "6900" in platform_name:
            aliases.append("graniterapids")
        if "sapphire" in platform_name or "8470" in platform_name:
            aliases.append("sapphirerapids")
        if "emerald" in platform_name or "8570" in platform_name:
            aliases.append("emeraldrapids")
        if "diamond" in platform_name:
            aliases.append("diamondrapids")

        candidates = sorted(edp_dir.glob("*server*events*.txt"))
        for alias in aliases:
            matching = [path for path in candidates if alias in path.name.lower()]
            if matching:
                private = [path for path in matching if "private" in path.name.lower()]
                return private[0] if private else matching[0]
        private = [path for path in candidates if "private" in path.name.lower()]
        return private[0] if private else (candidates[0] if candidates else None)

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
