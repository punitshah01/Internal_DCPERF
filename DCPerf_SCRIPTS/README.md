# DCPerf_SCRIPTS

## 1. Overview

DCPerf_SCRIPTS orchestrates Facebook's [DCPerf](https://github.com/facebookresearch/DCPerf) benchmark suite (django_workload, feedsim, mediawiki, spark_standalone, tao_bench, video_transcode_bench, wdl_bench, health_check) with EMON/perf telemetry, OS tuning, core-scaling sweeps, and structured result capture layered on top of it. It does not replace DCPerf's own `benchpress_cli.py install/run` — every wrapper here calls that CLI under the hood and adds pre-flight checks, known-issue fixes, and machine-readable result artifacts around it. Wrapper structure (`BaseWrapper` execution flow, `results.json` schema, `Output Directory:` marker, `--experiment`/`--orch-run-id` flags) follows Intel PNPWLS conventions so these workloads can be registered with the same WLC orchestrator used for other PNPWLS runners.

## 2. Prerequisites

**System requirements**
- OS: CentOS Stream 8/9 or Ubuntu 22.04
- Python: 3.8 or higher
- sudo access required (OS tuning, EMON driver load/unload, package installs)

**Required packages (install before cloning):**
```bash
sudo dnf install -y git python3 python3-pip wget curl numactl binutils-devel
python3 -m pip install pyyaml
```

**EMON/SEP (optional, for telemetry):**
- Install Intel VTune or SEP separately (not distributed with this repo).
- Default expected path: `/opt/intel/sep`
- Override in `config/setup_config.yaml`: `sep_path`

**Workload-specific prerequisites:**

| Workload | Prerequisites |
|---|---|
| FeedSim | cmake, gcc, g++ (installed by workload installer); gengetopt-2.23 fetched by `FeedsimWrapper.pre_install_patch()` with mirror fallback |
| MediaWiki | HHVM 3.30 must be installed manually — see `packages/mediawiki/README.md` |
| Spark | Java 8 required; NVMe-TCP kernel modules required; custom kernel recommended (see Section 7); minimum 500GB NVMe storage |
| TaoBench | `binutils-devel`, updated `ca-certificates` (installed automatically by `TaoBenchWrapper.pre_install_check()`) |
| Video | El Fuente dataset (user must provide) — place at the path set in `config/setup_config.yaml` under `video_dataset_path` |

## 3. Installation

```bash
# 1. Clone the repo
git clone <your-repo-url>
cd DCPerf

# 2. Configure
cp DCPerf_SCRIPTS/config/setup_config.yaml.example DCPerf_SCRIPTS/config/setup_config.yaml
vim DCPerf_SCRIPTS/config/setup_config.yaml   # fill in null values you need

# 3. Install all workloads
cd DCPerf_SCRIPTS
python dcperf_master_setup.py --install-only --all

# 4. Install one workload
python dcperf_master_setup.py --install-only --workload tao_bench
```

## 4. Running

```bash
# Run everything
python dcperf_master_setup.py --run-only --all

# Run with EMON telemetry
python dcperf_master_setup.py --run-only --all --emon

# Run one workload
python dcperf_master_setup.py --run-only --workload django_workload

# Dry run (no execution, shows commands)
python dcperf_master_setup.py --dry-run --all --emon

# Resume after failure
python dcperf_master_setup.py --run-only --all --resume

# Full install + run
python dcperf_master_setup.py --all --emon
```

## 5. Configuration Reference

| Key | Required | Default | Description |
|---|---|---|---|
| `dcperf_root` | No | auto-detected | Path to the cloned DCPerf repo root |
| `sep_path` | No | `/opt/intel/sep` | Intel SEP (EMON) install directory |
| `emon_event_file` | Yes* | `null` | EMON event definition file, platform-specific |
| `emon_user` | Yes* | `null` | EMON/DCSOMETRICS upload user |
| `spark_data_path` | Yes* | `null` | Spark dataset mount path |
| `db_client_ip` | Yes* | `null` | Django clientserver DB client IP |
| `core_step` | No | `16` | Cores enabled per core-scaling sweep step |
| `default_runs` | No | `3` | Default `--runs` count |
| `video_dataset_path` | Yes* | `null` | El Fuente dataset directory |
| `nvme_tcp_interface` | No | `null` | NIC for NVMe-TCP traffic |
| `iommu_passthrough` | No | `false` | Whether IOMMU passthrough is required |
| `spark_kernel_rpms_path` | No | `null` | Custom kernel RPM directory (Spark) |
| `nvme_tcp_setup` | No | `false` | Run `setup_nvmet.py` automatically |
| `nvme_n` / `nvme_s` | Yes* | `null` | NVMe target/subsystem numbers |
| `java_path` | No | `null` | Auto-populated Java 8 path |
| `clear_tmp` | No | `false` | Allow `os_tuner.clear_tmp()` to run `rm -rf /tmp/*` |
| `results_base_dir` | No | `DCPerf_SCRIPTS/results` | Base output directory |

\* Required only for that workload.

## 6. Result Directory Layout

```
results/
└── <workload>_<YYYYMMDD_HHMMSS>/
    ├── stdout.log             # raw benchpress stdout
    ├── stderr.log             # raw benchpress stderr
    ├── metrics.json           # final KPI dict (+ os_tuning / spark_prerequisites when applicable)
    ├── results.csv            # smart-append CSV, one row per run
    ├── results.json           # {version, orch_run_id, rows[]} — WLC contract source of truth
    ├── system_metadata.json   # hostname/cpu/cores/kernel/os snapshot
    ├── command.txt            # exact argv that ran
    └── emon/
        ├── emon.dat           # raw EMON data (if --emon/--metric emon)
        └── emon_summary/      # EDP-processed output (modules.emon_manager.process_emon)
```

A `summary_<timestamp>/run_summary.json` + `run_summary.txt` is written once per `dcperf_master_setup.py` invocation, aggregating every workload run in that session.

## 7. Workload-Specific Notes

### django_workload
- Default iterations: 7 (upstream DCPerf default)
- Recommended for quick validation: 1 iteration (~5 min)
- Recommended for full benchmark: 3 iterations
- Control via CLI: `--runs 1` (quick single pass) / `--runs 3` (standard) / `--runs 7` (full upstream default)
- Or set in `config/setup_config.yaml`: `default_runs: 3`

### feedsim
- **Known issue — gengetopt download fails:** the upstream installer's single gengetopt-2.23 download URL is frequently unreachable. `FeedsimWrapper.pre_install_patch()` patches `packages/feedsim/install_feedsim.sh` with a 3-mirror fallback chain (`ftpmirror.gnu.org` -> `ftp.gnu.org` -> `ftp.gnu.org --no-check-certificate`) before install runs, and is idempotent (checks for a patch marker first).

### mediawiki
- **Known issue — CPU frequency check crash:** oss-performance crashes with `SystemChecks::CheckCPUFreq() -> HH\invariant_violation` on server CPUs. `MediaWikiWrapper.apply_mediawiki_patches()` comments out `self::CheckCPUFreq();` in `<dcperf_root>/oss-performance/base/SystemChecks.php` before every run (idempotent — checks for the disabled marker first).
- Core-scaling instance count is derived from `get_online_cores()`, not `nproc`.

### tao_bench
- **Known issue — missing system packages:** `binutils-devel` and an updated `ca-certificates`/`update-ca-trust` are required before install. `TaoBenchWrapper.pre_install_check()` installs these automatically.
- **Known issue — zlib download for folly build:** if `<dcperf_root>/benchmarks/tao_bench/build-folly/downloads/zlib-zlib-1.3.1.tar.gz` is missing or zero-byte, it's fetched from the zlib fossils mirror automatically.

### spark_standalone
- Full prerequisite sequence (`SparkWrapper.verify_spark_prerequisites()`, called before install and before every run): kernel version check (+ optional custom kernel RPM install), firewall disable, NVMe-TCP kernel modules, Java 8 detection, `/flash23` mount/setup (interactive confirm), NVMe-TCP network interface, IOMMU passthrough warning (grub changes are **never** applied automatically), optional `setup_nvmet.py` run, and an idempotent `ip_format = "ipv4"` force-fix patch.
- Cache/tmp cleanup (`tune_spark_post_run`) runs **after** every run, not before.

### video_transcode_bench
- **Known issue — dataset unzip zipbomb false-positive:** the El Fuente dataset trips `unzip`'s zipbomb-ratio heuristic. `VideoWrapper.prepare_dataset()` unzips with `UNZIP_DISABLE_ZIPBOMB_DETECTION=TRUE` and skips if already extracted.
- `--metric perf` is now wired to `modules.perf_collector` (previously accepted but silently did nothing).

### OS Tuning Applied Per Workload

| Setting | TaoBench | FeedSim | Spark | Video | Django |
|---|---|---|---|---|---|
| tcp_tw_reuse = 1 | v | v | | | v |
| THP = madvise | | v | | v | v |
| drop_caches = 3 | v | v | post | v | v |
| compact_memory = 1 | | v | post | v | v |
| ulimit -n | 1000000 | 655350 | | 655350 | 655350 |
| netdev_max_backlog = 524288 | v | | | | |
| somaxconn = 524288 | v | | | | |
| tcp_max_syn_backlog = 524288 | v | | | | |
| ip_local_port_range 1024 65535 | v | | | | |
| rmem_max/wmem_max = 134MB | v | | | | |
| tcp_syncookies = 0 | v | | | | |
| tcp_abort_on_overflow = 1 | v | | | | |
| nmi_watchdog = 0 | v | | | | |
| rm -rf /tmp/* | | | post | | |

*"post" means applied after the run, not before.*

## 8. EMON / Telemetry

- Enable with `--emon`/`-e` or `--metric emon` on any wrapper, or `--emon` on `dcperf_master_setup.py --run-only --all`.
- Event file is platform-specific — set `emon_event_file` in `config/setup_config.yaml` to the correct `<sep_path>/config/edp/<platform>_server_events*.txt`.
- Raw output goes to `results/<workload>_<timestamp>/emon/emon.dat`; processed EDP summaries go to `emon/emon_summary/` via `modules.emon_manager.process_emon()`.
- View selection: `--core-view/-cv`, `--uncore-view/-uv`, `--detailed-view/-dv` (socket view is always included).

## 9. Troubleshooting

| Error | Fix |
|---|---|
| `gengetopt: command not found` / FeedSim build fails | Handled automatically by `pre_install_patch()`; if all 3 mirrors fail, manually download `gengetopt-2.23.tar.xz` and place it in the FeedSim build downloads directory |
| `HH\invariant_violation` in `SystemChecks::CheckCPUFreq()` | Handled automatically by `apply_mediawiki_patches()`; verify `oss-performance/base/SystemChecks.php` contains the disabled marker if it recurs |
| TaoBench folly build fails on zlib download | Handled automatically by `pre_install_check()`; verify network access to `zlib.net` if it still fails |
| Video dataset `unzip` reports "zip bomb" and aborts | Handled automatically by `prepare_dataset()`; if still failing, unzip manually with `UNZIP_DISABLE_ZIPBOMB_DETECTION=TRUE unzip cuts.zip` |
| Spark run fails with NVMe-TCP errors | Run `python dcperf_master_setup.py --workload spark_standalone --dry-run` first to see the full prerequisite check output; `nvmet`/`nvmet-tcp`/`nvmet-rdma` modules must be loaded |
| `OS tuning requires sudo` FAIL in preflight | Run `sudo python dcperf_master_setup.py ...` or add your user to sudoers for passwordless `sudo -n` |
| `config_manager.require()` keeps prompting | The saved value didn't persist — check that `config/setup_config.yaml` is writable |
| `dcperf_root` not auto-detected | Set it explicitly in `config/setup_config.yaml`; auto-detect only walks up looking for `benchpress/config/benchmarks.yml` |

## 10. WLC / Orchestrator Integration

**Gate A — CLI:** every wrapper accepts `--experiment` and `--orch-run-id` (both optional, default `""`), and `--dry-run`/`-dr` returns the same shape as a real run.

**Gate B — results.json:** always written when the run directory exists, on both success and failure paths.
```json
{
  "version": 2,
  "orch_run_id": "",
  "rows": [
    {"system": {"...": "..."}, "params": {}, "kpis": {"qps": 1234.5}, "status": "PASS"}
  ]
}
```

**Gate C — Console:** `Output Directory: <absolute-path>` is printed exactly once per run, on both success and failure.

## 11. Adding a New Workload

1. Add the job name/benchmark name to `config/workload_manifest.json`.
2. Create `wrappers/<name>_wrapper.py` inheriting `BaseWrapper` (use `wrappers/base_wrapper.py` and `wrappers/tao_bench_wrapper.py` as templates).
3. Implement the 5 abstract methods: `get_job_name()`, `get_workload_name()`, `parse_output()`, `get_kpis()`, `get_csv_schema()`.
4. Override `pre_install_hook()`/`pre_run()`/`post_run()` only if the workload needs install patches, prerequisite checks, dataset prep, or post-run cleanup.
5. Register the new class in `WORKLOAD_REGISTRY` in `dcperf_master_setup.py` — this is the single place that needs a new line.
6. Add any new required config keys to both `config/setup_config.yaml` and `config/setup_config.yaml.example`.
