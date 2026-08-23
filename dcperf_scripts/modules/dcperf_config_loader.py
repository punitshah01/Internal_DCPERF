"""Unified configuration loader for dcperf.py."""

from __future__ import annotations

import os
from copy import deepcopy
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, MutableMapping, Optional

import yaml


WORKLOADS: List[str] = [
    "health_check",
    "mediawiki",
    "feedsim",
    "tao_bench",
    "video_transcode_bench",
    "django_workload",
    "spark_standalone",
    "wdl_bench",
]

DEFAULT_CONFIG: Dict[str, Any] = {
    "global": {
        "experiment_name": "default_experiment",
        "results_dir": "results",
        "log_level": "INFO",
        "dry_run": False,
    },
    "workloads": {
        "enabled": WORKLOADS.copy(),
        "overrides": {},
    },
    "emon": {
        "enabled": False,
        "sep_path": "/opt/intel/sep",
        "event_file": None,
    },
    "tmc": {
        "enabled": False,
        "upload": True,
        "server_url": None,
        "credentials_file": None,
        "emon_user": None,
    },
    "os_tuning": {
        "enabled": True,
        "thp": "madvise",
        "numa_balancing": None,
        "drop_caches": True,
    },
    "scaling": {
        "enabled": False,
        "core_counts": [16, 32, 64],
    },
}

ENV_VAR_MAP = {
    "DCPERF_EXPERIMENT": "global.experiment_name",
    "DCPERF_RESULTS_DIR": "global.results_dir",
    "DCPERF_LOG_LEVEL": "global.log_level",
    "DCPERF_DRY_RUN": "global.dry_run",
    "DCPERF_WORKLOADS": "workloads.enabled",
    "DCPERF_EMON": "emon.enabled",
    "DCPERF_EMON_SEP_PATH": "emon.sep_path",
    "DCPERF_EMON_EVENT_FILE": "emon.event_file",
    "DCPERF_UPLOAD_TMC": "tmc.enabled",
    "DCPERF_TMC_SERVER_URL": "tmc.server_url",
    "DCPERF_TMC_CREDENTIALS_FILE": "tmc.credentials_file",
    "DCPERF_TMC_EMON_USER": "tmc.emon_user",
}


class ConfigError(ValueError):
    """Raised when configuration is invalid."""


def _deep_merge(base: MutableMapping[str, Any], override: Mapping[str, Any]) -> Dict[str, Any]:
    result = deepcopy(dict(base))
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def _set_nested(config: MutableMapping[str, Any], dotted_path: str, value: Any) -> None:
    keys = dotted_path.split(".")
    ref: MutableMapping[str, Any] = config
    for key in keys[:-1]:
        current = ref.get(key)
        if not isinstance(current, dict):
            current = {}
            ref[key] = current
        ref = current
    ref[keys[-1]] = value


def _parse_bool(raw: str) -> bool:
    lowered = raw.strip().lower()
    if lowered in {"1", "true", "yes", "on"}:
        return True
    if lowered in {"0", "false", "no", "off"}:
        return False
    raise ConfigError(f"Invalid boolean value: {raw!r}")


def _coerce_env_value(path: str, raw: str) -> Any:
    if path.endswith(".enabled") or path.endswith(".dry_run"):
        return _parse_bool(raw)
    if path == "workloads.enabled":
        return [item.strip() for item in raw.split(",") if item.strip()]
    return raw


def _validate_workload_names(values: Iterable[str], field_name: str) -> None:
    unknown = [value for value in values if value not in WORKLOADS]
    if unknown:
        raise ConfigError(
            f"{field_name} contains unsupported workload(s): {', '.join(sorted(set(unknown)))}; "
            f"supported: {', '.join(WORKLOADS)}"
        )


def validate_config(config: Mapping[str, Any]) -> None:
    for section in ("global", "workloads", "emon", "tmc", "os_tuning", "scaling"):
        if section not in config or not isinstance(config[section], dict):
            raise ConfigError(f"Missing or invalid section: '{section}'")

    global_cfg = config["global"]
    if global_cfg.get("log_level") not in {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}:
        raise ConfigError("global.log_level must be one of DEBUG, INFO, WARNING, ERROR, CRITICAL")
    if not isinstance(global_cfg.get("dry_run"), bool):
        raise ConfigError("global.dry_run must be boolean")
    if not str(global_cfg.get("experiment_name", "")).strip():
        raise ConfigError("global.experiment_name must be a non-empty string")
    if not str(global_cfg.get("results_dir", "")).strip():
        raise ConfigError("global.results_dir must be a non-empty string")

    workloads_cfg = config["workloads"]
    enabled = workloads_cfg.get("enabled")
    if not isinstance(enabled, list) or not enabled:
        raise ConfigError("workloads.enabled must be a non-empty list")
    _validate_workload_names([str(v) for v in enabled], "workloads.enabled")

    scaling_cfg = config["scaling"]
    core_counts = scaling_cfg.get("core_counts")
    if not isinstance(core_counts, list) or not core_counts:
        raise ConfigError("scaling.core_counts must be a non-empty list")
    if not all(isinstance(v, int) and v > 0 for v in core_counts):
        raise ConfigError("scaling.core_counts must contain positive integers")

    os_tuning_cfg = config["os_tuning"]
    if os_tuning_cfg.get("thp") not in {"never", "always", "madvise"}:
        raise ConfigError("os_tuning.thp must be one of never, always, madvise")


def _apply_legacy_aliases(config: MutableMapping[str, Any], config_path: Path) -> None:
    global_cfg = config.get("global", {})
    emon_cfg = config.get("emon", {})
    tmc_cfg = config.get("tmc", {})
    workload_cfg = config.get("workloads", {}).get("overrides", {})

    config["results_base_dir"] = global_cfg.get("results_dir")
    config["default_runs"] = int(config.get("default_runs") or 1)
    config["sep_path"] = emon_cfg.get("sep_path")
    config["emon_event_file"] = emon_cfg.get("event_file")
    config["emon_user"] = tmc_cfg.get("emon_user") or config.get("emon_user")
    if "tao_bench" in workload_cfg and isinstance(workload_cfg["tao_bench"], dict):
        config["tao_bench_mode"] = workload_cfg["tao_bench"].get("mode", config.get("tao_bench_mode", "standalone"))

    default_root = config_path.resolve().parents[2]
    config["dcperf_root"] = config.get("dcperf_root") or str(default_root)


def load_config(
    config_path: Path,
    cli_overrides: Optional[Mapping[str, Any]] = None,
    env: Optional[Mapping[str, str]] = None,
) -> Dict[str, Any]:
    """Load config with default < file < env < CLI precedence."""
    env_values = dict(env or os.environ)
    resolved_path = Path(config_path)

    file_cfg: Dict[str, Any] = {}
    if resolved_path.exists():
        with open(resolved_path, "r", encoding="utf-8") as fh:
            loaded = yaml.safe_load(fh) or {}
            if not isinstance(loaded, dict):
                raise ConfigError("Top-level config must be a mapping")
            file_cfg = loaded

    config = _deep_merge(DEFAULT_CONFIG, file_cfg)

    for env_key, dotted_path in ENV_VAR_MAP.items():
        raw = env_values.get(env_key)
        if raw is None:
            continue
        _set_nested(config, dotted_path, _coerce_env_value(dotted_path, raw))

    for key, value in (cli_overrides or {}).items():
        if value is None:
            continue
        _set_nested(config, key, value)

    validate_config(config)
    _apply_legacy_aliases(config, resolved_path)
    return config
