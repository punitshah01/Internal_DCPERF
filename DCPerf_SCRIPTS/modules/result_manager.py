"""Result directory / CSV / JSON writer, following PNPWLS csv_writer.py and
json_results.py conventions, enforcing the standard DCPerf result layout::

    results/
    └── <workload>_<YYYYMMDD_HHMMSS>/
        ├── stdout.log
        ├── stderr.log
        ├── metrics.json
        ├── results.csv
        ├── results.json
        ├── system_metadata.json
        ├── command.txt
        └── emon/
            ├── emon.dat
            └── emon_summary/
"""

from __future__ import annotations

import csv
import json
import socket
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional


class ResultManager:
    """Owns the shared top-level results timestamp for one master run."""

    def __init__(self, base_results_dir: Path, logger):
        self.base_results_dir = Path(base_results_dir)
        self.logger = logger
        # Fixed once so every workload run in this master invocation shares
        # the same top-level timestamp for grouping in the summary report.
        self.timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

    # ------------------------------------------------------------------
    # Directory creation
    # ------------------------------------------------------------------

    def create_run_dir(self, workload: str) -> Path:
        run_dir = self.base_results_dir / f"{workload}_{self.timestamp}"
        try:
            run_dir.mkdir(parents=True, exist_ok=True)
            (run_dir / "emon").mkdir(parents=True, exist_ok=True)
            (run_dir / "emon" / "emon_summary").mkdir(parents=True, exist_ok=True)
        finally:
            # Printed on both success and failure paths (Gate C contract).
            print(f"Output Directory: {run_dir.resolve()}")
        return run_dir

    # ------------------------------------------------------------------
    # Simple artifact writers
    # ------------------------------------------------------------------

    def save_stdout(self, run_dir: Path, content: str) -> None:
        (Path(run_dir) / "stdout.log").write_text(content or "", encoding="utf-8")

    def save_stderr(self, run_dir: Path, content: str) -> None:
        (Path(run_dir) / "stderr.log").write_text(content or "", encoding="utf-8")

    def save_command(self, run_dir: Path, cmd: str) -> None:
        (Path(run_dir) / "command.txt").write_text(cmd or "", encoding="utf-8")

    def save_metrics(self, run_dir: Path, metrics: Dict[str, Any]) -> None:
        (Path(run_dir) / "metrics.json").write_text(
            json.dumps(metrics, indent=2, default=str), encoding="utf-8"
        )

    # ------------------------------------------------------------------
    # CSV writer (PNPWLS csv_writer.py style: smart header handling)
    # ------------------------------------------------------------------

    def write_csv_row(self, run_dir: Path, row: Dict[str, Any]) -> None:
        """Append one row to results.csv, writing the header only if new.

        Never silently swallows failures — exceptions propagate to the
        caller so a disk-full/permission error is visible.
        """
        csv_file = Path(run_dir) / "results.csv"
        header = list(row.keys())
        values = [str(v) if v is not None else "" for v in row.values()]

        file_exists = csv_file.exists() and csv_file.stat().st_size > 0
        write_header = True
        if file_exists:
            with open(csv_file, "r", newline="", encoding="utf-8") as fh:
                first_line = fh.readline().strip()
            write_header = first_line != ",".join(header)

        with open(csv_file, "a", newline="", encoding="utf-8") as fh:
            writer = csv.writer(fh, quoting=csv.QUOTE_MINIMAL)
            if write_header:
                writer.writerow(header)
            writer.writerow(values)

        self.logger.info("result_manager: wrote row to %s", csv_file)

    # ------------------------------------------------------------------
    # JSON results writer (PNPWLS json_results.py style)
    # ------------------------------------------------------------------

    def write_json_results(self, run_dir: Path, data: Dict[str, Any]) -> None:
        """Always write results.json, on both success and failure paths."""
        results_file = Path(run_dir) / "results.json"
        payload = {
            "version": 2,
            "orch_run_id": data.get("orch_run_id", ""),
            "rows": data.get("rows", []),
        }
        try:
            results_file.write_text(json.dumps(payload, indent=2, default=str), encoding="utf-8")
        except OSError as exc:
            self.logger.error("result_manager: FAILED to write results.json: %s", exc)
            raise

    def write_system_metadata(self, run_dir: Path, metadata: Dict[str, Any]) -> None:
        (Path(run_dir) / "system_metadata.json").write_text(
            json.dumps(metadata, indent=2, default=str), encoding="utf-8"
        )

    # ------------------------------------------------------------------
    # Master run summary
    # ------------------------------------------------------------------

    def write_summary(self, all_results: List[Dict[str, Any]]) -> None:
        """Write run_summary.json and run_summary.txt into the top-level results dir."""
        summary_dir = self.base_results_dir / f"summary_{self.timestamp}"
        summary_dir.mkdir(parents=True, exist_ok=True)

        (summary_dir / "run_summary.json").write_text(
            json.dumps(all_results, indent=2, default=str), encoding="utf-8"
        )

        text = self._render_summary_text(all_results)
        (summary_dir / "run_summary.txt").write_text(text, encoding="utf-8")
        print(text)

    def _render_summary_text(self, all_results: List[Dict[str, Any]]) -> str:
        hostname = socket.gethostname()
        cpu_model = self._read_cpu_model()
        bar = "=" * 64
        thin = "-" * 64

        lines = [
            bar,
            "DCPerf Run Summary",
            f"Timestamp : {self.timestamp}",
            f"Host      : {hostname}",
            f"Platform  : {cpu_model}",
            bar,
            f"{'Workload':<22}{'Status':<8}{'Runs':<7}{'Primary KPI'}",
            thin,
        ]

        pass_count = 0
        fail_count = 0
        for entry in all_results:
            status = entry.get("status", "FAIL")
            if status == "PASS":
                pass_count += 1
            else:
                fail_count += 1
            kpi = entry.get("primary_kpi", "--")
            lines.append(
                f"{entry.get('workload', ''):<22}{status:<8}{str(entry.get('runs', '')):<7}{kpi}"
            )

        lines.append(thin)
        total = len(all_results)
        lines.append(f"Total: {total} workloads | {pass_count} PASS | {fail_count} FAIL")
        lines.append(f"Results: results/{self.timestamp}/")
        lines.append(bar)
        return "\n".join(lines) + "\n"

    @staticmethod
    def _read_cpu_model() -> str:
        try:
            with open("/proc/cpuinfo", encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    if line.lower().startswith("model name"):
                        return line.split(":", 1)[1].strip()
        except OSError:
            pass
        return "Unknown"
