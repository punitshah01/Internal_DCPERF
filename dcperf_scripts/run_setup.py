#!/usr/bin/env python3
"""Install DCPerf prerequisites and all registered workloads."""

from __future__ import annotations

import sys
from typing import List, Optional

from dcperf_run import main as dcperf_main


def main(argv: Optional[List[str]] = None) -> int:
    """Run the setup phase while preserving dcperf_run's setup options."""
    user_args = sys.argv[1:] if argv is None else argv
    verifying = "--verify" in user_args
    setup_args = [] if verifying else ["--install-only"]
    if not verifying and not any(
        arg == "--all" or arg == "--workload" or arg.startswith("--workload=")
        for arg in user_args
    ):
        setup_args.append("--all")
    setup_args.extend(user_args)
    return dcperf_main(setup_args)


if __name__ == "__main__":
    raise SystemExit(main())