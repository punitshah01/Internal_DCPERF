#!/usr/bin/env python3
"""
Video Transcoding Performance Testing Script
Converted from vt_script.sh to Python
"""

import os
import sys
import subprocess
import argparse
import time
import datetime
from pathlib import Path


class VideoTranscodePerformanceTester:
    """Video transcoding performance testing with EMON/perf metrics collection"""

    def __init__(self):
        self.script_dir = Path(__file__).parent
        self.original_dir = os.getcwd()
        self.ramp_file = "/tmp/ffmpeg_log.txt"
        self.ramp_string_start = "start"
        self.result_file = "benchmarks/video_transcode_bench/video_transcode_bench_results.txt"
        self.cmd_file = "benchmarks/video_transcode_bench/generate_commands_all_parameters.txt"
        
    def tune_os(self):
        """Apply OS tuning for video transcoding workload"""
        tuning_commands = [
            "echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled",
            "echo 3 | sudo tee /proc/sys/vm/drop_caches",
            "echo 1 | sudo tee /proc/sys/vm/compact_memory",
            "ulimit -n 655350",
        ]
        
        print("Applying OS tuning for Video Transcoding...")
        for cmd in tuning_commands:
            try:
                subprocess.run(cmd, shell=True, check=False)
            except Exception as e:
                print(f"Warning: OS tuning command failed: {e}")
        
    def set_transparent_hugepages(self, setting="madvise"):
        """Set transparent hugepages mode"""
        try:
            subprocess.run(
                f"echo {setting} | sudo tee /sys/kernel/mm/transparent_hugepage/enabled",
                shell=True, check=False
            )
        except Exception as e:
            print(f"Warning: Could not set transparent hugepages: {e}")

    def drop_caches(self):
        """Clear system caches"""
        try:
            subprocess.run("echo 3 | sudo tee /proc/sys/vm/drop_caches",
                         shell=True, check=False)
            print("Dropped system caches")
        except Exception as e:
            print(f"Warning: Could not drop caches: {e}")

    def compact_memory(self):
        """Compact kernel memory"""
        try:
            subprocess.run("echo 1 | sudo tee /proc/sys/vm/compact_memory",
                         shell=True, check=False)
        except Exception as e:
            print(f"Warning: Could not compact memory: {e}")

    def increase_file_limits(self):
        """Increase file descriptor limits"""
        try:
            subprocess.run("ulimit -n 655350", shell=True, check=False)
        except Exception as e:
            print(f"Warning: Could not increase file limits: {e}")

    def enable_core(self, core_id):
        """Enable a specific CPU core"""
        online_file = Path(f"/sys/devices/system/cpu/cpu{core_id}/online")
        if online_file.exists():
            try:
                subprocess.run(
                    f"echo 1 | sudo tee {online_file}",
                    shell=True,
                    check=False,
                )
                print(f"Enabled core {core_id}")
            except Exception as e:
                print(f"Warning: Could not enable core {core_id}: {e}")

    def disable_core(self, core_id):
        """Disable a specific CPU core"""
        if core_id == 0:
            print(f"Skipping core 0 (cannot disable init core)")
            return
        online_file = Path(f"/sys/devices/system/cpu/cpu{core_id}/online")
        if online_file.exists():
            try:
                subprocess.run(
                    f"echo 0 | sudo tee {online_file}",
                    shell=True,
                    check=False,
                )
                print(f"Disabled core {core_id}")
            except Exception as e:
                print(f"Warning: Could not disable core {core_id}: {e}")

    def rebuild_emon_driver(self):
        """Rebuild EMON driver for topology changes"""
        try:
            sep_path = Path("/opt/intel/sep")
            if not sep_path.exists():
                print("Warning: EMON (SEP) not installed at /opt/intel/sep")
                return False
            
            # Unload and reload EMON driver
            print("Rebuilding EMON driver...")
            subprocess.run("sudo rmmod sep", shell=True, check=False)
            subprocess.run(
                "sudo insmod /opt/intel/sep/sep.ko",
                shell=True,
                check=False
            )
            print("EMON driver rebuilt successfully")
            return True
        except Exception as e:
            print(f"Warning: Could not rebuild EMON driver: {e}")
            return False

    def cleanup_ramp_file(self):
        """Remove ramp file if it exists"""
        try:
            if os.path.exists(self.ramp_file):
                os.remove(self.ramp_file)
        except Exception as e:
            print(f"Warning: Could not remove ramp file: {e}")

    def run_test(
        self,
        name,
        run_type,
        metric,
        num_runs,
        encoder,
        runtime,
        emon_user="pshah",
    ):
        """Run video transcoding performance test"""
        
        session_name = f"transcode_logs_{name}_{encoder}_{runtime}"
        if metric == "emon":
            session_name = f"{session_name}_WEMON"
        elif metric == "perf":
            session_name = f"{session_name}_WPERF"

        self.cleanup_ramp_file()
        
        now = datetime.datetime.now()
        logs_root = f"{session_name}_{now.strftime('%m%d%Y%H%M%S')}"

        for i in range(1, num_runs + 1):
            logs_dir = os.path.join(logs_root, f"run{i}")
            if run_type == "run":
                os.makedirs(logs_dir, exist_ok=True)

            logs_file = os.path.join(logs_dir, f"vt_{name}_{encoder}_{runtime}_run{i}.txt")

            cmd = (
                f"./run.sh --encoder {encoder} --runtime {runtime} "
                f"--levels 0:0 --output video_transcode_bench_results.txt "
                f"2>&1 | tee {logs_file}"
            )

            data_cmd = cmd

            if metric == "emon":
                data_cmd = (
                    f"tmc -c \"{cmd}\" -rl {self.ramp_file} "
                    f"-rs \"{self.ramp_string_start}\" -lt 200 -rt 100 "
                    f"-n -u -x pshah -a {session_name}_RUN{i} "
                    f"-T emon,sar -v -w thread,socket,core -G videotranscode_"
                )

            print(f"Run {i}/{num_runs}: {data_cmd}")

            if run_type == "run":
                self.set_transparent_hugepages("madvise")
                self.drop_caches()
                self.compact_memory()
                self.increase_file_limits()

                result = subprocess.run(data_cmd, shell=True, capture_output=False)

                # Copy results to logs directory
                try:
                    if os.path.exists(self.result_file):
                        subprocess.run(
                            f"cp {self.result_file} {logs_dir}",
                            shell=True,
                            check=False
                        )
                    if os.path.exists(self.ramp_file):
                        subprocess.run(
                            f"cp {self.ramp_file} {logs_dir}",
                            shell=True,
                            check=False
                        )
                    if os.path.exists(self.cmd_file):
                        subprocess.run(
                            f"mv {self.cmd_file} {logs_dir}",
                            shell=True,
                            check=False
                        )
                except Exception as e:
                    print(f"Warning: Could not copy results: {e}")

                time.sleep(30)

    def run_core_scaling_study(
        self,
        name,
        total_cores,
        cores_per_iteration,
        metric,
        num_runs,
        encoder,
        runtime,
        emon_user="pshah",
    ):
        """Run a core scaling study with progressive core enabling"""
        
        print(f"Starting core scaling study: 0 to {total_cores} cores "
              f"in steps of {cores_per_iteration}")

        # Rebuild EMON driver at start
        if metric == "emon":
            print("Building EMON driver with initial topology...")
            if not self.rebuild_emon_driver():
                print("Warning: EMON driver build failed, continuing anyway")

        current_core = cores_per_iteration
        while current_core <= total_cores:
            print(f"\n{'='*60}")
            print(f"Testing with {current_core} cores")
            print(f"{'='*60}\n")

            self.drop_caches()
            self.tune_os()

            test_name = f"{name}_Scale_{current_core}cores"
            
            self.run_test(
                name=test_name,
                run_type="run",
                metric=metric,
                num_runs=num_runs,
                encoder=encoder,
                runtime=runtime,
                emon_user=emon_user,
            )

            # Enable next set of cores
            if current_core < total_cores:
                next_core = min(current_core + cores_per_iteration, total_cores)
                print(f"\nEnabling cores from {current_core} to {next_core - 1}")
                for core_id in range(current_core, next_core):
                    self.enable_core(core_id)
                    time.sleep(0.5)
                
                # Rebuild EMON driver after topology change if using EMON
                if metric == "emon":
                    self.rebuild_emon_driver()
                
                print("Waiting 15 seconds before next iteration...")
                time.sleep(15)

            current_core += cores_per_iteration

        self.drop_caches()
        print("\nCore scaling study completed!")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Video Transcoding Performance Testing Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 vt_script.py --name "VT_Test" --metric emon --encoder svt --runtime short
  python3 vt_script.py --name "VT_Test" --metric perf --encoder x264 --runtime medium --runs 3
  python3 vt_script.py --name "VT_Test" --encoder aom --runtime long --core-scaling
  python3 vt_script.py --name "VT_Test" --encoder svt --runtime short --dry-run
        """,
    )

    parser.add_argument(
        "--name", "-n", required=True, help="Test name/identifier"
    )
    parser.add_argument(
        "--metric", "-m",
        choices=["emon", "perf"],
        default="emon",
        help="Metric collection type (default: emon)",
    )
    parser.add_argument(
        "--runs", "-r", type=int, default=1, help="Number of runs (default: 1)"
    )
    parser.add_argument(
        "--encoder", "-e",
        choices=["svt", "x264", "aom"],
        required=True,
        help="Video encoder type"
    )
    parser.add_argument(
        "--runtime", "-t",
        choices=["short", "medium", "long"],
        required=True,
        help="Test runtime duration"
    )
    
    # Core scaling parameters
    parser.add_argument(
        "--core-scaling", action="store_true", help="Enable core scaling study mode"
    )
    parser.add_argument(
        "--total-cores", type=int, default=288, help="Total cores in system (default: 288)"
    )
    parser.add_argument(
        "--cores-per-iteration", type=int, default=16,
        help="Cores to enable per iteration (default: 16)",
    )
    parser.add_argument(
        "--emon-user",
        default="pshah",
        help="EMON user/owner for TMC (default: pshah)"
    )
    
    parser.add_argument(
        "--dry-run", action="store_true", help="Show commands without executing"
    )

    args = parser.parse_args()

    tester = VideoTranscodePerformanceTester()

    if args.dry_run:
        print("DRY RUN MODE - Commands will be shown but not executed\n")
        if args.core_scaling:
            print(f"Would run Video Transcoding core scaling test:")
            print(f"  Name: {args.name}")
            print(f"  Metric: {args.metric}")
            print(f"  EMON User: {args.emon_user}")
            print(f"  Total cores: {args.total_cores}")
            print(f"  Cores per iteration: {args.cores_per_iteration}")
            print(f"  Encoder: {args.encoder}")
            print(f"  Runtime: {args.runtime}")
        else:
            print(f"Would run Video Transcoding test:")
            print(f"  Name: {args.name}")
            print(f"  Metric: {args.metric}")
            print(f"  EMON User: {args.emon_user}")
            print(f"  Runs: {args.runs}")
            print(f"  Encoder: {args.encoder}")
            print(f"  Runtime: {args.runtime}")
    else:
        tester.tune_os()
        if args.core_scaling:
            tester.run_core_scaling_study(
                name=args.name,
                total_cores=args.total_cores,
                cores_per_iteration=args.cores_per_iteration,
                metric=args.metric,
                num_runs=args.runs,
                encoder=args.encoder,
                runtime=args.runtime,
                emon_user=args.emon_user,
            )
        else:
            tester.run_test(
                name=args.name,
                run_type="run",
                metric=args.metric,
                num_runs=args.runs,
                encoder=args.encoder,
                runtime=args.runtime,
                emon_user=args.emon_user,
            )

    print("\nTest completed!")
