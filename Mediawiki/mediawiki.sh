#!/bin/bash
# mediawiki_workload.sh - MediaWiki benchmark script for main wrapper

# =============================================================================
# MEDIAWIKI WORKLOAD SCRIPT
# =============================================================================
# This script runs MediaWiki benchmarks with configurable core counts
# Compatible with the main wrapper script
# =============================================================================

# Set performance governor
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    echo performance | sudo tee $cpu/cpufreq/scaling_governor > /dev/null 2>&1
done

# Determine script directory
MY_PATH="$(dirname -- "${BASH_SOURCE[0]}")"
WRK_PATH="$MY_PATH/../../benchmarks/oss_performance_mediawiki/wrk/wrk"

# ------------------------------ DEFAULT VALUES -----------------------------------
DEFAULT_DURATION=10
DEFAULT_RUNS=1
DEFAULT_TYPE="local"
DEFAULT_CLIENTS_PER_100_CORES=1

# ------------------------------ VARIABLES -----------------------------------
cores=""
duration=$DEFAULT_DURATION
runs=$DEFAULT_RUNS
clients=""
workload_type=$DEFAULT_TYPE
metric_collection="none"  # none, emon, perf, ptat
custom_name=""

# EMON/TMC specific (will be handled by main wrapper)
enable_emon_direct=0

# ------------------------------ FUNCTIONS -----------------------------------
print_usage(){
    echo -e "
Usage: $0 --cores N [OPTIONS]

REQUIRED:
  --cores N              Number of cores to use (REQUIRED)

OPTIONAL:
  --duration SEC         Test duration in seconds (default: $DEFAULT_DURATION)
  --runs N               Number of test runs (default: $DEFAULT_RUNS)
  --clients N            Number of client connections (default: auto-calculated)
  --type TYPE            Client type: local/remote (default: $DEFAULT_TYPE)
  --name NAME            Custom name prefix for logs
  --metric TYPE          Direct metric collection: none/emon/perf/ptat (default: none)
                        Note: Use main wrapper --emon instead of --metric emon

EXAMPLES:
  $0 --cores 32 --duration 60 --runs 3
  $0 --cores 64 --duration 300 --clients 50 --type remote
"
}

enable_core() {
    local core_id=$1
    if [[ -f "/sys/devices/system/cpu/cpu$core_id/online" ]]; then
        echo 1 > "/sys/devices/system/cpu/cpu$core_id/online" 2>/dev/null
    fi
}

disable_core() {
    local core_id=$1
    if [[ -f "/sys/devices/system/cpu/cpu$core_id/online" ]]; then
        echo 0 > "/sys/devices/system/cpu/cpu$core_id/online" 2>/dev/null
    fi
}

setup_cores() {
    local target_cores=$1
    local total_cores=$(nproc --all)
    
    echo "Setting up $target_cores cores (total available: $total_cores)"
    
    # First, enable cores up to target
    for ((i=0; i<target_cores && i<total_cores; i++)); do
        enable_core $i
    done
    
    # Disable cores beyond target
    for ((i=target_cores; i<total_cores; i++)); do
        disable_core $i
    done
    
    sleep 5  # Allow time for core state changes
    
    # Verify core count
    local active_cores=$(nproc)
    echo "Active cores after setup: $active_cores"
    
    if [[ $active_cores -ne $target_cores ]]; then
        echo "Warning: Expected $target_cores cores, but $active_cores are active"
    fi
}

build_driver_and_run_emon() {
    local original_dir=$(pwd)
    
    # Check if EMON is available
    if [[ ! -d "/opt/intel/sep" ]]; then
        echo "Warning: EMON/SEP not found at /opt/intel/sep"
        return 1
    fi
    
    echo "Building EMON driver..."
    
    # Build and load SEP driver
    cd /opt/intel/sep/sepdk/src || { echo "Failed to change to SEP directory"; return 1; }
    
    ./rmmod-sep
    ./build-driver -ni
    ./insmod-sep -g root
    
    # Source SEP environment
    cd /opt/intel/sep || { echo "Failed to change to SEP directory"; return 1; }
    source sep_vars.sh
    
    # Return to original directory
    cd "$original_dir" || { echo "Failed to return to original directory"; return 1; }
    
    return 0
}

calculate_clients() {
    local cores=$1
    if [[ -n "$clients" ]]; then
        echo "$clients"
    else
        # Auto-calculate: 1 client per 100 cores, minimum 1
        local calculated=$(echo "scale=0; ($cores + 99) / 100" | bc 2>/dev/null || echo "1")
        if [[ $calculated -lt 1 ]]; then
            calculated=1
        fi
        echo "$calculated"
    fi
}

setup_system() {
    echo "Setting up system for MediaWiki benchmark..."
    
    # System optimizations
    echo 1 > /proc/sys/net/ipv4/tcp_tw_reuse 2>/dev/null || true
    echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    
    # Restart MariaDB
    systemctl restart mariadb 2>/dev/null || echo "Warning: Could not restart mariadb"
    
    # Drop caches
    sysctl -w vm.drop_caches=3 > /dev/null 2>&1 || true
}

parse_mediawiki_results() {
    local log_file=$1
    
    # Extract key performance metrics from MediaWiki output
    local req_per_sec=""
    local latency_avg=""
    local latency_99=""
    local throughput=""
    
    if [[ -f "$log_file" ]]; then
        # Look for "Combined" section results
        req_per_sec=$(grep "Combined" -A15 "$log_file" | grep "Requests/sec" | awk '{print $2}' | head -1)
        latency_avg=$(grep "Combined" -A15 "$log_file" | grep "Latency" | awk '{print $2}' | head -1)
        throughput=$(grep "Combined" -A15 "$log_file" | grep "Transfer/sec" | awk '{print $2}' | head -1)
        
        # Alternative parsing if above doesn't work
        if [[ -z "$req_per_sec" ]]; then
            req_per_sec=$(grep -i "requests/sec" "$log_file" | awk '{print $2}' | tail -1)
        fi
        
        if [[ -z "$throughput" ]]; then
            throughput=$(grep -i "transfer/sec" "$log_file" | awk '{print $2}' | tail -1)
        fi
    fi
    
    # Output in parseable format
    if [[ -n "$req_per_sec" ]]; then
        echo "Performance: $req_per_sec requests/sec"
        echo "Throughput: $req_per_sec requests/sec"
    else
        echo "Performance: N/A requests/sec"
        echo "Throughput: N/A requests/sec"
    fi
    
    if [[ -n "$latency_avg" ]]; then
        echo "Latency: $latency_avg ms"
    fi
    
    if [[ -n "$throughput" ]]; then
        echo "Transfer: $throughput MB/sec"
    fi
}

run_mediawiki_benchmark() {
    local cores=$1
    local run_number=$2
    
    echo "=========================================="
    echo "MediaWiki Benchmark Run $run_number"
    echo "Cores: $cores"
    echo "Duration: ${duration}s"
    echo "Clients: $(calculate_clients $cores)"
    echo "=========================================="
    
    # Setup cores
    setup_cores $cores
    
    # Calculate parameters
    local actual_clients=$(calculate_clients $cores)
    local timeout=$((duration + 1))
    
    # Create session name and logs directory
    local session_name="${custom_name:-MW}_${workload_type}client_${cores}cores_$(date +%m%d%Y%H%M%S)"
    local logs_dir="mw_logs_${session_name}"
    local logs_file="$logs_dir/mediawiki_${session_name}_${actual_clients}clients_run${run_number}.txt"
    
    mkdir -p "$logs_dir"
    
    # Setup system
    setup_system
    
    # Build base command
    local base_cmd="./run.sh -r /usr/local/hphpi/legacy/bin/hhvm -n /usr/local/nginx-1.22/sbin/nginx -L wrk -s $WRK_PATH -R0 -c${actual_clients} -- --mediawiki-mlp --client-duration=${duration}m --client-timeout=${timeout}m --run-as-root --i-am-not-benchmarking"
    
    # Handle different metric collection types
    local final_cmd=""
    case $metric_collection in
        "emon")
            if build_driver_and_run_emon; then
                local emon_start=600
                local emon_end=$((duration * 300 - 600))
                local ramp_string="Starting wrk for benchmark"
                final_cmd="tmc -c \"$base_cmd\" -rl $logs_file -rs \"$ramp_string\" -rt 2800 -n -u -x pshah -a ${logs_dir}_RUN${run_number} -S $emon_start -E $emon_end -A 10 -B $((duration * 30 - 10)) -w socket,core,uncore -Z metrics2 -G mediawiki_wrapper"
            else
                echo "EMON setup failed, running without EMON"
                final_cmd="$base_cmd 2>&1 | tee $logs_file"
            fi
            ;;
        "perf")
            local perf_duration=300
            local perf_start_delay=30
            local ramp_string="Starting wrk for benchmark"
            bash collect_perf.sh "$logs_dir" "$logs_file" "$ramp_string" "${session_name}_run${run_number}" $perf_duration $perf_start_delay &
            final_cmd="$base_cmd 2>&1 | tee $logs_file"
            ;;
        "ptat")
            local perf_duration=300
            local perf_start_delay=30
            local ramp_string="Starting wrk for benchmark"
            bash "$MY_PATH/collect_ptat.sh" "$PWD/$logs_dir" "$logs_file" "$ramp_string" "${session_name}_run${run_number}" $perf_duration $perf_start_delay &
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
    
    # Parse and display results
    if [[ $exit_code -eq 0 && -f "$logs_file" ]]; then
        echo ""
        echo "Results for run $run_number:"
        parse_mediawiki_results "$logs_file"
        
        # Generate CSV summary
        if grep "Combined" -A15 "$logs_file" > /dev/null 2>&1; then
            grep "Combined" -A15 "$logs_file" | grep -v Combined | awk -F ":" '{print $1","$2}' | tr "\"" " " > "/tmp/mw_result_${run_number}.csv"
        fi
    else
        echo "Error: Benchmark run $run_number failed or no results found"
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
        --duration)
            duration="$2"
            shift 2
            ;;
        --runs)
            runs="$2"
            shift 2
            ;;
        --clients)
            clients="$2"
            shift 2
            ;;
        --type)
            workload_type="$2"
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

if [[ $duration -le 0 ]]; then
    echo "Error: duration must be a positive integer"
    exit 1
fi

if [[ $runs -le 0 ]]; then
    echo "Error: runs must be a positive integer"
    exit 1
fi

# Check if required files exist
if [[ ! -f "$WRK_PATH" ]]; then
    echo "Error: wrk executable not found at $WRK_PATH"
    exit 1
fi

if [[ ! -f "./run.sh" ]]; then
    echo "Error: run.sh not found in current directory"
    exit 1
fi

# ------------------------------ EXECUTION -----------------------------------
echo "============================================="
echo "MEDIAWIKI BENCHMARK"
echo "============================================="
echo "Cores: $cores"
echo "Duration: ${duration}s"
echo "Runs: $runs"
echo "Clients: $(calculate_clients $cores)"
echo "Type: $workload_type"
echo "Metric Collection: $metric_collection"
echo "============================================="
echo ""

# Run benchmark for specified number of runs
total_req_per_sec=0
successful_runs=0

for ((i=1; i<=runs; i++)); do
    echo "Starting run $i of $runs..."
    
    if run_mediawiki_benchmark "$cores" "$i"; then
        successful_runs=$((successful_runs + 1))
    else
        echo "Run $i failed"
    fi
    
    # Sleep between runs
    if [[ $i -lt $runs ]]; then
        echo "Waiting 10 seconds before next run..."
        sleep 10
    fi
    echo ""
done

# Summary
echo "============================================="
echo "MEDIAWIKI BENCHMARK COMPLETED"
echo "============================================="
echo "Total runs: $runs"
echo "Successful runs: $successful_runs"
echo "Failed runs: $((runs - successful_runs))"

# Calculate average if multiple runs
if [[ $successful_runs -gt 1 ]]; then
    echo "Individual run results saved in respective log directories"
fi

echo "============================================="
