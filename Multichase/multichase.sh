#!/bin/bash
# multichase_workload.sh - Multichase memory benchmark workload script

# =============================================================================
# MULTICHASE WORKLOAD SCRIPT
# =============================================================================
# This script runs Multichase memory benchmarks and collects performance metrics
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MULTICHASE_DIR="$SCRIPT_DIR/multichase-master"
RESULTS_DIR="$SCRIPT_DIR/results"
EXCEL_FILE="$RESULTS_DIR/multichase_results.csv"

# Default values
CORES=""
EMON_ENABLED=0
EMON_SESSION=""
TMC_ENABLED=0
TEST_TYPE="multiload"  # multiload, pingpong, or both
MEMORY_SIZE="512m"
STRIDE_SIZE=256
ITERATIONS=5
MAX_THREADS=32
WORKLOAD_NAME="Multichase"

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

run_multiload_test() {
    local cores="$1"
    local output_file="$RESULTS_DIR/multiload_${cores}cores_$(date +%Y%m%d_%H%M%S).txt"
    
    log_info "Running Multiload test with up to $cores threads..."
    
    cd "$MULTICHASE_DIR" || {
        log_error "Failed to enter Multichase directory: $MULTICHASE_DIR"
        return 1
    }
    
    # Start monitoring
    start_emon
    start_tmc
    
    # Run multiload for different thread counts
    local max_threads=$cores
    if [[ $max_threads -gt $MAX_THREADS ]]; then
        max_threads=$MAX_THREADS
    fi
    
    log_info "Running multiload tests for 1 to $max_threads threads..."
    
    # Create temporary file for results
    local temp_results="/tmp/multiload_results_$$"
    > "$temp_results"
    
    for i in $(seq 1 $max_threads); do
        log_info "Testing with $i threads..."
        
        local cmd="numactl --cpunodebind=0 --membind=0 ./multiload -s $STRIDE_SIZE -n $ITERATIONS -t $i -m $MEMORY_SIZE -c chaseload -l stream-triad"
        
        # Run the test and capture output
        local result_line=$(eval "$cmd" 2>/dev/null | grep -v Samples | tail -1 | sed 's/,//g')
        
        if [[ -n "$result_line" ]]; then
            echo "$i: $result_line" >> "$temp_results"
            log_info "Thread $i result: $result_line"
        else
            log_warning "No result for thread $i"
            echo "$i: No result" >> "$temp_results"
        fi
    done
    
    # Stop monitoring
    stop_tmc
    stop_emon
    
    # Copy results to output file
    cp "$temp_results" "$output_file"
    
    # Parse and save results
    parse_multiload_results "$temp_results" "$max_threads"
    
    # Clean up
    rm -f "$temp_results"
    
    cd "$SCRIPT_DIR"
    log_info "Multiload test completed successfully"
    return 0
}

parse_multiload_results() {
    local results_file="$1"
    local max_threads="$2"
    
    log_info "Parsing multiload results..."
    
    # Extract chaseNS values and calculate summary
    local total_chase_ns=0
    local valid_results=0
    
    while IFS=': ' read -r threads result_line; do
        if [[ "$result_line" != "No result" ]] && [[ -n "$result_line" ]]; then
            # Extract chaseNS value (assuming it's in a specific column)
            # This may need adjustment based on actual output format
            local chase_ns=$(echo "$result_line" | awk '{print $NF}')
            
            if [[ "$chase_ns" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                total_chase_ns=$(echo "$total_chase_ns + $chase_ns" | bc -l)
                ((valid_results++))
                
                # Save individual thread result
                local test_case="Multiload_${threads}threads"
                local cmd="multiload -t $threads"
                save_result_to_csv "$test_case" "$cmd" "ChaseNS" "$chase_ns"
            fi
        fi
    done < "$results_file"
    
    # Calculate and save summary
    if [[ $valid_results -gt 0 ]]; then
        local avg_chase_ns=$(echo "scale=2; $total_chase_ns / $valid_results" | bc -l)
        save_result_to_csv "Multiload_Summary_${max_threads}threads" "multiload summary" "Average_ChaseNS" "$avg_chase_ns"
        save_result_to_csv "Multiload_Total_${max_threads}threads" "multiload summary" "Total_ChaseNS" "$total_chase_ns"
        
        log_info "Multiload Summary - Total ChaseNS: $total_chase_ns, Average: $avg_chase_ns"
    else
        log_error "No valid multiload results found"
        return 1
    fi
    
    return 0
}

run_pingpong_test() {
    local cores="$1"
    local output_file="$RESULTS_DIR/pingpong_${cores}cores_$(date +%Y%m%d_%H%M%S).txt"
    
    log_info "Running Pingpong test..."
    
    cd "$MULTICHASE_DIR" || {
        log_error "Failed to enter Multichase directory: $MULTICHASE_DIR"
        return 1
    }
    
    # Start monitoring
    start_emon
    start_tmc
    
    # Run pingpong test
    local cmd="./pingpong -u -c 1"
    log_info "Executing: $cmd"
    
    eval "$cmd" > "$output_file" 2>&1
    local exit_code=$?
    
    # Stop monitoring
    stop_tmc
    stop_emon
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "Pingpong test failed with exit code: $exit_code"
        cd "$SCRIPT_DIR"
        return 1
    fi
    
    # Parse results
    parse_pingpong_results "$output_file"
    
    cd "$SCRIPT_DIR"
    log_info "Pingpong test completed successfully"
    return 0
}

parse_pingpong_results() {
    local output_file="$1"
    
    log_info "Parsing pingpong results from: $output_file"
    
    # Extract latency matrix from pingpong output
    # This will need to be adjusted based on actual output format
    local latency_lines=$(grep -E "^[0-9]+:" "$output_file" 2>/dev/null)
    
    if [[ -n "$latency_lines" ]]; then
        local line_count=0
        while IFS= read -r line; do
            ((line_count++))
            
            # Extract core number and latencies
            local core_num=$(echo "$line" | cut -d':' -f1)
            local latencies=$(echo "$line" | cut -d':' -f2- | tr -s ' ')
            
            # Save core-to-core latency results
            local test_case="Pingpong_Core${core_num}_Latencies"
            save_result_to_csv "$test_case" "./pingpong -u -c 1" "Core_Latencies_ns" "$latencies"
            
            # Calculate average latency for this core
            local avg_latency=$(echo "$latencies" | awk '{sum=0; count=0; for(i=1;i<=NF;i++) {if($i ~ /^[0-9]+\.?[0-9]*$/) {sum+=$i; count++}} if(count>0) print sum/count; else print 0}')
            
            if [[ "$avg_latency" != "0" ]]; then
                local avg_test_case="Pingpong_Core${core_num}_Average"
                save_result_to_csv "$avg_test_case" "./pingpong -u -c 1" "Average_Latency_ns" "$avg_latency"
            fi
            
        done <<< "$latency_lines"
        
        log_info "Parsed $line_count core latency measurements"
    else
        log_error "No latency data found in pingpong output"
        return 1
    fi
    
    return 0
}

run_multichase_basic() {
    local output_file="$RESULTS_DIR/multichase_basic_$(date +%Y%m%d_%H%M%S).txt"
    
    log_info "Running basic Multichase test (256MB, 256 byte stride, 2.5s)..."
    
    cd "$MULTICHASE_DIR" || {
        log_error "Failed to enter Multichase directory: $MULTICHASE_DIR"
        return 1
    }
    
    # Start monitoring
    start_emon
    start_tmc
    
    # Run basic multichase (if available)
    local cmd="./multichase"
    if [[ -f "multichase" ]]; then
        log_info "Executing: $cmd"
        eval "$cmd" > "$output_file" 2>&1
        local exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            # Parse basic multichase results
            local latency=$(grep -o "[0-9.]\+ ns" "$output_file" | head -1 | cut -d' ' -f1)
            if [[ -n "$latency" ]]; then
                save_result_to_csv "Multichase_Basic" "$cmd" "Latency_ns" "$latency"
                log_info "Basic Multichase latency: $latency ns"
            fi
        else
            log_warning "Basic multichase test failed, but continuing with other tests"
        fi
    else
        log_info "Basic multichase executable not found, skipping"
    fi
    
    # Stop monitoring
    stop_tmc
    stop_emon
    
    cd "$SCRIPT_DIR"
    return 0
}

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  --cores N              Number of CPU cores to use"
    echo "  --test-type TYPE       Test type: multiload, pingpong, basic, or all (default: multiload)"
    echo "  --memory-size SIZE     Memory size for tests (default: 512m)"
    echo "  --stride-size N        Stride size in bytes (default: 256)"
    echo "  --iterations N         Number of iterations (default: 5)"
    echo "  --max-threads N        Maximum threads for multiload (default: 32)"
    echo "  --emon                 Enable EMON performance monitoring"
    echo "  --emon-session NAME    EMON session name"
    echo "  --tmc                  Enable TMC monitoring"
    echo "  --workload-name NAME   Custom workload name"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "EXAMPLES:"
    echo "  $0 --cores 8 --test-type multiload"
    echo "  $0 --cores 16 --test-type pingpong"
    echo "  $0 --cores 32 --test-type all --emon --emon-session multichase_test"
    echo "  $0 --cores 8 --memory-size 1g --max-threads 16"
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cores)
                CORES="$2"
                shift 2
                ;;
            --test-type)
                TEST_TYPE="$2"
                shift 2
                ;;
            --memory-size)
                MEMORY_SIZE="$2"
                shift 2
                ;;
            --stride-size)
                STRIDE_SIZE="$2"
                shift 2
                ;;
            --iterations)
                ITERATIONS="$2"
                shift 2
                ;;
            --max-threads)
                MAX_THREADS="$2"
                shift 2
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
    
    # Validate required parameters
    if [[ -z "$CORES" ]]; then
        log_error "Number of cores must be specified with --cores"
        print_usage
        exit 1
    fi
    
    # Check if Multichase is installed
    if [[ ! -d "$MULTICHASE_DIR" ]]; then
        log_error "Multichase not found. Please run setup_multichase.sh first"
        exit 1
    fi
    
    if [[ ! -f "$MULTICHASE_DIR/multiload" ]] && [[ ! -f "$MULTICHASE_DIR/pingpong" ]]; then
        log_error "Multichase executables not found. Please run setup_multichase.sh first"
        exit 1
    fi
    
    # Setup results directory
    setup_results_dir
    
    log_info "Starting Multichase benchmark..."
    log_info "Cores: $CORES"
    log_info "Test Type: $TEST_TYPE"
    log_info "Memory Size: $MEMORY_SIZE"
    log_info "Stride Size: $STRIDE_SIZE"
    log_info "Iterations: $ITERATIONS"
    log_info "Max Threads: $MAX_THREADS"
    log_info "EMON: $([ $EMON_ENABLED -eq 1 ] && echo "Enabled ($EMON_SESSION)" || echo "Disabled")"
    log_info "TMC: $([ $TMC_ENABLED -eq 1 ] && echo "Enabled" || echo "Disabled")"
    log_info "Results will be saved to: $EXCEL_FILE"
    
    # Run benchmark based on test type
    case "$TEST_TYPE" in
        multiload)
            run_multiload_test "$CORES"
            ;;
        pingpong)
            run_pingpong_test "$CORES"
            ;;
        basic)
            run_multichase_basic
            ;;
        all)
            run_multiload_test "$CORES"
            run_pingpong_test "$CORES"
            run_multichase_basic
            ;;
        *)
            log_error "Invalid test type: $TEST_TYPE"
            print_usage
            exit 1
            ;;
    esac
    
    log_info "Multichase benchmark completed"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up..."
    stop_tmc
    stop_emon
    
    # Clean up any remaining temp files
    rm -f /tmp/multiload_results_*
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Run main function
main "$@"
