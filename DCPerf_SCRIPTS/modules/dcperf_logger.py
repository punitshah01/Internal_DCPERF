"""Shared logging setup for DCPerf workload wrappers."""

from __future__ import annotations

import logging
import sys
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory


_LOGGER_CONFIGURED_ATTR = "_dcperf_logger_configured"
_LOG_FILE_ATTR = "dcperf_log_path"
_SHARED_LOG_PATH: Path | None = None
_RESET = "\033[0m"
_YELLOW = "\033[33m"
_RED = "\033[31m"
_BOLD_RED = "\033[1;31m"


class _ConsoleFormatter(logging.Formatter):
    """Format log levels with color only when stdout is an interactive TTY."""

    _COLORS = {
        logging.WARNING: _YELLOW,
        logging.ERROR: _RED,
        logging.CRITICAL: _BOLD_RED,
    }

    def __init__(self, use_color: bool) -> None:
        super().__init__()
        self.use_color = use_color

    def format(self, record: logging.LogRecord) -> str:
        level = f"{record.levelname:<8}"
        if self.use_color:
            color = self._COLORS.get(record.levelno, "")
            level = f"{color}{level}{_RESET}" if color else level
        return f"{level} | {record.getMessage()}"


def get_logger(name: str, log_dir: Path) -> logging.Logger:
    """Return an idempotently configured logger for a DCPerf component.

    All loggers in a process share one log file so master and wrapper output
    stay in a single place.
    """
    global _SHARED_LOG_PATH

    logger = logging.getLogger(name)
    if getattr(logger, _LOGGER_CONFIGURED_ATTR, False):
        return logger

    log_dir = Path(log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    first_logger = _SHARED_LOG_PATH is None
    if first_logger:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        _SHARED_LOG_PATH = log_dir / f"dcperf_{timestamp}.log"
    log_path = _SHARED_LOG_PATH

    file_handler = logging.FileHandler(log_path, encoding="utf-8")
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(
        logging.Formatter(
            "%(asctime)s | %(levelname)-8s | %(name)-20s | %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        )
    )

    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setLevel(logging.INFO)
    console_handler.setFormatter(_ConsoleFormatter(sys.stdout.isatty()))

    logger.setLevel(logging.DEBUG)
    logger.handlers.clear()
    logger.addHandler(file_handler)
    logger.addHandler(console_handler)
    logger.propagate = False
    setattr(logger, _LOGGER_CONFIGURED_ATTR, True)
    setattr(logger, _LOG_FILE_ATTR, log_path)

    if first_logger:
        logger.info("Log file: %s", log_path)
    return logger


def log_section(logger: logging.Logger, title: str) -> None:
    """Write a visible section divider through the shared logger."""
    divider = "-" * 60
    logger.info("%s %s %s", divider, title, divider)


if __name__ == "__main__":
    with TemporaryDirectory() as temporary_dir:
        test_logger = get_logger("dcperf_logger_self_test", Path(temporary_dir))
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
