#!/bin/bash

# =============================================================================
# MAIN WORKLOAD WRAPPER SCRIPT (BASH VERSION)
# =============================================================================
# This script orchestrates different workload scripts with core scaling,
# TMC/EMON integration, and workload results generation
# =============================================================================

set -euo pipefail

# ------------------------------ DEFAULT VALUES -----------------------------------
DEFAULT_CORES_STEP=4
DEFAULT_METRIC_TYPE="Throughput"
DEFAULT_EMON_CHART_VIEWS="core,socket"
DEFAULT_EMON_OUTPUT_DIR="./emon_traces"
DEFAULT_EMON_DURATION=0

# ------------------------------ VARIABLES -----------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Required parameters
script_path=""

# Core scaling parameters
cores_step=$DEFAULT_CORES_STEP
specific_nproc=""
dry_run=false  # false = actual execution (default), true = dry run with -r

# TMC/EMON parameters
enable_emon=false
emon_user=""
emon_group=""
emon_session=""
emon_server=""
workload_name=""
metric_type=$DEFAULT_METRIC_TYPE
metric_unit=""
emon_duration=$DEFAULT_EMON_DURATION
emon_chart_views=$DEFAULT_EMON_CHART_VIEWS
emon_output_dir=$DEFAULT_EMON_OUTPUT_DIR

# Script parameters
script_args=""

# System info variables
total_cores=0
total_sockets=0
total_numa_nodes=0
cpu_model_name=""
bios_version=""
microcode=""
operating_system=""
kernel_version=""

# ------------------------------ FUNCTIONS -----------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    echo "Error: $1" >&2
    exit 1
}

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

REQUIRED:
  -s, --script PATH           Path to workload script to execute (REQUIRED)

CORE SCALING:
  -c, --cores N              Core stepping size (default: $DEFAULT_CORES_STEP)
  -n, --nproc N              Run only with specific nproc value (overrides stepping)
  -r, --dry-run              Show commands without executing (default: execute)

TMC/EMON INTEGRATION:
  -e, --emon                 Enable TMC/EMON integration (default: disabled)
  --emon-user USER           TMC username (optional, workload script default used)
  --emon-group GROUP         TMC group name (optional, workload script default used)
  --emon-server SERVER       Server identifier (optional, workload script default used)
  --emon-session SESSION     TMC session identifier (required if --emon)

WORKLOAD RESULTS:
  --workload-name NAME       Workload name for results file (required if --emon)
  --metric-type TYPE         Metric type: Throughput/Latency/etc (default: $DEFAULT_METRIC_TYPE)
  --metric-unit UNIT         Metric unit: ops/s, ms, GFLOPS, etc (required if --emon)

SCRIPT PARAMETERS:
  --script-args "ARGS"       Additional arguments to pass to workload script

TMC OPTIONAL:
  --emon-duration SEC        Collection duration in seconds (default: $DEFAULT_EMON_DURATION = until completion)
  --emon-chart-views VIEWS   Chart views (default: $DEFAULT_EMON_CHART_VIEWS)
  --emon-output-dir DIR      Base output directory (default: $DEFAULT_EMON_OUTPUT_DIR)

EXAMPLES:
  # Basic execution
  $0 --script ./SuperPi/superpi.sh --cores 8

  # Dry run to check commands
  $0 --script ./SuperPi/superpi.sh --cores 8 --dry-run

  # Execution with specific nproc
  $0 --script ./SuperPi/superpi.sh --nproc 32

  # With EMON integration
  $0 --script ./SuperPi/superpi.sh --cores 4 --emon \\
     --emon-session "superpi_test" --workload-name "SuperPi" --metric-unit "seconds"

  # With additional script arguments
  $0 --script ./SuperPi/superpi.sh --cores 8 \\
     --script-args "--scale 10000 --runs 3"

AVAILABLE WORKLOADS:
  Look for workload scripts in subdirectories:
  - ./SuperPi/superpi.sh
  - ./ffmpeg/workload.sh
  - ./multichase/workload.sh
  - ./crypto++/workload.sh
  - ./sysbench/workload.sh
  - ./stream/workload.sh
  - ./stress-ng/workload.sh
EOF
}

get_system_info() {
    log "Gathering system information..."
    
    # Get total cores
    total_cores=$(nproc)
    
    # Get CPU information from lscpu
    if command -v lscpu >/dev/null 2>&1; then
        local lscpu_output=$(lscpu)
        
        total_sockets=$(echo "$lscpu_output" | grep "Socket(s):" | awk '{print $2}' || echo "1")
        total_numa_nodes=$(echo "$lscpu_output" | grep "NUMA node(s):" | awk '{print $3}' || echo "1")
        cpu_model_name=$(echo "$lscpu_output" | grep "Model name:" | cut -d':' -f2 | sed 's/^[[:space:]]*//' || echo "Unknown")
    else
        total_sockets=1
        total_numa_nodes=1
        cpu_model_name="Unknown"
    fi
    
    # Get BIOS version
    if command -v dmidecode >/dev/null 2>&1; then
        bios_version=$(dmidecode -t bios 2>/dev/null | grep "Version:" | head -1 | cut -d':' -f2 | sed 's/^[[:space:]]*//' || echo "Unknown")
    else
        bios_version="Unknown"
    fi
    
    # Get microcode
    if [[ -f /proc/cpuinfo ]]; then
        microcode=$(grep "microcode" /proc/cpuinfo | head -1 | cut -d':' -f2 | sed 's/^[[:space:]]*//' || echo "Unknown")
    else
        microcode="Unknown"
    fi
    
    # Get OS information
    if [[ -f /etc/os-release ]]; then
        operating_system=$(grep "PRETTY_NAME=" /etc/os-release | cut -d'=' -f2 | tr -d '"' || echo "Unknown")
    else
        operating_system="Unknown"
    fi
    
    # Get kernel version
    kernel_version=$(uname -r)
    
    log "System info gathered: $total_cores cores, $total_sockets sockets, $total_numa_nodes NUMA nodes"
}

validate_emon_params() {
    local missing_params=()
    
    if [[ -z "$emon_session" ]]; then
        missing_params+=("--emon-session")
    fi
    if [[ -z "$workload_name" ]]; then
        missing_params+=("--workload-name")
    fi
    if [[ -z "$metric_unit" ]]; then
        missing_params+=("--metric-unit")
    fi
    
    if [[ ${#missing_params[@]} -gt 0 ]]; then
        error_exit "EMON enabled but missing required parameters: ${missing_params[*]}"
    fi
}

validate_script() {
    if [[ -z "$script_path" ]]; then
        error_exit "--script parameter is required"
    fi
    
    # Handle relative paths
    if [[ ! "$script_path" = /* ]]; then
        script_path="$SCRIPT_DIR/$script_path"
    fi
    
    if [[ ! -f "$script_path" ]]; then
        echo "Error: Script file '$script_path' not found" >&2
        suggest_available_workloads
        exit 1
    fi
    
    if [[ ! -x "$script_path" ]]; then
        error_exit "Script file '$script_path' is not executable. Try: chmod +x $script_path"
    fi
}

suggest_available_workloads() {
    echo ""
    echo "Available workload scripts:"
    
    local found_workloads=false
    for dir in "$SCRIPT_DIR"/*; do
        if [[ -d "$dir" ]]; then
            local workload_script="$dir/workload.sh"
            local superpi_script="$dir/superpi.sh"
            
            if [[ -f "$workload_script" ]]; then
                echo "  ./${dir##*/}/workload.sh"
                found_workloads=true
            fi
            if [[ -f "$superpi_script" ]]; then
                echo "  ./${dir##*/}/superpi.sh"
                found_workloads=true
            fi
        fi
    done
    
    if [[ "$found_workloads" == false ]]; then
        echo "  No workload scripts found in subdirectories"
    fi
}

get_core_list() {
    local core_list=()
    
    if [[ -n "$specific_nproc" ]]; then
        if [[ $specific_nproc -gt $total_cores ]]; then
            error_exit "Specified nproc ($specific_nproc) exceeds available cores ($total_cores)"
        fi
        core_list=($specific_nproc)
    else
        for ((i=cores_step; i<=total_cores; i+=cores_step)); do
            core_list+=($i)
        done
        
        # Always include max cores if not already included
        if [[ $((total_cores % cores_step)) -ne 0 ]]; then
            core_list+=($total_cores)
        fi
    fi
    
    echo "${core_list[@]}"
}

create_system_info_file() {
    local output_dir="$1"
    local cores="$2"
    local system_info_file="$output_dir/system_info.txt"
    
    cat > "$system_info_file" << EOF
# System Configuration
timestamp: "$(date '+%Y-%m-%d %H:%M:%S')"
hostname: "$(hostname)"
bios_version: "$bios_version"
microcode: "$microcode"
operating_system: "$operating_system"
kernel: "$kernel_version"
cpu_model: "$cpu_model_name"
total_cores: $total_cores
total_sockets: $total_sockets
numa_nodes: $total_numa_nodes
test_cores: $cores
workload_script: "$script_path"
script_args: "$script_args"
EOF

    if [[ "$enable_emon" == true ]]; then
        cat >> "$system_info_file" << EOF
emon_user: "$emon_user"
emon_group: "$emon_group"
emon_session: "$emon_session"
emon_server: "$emon_server"
EOF
    fi
}

create_workload_result_file() {
    local output_dir="$1"
    local cores="$2"
    local performance_result="$3"
    local workload_result_file="$output_dir/workload_result.txt"
    
    cat > "$workload_result_file" << EOF
workload_name:"$workload_name"
metric_type:"$metric_type"
result:"$performance_result"
metric:"$metric_unit"
num_instances:1
sockets:$total_sockets
cores_used:$cores
total_cores:$total_cores
notes:"Core scaling test with $cores cores using $(basename "$script_path")"
test_date:"$(date '+%Y-%m-%d %H:%M:%S')"
hostname:"$(hostname)"
EOF
}

parse_performance_output() {
    local output_file="$1"
    
    if [[ ! -f "$output_file" ]]; then
        echo "N/A"
        return
    fi
    
    local content=$(cat "$output_file")
    
    # Pattern 1: "Performance: 1234.56 seconds"
    local perf_match=$(echo "$content" | grep -i "performance:" | head -1 | sed 's/.*performance:[[:space:]]*\([0-9.]*\).*/\1/')
    if [[ -n "$perf_match" && "$perf_match" =~ ^[0-9.]+$ ]]; then
        echo "$perf_match"
        return
    fi
    
    # Pattern 2: "Throughput: 1234.56"
    local throughput_match=$(echo "$content" | grep -i "throughput:" | head -1 | sed 's/.*throughput:[[:space:]]*\([0-9.]*\).*/\1/')
    if [[ -n "$throughput_match" && "$throughput_match" =~ ^[0-9.]+$ ]]; then
        echo "$throughput_match"
        return
    fi
    
    # Pattern 3: CSV format - look for Score column
    local csv_match=$(echo "$content" | grep "," | grep -v "Date,Workload" | head -1 | cut -d',' -f6)
    if [[ -n "$csv_match" && "$csv_match" =~ ^[0-9.]+$ ]]; then
        echo "$csv_match"
        return
    fi
    
    echo "N/A"
}

debug_script_info() {
    echo "=" * 50
    echo "SCRIPT DEBUG INFORMATION"
    echo "=" * 50
    echo "Script path (input): $script_path"
    echo "Script path (resolved): $(readlink -f "$script_path")"
    echo "Script exists: $(if [[ -f "$script_path" ]]; then echo "true"; else echo "false"; fi)"
    
    if [[ -f "$script_path" ]]; then
        echo "Script permissions: $(ls -la "$script_path" | awk '{print $1}')"
        echo "Script is executable: $(if [[ -x "$script_path" ]]; then echo "true"; else echo "false"; fi)"
        echo "Script size: $(stat -c%s "$script_path") bytes"
        
        # Check shebang
        local first_line=$(head -1 "$script_path")
        echo "First line (shebang): $first_line"
    else
        echo "Script file does not exist!"
        
        # Suggest available scripts
        local parent_dir=$(dirname "$script_path")
        if [[ -d "$parent_dir" ]]; then
            echo ""
            echo "Files in $parent_dir:"
            find "$parent_dir" -maxdepth 1 -name "*.sh" -o -name "*.py" | while read -r file; do
                echo "  $(basename "$file")"
            done
        fi
    fi
    echo "=" * 50
}

run_workload_with_cores() {
    local cores="$1"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local workload_basename=$(basename "$(dirname "$script_path")")
    local run_id="${workload_basename}_${cores}cores_${timestamp}"
    local output_dir="$emon_output_dir/$run_id"
    
    echo "=================================================="
    echo "Running $workload_basename with $cores cores"
    echo "Output directory: $output_dir"
    echo "=================================================="
    
    # Create output directory
    if [[ "$dry_run" == false ]]; then
        mkdir -p "$output_dir"
        create_system_info_file "$output_dir" "$cores"
    fi
    
    # Prepare workload command
    local script_abs_path=$(readlink -f "$script_path")
    local workload_cmd="$script_abs_path --cpu-cores 0-$((cores-1))"
    
    # Add additional script arguments if provided
    if [[ -n "$script_args" ]]; then
        workload_cmd="$workload_cmd $script_args"
    fi
    
    local output_file="$output_dir/workload_output.log"
    local exit_code=0
    
    if [[ "$enable_emon" == true ]]; then
        # TMC command
        local tmc_cmd="python3 /root/tmc/tmc.py -c \"$workload_cmd\" -d \"$(readlink -f "$output_dir")\" -n"
        
        # Add optional parameters only if provided
        if [[ -n "$emon_user" ]]; then
            tmc_cmd="$tmc_cmd -x \"$emon_user\""
        fi
        
        if [[ -n "$emon_group" ]]; then
            tmc_cmd="$tmc_cmd -G \"$emon_group\""
        fi
        
        if [[ -n "$emon_session" ]]; then
            tmc_cmd="$tmc_cmd -i \"${emon_session}_${cores}cores\""
        fi
        
        if [[ $emon_duration -gt 0 ]]; then
            tmc_cmd="$tmc_cmd -t $emon_duration"
        fi
        
        tmc_cmd="$tmc_cmd -w \"$emon_chart_views\""
        
        echo "TMC Command: $tmc_cmd"
        
        if [[ "$dry_run" == false ]]; then
            echo "Executing with TMC/EMON..."
            
            # Check if TMC script exists
            if [[ ! -f "/root/tmc/tmc.py" ]]; then
                echo "Error: TMC script not found at /root/tmc/tmc.py"
                echo "Please check TMC installation path"
                return 1
            fi
            
            # Check if workload script exists and is executable
            if [[ ! -f "$script_abs_path" ]]; then
                echo "Error: Workload script not found at $script_abs_path"
                return 1
            fi
            
            if [[ ! -x "$script_abs_path" ]]; then
                echo "Error: Workload script is not executable: $script_abs_path"
                echo "Try: chmod +x $script_abs_path"
                return 1
            fi
            
            if eval "$tmc_cmd" > "$output_file" 2>&1; then
                exit_code=0
            else
                exit_code=$?
            fi
        else
            echo "DRY RUN: Would execute TMC command above"
            exit_code=0
        fi
    else
        # Direct workload execution
        echo "Workload Command: $workload_cmd"
        
        if [[ "$dry_run" == false ]]; then
            echo "Executing workload directly..."
            
            # Check if workload script exists and is executable
            if [[ ! -f "$script_abs_path" ]]; then
                echo "Error: Workload script not found at $script_abs_path"
                return 1
            fi
            
            if [[ ! -x "$script_abs_path" ]]; then
                echo "Error: Workload script is not executable: $script_abs_path"
                echo "Try: chmod +x $script_abs_path"
                return 1
            fi
            
            if eval "$workload_cmd" > "$output_file" 2>&1; then
                exit_code=0
            else
                exit_code=$?
            fi
        else
            echo "DRY RUN: Would execute workload command above"
            exit_code=0
        fi
    fi
    
    # Process results if not dry run
    if [[ "$dry_run" == false && $exit_code -eq 0 ]]; then
        if [[ "$enable_emon" == true ]]; then
            # Parse performance output and create workload result file
            local perf_result=$(parse_performance_output "$output_file")
            create_workload_result_file "$output_dir" "$cores" "$perf_result"
            echo "Performance result: $perf_result $metric_unit"
        fi
        echo "Results saved to: $output_dir"
    elif [[ "$dry_run" == false ]]; then
        echo "Warning: Workload execution failed with exit code $exit_code"
        if [[ $exit_code -eq 126 ]]; then
            echo "Exit code 126 usually means 'Permission denied' or 'Command not executable'"
            echo "Check if the script is executable: ls -la $script_abs_path"
            echo "Make it executable with: chmod +x $script_abs_path"
        elif [[ $exit_code -eq 127 ]]; then
            echo "Exit code 127 usually means 'Command not found'"
            echo "Check if the script path is correct: $script_abs_path"
        fi
    fi
    
    echo ""
}

set_performance_governor() {
    if [[ "$dry_run" == true ]]; then
        echo "DRY RUN: Would set CPU governor to performance"
        return
    fi
    
    log "Setting CPU governor to performance..."
    
    local cpu_dirs=(/sys/devices/system/cpu/cpu[0-9]*)
    for cpu_dir in "${cpu_dirs[@]}"; do
        local governor_file="$cpu_dir/cpufreq/scaling_governor"
        if [[ -f "$governor_file" ]]; then
            echo "performance" > "$governor_file" 2>/dev/null || true
        fi
    done
    
    log "CPU governor set to performance"
}

# ------------------------------ ARGUMENT PARSING -----------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--script)
            script_path="$2"
            shift 2
            ;;
        -c|--cores)
            cores_step="$2"
            shift 2
            ;;
        -n|--nproc)
            specific_nproc="$2"
            shift 2
            ;;
        -r|--dry-run)
            dry_run=true
            shift
            ;;
        -e|--emon)
            enable_emon=true
            shift
            ;;
        --emon-user)
            emon_user="$2"
            shift 2
            ;;
        --emon-group)
            emon_group="$2"
            shift 2
            ;;
        --emon-server)
            emon_server="$2"
            shift 2
            ;;
        --emon-session)
            emon_session="$2"
            shift 2
            ;;
        --workload-name)
            workload_name="$2"
            shift 2
            ;;
        --metric-type)
            metric_type="$2"
            shift 2
            ;;
        --metric-unit)
            metric_unit="$2"
            shift 2
            ;;
        --script-args)
            script_args="$2"
            shift 2
            ;;
        --emon-duration)
            emon_duration="$2"
            shift 2
            ;;
        --emon-chart-views)
            emon_chart_views="$2"
            shift 2
            ;;
        --emon-output-dir)
            emon_output_dir="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            error_exit "Unknown option: $1"
            ;;
    esac
done

# ------------------------------ MAIN EXECUTION -----------------------------------

# Validation
if [[ -z "$script_path" ]]; then
    error_exit "--script parameter is required. Use --help for usage information."
fi

validate_script

if [[ "$enable_emon" == true ]]; then
    validate_emon_params
fi

if [[ $cores_step -le 0 ]]; then
    error_exit "Core stepping size must be positive"
fi

if [[ -n "$specific_nproc" && $specific_nproc -le 0 ]]; then
    error_exit "nproc value must be positive"
fi

# Get system information
get_system_info

# Debug information in dry run mode
if [[ "$dry_run" == true ]]; then
    debug_script_info
fi

# Print execution info
echo "============================================================"
echo "WORKLOAD WRAPPER SCRIPT (BASH VERSION)"
echo "============================================================"
echo "Script: $script_path"
echo "Mode: $(if [[ "$dry_run" == true ]]; then echo "DRY RUN"; else echo "EXECUTION"; fi)"
echo "EMON: $(if [[ "$enable_emon" == true ]]; then echo "ENABLED"; else echo "DISABLED"; fi)"
echo "System: $total_cores cores, $total_sockets sockets, $total_numa_nodes NUMA nodes"

if [[ -n "$script_args" ]]; then
    echo "Script Args: $script_args"
fi

if [[ "$enable_emon" == true ]]; then
    echo "EMON User: $emon_user"
    echo "EMON Group: $emon_group"
    echo "EMON Session: $emon_session"
    echo "Workload: $workload_name"
    echo "Metric: $metric_unit"
fi

echo "============================================================"
echo ""

# Get list of core counts to test
core_list=($(get_core_list))
echo "Testing with core counts: ${core_list[*]}"
echo ""

# Set performance governor
set_performance_governor

# Run workload for each core count
for cores in "${core_list[@]}"; do
    run_workload_with_cores "$cores"
done

echo "============================================================"
echo "WORKLOAD WRAPPER EXECUTION COMPLETED"
echo "============================================================"

if [[ "$dry_run" == false ]]; then
    echo "Results directory: $emon_output_dir"
    if [[ "$enable_emon" == true ]]; then
        echo ""
        echo "Generated files per run:"
        echo "  - workload_result.txt (performance metrics)"
        echo "  - system_info.txt (system configuration)"
        echo "  - workload_output.log (execution log)"
        echo "  - EMON traces (if TMC enabled)"
    fi
fi
