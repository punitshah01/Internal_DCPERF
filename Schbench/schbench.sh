#!/bin/bash
# schbench_workload.sh - Schbench scheduler benchmark workload script

# =============================================================================
# SCHBENCH WORKLOAD SCRIPT
# =============================================================================
# This script runs Schbench scheduler benchmarks and collects performance metrics
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHBENCH_DIR="$SCRIPT_DIR/schbench-1.0"
RESULTS_DIR="$SCRIPT_DIR/results"
EXCEL_FILE="$RESULTS_DIR/schbench_results.csv"

# Default values
CORES=""
EMON_ENABLED=0
EMON_SESSION=""
TMC_ENABLED=0
RUNTIME=30
MESSAGE_THREADS=""
WORKER_THREADS=2
SLEEPTIME=30000
CPUTIME=30000
PIPE_TEST=0
WORKLOAD_NAME="Schbench"

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

setup_results_dir() {
    mkdir -p "$RESULTS_DIR"
    
    # Create CSV header if file doesn't exist
    if [ ! -f "$EXCEL_FILE" ]; then
        echo "Date,Workload Name,Test Case,Command,KPI,Score" > "$EXCEL_FILE"
        log_info "Created results CSV file: $EXCEL_FILE"
    fi
}

save_result_to_csv() {
    local test_case="$1"
    local command="$2"
    local kpi="$3"
    local score="$4"
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "\"$date\",\"$WORKLOAD_NAME\",\"$test_case\",\"$command\",\"$kpi\",\"$score\"" >> "$EXCEL_FILE"
    log_info "Result saved to CSV: $test_case - $kpi: $score"
}

start_emon() {
    if [[ $EMON_ENABLED -eq 1 ]] && command_exists emon; then
        log_info "Starting EMON collection with session: $EMON_SESSION"
        emon -i "$EMON_SESSION" &
        EMON_PID=$!
        sleep 2
        log_info "EMON started with PID: $EMON_PID"
    fi
}

stop_emon() {
    if [[ $EMON_ENABLED -eq 1 ]] && [[ -n "$EMON_PID" ]]; then
        log_info "Stopping EMON collection..."
        kill -TERM "$EMON_PID" 2>/dev/null
        wait "$EMON_PID" 2>/dev/null
        log_info "EMON collection stopped"
    fi
}

start_tmc() {
    if [[ $TMC_ENABLED -eq 1 ]] && command_exists tmc; then
        log_info "Starting TMC collection..."
        tmc start &
        TMC_PID=$!
        sleep 2
        log_info "TMC started with PID: $TMC_PID"
    fi
}

stop_tmc() {
    if [[ $TMC_ENABLED -eq 1 ]] && [[ -n "$TMC_PID" ]]; then
        log_info "Stopping TMC collection..."
        tmc stop 2>/dev/null
        log_info "TMC collection stopped"
    fi
}

calculate_message_threads() {
    local cores="$1"
    
    # Default calculation: half of available cores
    local calculated_threads=$((cores / 2))
    
    # Ensure at least 1 thread
    if [[ $calculated_threads -lt 1 ]]; then
        calculated_threads=1
    fi
    
    echo "$calculated_threads"
}

run_schbench_test() {
    local cores="$1"
    local msg_threads="$2"
    local output_file="$RESULTS_DIR/schbench_${cores}cores_${msg_threads}msg_$(date +%Y%m%d_%H%M%S).txt"
    
    log_info "Running Schbench with $cores cores, $msg_threads message threads, $WORKER_THREADS worker threads..."
    
    cd "$SCHBENCH_DIR" || {
        log_error "Failed to enter Schbench directory: $SCHBENCH_DIR"
        return 1
    }
    
    # Set CPU affinity if cores specified
    local taskset_cmd=""
    if [[ -n "$cores" ]] && [[ "$cores" != "0" ]]; then
        local core_list=$(seq -s, 0 $((cores-1)))
        taskset_cmd="taskset -c $core_list"
        log_info "Using CPU cores: $core_list"
    fi
    
    # Start monitoring
    start_emon
    start_tmc
    
    # Build schbench command
    local cmd="$taskset_cmd ./schbench -r $RUNTIME -m $msg_threads -t $WORKER_THREADS"
    
    # Add optional parameters
    if [[ $SLEEPTIME -ne 30000 ]]; then
        cmd="$cmd -s $SLEEPTIME"
    fi
    
    if [[ $CPUTIME -ne 30000 ]]; then
        cmd="$cmd -c $CPUTIME"
    fi
    
    if [[ $PIPE_TEST -eq 1 ]]; then
        cmd="$cmd -p"
    fi
    
    log_info "Executing: $cmd"
    
    # Run the benchmark
    eval "$cmd" > "$output_file" 2>&1
    local exit_code=$?
    
    # Stop monitoring
    stop_tmc
    stop_emon
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "Schbench test failed with exit code: $exit_code"
        cd "$SCRIPT_DIR"
        return 1
    fi
    
    # Parse results
    parse_schbench_results "$output_file" "$cores" "$msg_threads" "$cmd"
    
    cd "$SCRIPT_DIR"
    log_info "Schbench test completed successfully"
    return 0
}

parse_schbench_results() {
    local output_file="$1"
    local cores="$2"
    local msg_threads="$3"
    local command="$4"
    
    log_info "Parsing Schbench results from: $output_file"
    
    # Extract key metrics from schbench output
    local avg_rps=$(grep -i "average rps" "$output_file" | grep -o "[0-9.]*" | tail -1)
    local percentile_99th=$(grep -i "99th percentile" "$output_file" | grep -o "[0-9.]*" | tail -1)
    local percentile_95th=$(grep -i "95th percentile" "$output_file" | grep -o "[0-9.]*" | tail -1)
    local percentile_90th=$(grep -i "90th percentile" "$output_file" | grep -o "[0-9.]*" | tail -1)
    local percentile_50th=$(grep -i "50th percentile\|median" "$output_file" | grep -o "[0-9.]*" | tail -1)
    local max_latency=$(grep -i "max" "$output_file" | grep -o "[0-9.]*" | tail -1)
    local min_latency=$(grep -i "min" "$output_file" | grep -o "[0-9.]*" | tail -1)
    
    # Alternative parsing for different output formats
    if [[ -z "$avg_rps" ]]; then
        avg_rps=$(grep -E "rps|RPS" "$output_file" | grep -o "[0-9.]*" | tail -1)
    fi
    
    if [[ -z "$percentile_99th" ]]; then
        percentile_99th=$(grep "99%" "$output_file" | grep -o "[0-9.]*" | tail -1)
    fi
    
    # Save results to CSV
    local test_case="Schbench_${cores}cores_${msg_threads}msg"
    
    if [[ -n "$avg_rps" ]]; then
        log_info "Average RPS: $avg_rps"
        save_result_to_csv "$test_case" "$command" "Average_RPS" "$avg_rps"
    else
        log_warning "Failed to extract Average RPS from output"
    fi
    
    if [[ -n "$percentile_99th" ]]; then
        log_info "99th Percentile Latency: ${percentile_99th}us"
        save_result_to_csv "${test_case}_99th" "$command" "99th_Percentile_Latency_us" "$percentile_99th"
    else
        log_warning "Failed to extract 99th percentile latency from output"
    fi
    
    if [[ -n "$percentile_95th" ]]; then
        log_info "95th Percentile Latency: ${percentile_95th}us"
        save_result_to_csv "${test_case}_95th" "$command" "95th_Percentile_Latency_us" "$percentile_95th"
    fi
    
    if [[ -n "$percentile_50th" ]]; then
        log_info "50th Percentile Latency: ${percentile_50th}us"
        save_result_to_csv "${test_case}_50th" "$command" "50th_Percentile_Latency_us" "$percentile_50th"
    fi
    
    if [[ -n "$max_latency" ]]; then
        log_info "Max Latency: ${max_latency}us"
        save_result_to_csv "${test_case}_max" "$command" "Max_Latency_us" "$max_latency"
    fi
    
    # Display summary
    echo "========================================="
    echo "Schbench Results"
    echo "========================================="
    echo "Cores Used: $cores"
    echo "Message Threads: $msg_threads"
    echo "Worker Threads: $WORKER_THREADS"
    echo "Runtime: $RUNTIME seconds"
    echo "Average RPS: ${avg_rps:-N/A}"
    echo "99th Percentile: ${percentile_99th:-N/A} us"
    echo "95th Percentile: ${percentile_95th:-N/A} us"
    echo "50th Percentile: ${percentile_50th:-N/A} us"
    echo "Max Latency: ${max_latency:-N/A} us"
    echo "Min Latency: ${min_latency:-N/A} us"
    echo "Output File: $output_file"
    echo "========================================="
    
    return 0
}

run_default_test() {
    local cores="$1"
    local output_file="$RESULTS_DIR/schbench_default_$(date +%Y%m%d_%H%M%S).txt"
    
    log_info "Running default Schbench test..."
    
    cd "$SCHBENCH_DIR" || {
        log_error "Failed to enter Schbench directory: $SCHBENCH_DIR"
        return 1
    }
    
    # Start monitoring
    start_emon
    start_tmc
    
    # Run default schbench (no parameters)
    local cmd="./schbench"
    log_info "Executing: $cmd"
    
    eval "$cmd" > "$output_file" 2>&1
    local exit_code=$?
    
    # Stop monitoring
    stop_tmc
    stop_emon
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "Default Schbench test failed with exit code: $exit_code"
        cd "$SCRIPT_DIR"
        return 1
    fi
    
    # Parse results
    parse_schbench_results "$output_file" "$cores" "default" "$cmd"
    
    cd "$SCRIPT_DIR"
    log_info "Default Schbench test completed successfully"
    return 0
}

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  --cores N              Number of CPU cores to use"
    echo "  --runtime N            Runtime in seconds (default: 30)"
    echo "  --message-threads N    Number of message threads (default: cores/2)"
    echo "  --worker-threads N     Number of worker threads per message thread (default: 2)"
    echo "  --sleeptime N          Sleep time in microseconds (default: 30000)"
    echo "  --cputime N            CPU time in microseconds (default: 30000)"
    echo "  --pipe-test            Enable pipe test mode"
    echo "  --default-test         Run default schbench without parameters"
    echo "  --emon                 Enable EMON performance monitoring"
    echo "  --emon-session NAME    EMON session name"
    echo "  --tmc                  Enable TMC monitoring"
    echo "  --workload-name NAME   Custom workload name"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "EXAMPLES:"
    echo "  $0 --cores 8"
    echo "  $0 --cores 16 --runtime 60 --message-threads 8"
    echo "  $0 --cores 32 --emon --emon-session schbench_test"
    echo "  $0 --default-test"
}

main() {
    local default_test=0
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cores)
                CORES="$2"
                shift 2
                ;;
            --runtime)
                RUNTIME="$2"
                shift 2
                ;;
            --message-threads)
                MESSAGE_THREADS="$2"
                shift 2
                ;;
            --worker-threads)
                WORKER_THREADS="$2"
                shift 2
                ;;
            --sleeptime)
                SLEEPTIME="$2"
                shift 2
                ;;
            --cputime)
                CPUTIME="$2"
                shift 2
                ;;
            --pipe-test)
                PIPE_TEST=1
                shift
                ;;
            --default-test)
                default_test=1
                shift
                ;;
            --emon)
                EMON_ENABLED=1
                shift
                ;;
            --emon-session)
                EMON_SESSION="$2"
                shift 2
                ;;
            --tmc)
                TMC_ENABLED=1
                shift
                ;;
            --workload-name)
                WORKLOAD_NAME="$2"
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
    
    # Validate required parameters for non-default test
    if [[ $default_test -eq 0 ]] && [[ -z "$CORES" ]]; then
        log_error "Number of cores must be specified with --cores (or use --default-test)"
        print_usage
        exit 1
    fi
    
    # Check if Schbench is installed
    if [[ ! -d "$SCHBENCH_DIR" ]]; then
        log_error "Schbench not found. Please run setup_schbench.sh first"
        exit 1
    fi
    
    if [[ ! -f "$SCHBENCH_DIR/schbench" ]]; then
        log_error "Schbench executable not found. Please run setup_schbench.sh first"
        exit 1
    fi
    
    # Setup results directory
    setup_results_dir
    
    log_info "Starting Schbench scheduler benchmark..."
    
    if [[ $default_test -eq 1 ]]; then
        log_info "Running default test mode"
        log_info "EMON: $([ $EMON_ENABLED -eq 1 ] && echo "Enabled ($EMON_SESSION)" || echo "Disabled")"
        log_info "TMC: $([ $TMC_ENABLED -eq 1 ] && echo "Enabled" || echo "Disabled")"
        
        run_default_test "${CORES:-0}"
    else
        # Calculate message threads if not specified
        if [[ -z "$MESSAGE_THREADS" ]]; then
            MESSAGE_THREADS=$(calculate_message_threads "$CORES")
        fi
        
        log_info "Cores: $CORES"
        log_info "Runtime: $RUNTIME seconds"
        log_info "Message Threads: $MESSAGE_THREADS"
        log_info "Worker Threads: $WORKER_THREADS"
        log_info "Sleep Time: $SLEEPTIME us"
        log_info "CPU Time: $CPUTIME us"
        log_info "Pipe Test: $([ $PIPE_TEST -eq 1 ] && echo "Enabled" || echo "Disabled")"
        log_info "EMON: $([ $EMON_ENABLED -eq 1 ] && echo "Enabled ($EMON_SESSION)" || echo "Disabled")"
        log_info "TMC: $([ $TMC_ENABLED -eq 1 ] && echo "Enabled" || echo "Disabled")"
        log_info "Results will be saved to: $EXCEL_FILE"
        
        # Run benchmark
        run_schbench_test "$CORES" "$MESSAGE_THREADS"
    fi
    
    log_info "Schbench benchmark completed"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up..."
    stop_tmc
    stop_emon
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Run main function
main "$@"
