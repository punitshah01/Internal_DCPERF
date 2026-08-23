"""TMC (telemetry collector) integration — EMON collection plus upload.

Restores the ``tmc`` flow the pre-automation baseline scripts used
(mw_perf.sh, dj_perf.sh, fs_perf.sh, sweep.sh, tao_perf.sh, vt_script.sh).
``EmonManager`` drives ``emon -collect-edp`` locally; TMC instead wraps the
whole workload command and uploads the resulting session, e.g.

    tmc -c "<workload cmd>" -rl <log> -rs "<ramp string>" -rt 2800 -n -u \\
        -x pshah -a <alias> -S 600 -E 2400 -A 10 -B 290 \\
        -w socket,core,uncore -Z metrics2 -G mediawiki_1.3E

Flag reference (as used by the baseline scripts):
  -c   command to run under TMC          -rl  ramp log file to watch
  -rs  ramp marker string                -rt  ramp timeout (seconds)
  -lt  lead time (seconds)               -n   non-interactive
  -u   upload the session                -x   upload user/owner
  -a   session alias                     -S/-E  collection start/end offset
  -A/-B  secondary collector window      -w   views (socket,core,uncore,thread)
  -Z   metrics set                       -G   session group/prefix tag
  -T   tools to run (emon,sar,iostat)    -e   EMON event file
  -d/-D  log/output directory            -v   verbose
"""

from __future__ import annotations

import shlex
import shutil
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


class TmcRunner:
    """Builds and executes ``tmc`` command lines."""

    def __init__(self, config: Dict[str, Any], logger, dry_run: bool = False):
        self.config = config
        self.logger = logger
        self.dry_run = dry_run

    def is_available(self) -> bool:
        if shutil.which("tmc"):
            return True
        self.logger.error("tmc: 'tmc' not found on PATH; run the PNPWLS setup_emon.sh first")
        return False

    def build_command(
        self,
        inner_cmd: str,
        *,
        alias: str,
        ramp_log: Optional[str] = None,
        ramp_string: Optional[str] = None,
        ramp_timeout: Optional[int] = None,
        lead_time: Optional[int] = None,
        start: Optional[int] = None,
        end: Optional[int] = None,
        secondary_start: Optional[int] = None,
        secondary_end: Optional[int] = None,
        views: Optional[str] = None,
        metrics_set: Optional[str] = None,
        group: Optional[str] = None,
        tools: Optional[str] = None,
        event_file: Optional[str] = None,
        log_dir: Optional[str] = None,
        upload: bool = True,
        user: Optional[str] = None,
        verbose: bool = False,
    ) -> List[str]:
        cmd: List[str] = ["tmc", "-c", inner_cmd]

        if log_dir:
            cmd += ["-d", log_dir, "-D", log_dir]
        if ramp_log:
            cmd += ["-rl", ramp_log]
        if ramp_string:
            cmd += ["-rs", ramp_string]
        if lead_time is not None:
            cmd += ["-lt", str(lead_time)]
        if ramp_timeout is not None:
            cmd += ["-rt", str(ramp_timeout)]

        cmd.append("-n")
        if upload:
            cmd.append("-u")
        if verbose:
            cmd.append("-v")

        user = user or self.config.get("emon_user") or (self.config.get("tmc") or {}).get("emon_user")
        if upload and not user:
            raise ValueError("tmc upload requested but emon_user is not set")
        if user:
            cmd += ["-x", str(user)]
        cmd += ["-a", alias]

        if start is not None:
            cmd += ["-S", str(start)]
        if end is not None:
            cmd += ["-E", str(end)]
        if secondary_start is not None:
            cmd += ["-A", str(secondary_start)]
        if secondary_end is not None:
            cmd += ["-B", str(secondary_end)]
        if views:
            cmd += ["-w", views]
        if metrics_set:
            cmd += ["-Z", metrics_set]
        if tools:
            cmd += ["-T", tools]

        event_file = event_file or self.config.get("emon_event_file") or (self.config.get("emon") or {}).get("event_file")
        if event_file:
            cmd += ["-e", str(event_file)]
        if group:
            cmd += ["-G", group]

        return cmd

    def run(self, cmd: List[str], cwd: Optional[str] = None) -> Tuple[int, str, str]:
        printable = " ".join(shlex.quote(part) for part in cmd)
        self.logger.info("tmc: %s", printable)
        if self.dry_run:
            return 0, "[dry-run] tmc not executed", ""

        if not self.is_available():
            return 1, "", "tmc not found on PATH"

        if cwd:
            Path(cwd).mkdir(parents=True, exist_ok=True)

        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
                cwd=cwd,
            )
        except OSError as exc:
            self.logger.error("tmc: failed to launch: %s", exc)
            return 1, "", str(exc)

        stdout, stderr = proc.communicate()
        if proc.returncode != 0:
            self.logger.error("tmc: exited %s: %s", proc.returncode, stderr.strip()[:500])
        return proc.returncode, stdout, stderr
