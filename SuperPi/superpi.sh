#!/bin/bash
# superpi.sh - Super Pi benchmark script with EMON support

# =============================================================================
# SUPER PI WORKLOAD SCRIPT
# =============================================================================
# This script runs Super Pi benchmarks with configurable core counts
# Compatible with the main wrapper script and supports direct EMON integration
# =============================================================================

# ------------------------------ DEFAULT VALUES -----------------------------------
DEFAULT_SCALE=5000
DEFAULT_RUNS=1

# Default EMON/TMC values
DEFAULT_EMON_USER="pshah"
DEFAULT_EMON_SERVER="metrics2"
DEFAULT_EMON_GROUP="superpi"
DEFAULT_TMC_PATH="/root/tmc/tmc.py"

# ------------------------------ VARIABLES -----------------------------------
cores=""
cpu_cores=""  # For wrapper compatibility
scale=$DEFAULT_SCALE
runs=$DEFAULT_RUNS
metric_collection="none"  # none, emon
custom_name=""

# EMON/TMC Variables with defaults
enable_emon=false
emon_user=$DEFAULT_EMON_USER
emon_server=$DEFAULT_EMON_SERVER
emon_group=$DEFAULT_EMON_GROUP
emon_session=""
emon_duration=0
emon_chart_views="core,socket"
emon_output_dir="./emon_traces"
tmc_path=$DEFAULT_TMC_PATH

# Get script directory for output files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="$SCRIPT_DIR/results.csv"

# ------------------------------ FUNCTIONS -----------------------------------
print_usage(){
    echo -e "
Usage: $0 --cores N [OPTIONS]
   or: $0 --cpu-cores RANGE [OPTIONS]  (for wrapper compatibility)

REQUIRED:
  --cores N              Number of cores to use (REQUIRED)
  --cpu-cores RANGE      CPU core range (e.g., 0-7 or 0,2,4) - wrapper format

OPTIONAL:
  --scale N              Pi calculation scale (default: $DEFAULT_SCALE)
  --runs N               Number of test runs (default: $DEFAULT_RUNS)
  --name NAME            Custom name prefix for logs

EMON INTEGRATION:
  --emon                 Enable EMON monitoring (default: disabled)
  --emon-user USER       EMON username (default: $DEFAULT_EMON_USER)
  --emon-server SERVER   EMON server (default: $DEFAULT_EMON_SERVER)
  --emon-group GROUP     EMON group (default: $DEFAULT_EMON_GROUP)
  --emon-session SESSION EMON session identifier (required if --emon)
  --emon-duration SEC    Collection duration in seconds (default: 0 = until completion)
  --emon-chart-views V   Chart views (default: core,socket)
  --emon-output-dir DIR  EMON output directory (default: ./emon_traces)
  --tmc-path PATH        Path to TMC script (default: $DEFAULT_TMC_PATH)

LEGACY SUPPORT:
  --metric TYPE          Legacy metric collection: none/emon (default: none)
                        Note: Use --emon instead

EXAMPLES:
  # Basic usage
  $0 --cores 8 --scale 5000 --runs 3
  
  # With EMON monitoring
  $0 --cores 8 --emon --emon-session \"superpi_test\"
  
  # Wrapper compatibility
  $0 --cpu-cores 0-7 --name custom_test
  
  # Full EMON configuration
  $0 --cores 16 --emon --emon-session \"performance_test\" \\
     --emon-user john --emon-group testing --emon-duration 300
"
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Parse CPU cores range to get core count
parse_cpu_cores() {
    local cpu_range="$1"
    
    if [[ "$cpu_range" =~ ^[0-9]+-[0-9]+$ ]]; then
        # Range format: 0-7
        local start=$(echo "$cpu_range" | cut -d'-' -f1)
        local end=$(echo "$cpu_range" | cut -d'-' -f2)
        cores=$((end - start + 1))
    elif [[ "$cpu_range" =~ ^[0-9,]+$ ]]; then
        # List format: 0,2,4,6
        cores=$(echo "$cpu_range" | tr ',' '\n' | wc -l)
    else
        error_exit "Invalid CPU cores format: $cpu_range. Use format like '0-7' or '0,2,4,6'"
    fi
}

validate_emon_params() {
    if [[ "$enable_emon" == true ]]; then
        if [[ -z "$emon_session" ]]; then
            error_exit "EMON enabled but --emon-session is required"
        fi
        
        if [[ ! -f "$tmc_path" ]]; then
            error_exit "TMC script not found at: $tmc_path"
        fi
        
        if [[ ! -x "$tmc_path" ]]; then
            error_exit "TMC script is not executable: $tmc_path"
        fi
    fi
}

setup_system() {
    log "Setting up system for Super Pi benchmark..."
    
    # Check if bc is available
    if ! command -v bc >/dev/null 2>&1; then
        error_exit "bc command not found. Please install bc package."
    fi
    
    # Check if taskset is available
    if ! command -v taskset >/dev/null 2>&1; then
        error_exit "taskset command not found. Please install util-linux package."
    fi
    
    # Create results directory
    mkdir -p "$SCRIPT_DIR/result"
    
    # Create EMON output directory if EMON is enabled
    if [[ "$enable_emon" == true ]]; then
        mkdir -p "$emon_output_dir"
    fi
}

start_emon_collection() {
    local session_name="$1"
    local output_dir="$2"
    
    if [[ "$enable_emon" != true ]]; then
        return 0
    fi
    
    log "Starting EMON collection for session: $session_name"
    
    # Build TMC command
    local tmc_cmd="python3 $tmc_path -c \"echo 'EMON_PLACEHOLDER'\" -d \"$output_dir\" -n"
    
    if [[ -n "$emon_user" ]]; then
        tmc_cmd="$tmc_cmd -x \"$emon_user\""
    fi
    
    if [[ -n "$emon_group" ]]; then
        tmc_cmd="$tmc_cmd -G \"$emon_group\""
    fi
    
    if [[ -n "$emon_session" ]]; then
        tmc_cmd="$tmc_cmd -i \"$session_name\""
    fi
    
    if [[ $emon_duration -gt 0 ]]; then
        tmc_cmd="$tmc_cmd -t $emon_duration"
    fi
    
    tmc_cmd="$tmc_cmd -w \"$emon_chart_views\""
    
    if [[ -n "$emon_server" ]]; then
        tmc_cmd="$tmc_cmd -Z \"$emon_server\""
    fi
    
    log "EMON Command: $tmc_cmd"
    
    # Start EMON in background
    eval "$tmc_cmd" &
    local emon_pid=$!
    
    # Give EMON time to start
    sleep 3
    
    echo "$emon_pid"
}

stop_emon_collection() {
    local emon_pid="$1"
    
    if [[ "$enable_emon" != true || -z "$emon_pid" ]]; then
        return 0
    fi
    
    log "Stopping EMON collection (PID: $emon_pid)"
    
    # Give EMON time to collect final data
    sleep 2
    
    # Stop EMON gracefully
    if kill -TERM "$emon_pid" 2>/dev/null; then
        # Wait for graceful shutdown
        local count=0
        while kill -0 "$emon_pid" 2>/dev/null && [[ $count -lt 10 ]]; do
            sleep 1
            ((count++))
        done
        
        # Force kill if still running
        if kill -0 "$emon_pid" 2>/dev/null; then
            kill -KILL "$emon_pid" 2>/dev/null || true
        fi
    fi
    
    wait "$emon_pid" 2>/dev/null || true
    log "EMON collection stopped"
}

run_single_pi_calculation() {
    local core_id=$1
    local output_file=$2
    local scale=$3
    
    # Run pi calculation on specific core and capture time
    { time -p echo "scale=$scale; 4*a(1)" | taskset -c $core_id bc -l -q; } 2>&1 | \
    grep real | awk '{print $NF}' > "$output_file"
}

parse_superpi_results() {
    local results_dir=$1
    local cores=$2
    local test_type=$3
    
    local total_time=0
    local avg_time=0
    local max_time=0
    local min_time=999999
    
    if [[ "$test_type" == "single" ]]; then
        # Single core test
        local time_file="$results_dir/single_core.log"
        if [[ -f "$time_file" ]]; then
            avg_time=$(cat "$time_file")
        else
            avg_time="N/A"
        fi
    else
        # Multi-core test - calculate average
        local valid_results=0
        for ((i=0; i<cores; i++)); do
            local core_file="$results_dir/core${i}.log"
            if [[ -f "$core_file" ]]; then
                local core_time=$(cat "$core_file")
                if [[ "$core_time" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    total_time=$(echo "scale=3; $total_time + $core_time" | bc)
                    valid_results=$((valid_results + 1))
                    
                    # Track min/max
                    if (( $(echo "$core_time > $max_time" | bc -l) )); then
                        max_time=$core_time
                    fi
                    if (( $(echo "$core_time < $min_time" | bc -l) )); then
                        min_time=$core_time
                    fi
                fi
            fi
        done
        
        if [[ $valid_results -gt 0 ]]; then
            avg_time=$(echo "scale=3; $total_time / $valid_results" | bc)
        else
            avg_time="N/A"
        fi
    fi
    
    # Output in parseable format for wrapper
    echo "Performance: $avg_time seconds"
    echo "Throughput: $avg_time seconds"
    echo "Test_Type: $test_type"
    echo "Cores_Used: $cores"
    echo "Scale: $scale"
    
    if [[ "$test_type" != "single" && "$max_time" != "0" ]]; then
        echo "Max_Time: $max_time seconds"
        echo "Min_Time: $min_time seconds"
    fi
    
    # Create CSV output
    create_csv_output "$cores" "$avg_time" "$test_type"
    
    # Return the average time for EMON integration
    echo "$avg_time"
}

create_system_info_file() {
    local output_dir="$1"
    local cores="$2"
    local system_info_file="$output_dir/system_info.txt"
    
    cat > "$system_info_file" << EOF
# System Configuration
timestamp: "$(date '+%Y-%m-%d %H:%M:%S')"
hostname: "$(hostname)"
total_cores: $(nproc)
test_cores: $cores
workload_script: "$0"
scale: $scale
runs: $runs
emon_enabled: $enable_emon
EOF

    if [[ "$enable_emon" == true ]]; then
        cat >> "$system_info_file" << EOF
emon_user: "$emon_user"
emon_group: "$emon_group"
emon_session: "$emon_session"
emon_server: "$emon_server"
emon_duration: $emon_duration
emon_chart_views: "$emon_chart_views"
EOF
    fi
}

create_workload_result_file() {
    local output_dir="$1"
    local cores="$2"
    local performance_result="$3"
    local workload_result_file="$output_dir/workload_result.txt"
    
    cat > "$workload_result_file" << EOF
workload_name:"Super Pi"
metric_type:"Latency"
result:"$performance_result"
metric:"seconds"
num_instances:1
cores_used:$cores
test_date:"$(date '+%Y-%m-%d %H:%M:%S')"
hostname:"$(hostname)"
scale:$scale
test_type:"pi_calculation"
EOF
}

run_superpi_benchmark() {
    local cores=$1
    local run_number=$2
    
    echo "=========================================="
    echo "Super Pi Benchmark Run $run_number"
    echo "Cores: $cores"
    echo "Scale: $scale"
    echo "EMON: $(if [[ "$enable_emon" == true ]]; then echo "ENABLED"; else echo "DISABLED"; fi)"
    echo "=========================================="
    
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local session_name="${custom_name:-SUPERPI}_${cores}cores_scale${scale}_run${run_number}"
    
    local results_dir="$SCRIPT_DIR/result/pi_${timestamp}"
    local emon_output=""
    local emon_pid=""
    
    # Setup EMON output directory if enabled
    if [[ "$enable_emon" == true ]]; then
        emon_output="$emon_output_dir/${session_name}"
        mkdir -p "$emon_output"
        create_system_info_file "$emon_output" "$cores"
        
        # Start EMON collection
        emon_pid=$(start_emon_collection "$session_name" "$emon_output")
    fi
    
    local test_dir=""
    local avg_time=""
    
    if [[ $cores -eq 1 ]]; then
        test_dir="$results_dir/single_core"
        mkdir -p "$test_dir"
        
        echo "Running Super Pi with single core..."
        
        # Run single core calculation
        run_single_pi_calculation 0 "$test_dir/single_core.log" "$scale"
        
        echo "Single core test completed"
        avg_time=$(parse_superpi_results "$test_dir" 1 "single")
        
    else
        test_dir="$results_dir/multi_cores"
        mkdir -p "$test_dir"
        
        echo "Running Super Pi with $cores cores..."
        
        # Run calculations on all cores in parallel
        local pids=()
        for ((i=0; i<cores; i++)); do
            run_single_pi_calculation $i "$test_dir/core${i}.log" "$scale" &
            pids[$i]=$!
        done
        
        # Wait for all calculations to complete
        for pid in "${pids[@]}"; do
            wait $pid
        done
        
        echo "Multi-core test completed"
        avg_time=$(parse_superpi_results "$test_dir" "$cores" "multi")
    fi
    
    # Stop EMON collection and create result files
    if [[ "$enable_emon" == true ]]; then
        stop_emon_collection "$emon_pid"
        
        # Create workload result file for EMON
        create_workload_result_file "$emon_output" "$cores" "$avg_time"
        
        echo "EMON results saved to: $emon_output"
    fi
    
    return 0
}

create_csv_output() {
    local cores=$1
    local avg_time=$2
    local test_type=$3
    
    local date_str=$(date '+%Y-%m-%d %H:%M:%S')
    local workload_name="Super Pi"
    local testcase="${cores}cores_scale${scale}_${test_type}"
    local command="echo 'scale=${scale}; 4*a(1)' | bc -l"
    local kpi="Calculation Time"
    local score="$avg_time"
    
    # Create CSV header if file doesn't exist
    if [[ ! -f "$RESULTS_FILE" ]]; then
        echo "Date,Workload Name,Test Case,Command,KPI,Score" > "$RESULTS_FILE"
    fi
    
    # Append result
    echo "$date_str,$workload_name,$testcase,$command,$kpi,$score" >> "$RESULTS_FILE"
    
    log "Results saved to: $RESULTS_FILE"
}

# ------------------------------ ARGUMENT PARSING -----------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --cores)
            cores="$2"
            shift 2
            ;;
        --cpu-cores)
            cpu_cores="$2"
            shift 2
            ;;
        --scale)
            scale="$2"
            shift 2
            ;;
        --runs)
            runs="$2"
            shift 2
            ;;
        --name)
            custom_name="$2"
            shift 2
            ;;
        --emon)
            enable_emon=true
            shift
            ;;
        --emon-user)
            emon_user="$2"
            shift 2
            ;;
        --emon-server)
            emon_server="$2"
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
        --tmc-path)
            tmc_path="$2"
            shift 2
            ;;
        --metric)
            # Legacy support
            if [[ "$2" == "emon" ]]; then
                enable_emon=true
            fi
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

# ------------------------------ VALIDATION -----------------------------------

# Handle wrapper compatibility - parse cpu-cores range
if [[ -n "$cpu_cores" ]]; then
    parse_cpu_cores "$cpu_cores"
fi

if [[ -z "$cores" ]]; then
    error_exit "--cores or --cpu-cores parameter is required"
fi

if [[ $cores -le 0 ]]; then
    error_exit "cores must be a positive integer"
fi

if [[ $scale -le 0 ]]; then
    error_exit "scale must be a positive integer"
fi

if [[ $runs -le 0 ]]; then
    error_exit "runs must be a positive integer"
fi

# Validate EMON parameters
validate_emon_params

# ------------------------------ EXECUTION -----------------------------------
echo "============================================="
echo "SUPER PI BENCHMARK"
echo "============================================="
echo "Script Directory: $SCRIPT_DIR"
echo "Results File: $RESULTS_FILE"
echo "Cores: $cores"
echo "Scale: $scale"
echo "Runs: $runs"
echo "EMON Enabled: $enable_emon"
if [[ "$enable_emon" == true ]]; then
    echo "EMON Session: $emon_session"
    echo "EMON Output Dir: $emon_output_dir"
fi
if [[ -n "$custom_name" ]]; then
    echo "Custom Name: $custom_name"
fi
echo "============================================="
echo ""

# Setup system
setup_system

# Run benchmark for specified number of runs
successful_runs=0

for ((i=1; i<=runs; i++)); do
    log "Starting run $i of $runs..."
    
    if run_superpi_benchmark "$cores" "$i"; then
        successful_runs=$((successful_runs + 1))
    else
        log "Run $i failed"
    fi
    
    # Sleep between runs if multiple runs
    if [[ $i -lt $runs ]]; then
        log "Waiting 30 seconds before next run..."
        sleep 30
    fi
    echo ""
done

# Summary
echo "============================================="
echo "SUPER PI BENCHMARK COMPLETED"
echo "============================================="
echo "Total runs: $runs"
echo "Successful runs: $successful_runs"
echo "Failed runs: $((runs - successful_runs))"
echo "Results saved to: $RESULTS_FILE"
if [[ "$enable_emon" == true ]]; then
    echo "EMON traces saved to: $emon_output_dir"
fi
echo "============================================="
