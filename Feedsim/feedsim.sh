#!/bin/bash
# feedsim_workload.sh - FeedSim benchmark script for main wrapper

# =============================================================================
# FEEDSIM WORKLOAD SCRIPT
# =============================================================================
# This script runs FeedSim benchmarks with configurable core counts
# Compatible with the main wrapper script
# =============================================================================

# Determine script directory
MY_PATH="$(dirname -- "${BASH_SOURCE[0]}")"

# ------------------------------ DEFAULT VALUES -----------------------------------
DEFAULT_RUNS=1
DEFAULT_NUM_INSTANCES=1
DEFAULT_PERF_START_DELAY=30
DEFAULT_PERF_DURATION=240

# Default EMON/TMC values (same as MediaWiki)
DEFAULT_EMON_USER="pshah"
DEFAULT_EMON_SERVER="metrics2"
DEFAULT_EMON_GROUP="feedsim"

# ------------------------------ VARIABLES -----------------------------------
cores=""
runs=$DEFAULT_RUNS
num_instances=$DEFAULT_NUM_INSTANCES
metric_collection="none"  # none, emon, perf
custom_name=""
perf_start_delay=$DEFAULT_PERF_START_DELAY
perf_duration=$DEFAULT_PERF_DURATION

# EMON/TMC Variables with defaults
emon_user=$DEFAULT_EMON_USER
emon_server=$DEFAULT_EMON_SERVER
emon_group=$DEFAULT_EMON_GROUP

# FeedSim specific settings
RAMP_STRING="after warmup"
RAMP_FILE="/tmp/feedsim_log.txt"

# ------------------------------ FUNCTIONS -----------------------------------
print_usage(){
    echo -e "
Usage: $0 --cores N [OPTIONS]

REQUIRED:
  --cores N              Number of cores to use (REQUIRED)

OPTIONAL:
  --runs N               Number of test runs (default: $DEFAULT_RUNS)
  --instances N          Number of FeedSim instances (default: $DEFAULT_NUM_INSTANCES)
  --name NAME            Custom name prefix for logs
  --metric TYPE          Direct metric collection: none/emon/perf (default: none)
                        Note: Use main wrapper --emon instead of --metric emon
  --perf-delay SEC       Perf collection start delay (default: $DEFAULT_PERF_START_DELAY)
  --perf-duration SEC    Perf collection duration (default: $DEFAULT_PERF_DURATION)

EMON OPTIONS (with defaults):
  --emon-user USER       EMON username (default: $DEFAULT_EMON_USER)
  --emon-server SERVER   EMON server (default: $DEFAULT_EMON_SERVER)
  --emon-group GROUP     EMON group (default: $DEFAULT_EMON_GROUP)

EXAMPLES:
  $0 --cores 32 --instances 4 --runs 3
  $0 --cores 64 --instances 8 --name custom_test
"
}

setup_system() {
    echo "Setting up system for FeedSim benchmark..."
    
    # System optimizations
    echo 1 | sudo tee /proc/sys/net/ipv4/tcp_tw_reuse > /dev/null 2>&1 || true
    echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
    ulimit -n 655350 2>/dev/null || true
    
    # Clean up previous results
    rm -rf benchmarks/feedsim/feedsim_results*.txt benchmarks/feedsim/feedsim-multi*.log 2>/dev/null || true
}

parse_feedsim_results() {
    local logs_dir=$1
    
    # Extract performance metrics from FeedSim results
    local throughput=""
    local latency=""
    local qps=""
    
    # Look for results in copied files
    local result_files=$(find "$logs_dir" -name "feedsim_results*.txt" 2>/dev/null)
    
    if [[ -n "$result_files" ]]; then
        for result_file in $result_files; do
            # Extract throughput/QPS from FeedSim results
            local file_throughput=$(grep -i "throughput\|qps\|requests" "$result_file" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
            local file_latency=$(grep -i "latency\|response.*time" "$result_file" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
            
            if [[ -n "$file_throughput" ]]; then
                throughput="$file_throughput"
            fi
            if [[ -n "$file_latency" ]]; then
                latency="$file_latency"
            fi
        done
    fi
    
    # Alternative: parse from log files
    if [[ -z "$throughput" ]]; then
        local log_files=$(find "$logs_dir" -name "fs_*.txt" 2>/dev/null)
        for log_file in $log_files; do
            throughput=$(grep -i "throughput\|qps\|req/s" "$log_file" | grep -oE '[0-9]+\.?[0-9]*' | tail -1)
            if [[ -n "$throughput" ]]; then
                break
            fi
        done
    fi
    
    # Output in parseable format
    if [[ -n "$throughput" ]]; then
        echo "Performance: $throughput QPS"
        echo "Throughput: $throughput QPS"
    else
        echo "Performance: N/A QPS"
        echo "Throughput: N/A QPS"
    fi
    
    if [[ -n "$latency" ]]; then
        echo "Latency: $latency ms"
    fi
}

run_feedsim_benchmark() {
    local cores=$1
    local run_number=$2
    
    echo "=========================================="
    echo "FeedSim Benchmark Run $run_number"
    echo "Cores: $cores"
    echo "Instances: $num_instances"
    echo "=========================================="
    
    # Create session name and logs directory
    local name_prefix="${custom_name:-FEEDSIM}_${cores}cores_NUMINST${num_instances}"
    
    if [[ $metric_collection == "emon" ]]; then
        name_prefix="${name_prefix}_WEMON"
    elif [[ $metric_collection == "perf" ]]; then
        name_prefix="${name_prefix}_WPERF"
    fi
    
    local session_name="feedsim_logs_${name_prefix}"
    local logs_root="${session_name}_$(date +%m%d%Y%H%M%S)"
    local logs_dir="$logs_root/run${run_number}"
    local logs_file="$logs_dir/fs_${name_prefix}_run${run_number}.txt"
    
    mkdir -p "$logs_dir"
    
    # Setup system
    setup_system
    
    # Build base command
    local base_cmd="./run-feedsim-multi.sh ${num_instances}"
    
    # Handle different metric collection types
    local final_cmd=""
    case $metric_collection in
        "emon")
            final_cmd="tmc -c \"$base_cmd\" -rl $RAMP_FILE -rs \"$RAMP_STRING\" -rt 1000 -n -u -x $emon_user -a ${session_name}_RUN${run_number} -S 300 -E 900 -w socket,core -Z $emon_server -G $emon_group"
            ;;
        "perf")
            bash "$MY_PATH/collect_perf.sh" "$logs_dir" "$RAMP_FILE" "$RAMP_STRING" "${session_name}_run${run_number}" $perf_duration $perf_start_delay &
            final_cmd="$base_cmd 2>&1 | tee $logs_file"
            ;;
        *)
            final_cmd="$base_cmd 2>&1 | tee $logs_file"
            ;;
    esac
    
    echo "Executing: $final_cmd"
    echo ""
    
    # Execute the command
    eval "$final_cmd"
    local exit_code=$?
    
    # Wait for background processes
    wait
    
    # Copy results if successful
    if [[ $exit_code -eq 0 ]]; then
        # Copy FeedSim result files
        cp benchmarks/feedsim/feedsim_results*.txt "$logs_dir" 2>/dev/null || true
        cp benchmarks/feedsim/feedsim-multi*.log "$logs_dir" 2>/dev/null || true
        cp "$RAMP_FILE" "$logs_dir" 2>/dev/null || true
        
        echo ""
        echo "Results for run $run_number:"
        parse_feedsim_results "$logs_dir"
        
        # Sleep between runs
        sleep 30
    else
        echo "Error: FeedSim run $run_number failed"
        return 1
    fi
    
    return 0
}

# ------------------------------ ARGUMENT PARSING -----------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --cores)
            cores="$2"
            shift 2
            ;;
        --runs)
            runs="$2"
            shift 2
            ;;
        --instances)
            num_instances="$2"
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
        --perf-delay)
            perf_start_delay="$2"
            shift 2
            ;;
        --perf-duration)
            perf_duration="$2"
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
if [[ -z "$cores" ]]; then
    echo "Error: --cores parameter is required"
    print_usage
    exit 1
fi

if [[ $cores -le 0 ]]; then
    echo "Error: cores must be a positive integer"
    exit 1
fi

if [[ $runs -le 0 ]]; then
    echo "Error: runs must be a positive integer"
    exit 1
fi

if [[ $num_instances -le 0 ]]; then
    echo "Error: instances must be a positive integer"
    exit 1
fi

# Check if required files exist
if [[ ! -f "./run-feedsim-multi.sh" ]]; then
    echo "Error: run-feedsim-multi.sh not found in current directory"
    exit 1
fi

# ------------------------------ EXECUTION -----------------------------------
echo "============================================="
echo "FEEDSIM BENCHMARK"
echo "============================================="
echo "Cores: $cores"
echo "Instances: $num_instances"
echo "Runs: $runs"
echo "Metric Collection: $metric_collection"
if [[ -n "$custom_name" ]]; then
    echo "Custom Name: $custom_name"
fi
echo "============================================="
echo ""

# Run benchmark for specified number of runs
successful_runs=0

for ((i=1; i<=runs; i++)); do
    echo "Starting run $i of $runs..."
    
    if run_feedsim_benchmark "$cores" "$i"; then
        successful_runs=$((successful_runs + 1))
    else
        echo "Run $i failed"
    fi
    
    echo ""
done

# Summary
echo "============================================="
echo "FEEDSIM BENCHMARK COMPLETED"
echo "============================================="
echo "Total runs: $runs"
echo "Successful runs: $successful_runs"
echo "Failed runs: $((runs - successful_runs))"
echo "============================================="
