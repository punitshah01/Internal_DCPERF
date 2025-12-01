#!/usr/bin/env python3
"""
=============================================================================
MAIN WORKLOAD WRAPPER SCRIPT
=============================================================================
This script orchestrates different workload scripts with core scaling,
TMC/EMON integration, and workload results generation
=============================================================================
"""

import os
import sys
import argparse
import subprocess
import re
import datetime
from pathlib import Path
from typing import List, Optional, Dict, Any

class WorkloadWrapper:
    def __init__(self):
        # System parameters
        self.abs_dir = Path(__file__).parent.absolute()
        self.system_info = self._get_system_info()
        
        # Default values
        self.DEFAULT_CORES_STEP = 4
        self.DEFAULT_METRIC_TYPE = "Throughput"
        self.DEFAULT_EMON_CHART_VIEWS = "core,socket"
        self.DEFAULT_EMON_OUTPUT_DIR = "./emon_traces"
        self.DEFAULT_EMON_DURATION = 0
        
        # Variables
        self.script_path = ""
        self.cores_step = self.DEFAULT_CORES_STEP
        self.specific_nproc = None
        self.dry_run = True  # True = dry run (default), False = actual execution
        self.enable_emon = False
        self.script_args = ""
        
        # EMON/TMC Variables
        self.emon_user = ""
        self.emon_group = ""
        self.emon_session = ""
        self.emon_server = ""
        self.workload_name = ""
        self.metric_type = self.DEFAULT_METRIC_TYPE
        self.metric_unit = ""
        self.emon_duration = self.DEFAULT_EMON_DURATION
        self.emon_chart_views = self.DEFAULT_EMON_CHART_VIEWS
        self.emon_output_dir = self.DEFAULT_EMON_OUTPUT_DIR

    def _get_system_info(self) -> Dict[str, Any]:
        """Gather system information"""
        info = {}
        
        try:
            # BIOS version
            result = subprocess.run(['dmidecode', '-t', 'bios'], 
                                  capture_output=True, text=True, check=True)
            bios_match = re.search(r'Version:\s+(.+)', result.stdout)
            info['bios'] = bios_match.group(1) if bios_match else "Unknown"
        except:
            info['bios'] = "Unknown"
        
        try:
            # Microcode
            with open('/proc/cpuinfo', 'r') as f:
                for line in f:
                    if 'microcode' in line:
                        info['microcode'] = line.split(':')[1].strip()
                        break
                else:
                    info['microcode'] = "Unknown"
        except:
            info['microcode'] = "Unknown"
        
        try:
            # Operating system
            with open('/etc/os-release', 'r') as f:
                for line in f:
                    if line.startswith('PRETTY_NAME='):
                        info['operating_system'] = line.split('=')[1].strip().strip('"')
                        break
                else:
                    info['operating_system'] = "Unknown"
        except:
            info['operating_system'] = "Unknown"
        
        # Kernel
        info['kernel'] = os.uname().release
        
        # CPU information from lscpu
        try:
            result = subprocess.run(['lscpu'], capture_output=True, text=True, check=True)
            lscpu_output = result.stdout
            
            info['cores_per_socket'] = self._extract_lscpu_value(lscpu_output, r'Core\(s\) per socket:\s+(\d+)')
            info['total_sockets'] = self._extract_lscpu_value(lscpu_output, r'Socket\(s\):\s+(\d+)')
            info['model'] = self._extract_lscpu_value(lscpu_output, r'Model:\s+(\d+)')
            info['family'] = self._extract_lscpu_value(lscpu_output, r'CPU family:\s+(\d+)')
            info['stepping'] = self._extract_lscpu_value(lscpu_output, r'Stepping:\s+(\d+)')
            info['total_numa_nodes'] = self._extract_lscpu_value(lscpu_output, r'NUMA node\(s\):\s+(\d+)')
            
            # CPU model name
            model_match = re.search(r'Model name:\s+(.+)', lscpu_output)
            info['cpu_model_name'] = model_match.group(1).strip() if model_match else "Unknown"
            
        except:
            info.update({
                'cores_per_socket': 1,
                'total_sockets': 1,
                'model': 0,
                'family': 0,
                'stepping': 0,
                'total_numa_nodes': 1,
                'cpu_model_name': "Unknown"
            })
        
        # Calculate total cores
        info['total_cores'] = info['cores_per_socket'] * info['total_sockets']
        
        # Processor count
        info['procs'] = os.cpu_count() or info['total_cores']
        
        return info

    def _extract_lscpu_value(self, lscpu_output: str, pattern: str) -> int:
        """Extract integer value from lscpu output using regex pattern"""
        match = re.search(pattern, lscpu_output)
        return int(match.group(1)) if match else 1

    def print_usage(self):
        """Print usage information"""
        usage = f"""
Usage: {sys.argv[0]} [OPTIONS]

REQUIRED:
  -s, --script PATH           Path to workload script to execute (REQUIRED)

CORE SCALING:
  -c, --cores N              Core stepping size (default: {self.DEFAULT_CORES_STEP})
  -n, --nproc N              Run only with specific nproc value (overrides stepping)
  -r, --run                  Execute commands (default: dry-run mode)

TMC/EMON INTEGRATION:
  -e, --emon                 Enable TMC/EMON integration (default: disabled)
  --emon-user USER           TMC username (optional, workload script default used)
  --emon-group GROUP         TMC group name (optional, workload script default used)
  --emon-server SERVER       Server identifier (optional, workload script default used)
  --emon-session SESSION     TMC session identifier (required if --emon)

WORKLOAD RESULTS:
  --workload-name NAME       Workload name for results file (required if --emon)
  --metric-type TYPE         Metric type: Throughput/Latency/etc (default: {self.DEFAULT_METRIC_TYPE})
  --metric-unit UNIT         Metric unit: ops/s, ms, GFLOPS, etc (required if --emon)

SCRIPT PARAMETERS:
  --script-args "ARGS"       Additional arguments to pass to workload script

TMC OPTIONAL:
  --emon-duration SEC        Collection duration in seconds (default: {self.DEFAULT_EMON_DURATION} = until completion)
  --emon-chart-views VIEWS   Chart views (default: {self.DEFAULT_EMON_CHART_VIEWS})
  --emon-output-dir DIR      Base output directory (default: {self.DEFAULT_EMON_OUTPUT_DIR})

EXAMPLES:
  # Basic dry run
  {sys.argv[0]} --script ./ffmpeg/workload.sh --cores 8

  # Actual execution with specific nproc
  {sys.argv[0]} --script ./sysbench/workload.sh --nproc 32 --run

  # Minimal TMC integration (uses workload script defaults)
  {sys.argv[0]} --script ./stream/workload.sh --cores 4 --emon \\
     --emon-session "scaling_test" --workload-name "STREAM" --metric-unit "MB/s" --run

  # Full TMC integration with custom parameters
  {sys.argv[0]} --script ./stress-ng/workload.sh --cores 4 --emon \\
     --emon-user john --emon-group custom_group --emon-server cluster01 \\
     --emon-session "stress_scaling" --workload-name "Stress-ng" --metric-unit "Bogo_Ops/s" --run

AVAILABLE WORKLOADS:
  Look for workload.sh files in subdirectories:
  - ./ffmpeg/workload.sh
  - ./multichase/workload.sh
  - ./crypto++/workload.sh
  - ./super_pi/workload.sh
  - ./sysbench/workload.sh
  - ./stream/workload.sh
  - ./stress-ng/workload.sh
"""
        print(usage)

    def validate_emon_params(self):
        """Validate EMON parameters"""
        missing_params = []
        
        if not self.emon_session:
            missing_params.append("--emon-session")
        if not self.workload_name:
            missing_params.append("--workload-name")
        if not self.metric_unit:
            missing_params.append("--metric-unit")
        
        if missing_params:
            print(f"Error: EMON enabled but missing required parameters: {' '.join(missing_params)}")
            print("Use --help for usage information")
            sys.exit(1)

    def validate_script(self):
        """Validate script path"""
        if not self.script_path:
            print("Error: --script parameter is required")
            self.print_usage()
            sys.exit(1)
        
        # Handle relative paths from current directory
        if not os.path.isabs(self.script_path):
            self.script_path = os.path.join(self.abs_dir, self.script_path)
        
        script_file = Path(self.script_path)
        if not script_file.exists():
            print(f"Error: Script file '{self.script_path}' not found")
            
            # Try to suggest available workloads
            self.suggest_available_workloads()
            sys.exit(1)
        
        if not os.access(script_file, os.X_OK):
            print(f"Error: Script file '{self.script_path}' is not executable")
            print(f"Try: chmod +x {self.script_path}")
            sys.exit(1)

    def suggest_available_workloads(self):
        """Suggest available workload scripts"""
        print("\nAvailable workload scripts:")
        workload_dirs = []
        
        # Look for workload.sh files in subdirectories
        for item in self.abs_dir.iterdir():
            if item.is_dir():
                workload_script = item / "workload.sh"
                if workload_script.exists():
                    workload_dirs.append(f"  ./{item.name}/workload.sh")
        
        if workload_dirs:
            for workload in sorted(workload_dirs):
                print(workload)
        else:
            print("  No workload.sh files found in subdirectories")

    def get_core_list(self) -> List[int]:
        """Get list of core counts to test"""
        if self.specific_nproc:
            if self.specific_nproc > self.system_info['total_cores']:
                print(f"Error: Specified nproc ({self.specific_nproc}) exceeds available cores ({self.system_info['total_cores']})")
                sys.exit(1)
            return [self.specific_nproc]
        else:
            core_list = []
            for i in range(self.cores_step, self.system_info['total_cores'] + 1, self.cores_step):
                core_list.append(i)
            
            # Always include max cores if not already included
            if self.system_info['total_cores'] % self.cores_step != 0:
                core_list.append(self.system_info['total_cores'])
            
            return core_list

    def create_system_info_file(self, output_dir: Path, cores: int):
        """Create system information file"""
        system_info_content = f"""# System Configuration
        timestamp: "{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
        hostname: "{os.uname().nodename}"
        bios_version: "{self.system_info['bios']}"
        microcode: "{self.system_info['microcode']}"
        operating_system: "{self.system_info['operating_system']}"
        kernel: "{self.system_info['kernel']}"
        cpu_model: "{self.system_info['cpu_model_name']}"
        cpu_family: "{self.system_info['family']}"
        cpu_model_num: "{self.system_info['model']}"
        cpu_stepping: "{self.system_info['stepping']}"
        total_cores: {self.system_info['total_cores']}
        cores_per_socket: {self.system_info['cores_per_socket']}
        total_sockets: {self.system_info['total_sockets']}
        numa_nodes: {self.system_info['total_numa_nodes']}
        test_cores: {cores}
        workload_script: "{self.script_path}"
        script_args: "{self.script_args}"
        """
        
        if self.enable_emon:
            system_info_content += f"""emon_user: "{self.emon_user}"
            emon_group: "{self.emon_group}"
            emon_session: "{self.emon_session}"
            emon_server: "{self.emon_server}"
            """
        
        with open(output_dir / "system_info.txt", 'w') as f:
            f.write(system_info_content)

    def create_workload_result_file(self, output_dir: Path, cores: int, performance_result: str):
        """Create workload result file"""
        workload_result_content = f"""workload_name:"{self.workload_name}"
        metric_type:"{self.metric_type}"
        result:"{performance_result}"
        metric:"{self.metric_unit}"
        num_instances:1
        sockets:{self.system_info['total_sockets']}
        cores_used:{cores}
        total_cores:{self.system_info['total_cores']}
        notes:"Core scaling test with {cores} cores using {Path(self.script_path).name}"
        test_date:"{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
        hostname:"{os.uname().nodename}"
        """
        
        with open(output_dir / "workload_result.txt", 'w') as f:
            f.write(workload_result_content)

    def parse_performance_output(self, output_file: Path) -> str:
        """Parse performance output from workload log"""
        if not output_file.exists():
            return "N/A"
        
        try:
            with open(output_file, 'r') as f:
                content = f.read()
            
            # Pattern 1: "Performance: 1234.56 ops/s"
            match = re.search(r'performance:\s*([0-9]+\.?[0-9]*)', content, re.IGNORECASE)
            if match:
                return match.group(1)
            
            # Pattern 2: "Throughput: 1234.56"
            match = re.search(r'throughput:\s*([0-9]+\.?[0-9]*)', content, re.IGNORECASE)
            if match:
                return match.group(1)
            
            # Pattern 3: "Rate: 1234.56"
            match = re.search(r'rate:\s*([0-9]+\.?[0-9]*)', content, re.IGNORECASE)
            if match:
                return match.group(1)
            
            # Pattern 4: Look for SPEC-like output "SPECrate2017_*_base,1234.56"
            match = re.search(r'SPEC.*rate.*base.*,([0-9]+\.?[0-9]*)', content, re.IGNORECASE)
            if match:
                return match.group(1)
            
            # Pattern 5: Look for CSV results with Score column
            lines = content.split('\n')
            for line in lines:
                if 'Score' in line and ',' in line:
                    parts = line.split(',')
                    if len(parts) >= 6:  # Date,Workload Name,Test Case,Command,KPI,Score
                        try:
                            score = float(parts[5].strip())
                            return str(score)
                        except:
                            continue
            
        except Exception as e:
            print(f"Warning: Error parsing performance output: {e}")
        
        return "N/A"

    def run_workload_with_cores(self, cores: int):
        """Run workload with specified number of cores"""
        timestamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
        workload_basename = Path(self.script_path).parent.name
        run_id = f"{workload_basename}_{cores}cores_{timestamp}"
        output_dir = Path(self.emon_output_dir) / run_id
        
        print("=" * 50)
        print(f"Running {workload_basename} with {cores} cores")
        print(f"Output directory: {output_dir}")
        print("=" * 50)
        
        # Create output directory
        if not self.dry_run:
            output_dir.mkdir(parents=True, exist_ok=True)
            # Create system info file
            self.create_system_info_file(output_dir, cores)
        
        # Prepare workload command - use absolute path to avoid issues
        script_abs_path = Path(self.script_path).resolve()
        workload_cmd = f"{script_abs_path} --cpu-cores 0-{cores-1}"
        
        # Add additional script arguments if provided
        if self.script_args:
            workload_cmd += f" {self.script_args}"
        
        output_file = output_dir / "workload_output.log" if not self.dry_run else Path("/dev/null")
        
        if self.enable_emon:
            # TMC command - use absolute paths and proper quoting
            tmc_cmd = f"python3 /root/tmc/tmc.py -c \"{workload_cmd}\" -d \"{output_dir.absolute()}\" -n"
            
            # Add optional parameters only if provided
            if self.emon_user:
                tmc_cmd += f" -x \"{self.emon_user}\""
            
            if self.emon_group:
                tmc_cmd += f" -G \"{self.emon_group}\""
            
            if self.emon_session:
                tmc_cmd += f" -i \"{self.emon_session}_{cores}cores\""
            
            if self.emon_duration > 0:
                tmc_cmd += f" -t {self.emon_duration}"
            
            tmc_cmd += f" -w \"{self.emon_chart_views}\""
            
            print(f"TMC Command: {tmc_cmd}")
            
            if not self.dry_run:
                print("Executing with TMC/EMON...")
                try:
                    # Check if TMC script exists
                    tmc_script = Path("/root/tmc/tmc.py")
                    if not tmc_script.exists():
                        print(f"Error: TMC script not found at {tmc_script}")
                        print("Please check TMC installation path")
                        return
                    
                    # Check if workload script exists and is executable
                    if not script_abs_path.exists():
                        print(f"Error: Workload script not found at {script_abs_path}")
                        return
                    
                    if not os.access(script_abs_path, os.X_OK):
                        print(f"Error: Workload script is not executable: {script_abs_path}")
                        print(f"Try: chmod +x {script_abs_path}")
                        return
                    
                    with open(output_file, 'w') as f:
                        result = subprocess.run(tmc_cmd, shell=True, stdout=f, stderr=subprocess.STDOUT, 
                                              cwd=Path(self.script_path).parent)
                    exit_code = result.returncode
                except Exception as e:
                    print(f"Error executing TMC command: {e}")
                    exit_code = 1
            else:
                print("DRY RUN: Would execute TMC command above")
                exit_code = 0
        else:
            # Direct workload execution
            print(f"Workload Command: {workload_cmd}")
            
            if not self.dry_run:
                print("Executing workload directly...")
                try:
                    # Check if workload script exists and is executable
                    if not script_abs_path.exists():
                        print(f"Error: Workload script not found at {script_abs_path}")
                        return
                    
                    if not os.access(script_abs_path, os.X_OK):
                        print(f"Error: Workload script is not executable: {script_abs_path}")
                        print(f"Try: chmod +x {script_abs_path}")
                        return
                    
                    with open(output_file, 'w') as f:
                        result = subprocess.run(workload_cmd, shell=True, stdout=f, stderr=subprocess.STDOUT,
                                              cwd=Path(self.script_path).parent)
                    exit_code = result.returncode
                except Exception as e:
                    print(f"Error executing workload command: {e}")
                    exit_code = 1
            else:
                print("DRY RUN: Would execute workload command above")
                exit_code = 0
        
        # Process results if not dry run
        if not self.dry_run and exit_code == 0:
            if self.enable_emon:
                # Parse performance output and create workload result file
                perf_result = self.parse_performance_output(output_file)
                self.create_workload_result_file(output_dir, cores, perf_result)
                print(f"Performance result: {perf_result} {self.metric_unit}")
            print(f"Results saved to: {output_dir}")
        elif not self.dry_run:
            print(f"Warning: Workload execution failed with exit code {exit_code}")
            if exit_code == 126:
                print("Exit code 126 usually means 'Permission denied' or 'Command not executable'")
                print(f"Check if the script is executable: ls -la {script_abs_path}")
                print(f"Make it executable with: chmod +x {script_abs_path}")
            elif exit_code == 127:
                print("Exit code 127 usually means 'Command not found'")
                print(f"Check if the script path is correct: {script_abs_path}")
        
        print()

    def set_performance_governor(self):
        """Set CPU governor to performance"""
        if self.dry_run:
            print("DRY RUN: Would set CPU governor to performance")
            return
            
        try:
            cpu_dirs = Path('/sys/devices/system/cpu').glob('cpu[0-9]*')
            for cpu_dir in cpu_dirs:
                governor_file = cpu_dir / 'cpufreq' / 'scaling_governor'
                if governor_file.exists():
                    try:
                        with open(governor_file, 'w') as f:
                            f.write('performance')
                    except:
                        pass  # Ignore individual failures
            print("CPU governor set to performance")
        except Exception as e:
            print(f"Warning: Could not set performance governor: {e}")

    def parse_arguments(self):
        """Parse command line arguments"""
        parser = argparse.ArgumentParser(
            description="Main Workload Wrapper Script",
            formatter_class=argparse.RawDescriptionHelpFormatter,
            epilog="""
Examples:
  # Basic dry run
  python3 main_wrapper.py --script ./ffmpeg/workload.sh --cores 8

  # Actual execution with specific nproc
  python3 main_wrapper.py --script ./sysbench/workload.sh --nproc 32 --run

  # With EMON integration
  python3 main_wrapper.py --script ./stream/workload.sh --cores 4 --emon \\
     --emon-session "scaling_test" --workload-name "STREAM" --metric-unit "MB/s" --run
            """
        )
        
        # Required arguments
        parser.add_argument('-s', '--script', required=True, 
                          help='Path to workload script to execute (REQUIRED)')
        
        # Core scaling arguments
        parser.add_argument('-c', '--cores', type=int, default=self.DEFAULT_CORES_STEP,
                          help=f'Core stepping size (default: {self.DEFAULT_CORES_STEP})')
        parser.add_argument('-n', '--nproc', type=int, 
                          help='Run only with specific nproc value (overrides stepping)')
        parser.add_argument('-r', '--run', action='store_true', 
                          help='Execute commands (default: dry-run mode)')
        
        # TMC/EMON arguments
        parser.add_argument('-e', '--emon', action='store_true', 
                          help='Enable TMC/EMON integration (default: disabled)')
        parser.add_argument('--emon-user', help='TMC username (optional)')
        parser.add_argument('--emon-group', help='TMC group name (optional)')
        parser.add_argument('--emon-server', help='Server identifier (optional)')
        parser.add_argument('--emon-session', help='TMC session identifier (required if --emon)')
        
        # Workload results arguments
        parser.add_argument('--workload-name', help='Workload name for results file (required if --emon)')
        parser.add_argument('--metric-type', default=self.DEFAULT_METRIC_TYPE, 
                          help=f'Metric type (default: {self.DEFAULT_METRIC_TYPE})')
        parser.add_argument('--metric-unit', help='Metric unit: ops/s, ms, GFLOPS, etc (required if --emon)')
        
        # Script parameters
        parser.add_argument('--script-args', default='', 
                          help='Additional arguments to pass to workload script')
        
        # TMC optional arguments
        parser.add_argument('--emon-duration', type=int, default=self.DEFAULT_EMON_DURATION,
                          help=f'Collection duration in seconds (default: {self.DEFAULT_EMON_DURATION} = until completion)')
        parser.add_argument('--emon-chart-views', default=self.DEFAULT_EMON_CHART_VIEWS,
                          help=f'Chart views (default: {self.DEFAULT_EMON_CHART_VIEWS})')
        parser.add_argument('--emon-output-dir', default=self.DEFAULT_EMON_OUTPUT_DIR,
                          help=f'Base output directory (default: {self.DEFAULT_EMON_OUTPUT_DIR})')
        
        try:
            args = parser.parse_args()
        except SystemExit as e:
            if e.code == 0:  # Help was requested
                sys.exit(0)
            else:  # Error in arguments
                sys.exit(1)
        
        # Set instance variables
        self.script_path = args.script
        self.cores_step = args.cores
        self.specific_nproc = args.nproc
        self.dry_run = not args.run
        self.enable_emon = args.emon
        self.script_args = args.script_args
        
        self.emon_user = args.emon_user or ""
        self.emon_group = args.emon_group or ""
        self.emon_session = args.emon_session or ""
        self.emon_server = args.emon_server or ""
        self.workload_name = args.workload_name or ""
        self.metric_type = args.metric_type
        self.metric_unit = args.metric_unit or ""
        self.emon_duration = args.emon_duration
        self.emon_chart_views = args.emon_chart_views
        self.emon_output_dir = args.emon_output_dir

    def run(self):
        """Main execution function"""
        # Parse arguments
        self.parse_arguments()
        
        # Validation
        self.validate_script()
        
        if self.enable_emon:
            self.validate_emon_params()
        
        if self.cores_step <= 0:
            print("Error: Core stepping size must be positive")
            sys.exit(1)
        
        if self.specific_nproc is not None and self.specific_nproc <= 0:
            print("Error: nproc value must be positive")
            sys.exit(1)
        
        # Print execution info
        print("=" * 60)
        print("WORKLOAD WRAPPER SCRIPT")
        print("=" * 60)
        print(f"Script: {self.script_path}")
        print(f"Mode: {'DRY RUN' if self.dry_run else 'EXECUTION'}")
        print(f"EMON: {'ENABLED' if self.enable_emon else 'DISABLED'}")
        print(f"System: {self.system_info['total_cores']} cores, {self.system_info['total_sockets']} sockets, {self.system_info['total_numa_nodes']} NUMA nodes")
        
        if self.script_args:
            print(f"Script Args: {self.script_args}")
        
        if self.enable_emon:
            print(f"EMON User: {self.emon_user}")
            print(f"EMON Group: {self.emon_group}")
            print(f"EMON Session: {self.emon_session}")
            print(f"Workload: {self.workload_name}")
            print(f"Metric: {self.metric_unit}")
        
        print("=" * 60)
        print()
        
        # Get list of core counts to test
        core_list = self.get_core_list()
        print(f"Testing with core counts: {' '.join(map(str, core_list))}")
        print()
        
        # Set performance governor
        self.set_performance_governor()
        
        # Run workload for each core count
        for cores in core_list:
            self.run_workload_with_cores(cores)
        
        print("=" * 60)
        print("WORKLOAD WRAPPER EXECUTION COMPLETED")
        print("=" * 60)
        
        if not self.dry_run:
            print(f"Results directory: {self.emon_output_dir}")
            if self.enable_emon:
                print()
                print("Generated files per run:")
                print("  - workload_result.txt (performance metrics)")
                print("  - system_info.txt (system configuration)")
                print("  - workload_output.log (execution log)")
                print("  - EMON traces (if TMC enabled)")


def main():
    """Main entry point"""
    try:
        wrapper = WorkloadWrapper()
        wrapper.run()
    except KeyboardInterrupt:
        print("\nExecution interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
