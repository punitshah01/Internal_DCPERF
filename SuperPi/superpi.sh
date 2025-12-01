#!/bin/bash
# superpi.sh - Super Pi benchmark script for main wrapper

# =============================================================================
# SUPER PI WORKLOAD SCRIPT
# =============================================================================
# This script runs Super Pi benchmarks with configurable core counts
# Compatible with the main wrapper script
# =============================================================================

# ------------------------------ DEFAULT VALUES -----------------------------------
DEFAULT_SCALE=5000
DEFAULT_RUNS=1

# Default EMON/TMC values (same as other workloads)
DEFAULT_EMON_USER="pshah"
DEFAULT_EMON_SERVER="metrics2"
DEFAULT_EMON_GROUP="superpi"

# ------------------------------ VARIABLES -----------------------------------
cores=""
cpu_cores=""  # For wrapper compatibility
scale=$DEFAULT_SCALE
runs=$DEFAULT_RUNS
metric_collection="none"  # none, emon
custom_name=""

# EMON/TMC Variables with defaults
emon_user=$DEFAULT_EMON_USER
emon_server=$DEFAULT_EMON_SERVER
emon_group=$DEFAULT_EMON_GROUP

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
  --metric TYPE          Direct metric collection: none/emon (default: none)
                        Note: Use main wrapper --emon instead of --metric emon

EMON OPTIONS (with defaults):
  --emon-user USER       EMON username (default: $DEFAULT_EMON_USER)
  --emon-server SERVER   EMON server (default: $DEFAULT_EMON_SERVER)
  --emon-group GROUP     EMON group (default: $DEFAULT_EMON_GROUP)

EXAMPLES:
  $0 --cores 8 --scale 5000 --runs 3
  $0 --cpu-cores 0-7 --name custom_test
  $0 --cores 32 --name custom_test
"
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
        echo "Error: Invalid CPU cores format: $cpu_range"
        echo "Use format like '0-7' or '0,2,4,6'"
        exit 1
    fi
}

setup_system() {
    echo "Setting up system for Super Pi benchmark..."
    
    # Check if bc is available
    if ! command -v bc >/dev/null 2>&1; then
        echo "Error: bc command not found. Please install bc package."
        exit 1
    fi
    
    # Check if taskset is available
    if ! command -v taskset >/dev/null 2>&1; then
        echo "Error: taskset command not found. Please install util-linux package."
        exit 1
    fi
    
    # Create results directory
    mkdir -p "$SCRIPT_DIR/result"
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
}

run_superpi_benchmark() {
    local cores=$1
    local run_number=$2
    
    echo "=========================================="
    echo "Super Pi Benchmark Run $run_number"
    echo "Cores: $cores"
    echo "Scale: $scale"
    echo "=========================================="
    
    local timestamp=$(date '+%Y%m%d%H%M%S')
    local session_name="${custom_name:-SUPERPI}_${cores}cores_scale${scale}"
    
    if [[ $metric_collection == "emon" ]]; then
        session_name="${session_name}_WEMON"
    fi
    
    local results_dir="$SCRIPT_DIR/result/pi_${timestamp}"
    local test_dir=""
    
    if [[ $cores -eq 1 ]]; then
        test_dir="$results_dir/single_core"
        mkdir -p "$test_dir"
        
        echo "Running Super Pi with single core..."
        
        # Start EMON collection if enabled
        local emon_pid=""
        if [[ $metric_collection == "emon" ]]; then
            echo "Starting EMON collection..."
            python3 /root/tmc/tmc.py -u -n -x "$emon_user" -G "$emon_group" \
                -i "superpi_1core_run${run_number}" -a "superpi_1core_run${run_number}" \
                -Z "$emon_server" &
            emon_pid=$!
            sleep 2  # Give EMON time to start
        fi
        
        # Run single core calculation
        run_single_pi_calculation 0 "$test_dir/single_core.log" "$scale"
        
        # Stop EMON if running
        if [[ -n "$emon_pid" ]]; then
            sleep 2  # Let EMON collect a bit more data
            kill $emon_pid 2>/dev/null || true
            wait $emon_pid 2>/dev/null || true
        fi
        
        echo "Single core test completed"
        parse_superpi_results "$test_dir" 1 "single"
        
    else
        test_dir="$results_dir/multi_cores"
        mkdir -p "$test_dir"
        
        echo "Running Super Pi with $cores cores..."
        
        # Start EMON collection if enabled
        local emon_pid=""
        if [[ $metric_collection == "emon" ]]; then
            echo "Starting EMON collection..."
            python3 /root/tmc/tmc.py -u -n -x "$emon_user" -G "$emon_group" \
                -i "superpi_${cores}cores_run${run_number}" -a "superpi_${cores}cores_run${run_number}" \
                -Z "$emon_server" &
            emon_pid=$!
            sleep 2  # Give EMON time to start
        fi
        
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
        
        # Stop EMON if running
        if [[ -n "$emon_pid" ]]; then
            sleep 2  # Let EMON collect a bit more data
            kill $emon_pid 2>/dev/null || true
            wait $emon_pid 2>/dev/null || true
        fi
        
        echo "Multi-core test completed"
        parse_superpi_results "$test_dir" "$cores" "multi"
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
    
    echo "Results saved to: $RESULTS_FILE"
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
        --metric)
            metric_collection="$2"
            shift 2
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

# Handle wrapper compatibility - parse cpu-cores range
if [[ -n "$cpu_cores" ]]; then
    parse_cpu_cores "$cpu_cores"
fi

if [[ -z "$cores" ]]; then
    echo "Error: --cores or --cpu-cores parameter is required"
    print_usage
    exit 1
fi

if [[ $cores -le 0 ]]; then
    echo "Error: cores must be a positive integer"
    exit 1
fi

if [[ $scale -le 0 ]]; then
    echo "Error: scale must be a positive integer"
    exit 1
fi

if [[ $runs -le 0 ]]; then
    echo "Error: runs must be a positive integer"
    exit 1
fi

# ------------------------------ EXECUTION -----------------------------------
echo "============================================="
echo "SUPER PI BENCHMARK"
echo "============================================="
echo "Script Directory: $SCRIPT_DIR"
echo "Results File: $RESULTS_FILE"
echo "Cores: $cores"
echo "Scale: $scale"
echo "Runs: $runs"
echo "Metric Collection: $metric_collection"
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
    echo "Starting run $i of $runs..."
    
    if run_superpi_benchmark "$cores" "$i"; then
        successful_runs=$((successful_runs + 1))
    else
        echo "Run $i failed"
    fi
    
    # Sleep between runs if multiple runs
    if [[ $i -lt $runs ]]; then
        echo "Waiting 30 seconds before next run..."
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
echo "============================================="
