# DCPerf Config Reference

Config file: `/home/runner/work/Internal_DCPERF/Internal_DCPERF/dcperf_scripts/config/dcperf_config.yaml`

## Sections

- `global`
  - `experiment_name`: default experiment label
  - `results_dir`: base output directory
  - `log_level`: `DEBUG|INFO|WARNING|ERROR|CRITICAL`
  - `dry_run`: when true, commands are not executed

- `workloads`
  - `enabled`: list of workloads used by `dcperf run` when `--workload/--all` is not provided
  - `overrides`: per-workload override block

- `emon`
  - `enabled`: enable EMON collection by default
  - `sep_path`: SEP installation path
  - `event_file`: optional event file path

- `tmc`
  - `enabled`: upload EMON to TMC by default
  - `upload`: keep upload enabled/disabled default state
  - `server_url`: optional TMC endpoint
  - `credentials_file`: optional credential file path
  - `emon_user`: upload identity

- `os_tuning`
  - `enabled`: enable tune command actions
  - `thp`: `never|always|madvise`
  - `numa_balancing`: optional setting placeholder
  - `drop_caches`: run cache drop when tuning

- `scaling`
  - `enabled`: reserve for scale sweep flows
  - `core_counts`: list of core-count targets

## Environment Variable Overrides

Supported overrides (higher precedence than file values):

- `DCPERF_EXPERIMENT`
- `DCPERF_RESULTS_DIR`
- `DCPERF_LOG_LEVEL`
- `DCPERF_DRY_RUN`
- `DCPERF_WORKLOADS` (comma-separated)
- `DCPERF_EMON`
- `DCPERF_EMON_SEP_PATH`
- `DCPERF_EMON_EVENT_FILE`
- `DCPERF_UPLOAD_TMC`
- `DCPERF_TMC_SERVER_URL`
- `DCPERF_TMC_CREDENTIALS_FILE`
- `DCPERF_TMC_EMON_USER`

## Precedence

1. CLI flags (highest)
2. Environment variables
3. Config file values
4. Built-in defaults (lowest)
