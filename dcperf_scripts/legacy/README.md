# Legacy Scripts

> ⚠️ **Do not use these scripts for new work.**

These scripts are the pre-refactor automation layer kept for historical
reference only. They have been superseded by the wrapper-based architecture
in `dcperf_scripts/wrappers/`.

## Files

| File | Original Purpose | Superseded By |
|------|-----------------|---------------|
| dj_perf.py | Django workload runner | dcperf_django_wrapper.py |
| fs_perf.py | Feedsim workload runner | dcperf_feedsim_wrapper.py |
| mw_perf.py | MediaWiki workload runner | dcperf_mediawiki_wrapper.py |
| sweep.py | Core scaling sweep | dcperf_core_scaler.py |
| vt_script.py | Video transcode runner | dcperf_video_transcode_wrapper.py |

## Why They Are Kept

- Audit trail for design decisions made during the original implementation
- Reference for edge cases not yet covered by the new wrappers

## Do Not

- Import from these files
- Run these files directly
- Copy logic from these files without first checking if it already exists in the new wrapper or module layer
