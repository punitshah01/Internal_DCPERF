#!/usr/bin/env python3
"""
Spark Benchmark Performance Testing Script
Converted from sweep.sh to Python
"""

import os
import sys
import subprocess
import argparse
import time
import datetime
from pathlib import Path


class SparkBenchmarkTester:
    """Spark benchmark performance testing with EMON metrics collection"""

    def __init__(self):
        self.dcperf_dir = Path.home() / "DCPerf"
        self.spark_work_dir = self.dcperf_dir / "benchmarks/spark_standalone/work"
        self.release_log_file = self.spark_work_dir / "release_test_93586.log"
        self.benchpress_log = self.dcperf_dir / "benchpress.log"
        self.result_file = self.spark_work_dir / "results.txt"
        self.runner_script = (
            self.dcperf_dir / "packages/spark_standalone/templates/runner.py"
        )
        self.ramp_string = "TaskSchedulerImpl: Adding task set 2.0 with 200 tasks"
        self.original_dir = os.getcwd()
        
    def tune_os(self):
        """Apply OS tuning for Spark workload"""
        tuning_commands = [
            "rm -rf /tmp/*",
            "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches",
            "sync; echo 1 | sudo tee /proc/sys/vm/compact_memory",
        ]
        
        print("Applying OS tuning for Spark...")
        for cmd in tuning_commands:
            try:
                subprocess.run(cmd, shell=True, check=False)
            except Exception as e:
                print(f"Warning: OS tuning command failed: {e}")
        
    def cleanup_tmp(self):
        """Clean /tmp directory"""
        try:
            subprocess.run("rm -rf /tmp/*", shell=True, check=False)
            print("Cleaned /tmp/")
        except Exception as e:
            print(f"Warning: Could not clean /tmp: {e}")

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
            subprocess.run("sync; echo 1 | sudo tee /proc/sys/vm/compact_memory",
                         shell=True, check=False)
        except Exception as e:
            print(f"Warning: Could not compact memory: {e}")

    def verify_paths(self):
        """Verify that required paths exist"""
        required_paths = [
            self.dcperf_dir,
            self.spark_work_dir,
            self.runner_script,
        ]
        
        for path in required_paths:
            if not path.exists():
                print(f"Warning: Path does not exist: {path}")
                return False
        return True

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

    def run_test(
        self,
        name,
        run_type,
        use_emon,
        emon_user="pshah",
    ):
        """Run Spark benchmark performance test"""
        
        now = datetime.datetime.now()
        logs_dir = f"{name}_{now.strftime('%m%d%Y%H%M%S')}"
        
        if run_type == "run":
            os.makedirs(logs_dir, exist_ok=True)

        logs_file = os.path.join(logs_dir, f"spark_{name}.txt")

        # Build the runner command with required parameters
        cmd = (
            f"{self.runner_script} run "
            f"--dataset-path /flash23/ "
            f"--warehouse-dir /flash23/warehouse "
            f"--shuffle-dir /flash23/spark_local_dir "
            f"--real"
        )

        data_cmd = cmd

        if use_emon == "1":
            data_cmd = (
                f"tmc -c \"{cmd}\" -d {logs_dir} -D {logs_dir} "
                f"-rl {self.release_log_file} -rs \"{self.ramp_string}\" "
                f"-n -u -w socket,core "
                f"-e \"/opt/intel/sep/config/edp/graniterapids_server_events_private.txt\" "
                f"-G spark_ -T emon,iostat -x {emon_user} -a {logs_dir}"
            )

        print(f"Command: {data_cmd}")

        if run_type == "run":
            self.cleanup_tmp()
            self.drop_caches()
            self.compact_memory()

            # Run the command with tee to capture output
            try:
                result = subprocess.run(
                    f"{data_cmd} 2>&1 | tee {logs_file}",
                    shell=True,
                    capture_output=False
                )
            except Exception as e:
                print(f"Error running benchmark: {e}")
                return False

            # Copy log files to results directory
            try:
                if self.release_log_file.exists():
                    subprocess.run(
                        f"mv {self.release_log_file} {logs_dir}",
                        shell=True,
                        check=False
                    )
                if self.benchpress_log.exists():
                    subprocess.run(
                        f"cp {self.benchpress_log} {logs_dir}",
                        shell=True,
                        check=False
                    )
                if self.result_file.exists():
                    subprocess.run(
                        f"mv {self.result_file} {logs_dir}",
                        shell=True,
                        check=False
                    )
            except Exception as e:
                print(f"Warning: Could not copy result files: {e}")

            time.sleep(21)
            return True

        return True

    def run_core_scaling_study(
        self,
        name,
        total_cores,
        cores_per_iteration,
        use_emon,
        emon_user="pshah",
    ):
        """Run a core scaling study with progressive core enabling"""
        
        print(f"Starting core scaling study: 0 to {total_cores} cores "
              f"in steps of {cores_per_iteration}")

        # Rebuild EMON driver at start
        if use_emon == "1":
            print("Building EMON driver with initial topology...")
            if not self.rebuild_emon_driver():
                print("Warning: EMON driver build failed, continuing anyway")

        current_core = cores_per_iteration
        while current_core <= total_cores:
            print(f"\n{'='*60}")
            print(f"Testing with {current_core} cores")
            print(f"{'='*60}\n")

            self.tune_os()

            test_name = f"{name}_Scale_{current_core}cores"
            
            success = self.run_test(
                name=test_name,
                run_type="run",
                use_emon=use_emon,
                emon_user=emon_user,
            )

            if not success:
                print(f"Warning: Test failed at {current_core} cores")
                return False

            # Enable next set of cores
            if current_core < total_cores:
                next_core = min(current_core + cores_per_iteration, total_cores)
                print(f"\nEnabling cores from {current_core} to {next_core - 1}")
                for core_id in range(current_core, next_core):
                    self.enable_core(core_id)
                    time.sleep(0.5)
                
                # Rebuild EMON driver after topology change if using EMON
                if use_emon == "1":
                    self.rebuild_emon_driver()
                
                print("Waiting 15 seconds before next iteration...")
                time.sleep(15)

            current_core += cores_per_iteration

        self.cleanup_tmp()
        self.drop_caches()
        print("\nCore scaling study completed!")
        return True


def main():
    parser = argparse.ArgumentParser(
        description="Spark Benchmark Performance Testing Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 sweep.py --name "Spark_Test" --emon 1
  python3 sweep.py --name "Spark_Test" --emon 0
  python3 sweep.py --name "Spark_Baseline" --dry-run
  python3 sweep.py --name "Spark_Optimized" --emon 1 --emon-user myuser
  python3 sweep.py --name "Spark_Scale" --core-scaling --cores-per-iteration 32
        """,
    )

    parser.add_argument(
        "--name", "-n", required=True, help="Test name/identifier"
    )
    parser.add_argument(
        "--emon",
        choices=["0", "1"],
        default="1",
        help="Enable EMON collection (default: 1)"
    )
    parser.add_argument(
        "--emon-user",
        default="pshah",
        help="EMON user/owner for TMC (default: pshah)"
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
        "--dry-run", action="store_true", help="Show commands without executing"
    )

    args = parser.parse_args()

    tester = SparkBenchmarkTester()

    # Verify paths
    if not tester.verify_paths():
        print("Error: Required paths do not exist. Check DCPerf installation.")
        if not args.dry_run:
            sys.exit(1)

    if args.dry_run:
        print("DRY RUN MODE - Commands will be shown but not executed\n")
        if args.core_scaling:
            print(f"Would run Spark core scaling test:")
            print(f"  Name: {args.name}")
            print(f"  EMON Enabled: {args.emon}")
            print(f"  EMON User: {args.emon_user}")
            print(f"  Total cores: {args.total_cores}")
            print(f"  Cores per iteration: {args.cores_per_iteration}")
        else:
            print(f"Would run Spark benchmark:")
            print(f"  Name: {args.name}")
            print(f"  EMON Enabled: {args.emon}")
            print(f"  EMON User: {args.emon_user}")
        print(f"  DCPerf Dir: {tester.dcperf_dir}")
        print(f"  Spark Work Dir: {tester.spark_work_dir}")
    else:
        if args.core_scaling:
            success = tester.run_core_scaling_study(
                name=args.name,
                total_cores=args.total_cores,
                cores_per_iteration=args.cores_per_iteration,
                use_emon=args.emon,
                emon_user=args.emon_user,
            )
        else:
            success = tester.run_test(
                name=args.name,
                run_type="run",
                use_emon=args.emon,
                emon_user=args.emon_user,
            )
        if success:
            print("\nTest completed!")
        else:
            print("\nTest failed!")
            sys.exit(1)


if __name__ == "__main__":
    main()
