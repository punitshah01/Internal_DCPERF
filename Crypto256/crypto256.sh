#!/bin/bash
# crypto256_workload.sh - Crypto++ SHA-256 benchmark workload script

# =============================================================================
# CRYPTO++ SHA-256 WORKLOAD SCRIPT
# =============================================================================
# This script runs Crypto++ SHA-256 benchmark and collects performance metrics
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRYPTO_DIR="$SCRIPT_DIR/cryptopp-CRYPTOPP_8_5_0"
RESULTS_DIR="$SCRIPT_DIR/results"
EXCEL_FILE="$RESULTS_DIR/crypto256_results.csv"

# Default values
CORES=""
EMON_ENABLED=0
EMON_SESSION=""
TMC_ENABLED=0
TEST_DURATION=60
WORKLOAD_NAME="Crypto++ SHA-256"

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
        echo "Date,WorkloadName,TestName,Command,KPI,Score" > "$EXCEL_FILE"
        log_info "Created results CSV file: $EXCEL_FILE"
    fi
}

save_result_to_csv() {
    local test_name="$1"
    local command="$2"
    local kpi="$3"
    local score="$4"
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "\"$date\",\"$WORKLOAD_NAME\",\"$test_name\",\"$command\",\"$kpi\",\"$score\"" >> "$EXCEL_FILE"
    log_info "Result saved to CSV: $test_name - $kpi: $score"
}

start_emon() {
    if [[ $EMON_ENABLED -eq 1 ]] && command_exists emon; then
        log_info "Starting EMON collection..."
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

run_crypto_benchmark() {
    local cores="$1"
    local output_file="$RESULTS_DIR/crypto256_output_${cores}cores_$(date +%Y%m%d_%H%M%S).txt"
    
    log_info "Running Crypto++ SHA-256 benchmark with $cores cores..."
    
    cd "$CRYPTO_DIR" || {
        log_error "Failed to enter Crypto++ directory: $CRYPTO_DIR"
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
    
    # Run the benchmark
    local cmd="$taskset_cmd ./cryptest.exe b"
    log_info "Executing: $cmd"
    
    eval "$cmd" > "$output_file" 2>&1
    local exit_code=$?
    
    # Stop monitoring
    stop_tmc
    stop_emon
    
    cd "$SCRIPT_DIR"
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "Crypto++ benchmark failed with exit code: $exit_code"
        return 1
    fi
    
    # Parse results
    parse_results "$output_file" "$cmd" "$cores"
    
    log_info "Crypto++ SHA-256 benchmark completed successfully"
    return 0
}

parse_results() {
    local output_file="$1"
    local command="$2"
    local cores="$3"
    
    log_info "Parsing results from: $output_file"
    
    # Extract SHA-256 performance
    local sha256_line=$(grep '<TR><TD>SHA-256<TD>' "$output_file" 2>/dev/null)
    
    if [[ -n "$sha256_line" ]]; then
        # Parse the HTML table format to extract performance value
        # Expected format: <TR><TD>SHA-256<TD>XXX.XX MB/s<TD>...
        local performance=$(echo "$sha256_line" | sed -n 's/.*<TD>SHA-256<TD>\([0-9.]*\) MB\/s.*/\1/p')
        
        if [[ -n "$performance" ]]; then
            log_info "SHA-256 Performance: $performance MB/s"
            
            # Save to CSV
            local test_name="SHA-256_${cores}cores"
            save_result_to_csv "$test_name" "$command" "Throughput_MB/s" "$performance"
            
            # Display result
            echo "========================================="
            echo "Crypto++ SHA-256 Benchmark Results"
            echo "========================================="
            echo "Cores Used: $cores"
            echo "SHA-256 Throughput: $performance MB/s"
            echo "Output File: $output_file"
            echo "========================================="
        else
            log_error "Failed to parse SHA-256 performance from output"
            return 1
        fi
    else
        log_error "SHA-256 results not found in output file"
        return 1
    fi
    
    return 0
}

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  --cores N              Number of CPU cores to use"
    echo "  --emon                 Enable EMON performance monitoring"
    echo "  --emon-session NAME    EMON session name"
    echo "  --tmc                  Enable TMC monitoring"
    echo "  --duration N           Test duration in seconds (default: 60)"
    echo "  --workload-name NAME   Custom workload name"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "EXAMPLES:"
    echo "  $0 --cores 8"
    echo "  $0 --cores 16 --emon --emon-session crypto_test"
    echo "  $0 --cores 4 --tmc --duration 120"
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cores)
                CORES="$2"
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
            --duration)
                TEST_DURATION="$2"
                shift 2
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
    
    # Check if Crypto++ is installed
    if [[ ! -d "$CRYPTO_DIR" ]]; then
        log_error "Crypto++ not found. Please run setup_crypto256.sh first"
        exit 1
    fi
    
    if [[ ! -f "$CRYPTO_DIR/cryptest.exe" ]]; then
        log_error "Crypto++ test executable not found. Please run setup_crypto256.sh first"
        exit 1
    fi
    
    # Setup results directory
    setup_results_dir
    
    log_info "Starting Crypto++ SHA-256 benchmark..."
    log_info "Cores: $CORES"
    log_info "EMON: $([ $EMON_ENABLED -eq 1 ] && echo "Enabled ($EMON_SESSION)" || echo "Disabled")"
    log_info "TMC: $([ $TMC_ENABLED -eq 1 ] && echo "Enabled" || echo "Disabled")"
    log_info "Duration: $TEST_DURATION seconds"
    log_info "Results will be saved to: $EXCEL_FILE"
    
    # Run benchmark
    run_crypto_benchmark "$CORES"
    
    log_info "Crypto++ SHA-256 benchmark completed"
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
