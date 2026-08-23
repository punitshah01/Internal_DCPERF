# DCPerf Quick Start

## 1) Configure once

Edit `/home/runner/work/Internal_DCPERF/Internal_DCPERF/dcperf_scripts/config/dcperf_config.yaml`:

- `global.experiment_name`
- `global.results_dir`
- `emon.*` / `tmc.*` if telemetry is needed
- `workloads.enabled`

## 2) Validate config

```bash
python /home/runner/work/Internal_DCPERF/Internal_DCPERF/dcperf_scripts/dcperf.py config --validate
```

## 3) See workloads

```bash
python /home/runner/work/Internal_DCPERF/Internal_DCPERF/dcperf_scripts/dcperf.py list
```

## 4) Dry-run a full execution

```bash
python /home/runner/work/Internal_DCPERF/Internal_DCPERF/dcperf_scripts/dcperf.py run --all --dry-run
```

## 5) Run an experiment

```bash
python /home/runner/work/Internal_DCPERF/Internal_DCPERF/dcperf_scripts/dcperf.py run \
  --workload mediawiki \
  --iterations 3 \
  --experiment my_test
```

## 6) Run health checks and tuning

```bash
python /home/runner/work/Internal_DCPERF/Internal_DCPERF/dcperf_scripts/dcperf.py check
python /home/runner/work/Internal_DCPERF/Internal_DCPERF/dcperf_scripts/dcperf.py tune
```

## 7) Summarize results

```bash
python /home/runner/work/Internal_DCPERF/Internal_DCPERF/dcperf_scripts/dcperf.py results --experiment my_test
```

## Exit Codes

- `0`: success
- `1`: generic runtime error
- `2`: configuration error
- `3`: system check failure
