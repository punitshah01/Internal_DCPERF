#!/bin/bash

# =============================================================================
# MAIN WORKLOAD WRAPPER SCRIPT
# =============================================================================
# This script orchestrates different workload scripts with core scaling,
# TMC/EMON integration, and workload results generation
# =============================================================================

abs_dir=$(dirname $(realpath $0))

# ------------------------------  SYSTEM PARAMS -----------------------------------
bios=$(dmidecode -t bios | grep Version | awk '{print $2}')
microcode=$(grep micro /proc/cpuinfo | uniq | awk '{print $3}')
operating_system=$(awk -F '"' '/PRETTY_NAME=/{print $2}' /etc/os-release)
kernel=$(uname -r)
procs=$(cat /proc/cpuinfo | grep -c processor)
cores_per_socket=$(lscpu | awk '/Core\(s\) per socket:/{print $NF}')
total_sockets=$(lscpu | awk '/Socket\(s\):/{print $NF}')
total_cores=$((cores_per_socket*total_sockets))
model=$(lscpu | awk '/Model:/{print $NF}')
family=$(lscpu | awk '/CPU family:/{print $NF}')
stepping=$(lscpu | awk '/Stepping:/{print $NF}')
total_numa_nodes=$(lscpu | awk  '/NUMA node\(s\):/{print $NF}')
cpu_model_name=$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')

# ------------------------------ DEFAULT VALUES -----------------------------------
DEFAULT_CORES_STEP=4
DEFAULT_METRIC_TYPE="Throughput"
DEFAULT_EMON_CHART_VIEWS="core,socket"
DEFAULT_EMON_OUTPUT_DIR="./emon_traces"
DEFAULT_EMON_DURATION=0

# ------------------------------ VARIABLES -----------------------------------
script_path=""
cores_step=$DEFAULT_CORES_STEP
specific_nproc=""
dry_run=1  # 1 = dry run (default), 0 = actual execution
enable_emon=0
script_args=""

# EMON/TMC Variables
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

# ------------------------------ FUNCTIONS -----------------------------------
print_usage(){
    echo -e "
Usage: $0 [OPTIONS]

REQUIRED:
  -s, --script PATH           Path to workload script to execute (REQUIRED)

CORE SCALING:
  -c, --cores N              Core stepping size (default: $DEFAULT_CORES_STEP)
  -n, --nproc N              Run only with specific nproc value (overrides stepping)
  -r, --run                  Execute commands (default: dry-run mode)

TMC/EMON INTEGRATION:
  -e, --emon                 Enable TMC/EMON integration (default: disabled)
  --emon-user USER           TMC username (required if --emon)
  --emon-group GROUP         TMC group name (required if --emon)
  --emon-session SESSION     TMC session identifier (required if --emon)
  --emon-server SERVER       Server identifier (required if --emon)

WORKLOAD RESULTS:
  --workload-name NAME       Workload name for results file (required if --emon)
  --metric-type TYPE         Metric type: Throughput/Latency/etc (default: $DEFAULT_METRIC_TYPE)
  --metric-unit UNIT         Metric unit: ops/s, ms, GFLOPS, etc (required if --emon)

SCRIPT PARAMETERS:
  --script-args \"ARGS\"       Additional arguments to pass to workload script

TMC OPTIONAL:
  --emon-duration SEC        Collection duration in seconds (default: $DEFAULT_EMON_DURATION = until completion)
  --emon-chart-views VIEWS   Chart views (default: $DEFAULT_EMON_CHART_VIEWS)
  --emon-output-dir DIR      Base output directory (default: $DEFAULT_EMON_OUTPUT_DIR)

EXAMPLES:
  # Basic dry run
  $0 --script ./benchmarks/spec_cpu.sh --cores 8

  # Actual execution with specific nproc
  $0 --script ./benchmarks/ml_training.sh --nproc 32 --run

  # Full TMC integration
  $0 --script ./benchmarks/hpc_workload.sh --cores 4 --emon \\
     --emon-user john --emon-group scaling_test --emon-session \"hpc_scaling\" \\
     --emon-server cluster01 --workload-name \"HPC Benchmark\" --metric-unit \"GFLOPS\" --run

  # With script arguments
  $0 --script ./benchmarks/database.sh --cores 8 --script-args \"--batch-size 1000 --threads 16\" --run
"
}

validate_emon_params(){
    local missing_params=()
    
    if [[ -z "$emon_user" ]]; then missing_params+=("--emon-user"); fi
    if [[ -z "$emon_group" ]]; then missing_params+=("--emon-group"); fi
    if [[ -z "$emon_session" ]]; then missing_params+=("--emon-session"); fi
    if [[ -z "$emon_server" ]]; then missing_params+=("--emon-server"); fi
    if [[ -z "$workload_name" ]]; then missing_params+=("--workload-name"); fi
    if [[ -z "$metric_unit" ]]; then missing_params+=("--metric-unit"); fi
    
    if [[ ${#missing_params[@]} -gt 0 ]]; then
        echo "Error: EMON enabled but missing required parameters: ${missing_params[*]}"
        echo "Use --help for usage information"
        exit 1
    fi
}

validate_script(){
    if [[ -z "$script_path" ]]; then
        echo "Error: --script parameter is required"
        print_usage
        exit 1
    fi
    
    if [[ ! -f "$script_path" ]]; then
        echo "Error: Script file '$script_path' not found"
        exit 1
    fi
    
    if [[ ! -x "$script_path" ]]; then
        echo "Error: Script file '$script_path' is not executable"
        exit 1
    fi
}

get_core_list(){
    if [[ -n "$specific_nproc" ]]; then
        if [[ $specific_nproc -gt $total_cores ]]; then
            echo "Error: Specified nproc ($specific_nproc) exceeds available cores ($total_cores)"
            exit 1
        fi
        echo "$specific_nproc"
    else
        local core_list=""
        for ((i=cores_step; i<=total_cores; i+=cores_step)); do
            core_list="$core_list $i"
        done
        # Always include max cores if not already included
        if [[ $((total_cores % cores_step)) -ne 0 ]]; then
            core_list="$core_list $total_cores"
        fi
        echo "$core_list"
    fi
}

create_system_info_file(){
    local output_dir=$1
    local cores=$2
    
    cat > "$output_dir/system_info.txt" << EOF
# System Configuration
timestamp: "$(date '+%Y-%m-%d %H:%M:%S')"
hostname: "$(hostname)"
bios_version: "$bios"
microcode: "$microcode"
operating_system: "$operating_system"
kernel: "$kernel"
cpu_model: "$cpu_model_name"
cpu_family: "$family"
cpu_model_num: "$model"
cpu_stepping: "$stepping"
total_cores: $total_cores
cores_per_socket: $cores_per_socket
total_sockets: $total_sockets
numa_nodes: $total_numa_nodes
test_cores: $cores
workload_script: "$script_path"
script_args: "$script_args"
EOF

    if [[ $enable_emon -eq 1 ]]; then
        cat >> "$output_dir/system_info.txt" << EOF
emon_user: "$emon_user"
emon_group: "$emon_group"
emon_session: "$emon_session"
emon_server: "$emon_server"
EOF
    fi
}

create_workload_result_file(){
    local output_dir=$1
    local cores=$2
    local performance_result=$3
    
    cat > "$output_dir/workload_result.txt" << EOF
workload_name:"$workload_name"
metric_type:"$metric_type"
result:"$performance_result"
metric:"$metric_unit"
num_instances:1
sockets:$total_sockets
cores_used:$cores
total_cores:$total_cores
notes:"Core scaling test with $cores cores using $(basename $script_path)"
test_date:"$(date '+%Y-%m-%d %H:%M:%S')"
hostname:"$(hostname)"
EOF
}

parse_performance_output(){
    local output_file=$1
    # This function should be customized based on your workload output format
    # For now, it looks for common performance patterns
    
    # Try to extract performance numbers from common patterns
    local perf_value=""
    
    # Pattern 1: "Performance: 1234.56 ops/s"
    perf_value=$(grep -i "performance:" "$output_file" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    
    # Pattern 2: "Throughput: 1234.56"
    if [[ -z "$perf_value" ]]; then
        perf_value=$(grep -i "throughput:" "$output_file" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    fi
    
    # Pattern 3: "Rate: 1234.56"
    if [[ -z "$perf_value" ]]; then
        perf_value=$(grep -i "rate:" "$output_file" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    fi
    
    # Pattern 4: Look for SPEC-like output "SPECrate2017_*_base,1234.56"
    if [[ -z "$perf_value" ]]; then
        perf_value=$(grep -E "SPEC.*rate.*base" "$output_file" | awk -F',' '{print $NF}' | head -1)
    fi
    
    # Default if nothing found
    if [[ -z "$perf_value" ]]; then
        perf_value="N/A"
    fi
    
    echo "$perf_value"
}

run_workload_with_cores(){
    local cores=$1
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local run_id="${workload_name// /_}_${cores}cores_${timestamp}"
    local output_dir="$emon_output_dir/$run_id"
    
    echo "=========================================="
    echo "Running with $cores cores"
    echo "Output directory: $output_dir"
    echo "=========================================="
    
    # Create output directory
    mkdir -p "$output_dir"
    
    # Create system info file
    create_system_info_file "$output_dir" "$cores"
    
    # Prepare workload command
    local workload_cmd="$script_path --cores $cores $script_args"
    local output_file="$output_dir/workload_output.log"
    
    if [[ $enable_emon -eq 1 ]]; then
        # TMC command
        local tmc_cmd="tmc.py -x \"$emon_user\" -G \"$emon_group\" -i \"${emon_session}_${cores}cores\" -c \"$workload_cmd\" -d \"$output_dir\" -n"
        
        if [[ $emon_duration -gt 0 ]]; then
            tmc_cmd="$tmc_cmd -t $emon_duration"
        fi
        
        tmc_cmd="$tmc_cmd -w \"$emon_chart_views\""
        
        echo "TMC Command: $tmc_cmd"
        
        if [[ $dry_run -eq 0 ]]; then
            echo "Executing with TMC/EMON..."
            eval "$tmc_cmd" 2>&1 | tee "$output_file"
            local exit_code=${PIPESTATUS[0]}
        else
            echo "DRY RUN: Would execute TMC command above"
            local exit_code=0
        fi
    else
        # Direct workload execution
        echo "Workload Command: $workload_cmd"
        
        if [[ $dry_run -eq 0 ]]; then
            echo "Executing workload directly..."
            eval "$workload_cmd" 2>&1 | tee "$output_file"
            local exit_code=${PIPESTATUS[0]}
        else
            echo "DRY RUN: Would execute workload command above"
            local exit_code=0
        fi
    fi
    
    # Process results if not dry run
    if [[ $dry_run -eq 0 && $exit_code -eq 0 ]]; then
        if [[ $enable_emon -eq 1 ]]; then
            # Parse performance output and create workload result file
            local perf_result=$(parse_performance_output "$output_file")
            create_workload_result_file "$output_dir" "$cores" "$perf_result"
            echo "Performance result: $perf_result $metric_unit"
        fi
        echo "Results saved to: $output_dir"
    elif [[ $dry_run -eq 0 ]]; then
        echo "Warning: Workload execution failed with exit code $exit_code"
    fi
    
    echo ""
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
        -r|--run)
            dry_run=0
            shift
            ;;
        -e|--emon)
            enable_emon=1
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
        --emon-session)
            emon_session="$2"
            shift 2
            ;;
        --emon-server)
            emon_server="$2"
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
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# ------------------------------ VALIDATION -----------------------------------
validate_script

if [[ $enable_emon -eq 1 ]]; then
    validate_emon_params
fi

if [[ $cores_step -le 0 ]]; then
    echo "Error: Core stepping size must be positive"
    exit 1
fi

if [[ -n "$specific_nproc" && $specific_nproc -le 0 ]]; then
    echo "Error: nproc value must be positive"
    exit 1
fi

# ------------------------------ EXECUTION -----------------------------------
echo "============================================="
echo "WORKLOAD WRAPPER SCRIPT"
echo "============================================="
echo "Script: $script_path"
echo "Mode: $([ $dry_run -eq 1 ] && echo "DRY RUN" || echo "EXECUTION")"
echo "EMON: $([ $enable_emon -eq 1 ] && echo "ENABLED" || echo "DISABLED")"
echo "System: $total_cores cores, $total_sockets sockets, $total_numa_nodes NUMA nodes"

if [[ -n "$script_args" ]]; then
    echo "Script Args: $script_args"
fi

if [[ $enable_emon -eq 1 ]]; then
    echo "EMON User: $emon_user"
    echo "EMON Group: $emon_group"
    echo "EMON Session: $emon_session"
    echo "Workload: $workload_name"
    echo "Metric: $metric_unit"
fi

echo "============================================="
echo ""

# Get list of core counts to test
core_list=$(get_core_list)
echo "Testing with core counts: $core_list"
echo ""

# Set performance governor
echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null 2>&1

# Run workload for each core count
for cores in $core_list; do
    run_workload_with_cores "$cores"
done

echo "============================================="
echo "WORKLOAD WRAPPER EXECUTION COMPLETED"
echo "============================================="

if [[ $dry_run -eq 0 ]]; then
    echo "Results directory: $emon_output_dir"
    if [[ $enable_emon -eq 1 ]]; then
        echo ""
        echo "Generated files per run:"
        echo "  - workload_result.txt (performance metrics)"
        echo "  - system_info.txt (system configuration)"
        echo "  - workload_output.log (execution log)"
        echo "  - EMON traces (if TMC enabled)"
    fi
fi
