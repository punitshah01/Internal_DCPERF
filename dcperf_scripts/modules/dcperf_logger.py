"""Shared logging setup for DCPerf components."""

from __future__ import annotations

import json
import logging
import sys
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any, Optional


_LOGGER_CONFIGURED_ATTR = "_dcperf_logger_configured"
_LOG_FILE_ATTR = "dcperf_log_path"
_SHARED_LOG_PATH: Optional[Path] = None
_RESET = "\033[0m"
_COLORS = {
    "DEBUG": "\033[36m",
    "INFO": "\033[32m",
    "WARNING": "\033[33m",
    "ERROR": "\033[31m",
    "CRITICAL": "\033[1;31m",
}


class _ConsoleFormatter(logging.Formatter):
    def __init__(self, use_color: bool) -> None:
        super().__init__()
        self.use_color = use_color

    def format(self, record: logging.LogRecord) -> str:
        level = f"{record.levelname:<8}"
        if self.use_color:
            color = _COLORS.get(record.levelname)
            if color:
                level = f"{color}{level}{_RESET}"
        ts = datetime.fromtimestamp(record.created).strftime("%Y-%m-%d %H:%M:%S")
        workload = getattr(record, "workload", "-")
        return f"{ts} | {level} | {record.name} | workload={workload} | {record.getMessage()}"


class _JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": datetime.fromtimestamp(record.created).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "module": record.name,
            "workload": getattr(record, "workload", None),
            "experiment": getattr(record, "experiment", None),
            "message": record.getMessage(),
            "duration_ms": getattr(record, "duration_ms", None),
        }
        return json.dumps(payload, separators=(",", ":"), ensure_ascii=False)


class _DefaultContextFilter(logging.Filter):
    def __init__(self, workload: Optional[str], experiment: Optional[str]) -> None:
        super().__init__()
        self.workload = workload
        self.experiment = experiment

    def filter(self, record: logging.LogRecord) -> bool:
        if not hasattr(record, "workload"):
            record.workload = self.workload or "-"
        if not hasattr(record, "experiment"):
            record.experiment = self.experiment or "-"
        if not hasattr(record, "duration_ms"):
            record.duration_ms = None
        return True


def get_logger(
    name: str,
    log_dir: Path,
    log_level: str = "DEBUG",
    experiment: Optional[str] = None,
    workload: Optional[str] = None,
) -> logging.Logger:
    """Return an idempotently configured logger for a DCPerf component."""
    global _SHARED_LOG_PATH

    logger = logging.getLogger(name)
    if getattr(logger, _LOGGER_CONFIGURED_ATTR, False):
        return logger

    level = getattr(logging, str(log_level).upper(), logging.DEBUG)
    log_dir = Path(log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)

    first_logger = _SHARED_LOG_PATH is None
    if first_logger:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        exp = (experiment or "default").strip().replace(" ", "_")
        _SHARED_LOG_PATH = log_dir / f"dcperf_{exp}_{timestamp}.jsonl"
    log_path = _SHARED_LOG_PATH

    file_handler = logging.FileHandler(log_path, encoding="utf-8")
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(_JsonFormatter())

    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setLevel(logging.INFO)
    console_handler.setFormatter(_ConsoleFormatter(sys.stdout.isatty()))

    context_filter = _DefaultContextFilter(workload=workload or name, experiment=experiment)

    logger.setLevel(level)
    logger.handlers.clear()
    logger.filters.clear()
    logger.addFilter(context_filter)
    logger.addHandler(file_handler)
    logger.addHandler(console_handler)
    logger.propagate = False

    setattr(logger, _LOGGER_CONFIGURED_ATTR, True)
    setattr(logger, _LOG_FILE_ATTR, log_path)

    if first_logger:
        logger.info("Log file: %s", log_path)
    return logger


def log_section(logger: logging.Logger, title: str) -> None:
    divider = "-" * 60
    logger.info("%s %s %s", divider, title, divider)


if __name__ == "__main__":
    with TemporaryDirectory() as temporary_dir:
        test_logger = get_logger("dcperf_logger_self_test", Path(temporary_dir), experiment="selftest")
        test_logger.debug("debug test message")
        test_logger.info("info test message")
        test_logger.warning("warning test message")
        test_logger.error("error test message")
        test_logger.critical("critical test message")
        log_section(test_logger, "LOGGER SETUP SELF-TEST")

        test_log_path = getattr(test_logger, _LOG_FILE_ATTR)
        print(f"Log file created: {test_log_path.exists()} ({test_log_path})")
        for handler in test_logger.handlers:
            handler.close()
