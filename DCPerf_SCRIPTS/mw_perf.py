#!/usr/bin/env python3
"""
Combined MediaWiki Performance Testing and Core Scaling Script
Combines mw_perf.sh and mw_wrapper.sh functionality into a single Python script
"""

import os
import sys
import subprocess
import argparse
import time
import datetime
import tempfile
import csv
from pathlib import Path


class MediaWikiPerfTester:
    """Combines MediaWiki perf testing and core scaling functionality"""

    def __init__(self):
        self.script_dir = Path(__file__).parent
        self.original_dir = os.getcwd()
        self.wrk_path = self.script_dir / "../../benchmarks/oss_performance_mediawiki/wrk/wrk"
        
    def set_cpu_governor(self, governor="performance"):
        """Set CPU frequency scaling governor"""
        print(f"Setting CPU governor to {governor}...")
        try:
            cpu_dir = Path("/sys/devices/system/cpu")
            for cpu_path in sorted(cpu_dir.glob("cpu[0-9]*")):
                gov_file = cpu_path / "cpufreq" / "scaling_governor"
                if gov_file.exists():
                    subprocess.run(
                        f"echo {governor} | sudo tee {gov_file}",
                        shell=True,
                        check=False,
                    )
        except Exception as e:
            print(f"Warning: Could not set CPU governor: {e}")

    def tune_os(self):
        """Apply comprehensive OS tuning for MediaWiki workload"""
        tuning_commands = [
            "echo 1 | sudo tee /proc/sys/net/ipv4/tcp_tw_reuse",
            "echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled",
            "echo 1024 65535 | sudo tee /proc/sys/net/ipv4/ip_local_port_range",
            "echo 3 | sudo tee /proc/sys/vm/drop_caches",
        ]
        
        print("Applying OS tuning for MediaWiki...")
        for cmd in tuning_commands:
            try:
                subprocess.run(cmd, shell=True, check=False)
            except Exception as e:
                print(f"Warning: OS tuning command failed: {e}")

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

    def drop_caches(self):
        """Clear system caches"""
        try:
            subprocess.run(
                "echo 3 | sudo tee /proc/sys/vm/drop_caches",
                shell=True,
                check=False,
            )
            print("Dropped system caches")
        except Exception as e:
            print(f"Warning: Could not drop caches: {e}")

    def enable_tcp_reuse(self):
        """Enable TCP time-wait socket reuse"""
        try:
            subprocess.run(
                "echo 1 | sudo tee /proc/sys/net/ipv4/tcp_tw_reuse",
                shell=True,
                check=False,
            )
            print("Enabled TCP time-wait reuse")
        except Exception as e:
            print(f"Warning: Could not enable TCP reuse: {e}")

    def set_transparent_hugepages(self, setting="madvise"):
        """Set transparent hugepages mode"""
        try:
            subprocess.run(
                f"echo {setting} | sudo tee /sys/kernel/mm/transparent_hugepage/enabled",
                shell=True,
                check=False,
            )
            print(f"Set transparent hugepages to {setting}")
        except Exception as e:
            print(f"Warning: Could not set transparent hugepages: {e}")

    def restart_database(self):
        """Restart MariaDB service"""
        try:
            subprocess.run("sudo systemctl restart mariadb", shell=True, check=False)
            print("Restarted MariaDB")
        except Exception as e:
            print(f"Warning: Could not restart MariaDB: {e}")

    def build_emon_driver(self):
        """Build and load EMON driver"""
        sep_src_path = Path("/opt/intel/sep/sepdk/src")
        sep_path = Path("/opt/intel/sep")

        try:
            print("Building EMON driver...")
            
            # Change to SEP source directory
            if not sep_src_path.exists():
                print(f"Error: {sep_src_path} does not exist")
                return False

            os.chdir(sep_src_path)

            # Remove existing module
            subprocess.run("./rmmod-sep", shell=True, check=False)
            time.sleep(1)

            # Build driver without instrumentation
            result = subprocess.run("./build-driver -ni", shell=True, capture_output=True)
            if result.returncode != 0:
                print(f"Build driver failed: {result.stderr.decode()}")
                return False

            # Insert module with root group
            subprocess.run("./insmod-sep -g root", shell=True, check=False)
            time.sleep(1)

            # Source SEP environment
            os.chdir(sep_path)
            if sep_path.exists():
                env_file = sep_path / "sep_vars.sh"
                if env_file.exists():
                    subprocess.run(f"source {env_file}", shell=True, check=False)

            # Return to original directory
            os.chdir(self.original_dir)
            print("EMON driver built successfully")
            return True

        except Exception as e:
            print(f"Error building EMON driver: {e}")
            os.chdir(self.original_dir)
            return False

    def run_mediawiki_test(
        self,
        name,
        run_type,
        metric,
        num_runs,
        clients,
        duration,
        test_type="local",
        emon_user="pshah",
    ):
        """Run the MediaWiki performance test"""
        
        if test_type is None:
            test_type = "local"
        
        if clients is None or clients == 0:
            clients = 0
        
        if duration is None:
            duration = 10

        timeout = duration + 1
        emon_start = 600
        emon_end = (duration * 300) - 600
        ramp_string = "Starting wrk for benchmark"
        perf_start_delay = 30
        perf_duration = 300

        name_with_type = f"{name}_{test_type}client"
        
        # Create session name
        now = datetime.datetime.now()
        session_name = f"{name_with_type}_{now.strftime('%m%d%Y%H%M%S')}"
        logs_dir = f"mw_logs_{session_name}"

        # Add metric to name
        if metric == "emon":
            name_with_type = f"{name_with_type}_WEMON"
        elif metric == "perf":
            name_with_type = f"{name_with_type}_WPERF"

        # Setup phase
        if run_type == "run":
            os.makedirs(logs_dir, exist_ok=True)
            self.tune_os()
            self.enable_tcp_reuse()
            self.set_transparent_hugepages("madvise")
            self.restart_database()

        # Run each iteration
        for i in range(1, num_runs + 1):
            logs_file = os.path.join(
                logs_dir, f"mediawiki_{name_with_type}_{clients}clients_run{i}.txt"
            )

            # Build the main command
            cmd = (
                f"./run.sh -r /usr/local/hphpi/legacy/bin/hhvm "
                f"-n /usr/local/nginx-1.22/sbin/nginx -L wrk -s {self.wrk_path} -R0 "
                f"-c{clients} -- --mediawiki-mlp --client-duration={duration}m "
                f"--client-timeout={timeout}m --run-as-root "
                f"--i-am-not-benchmarking 2>&1 | tee {logs_file}"
            )

            data_cmd = cmd

            # Add metric-specific collection
            if metric == "emon":
                data_cmd = (
                    f"tmc -c \"{cmd}\" -rl {logs_file} -rs \"{ramp_string}\" "
                    f"-rt 2800 -n -u -x {emon_user} -a {logs_dir}_RUN{i} "
                    f"-S {emon_start} -E {emon_end} -A 10 "
                    f"-B {((duration * 30) - 10)} -w socket,core,uncore "
                    f"-Z metrics2 -G mediawiki_1.3E"
                )
            elif metric == "perf":
                perf_cmd = (
                    f"bash collect_perf.sh {logs_dir} {logs_file} "
                    f"\"{ramp_string}\" {session_name}_run{i} "
                    f"{perf_duration} {perf_start_delay} &"
                )
                print(perf_cmd)
                if run_type == "run":
                    subprocess.Popen(perf_cmd, shell=True)
            elif metric == "ptat":
                ptat_cmd = (
                    f"bash {self.script_dir}/collect_ptat.sh {os.getcwd()}/{logs_dir} "
                    f"{logs_file} \"{ramp_string}\" {session_name}_run{i} "
                    f"{perf_duration} {perf_start_delay} &"
                )
                print(ptat_cmd)
                if run_type == "run":
                    subprocess.Popen(ptat_cmd, shell=True)

            print(f"Run {i}/{num_runs}: {data_cmd}")

            # Execute the test
            if run_type == "run":
                self.drop_caches()
                result = subprocess.run(data_cmd, shell=True, capture_output=False)
                
                # Wait for perf/ptat collection to finish
                time.sleep(2)

                # Parse and send results
                try:
                    result_file = "/tmp/result.csv"
                    grep_cmd = (
                        f"grep 'Combined' -A15 {logs_file} | grep -v Combined | "
                        f"awk -F ':' '{{print $1\",\"$2}}' | tr '\"' ' ' > {result_file}"
                    )
                    subprocess.run(grep_cmd, shell=True, check=False)

                    # Send notification (if notify.py exists)
                    notify_py = self.script_dir / "notify.py"
                    if notify_py.exists():
                        notify_cmd = (
                            f"python {notify_py} --subject \"MediaWiki - {name_with_type} "
                            f"Run{i} completed\" --message \"Completed\" "
                            f"--summary {result_file} --logfile {logs_file}"
                        )
                        subprocess.run(notify_cmd, shell=True, check=False)
                except Exception as e:
                    print(f"Warning: Could not process results: {e}")

    def run_core_scaling_study(
        self,
        name,
        total_cores,
        cores_per_iteration,
        metric,
        num_runs,
        duration,
        test_type="local",
        emon_user="pshah",
    ):
        """Run a core scaling study with progressive core enabling"""
        
        print(f"Starting core scaling study: 0 to {total_cores} cores "
              f"in steps of {cores_per_iteration}")

        # Rebuild EMON driver at start
        if metric == "emon":
            print("Building EMON driver with initial topology...")
            if not self.build_emon_driver():
                print("Warning: EMON driver build failed, continuing anyway")

        # Iterate over core counts
        current_core = cores_per_iteration
        while current_core <= total_cores:
            print(f"\n{'='*60}")
            print(f"Testing with {current_core} cores")
            print(f"{'='*60}\n")

            # Apply OS tuning and drop caches between runs
            self.tune_os()
            self.drop_caches()
            self.restart_database()

            # Note: EMON driver already built at initialization

            # Calculate number of instances (threads) based on available cores
            try:
                nproc_result = subprocess.run(
                    "nproc", shell=True, capture_output=True, text=True
                )
                num_cores = int(nproc_result.stdout.strip())
                instances = (num_cores + 99) // 100  # Calculate as in original script
            except Exception as e:
                print(f"Warning: Could not determine core count: {e}")
                instances = 1

            print(f"Running mw_perf.sh with {num_cores} cores and {instances} instances")

            # Build test name with current core count
            test_name = f"{name}_P83_288Cores_SNC3_{num_cores}"

            # Run MediaWiki test
            self.run_mediawiki_test(
                name=test_name,
                run_type="run",
                metric=metric,
                num_runs=num_runs,
                clients=instances,
                duration=duration,
                test_type=test_type,
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
                    print("Rebuilding EMON driver after core topology change...")
                    self.build_emon_driver()
                
                print("Waiting 15 seconds before next iteration...")
                time.sleep(15)

            current_core += cores_per_iteration

        # Final cache drop
        self.drop_caches()
        print("\nCore scaling study completed!")


def main():
    parser = argparse.ArgumentParser(
        description="Combined MediaWiki Performance and Core Scaling Testing Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Run single MediaWiki test with EMON collection
  python mw_perf.py --name "MW_Test" --metric emon --clients 4 --duration 10
  
  # Run core scaling study from 16 to 288 cores
  python mw_perf.py --name "MW_Scaling" --core-scaling --total-cores 288 \\
                    --cores-per-iteration 16 --metric emon
  
  # Run multiple iterations with perf collection
  python mw_perf.py --name "MW_Test" --metric perf --runs 3 --clients 8 \\
                    --duration 20 --dry-run
        """,
    )

    # Main test parameters
    parser.add_argument(
        "--name", "-n", required=True, help="Test name/identifier"
    )
    parser.add_argument(
        "--metric", "-m",
        choices=["emon", "perf", "ptat"],
        default="emon",
        help="Metric collection type (default: emon)",
    )
    parser.add_argument(
        "--runs", "-r", type=int, default=1, help="Number of runs (default: 1)"
    )
    parser.add_argument(
        "--clients", "-c", type=int, default=0, help="Number of clients (default: 0)"
    )
    parser.add_argument(
        "--duration", "-d", type=int, default=10, help="Duration in minutes (default: 10)"
    )
    parser.add_argument(
        "--type", "-t",
        default="local",
        choices=["local", "remote"],
        help="Test type (default: local)",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Show commands without executing"
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

    args = parser.parse_args()

    # Initialize tester
    tester = MediaWikiPerfTester()

    # Set initial CPU governor
    tester.set_cpu_governor("performance")

    if args.dry_run:
        print("DRY RUN MODE - Commands will be shown but not executed\n")

    if args.core_scaling:
        # Core scaling mode
        if args.dry_run:
            print(f"Would run core scaling study:")
            print(f"  Name: {args.name}")
            print(f"  Total cores: {args.total_cores}")
            print(f"  Cores per iteration: {args.cores_per_iteration}")
            print(f"  Metric: {args.metric}")
            print(f"  EMON User: {args.emon_user}")
            print(f"  Runs: {args.runs}")
            print(f"  Duration: {args.duration} minutes")
        else:
            tester.run_core_scaling_study(
                name=args.name,
                total_cores=args.total_cores,
                cores_per_iteration=args.cores_per_iteration,
                metric=args.metric,
                num_runs=args.runs,
                duration=args.duration,
                test_type=args.type,
                emon_user=args.emon_user,
            )
    else:
        # Single test mode
        if args.dry_run:
            print(f"Would run MediaWiki test:")
            print(f"  Name: {args.name}")
            print(f"  Metric: {args.metric}")
            print(f"  Runs: {args.runs}")
            print(f"  Clients: {args.clients}")
            print(f"  Duration: {args.duration} minutes")
            print(f"  Type: {args.type}")
            print(f"  EMON User: {args.emon_user}")
        else:
            tester.run_mediawiki_test(
                name=args.name,
                run_type="run",
                metric=args.metric,
                num_runs=args.runs,
                clients=args.clients,
                duration=args.duration,
                test_type=args.type,
                emon_user=args.emon_user,
            )

    print("\nTest completed!")


if __name__ == "__main__":
    main()
