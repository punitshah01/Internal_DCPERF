# DCPerf Quick Start

Run these commands from the repository root.

## 1. Configure once

Copy the example configuration and edit the values for your machine:

```bash
cp dcperf_scripts/run_workloads.config.example.yaml \
   dcperf_scripts/run_workloads.config.yaml
```

The main configuration is `dcperf_scripts/config/dcperf_config.yaml`. Set the
experiment name, results directory, telemetry settings, and enabled workloads.

## 2. Install

```bash
sudo python dcperf_scripts/run_setup.py
```

Use `python dcperf_scripts/run_setup.py --help` for `--workload`, `--force`,
`--resume`, `--verify`, and `--dry-run` options. `--verify` checks the host and
workload artifacts without installing or modifying the configuration.

## 3. Validate and preview

```bash
python dcperf_scripts/run_health_check.py --dry-run
python dcperf_scripts/run_workloads.py --show-config
python dcperf_scripts/run_workloads.py --dry-run
```

## 4. Run workloads

Run one workload directly:

```bash
python dcperf_scripts/run_mediawiki.py --runs 3 --experiment my_test
```

Run a selected group:

```bash
python dcperf_scripts/run_workloads.py \
  --workloads mediawiki,feedsim,tao_bench \
  --iterations 3 \
  --experiment my_test \
  --emon --perf --cores 16,32,64
```

Replace `run_mediawiki.py` with `run_feedsim.py`, `run_django_workload.py`,
`run_spark_standalone.py`, `run_tao_bench.py`, or
`run_video_transcode_bench.py` for the other primary workloads.

## 5. Results and troubleshooting

Results are written under the configured results directory. Use
`dcperf_scripts/README.md` for the full result layout, telemetry options,
workload-specific settings, and troubleshooting guidance.

The lower-level compatibility entry points `dcperf.py` and `dcperf_run.py`
remain available for existing automation, but the `run_*.py` launchers are the
documented interface.

## Exit Codes

- `0`: success
- `1`: generic runtime error
- `2`: configuration error
- `3`: system check failure
