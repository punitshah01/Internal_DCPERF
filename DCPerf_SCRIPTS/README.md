# DCPerf_SCRIPTS

## 1. Overview

DCPerf_SCRIPTS orchestrates Facebook's [DCPerf](https://github.com/facebookresearch/DCPerf) benchmark suite (django_workload, feedsim, mediawiki, spark_standalone, tao_bench, video_transcode_bench, wdl_bench, health_check) with EMON/perf telemetry, OS tuning, core-scaling sweeps, and structured result capture layered on top of it. It does not replace DCPerf's own `benchpress_cli.py install/run` — every wrapper here calls that CLI under the hood and adds pre-flight checks, known-issue fixes, and machine-readable result artifacts around it. Wrapper structure (`BaseWrapper` execution flow, `results.json` schema, `Output Directory:` marker, `--experiment`/`--orch-run-id` flags) follows Intel PNPWLS conventions so these workloads can be registered with the same WLC orchestrator used for other PNPWLS runners.

Entry point: `dcperf_run.py`. Legacy pre-refactor scripts (`dj_perf.py`, `fs_perf.py`, `mw_perf.py`, `sweep.py`, `vt_script.py`) live under `legacy/` for reference only and are not used by the current automation.

## 2. Prerequisites

**System requirements**
- OS: CentOS Stream 8/9 or Ubuntu 22.04
- Python: 3.8 or higher
- sudo access required (OS tuning, EMON driver load/unload, package installs)
- Please set `ulimit -n` to at least 65536 (permanent: edit `/etc/security/limits.conf`)

**Per-OS prerequisite install commands** (run automatically by `dcperf_run.py` before any `--install-only`/`--all` run, via `install_os_prerequisites()`; can also be run manually):

CentOS Stream 8:
```bash
dnf install -y python38 python38-pip git
alternatives --set python3 /usr/bin/python3.8
pip-3.8 install click pyyaml tabulate pandas
dnf install -y epel-release
dnf install -y 'dnf-command(config-manager)'
dnf config-manager --set-enabled PowerTools
# Optional GCC 11 for newer folly:
dnf install -y gcc-toolset-11
scl enable gcc-toolset-11 bash
```

CentOS Stream 9:
```bash
dnf install -y epel-release
dnf install -y 'dnf-command(config-manager)'
dnf config-manager --set-enabled crb
dnf install -y git python3-click python3-pyyaml python3-tabulate python3-pip xz-devel
pip-3.9 install pandas
```

Ubuntu 22.04:
```bash
sudo apt update
sudo apt install -y python3-pip git
sudo pip3 install click pyyaml tabulate pandas
```

**MediaWiki-specific extras (CentOS 9 shown; automated by `DcperfMediaWikiWrapper.pre_install_hook()`):**
```bash
dnf install -y git python3-click python3-pyyaml python3-tabulate python3-pip
pip-3.9 install pandas
dnf install -y epel-release
dnf install -y 'dnf-command(config-manager)'
dnf config-manager --set-enabled crb
```
- SELinux must be disabled (`/etc/selinux/config` -> `SELINUX=disabled`). **A reboot is required** after this change before running MediaWiki — the automation warns but does not reboot for you.
- `/etc/security/limits.conf` needs `root hard/soft nofile 10485760`.
- **Remove Docker/Podman if installed** — HHVM's bundled dependencies conflict with container runtimes on the same host. This is not automated; check manually with `rpm -q docker podman` / `dpkg -l | grep -E 'docker|podman'` before running MediaWiki.
- HHVM 3.30 is downloaded from the Intel Artifactory workload repository and installed via `pour-hhvm.sh` automatically. Set `workload_artifact_base_url` to override the repository.
- `nginx-1.22.tar.gz` is downloaded from the same Artifactory repository and copied to `/usr/local`; set `nginx_1_22_tarball_path` to use a local copy instead.

**EMON/SEP (optional, for telemetry):**
- Install Intel VTune or SEP separately (not distributed with this repo).
- Default expected path: `/opt/intel/sep`
- Override in `config/dcperf_config.yaml`: `sep_path`
- PNPWLS provides the supported setup flow in `C:/repos/pnpwls/setup/setup_emon.sh`. Copy that script/repository to the SUT, set `emon_setup_script` if you want to track its location, and run it before enabling `--emon`. It installs SEP/pyedp and the telemetry client (`tmc`). After SEP is installed, ConfigManager automatically selects a platform-matching `*server*events*.txt` file from `/opt/intel/sep/config/edp`, falling back to the first private/server event file.

**Workload-specific prerequisites:**

| Workload | Prerequisites |
|---|---|
| FeedSim | cmake, gcc, g++ (installed by workload installer); gengetopt-2.23 fetched by `pre_install_patch()` with mirror fallback |
| MediaWiki | HHVM 3.30 and nginx-1.22 downloaded from Intel Artifactory (or local overrides), SELinux disabled (reboot required), nofile limits — see above |
| Spark | Java 8 required; NVMe-TCP kernel modules required; custom kernel recommended (see Section 7); minimum 500GB NVMe storage |
| TaoBench | `binutils-devel`, updated `ca-certificates` (installed automatically by `pre_install_check()`) |
| Video | `cuts.tar.gz` is downloaded automatically from Intel Artifactory into the DCPerf video dataset directory and extracted; override `video_dataset_url` or `video_dataset_path` if needed |

## 3. Installation

```bash
# 1. Clone the repo
git clone <your-repo-url>
cd DCPerf

# 2. Configure
cp DCPerf_SCRIPTS/config/dcperf_config.yaml.example DCPerf_SCRIPTS/config/dcperf_config.yaml
vim DCPerf_SCRIPTS/config/dcperf_config.yaml   # fill in null values you need

# 3. Install all workloads
cd DCPerf_SCRIPTS
python dcperf_run.py --install-only --all

# 4. Install one workload
python dcperf_run.py --install-only --workload tao_bench
```

## 4. Running

```bash
# Run everything
python dcperf_run.py --run-only --all

# Run with EMON telemetry
python dcperf_run.py --run-only --all --emon

# Run one workload
python dcperf_run.py --run-only --workload django_workload

# Dry run (no execution, shows commands)
python dcperf_run.py --dry-run --all --emon

# Resume after failure
python dcperf_run.py --run-only --all --resume

# Force reinstall a workload
python dcperf_run.py --install-only --workload tao_bench --force

# Full install + run
python dcperf_run.py --all --emon
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
| `nvme_tcp_n` / `nvme_tcp_s` | No | `3` / `6` | Documentation aliases matching the README naming |
| `nginx_1_22_tarball_path` | No | `null` | Local nginx-1.22.tar.gz for MediaWiki |
| `django_default_iterations` | No | `3` | Default django_workload `--iterations` |
| `tao_bench_mode` | No | `standalone` | Default tao_bench `--mode` |
| `java_path` | No | `null` | Auto-populated Java 8 path |
| `clear_tmp` | No | `false` | Allow `clear_tmp()` to run `rm -rf /tmp/*` |
| `results_base_dir` | No | `DCPerf_SCRIPTS/results` | Base output directory |

\* Required only for that workload.

## 6. Result Directory Layout

```
results/
└── <workload>_<YYYYMMDD_HHMMSS>/
    ├── stdout.log             # raw benchpress stdout
    ├── stderr.log             # raw benchpress stderr
    ├── metrics.json           # final KPI dict (+ os_tuning / cpu_utilization / spark_prerequisites when applicable)
    ├── results.csv            # smart-append CSV, one row per run
    ├── results.json           # {version, orch_run_id, rows[]} — WLC contract source of truth
    ├── system_metadata.json   # hostname/cpu/cores/kernel/os snapshot
    ├── command.txt            # exact argv that ran
    ├── benchmark_metrics/     # benchpress's own benchmark_metrics_<run_id>/ output, preserved
    ├── tao_bench_server_metrics/  # tao_bench only: per-server QPS CSVs + logs
    └── emon/
        ├── emon.dat           # raw EMON data (if --emon/--metric emon)
        └── emon_summary/      # EDP-processed output (dcperf_emon_manager.process_emon)
```

A `summary_<timestamp>/run_summary.json` + `run_summary.txt` is written once per `dcperf_run.py` invocation, aggregating every workload run in that session.

## 7. Workload-Specific Notes

### django_workload
- Default iterations: 7 (upstream DCPerf default)
- Recommended for quick validation: 1 iteration (~5 min)
- Recommended for full benchmark: 3 iterations
- CLI: `--iterations 1|3|7`
  - `--iterations 1` ~= 5 minutes (quick validation)
  - `--iterations 3` ~= 15 minutes (standard, default)
  - `--iterations 7` ~= 35 minutes (full upstream default)
  - Valid values are 1, 3, 7; other values are allowed but log a warning.
- Or set in `config/dcperf_config.yaml`: `django_default_iterations: 3`

### feedsim
- **Known issue — gengetopt download fails:** the upstream installer's single gengetopt-2.23 download URL is frequently unreachable. `pre_install_patch()` patches `packages/feedsim/install_feedsim.sh` with a 3-mirror fallback chain (`ftpmirror.gnu.org` -> `ftp.gnu.org` -> `ftp.gnu.org --no-check-certificate`) before install runs, and is idempotent (checks for a patch marker first).

### mediawiki
- **Known issue — CPU frequency check crash:** oss-performance crashes with `SystemChecks::CheckCPUFreq() -> HH\invariant_violation` on server CPUs. `apply_mediawiki_patches()` comments out `self::CheckCPUFreq();` in `<dcperf_root>/oss-performance/base/SystemChecks.php` before every run (idempotent — checks for the disabled marker first).
- Core-scaling instance count is derived from `get_online_cores()`, not `nproc`.

### tao_bench
- **Standalone vs autoscale:** `--mode standalone` (default) runs the single-machine `tao_bench_standalone` job and is the **only mode validated** with this automation. `--mode autoscale` runs the multi-instance/multi-machine `tao_bench_autoscale` job — experimental, logs a warning when selected, and requires the operator to copy the client commands autoscale prints to `benchpress.log` onto separate client machines.
- **Expected hit ratio range:** 0.88–0.90. Outside this range usually means `--memsize` needs adjusting; logged as a warning.
- **Expected data points formula:** `58 * spawned_instances` (e.g. 6 servers ⇒ ~348 data points). Fewer than 90% of that logs a warning that the run may be incomplete.
- **CPU utilization target:** 70–80% overall, 15–20% user (checked over the last 5–10 minutes).
- **Server CSV files:** per-instance time-series QPS CSVs (`server_N.csv`) and logs (`tao-bench-server-*.log`) are copied from benchpress's `benchmark_metrics_<run_id>/` into `results/<run>/tao_bench_server_metrics/`.
- **Known issue — missing system packages:** `binutils-devel` and an updated `ca-certificates`/`update-ca-trust` are required before install. `pre_install_check()` installs these automatically.
- **Known issue — zlib download for folly build:** if `<dcperf_root>/benchmarks/tao_bench/build-folly/downloads/zlib-zlib-1.3.1.tar.gz` is missing or zero-byte, it's fetched from the zlib fossils mirror automatically.
- **Direct run command** (bypassing the master entry point):
  ```bash
  python wrappers/dcperf_tao_bench_wrapper.py --mode standalone --test-time 300
  ```

### spark_standalone
- Full prerequisite sequence (`verify_spark_prerequisites()`, called before install and before every run): kernel version check (+ optional custom kernel RPM install), firewall disable, NVMe-TCP kernel modules, Java 8 detection, `/flash23` mount/setup (interactive confirm), NVMe-TCP network interface, IOMMU passthrough warning (grub changes are **never** applied automatically), optional `setup_nvmet.py` run, and an idempotent `ip_format = "ipv4"` force-fix patch.
- Cache/tmp cleanup (`tune_spark_post_run`) runs **after** every run, not before.

### video_transcode_bench
- **Known issue — dataset unzip zipbomb false-positive:** the El Fuente dataset trips `unzip`'s zipbomb-ratio heuristic. `prepare_dataset()` unzips with `UNZIP_DISABLE_ZIPBOMB_DETECTION=TRUE`, validates `cuts.zip` exists and is non-empty, skips if already extracted, and verifies at least one `.y4m` file exists afterward.
- `--metric perf` is now wired to `dcperf_perf_collector` (previously accepted but silently did nothing).

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
| tcp_rmem/tcp_wmem = "4096 87380 134217728" | v | | | | |
| tcp_syncookies = 0 | v | | | | |
| tcp_abort_on_overflow = 1 | v | | | | |
| nmi_watchdog = 0 | v | | | | |
| rm -rf /tmp/* | | | post | | |

*"post" means applied after the run, not before.*

## 8. EMON / Telemetry

- Enable with `--emon`/`-e` or `--metric emon` on any wrapper, or `--emon` on `dcperf_run.py --run-only --all`.
- Event file is platform-specific — set `emon_event_file` in `config/dcperf_config.yaml` to the correct `<sep_path>/config/edp/<platform>_server_events*.txt`.
- Raw output goes to `results/<workload>_<timestamp>/emon/emon.dat`; processed EDP summaries go to `emon/emon_summary/` via `dcperf_emon_manager.process_emon()`.
- View selection: `--core-view/-cv`, `--uncore-view/-uv`, `--detailed-view/-dv` (socket view is always included).

## 9. Troubleshooting

| Error | Fix |
|---|---|
| `gengetopt: command not found` / FeedSim build fails | Handled automatically by `pre_install_patch()`; if all 3 mirrors fail, manually download `gengetopt-2.23.tar.xz` and place it in the FeedSim build downloads directory |
| `HH\invariant_violation` in `SystemChecks::CheckCPUFreq()` | Handled automatically by `apply_mediawiki_patches()`; verify `oss-performance/base/SystemChecks.php` contains the disabled marker if it recurs |
| TaoBench folly build fails on zlib download | Handled automatically by `pre_install_check()`; verify network access to `zlib.net` if it still fails |
| Video dataset `unzip` reports "zip bomb" and aborts | Handled automatically by `prepare_dataset()`; if still failing, unzip manually with `UNZIP_DISABLE_ZIPBOMB_DETECTION=TRUE unzip cuts.zip` |
| Spark run fails with NVMe-TCP errors | Run `python dcperf_run.py --workload spark_standalone --dry-run` first to see the full prerequisite check output; `nvmet`/`nvmet-tcp`/`nvmet-rdma` modules must be loaded |
| `OS tuning requires sudo` FAIL in preflight | Run `sudo python dcperf_run.py ...` or add your user to sudoers for passwordless `sudo -n` |
| `ConfigManager.require()` keeps prompting | The saved value didn't persist — check that `config/dcperf_config.yaml` is writable |
| `dcperf_root` not auto-detected | Set it explicitly in `config/dcperf_config.yaml`; auto-detect only walks up looking for `benchpress/config/benchmarks.yml` |
| TaoBench hit ratio outside 0.88–0.90 | Adjust `--memsize`; logged as a warning by `dcperf_tao_bench_wrapper.py` |

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

1. Add the job name/benchmark name to `config/dcperf_workload_manifest.json`.
2. Create `wrappers/dcperf_<name>_wrapper.py` inheriting `BaseWrapper` (use `wrappers/dcperf_base_wrapper.py` and `wrappers/dcperf_tao_bench_wrapper.py` as templates).
3. Implement the 5 abstract methods: `get_job_name()`, `get_workload_name()`, `parse_output()`, `get_kpis()`, `get_csv_schema()`.
4. Override `pre_install_hook()`/`pre_run()`/`post_run()` only if the workload needs install patches, prerequisite checks, dataset prep, or post-run cleanup.
5. Register the new class in `WORKLOAD_REGISTRY` in `dcperf_run.py` — this is the single place that needs a new line.
6. Add any new required config keys to both `config/dcperf_config.yaml` and `config/dcperf_config.yaml.example`.

## 12. DCPerf Score

After all 5 core benchmarks (mediawiki, django, feedsim, sparkbench, taobench) have run, `dcperf_run.py` automatically calls `./benchpress_cli.py report score --all` and appends the parsed scores to `run_summary.txt`, matching the official DCPerf format:

```
==================================================================
DCPerf Benchmark Scores
==================================================================
mediawiki     : 4.741
django        : 4.871
feedsim       : 5.842
sparkbench    : 3.361
taobench      : 4.041
------------------------------------------------------------------
DCPerf Overall Score : 4.494
==================================================================
```

- **Video Transcode is not included** in the overall DCPerf score (per official DCPerf scoring methodology).
- **WDLBench has separate usage** (its own `benchmarks_wdl.yml`/`jobs_wdl.yml` registry) — see [Section 14](#14-wdlbench-special-usage).
- If fewer than the 5 scored benchmarks ran, or `report score` fails, the summary prints: `DCPerf Score: Not available (run all 5 benchmarks for overall score)`.

## 13. CPU Utilization Targets

`CpuMonitor` (`modules/dcperf_cpu_monitor.py`) samples `/proc/stat` in the background during every workload run and compares the average against the official DCPerf README's expected ranges:

| Benchmark | Target CPU% | Window |
|--------------|------------------|-----------------|
| TaoBench | 70-80% overall | Last 5-10 min |
| | 15-20% user | |
| FeedSim | 60-75% | Last 5 min |
| Django | ~95% | Entire run |
| MediaWiki | 90-100% | Last 10 min |
| Spark | 55-75% overall | Entire run |
| | 90-100% stage2 | Stage 2.0 only |
| Video | 85-100% | Encoding only |

Note: If CPU utilization is outside the target range, the automation logs a warning and records it in `metrics.json` under `cpu_utilization` (`within_target`, `warning`, `avg_overall_pct`, `avg_user_pct`, `min_overall_pct`, `max_overall_pct`).

## 14. WDLBench Special Usage

WDLBench uses a separate benchmark registry file (`benchmarks_wdl.yml`/`jobs_wdl.yml`), not the default `benchmarks.yml`/`jobs.yml`. Run with:

```bash
python dcperf_run.py --workload wdl_bench
```

`get_benchpress_global_args()` in `dcperf_wdl_bench_wrapper.py` automatically adds `-b benchmarks_wdl.yml -j jobs_wdl.yml` to every benchpress invocation for this workload. See `packages/wdl_bench/README.md` for details.

## 15. Benchpress System Check

Before running benchmarks, `dcperf_run.py`'s preflight check automatically runs `./benchpress_cli.py system_check` (in addition to, not instead of, its own tool-availability checks). To run manually:

```bash
cd <dcperf_root>
./benchpress_cli.py system_check
```

This checks SELinux status, THP, open file limits, NUMA nodes, CPU Turbo Boost, memory speed, base frequency, hyperthreading/SMT, and the `nvme-tcp` kernel module — alongside BIOS/NIC/BMC firmware versions.

## 16. Getting DCPerf Score Manually

```bash
cd <dcperf_root>
./benchpress_cli.py report score
./benchpress_cli.py report score --all
```

