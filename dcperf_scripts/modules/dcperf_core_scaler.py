"""CPU online/offline (core scaling) helpers extracted from dj_perf.py,
fs_perf.py, mw_perf.py, sweep.py, vt_script.py.

Fixes the mw_perf.py bug where the core-scaling instance-count formula
used ``nproc`` (total logical CPUs) instead of the actually-*enabled*
core count — ``set_core_count``/callers must use ``get_online_cores()``.

Module-level functions only.
"""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Iterator, List

_CPU_SYSFS_ROOT = Path("/sys/devices/system/cpu")


def get_online_cores() -> List[int]:
    """Return the currently online CPU indices, read from cpu*/online.

    cpu0 has no 'online' file on most kernels (it cannot be offlined) and
    is always considered online.
    """
    online: List[int] = []
    for cpu_dir in sorted(_CPU_SYSFS_ROOT.glob("cpu[0-9]*"), key=lambda p: int(p.name[3:])):
        idx = int(cpu_dir.name[3:])
        online_file = cpu_dir / "online"
        if not online_file.exists():
            online.append(idx)  # cpu0 case
            continue
        try:
            if online_file.read_text().strip() == "1":
                online.append(idx)
        except OSError:
            continue
    return online


def get_total_cores() -> int:
    """Return total logical CPUs present under /sys/devices/system/cpu (online or not)."""
    return len(list(_CPU_SYSFS_ROOT.glob("cpu[0-9]*")))


def _write_online(core_id: int, value: str, logger, dry_run: bool) -> bool:
    online_file = _CPU_SYSFS_ROOT / f"cpu{core_id}" / "online"
    cmd = f"echo {value} | sudo tee {online_file}"
    logger.info("core_scaler: %s", cmd)
    if dry_run:
        return True
    if not online_file.exists():
        logger.warning("core_scaler: %s does not exist, skipping", online_file)
        return False
    try:
        subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True)
        return True
    except subprocess.CalledProcessError as exc:
        logger.error("core_scaler: failed to set cpu%s online=%s: %s", core_id, value, exc.stderr)
        return False


def enable_cores(core_list: List[int], logger, dry_run: bool = False) -> bool:
    """Write 1 to cpu<id>/online for every id in core_list."""
    success = True
    for core_id in core_list:
        if not _write_online(core_id, "1", logger, dry_run):
            success = False
    return success


def disable_cores(core_list: List[int], logger, dry_run: bool = False) -> bool:
    """Write 0 to cpu<id>/online for every id in core_list. Never disables cpu0."""
    success = True
    for core_id in core_list:
        if core_id == 0:
            logger.info("core_scaler: skipping cpu0 (cannot be disabled)")
            continue
        if not _write_online(core_id, "0", logger, dry_run):
            success = False
    return success


def set_core_count(n: int, logger, dry_run: bool = False) -> bool:
    """Enable the first n cores, disable the rest, based on get_online_cores() / get_total_cores().

    This is the fix for the mw_perf.py bug: the caller must never compute
    ``n`` from ``nproc`` directly — ``n`` should be derived from the
    core-scaling sweep step, and the *current* topology used here comes
    from actual sysfs state, not the OS-reported logical CPU count.
    """
    total = get_total_cores()
    if n < 1 or n > total:
        logger.error("core_scaler: requested core count %s out of range (1..%s)", n, total)
        return False

    to_enable = list(range(0, n))
    to_disable = list(range(n, total))

    ok_enable = enable_cores(to_enable, logger, dry_run)
    ok_disable = disable_cores(to_disable, logger, dry_run)
    return ok_enable and ok_disable


def scale_generator(start: int, end: int, step: int) -> Iterator[int]:
    """Yield core counts from start to end (inclusive) in steps of step.

    Always yields ``end`` as the final value even if it doesn't fall on
    an exact step boundary, matching the sweep behavior of the original
    5 scripts (which always ran the full ``total_cores`` as the last step).
    """
    current = start
    while current < end:
        yield current
        current += step
    yield end
