# DCPerf Config Reference

Config file: `dcperf_scripts/config/dcperf_config.yaml` (copy from
`dcperf_config.yaml.example` on a new checkout)

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
- `perf_events`
  - optional comma-separated Linux `perf` event names used by `--perf`

The loader also accepts the legacy flat keys used by older configs, including
`dcperf_root`, `sep_path`, `emon_event_file`, `emon_user`,
`results_base_dir`, `default_runs`, and workload-specific paths. They are
normalized into the structured model while remaining available to workload
runners.

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

## Common Runner Options

Every named workload runner supports the shared options below in addition to
its workload-specific flags:

- `--config FILE`: use a different DCPerf configuration file.
- `--results-dir DIR`: override the result root.
- `--runs N` or `--iterations N`: repeat the runner. Django retains its
  historical workload-specific `--iterations` meaning; use `--runs` for repeat
  count there.
- `--emon` and `--perf`: enable telemetry collectors.
- `--tune-os` or `--no-tune-os`: enable or disable OS tuning.
- `--cores 16,32,64`: run explicit core-scaling points.
- `--verbose`: enable debug logging.
