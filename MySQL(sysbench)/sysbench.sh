#!/bin/bash
# sysbench_workload.sh - Sysbench database benchmark workload script

# =============================================================================
# SYSBENCH WORKLOAD SCRIPT
# =============================================================================
# This script runs Sysbench database benchmarks and collects performance metrics
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
EXCEL_FILE="$RESULTS_DIR/sysbench_results.csv"

# Default values
CORES=""
EMON_ENABLED=0
EMON_SESSION=""
TMC_ENABLED=0
DB_HOST="127.0.0.1"
DB_PORT=3306
DB_NAME="sysbench"
DB_USER="root"
DB_PASSWORD="intel123"
THREADS=""
TEST_TIME=60
MAX_REQUESTS=0
TABLES=10
TABLE_SIZE=5000000
TEST_MODES=("oltp_read_only" "oltp_write_only" "oltp_read_write")
WORKLOAD_NAME="Sysbench"
CORE_SCALING=false
SCALING_STEP=16

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

check_mysql_connection() {
    log_info "Checking MySQL connection..."
    
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1 || {
        log_error "Cannot connect to MySQL server"
        log_error "Host: $DB_HOST, Port: $DB_PORT, User: $DB_USER"
        log_error "Please verify MySQL is running and credentials are correct"
        return 1
    }
    
    # Check if database exists
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "USE $DB_NAME;" >/dev/null 2>&1 || {
        log_warning "Database '$DB_NAME' does not exist, creating it..."
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "CREATE DATABASE $DB_NAME;" || {
            log_error "Failed to create database '$DB_NAME'"
            return 1
        }
    }
    
    log_info "MySQL connection verified successfully"
    return 0
}

prepare_sysbench_data() {
    local threads="$1"
    
    log_info "Preparing Sysbench test data with $threads threads..."
    
    # Set CPU affinity if specified
    local taskset_cmd=""
    if [[ -n "$CORES" ]] && [[ "$CORES" != "0" ]]; then
        local core_list=$(seq -s, 0 $((CORES-1)))
        taskset_cmd="taskset -c $core_list"
        log_info "Using CPU cores for prepare: $core_list"
    fi
    
    local cmd="$taskset_cmd sysbench --time=$TEST_TIME --max-requests=$MAX_REQUESTS --threads=$threads --report-interval=1 --tables=$TABLES --table-size=$TABLE_SIZE --db-driver=mysql --mysql-host=$DB_HOST --mysql-port=$DB_PORT --mysql-user=$DB_USER --mysql-password=$DB_PASSWORD --mysql-db=$DB_NAME --percentile=99 oltp_read_write prepare"
    
    log_info "Executing prepare: $cmd"
    eval "$cmd" || {
        log_error "Failed to prepare Sysbench data"
        return 1
    }
    
    log_info "Sysbench data preparation completed"
    return 0
}

cleanup_sysbench_data() {
    local threads="$1"
    
    log_info "Cleaning up Sysbench test data..."
    
    local cmd="sysbench --time=$TEST_TIME --max-requests=$MAX_REQUESTS --threads=$threads --report-interval=1 --tables=$TABLES --table-size=$TABLE_SIZE --db-driver=mysql --mysql-host=$DB_HOST --mysql-port=$DB_PORT --mysql-user=$DB_USER --mysql-password=$DB_PASSWORD --mysql-db=$DB_NAME --percentile=99 oltp_read_write cleanup"
    
    log_info "Executing cleanup: $cmd"
    eval "$cmd" || {
        log_warning "Failed to cleanup Sysbench data"
    }
    
    log_info "Sysbench data cleanup completed"
}

run_sysbench_test() {
    local threads="$1"
    local mode="$2"
    local output_file="$RESULTS_DIR/sysbench_${mode}_${threads}threads_$(date +%Y%m%d_%H%M%S).txt"
    
    log_info "Running Sysbench test: $mode with $threads threads..."
    
    # Set CPU affinity if specified
    local taskset_cmd=""
    if [[ -n "$CORES" ]] && [[ "$CORES" != "0" ]]; then
        local core_list=$(seq -s, 0 $((CORES-1)))
        taskset_cmd="taskset -c $core_list"
        log_info "Using CPU cores: $core_list"
    fi
    
    # Start monitoring
    start_emon
    start_tmc
    
    # Build and execute sysbench command
    local cmd="$taskset_cmd sysbench --time=$TEST_TIME --max-requests=$MAX_REQUESTS --threads=$threads --report-interval=1 --tables=$TABLES --table-size=$TABLE_SIZE --db-driver=mysql --mysql-host=$DB_HOST --mysql-port=$DB_PORT --mysql-user=$DB_USER --mysql-password=$DB_PASSWORD --mysql-db=$DB_NAME --percentile=99 $mode run"
    
    log_info "Executing: $cmd"
    eval "$cmd" > "$output_file" 2>&1
    local exit_code=$?
    
    # Stop monitoring
    stop_tmc
    stop_emon
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "Sysbench test failed with exit code: $exit_code"
        return 1
    fi
    
    # Parse results
    parse_sysbench_results "$output_file" "$mode" "$threads" "$cmd"
    
    log_info "Sysbench test completed: $mode with $threads threads"
    return 0
}

parse_sysbench_results() {
    local output_file="$1"
    local mode="$2"
    local threads="$3"
    local command="$4"
    
    log_info "Parsing Sysbench results from: $output_file"
    
    # Extract TPS (Transactions Per Second)
    local tps=$(grep "transactions:" "$output_file" | grep -o "([0-9.]*" | grep -o "[0-9.]*" | head -1)
    
    # Extract 99th percentile latency
    local latency_99th=$(grep "99th percentile:" "$output_file" | grep -o "[0-9.]*" | head -1)
    
    # Extract average latency
    local avg_latency=$(grep "avg:" "$output_file" | grep -o "[0-9.]*" | head -1)
    
    # Extract min/max latency
    local min_latency=$(grep "min:" "$output_file" | grep -o "[0-9.]*" | head -1)
    local max_latency=$(grep "max:" "$output_file" | grep -o "[0-9.]*" | head -1)
    
    # Extract total transactions
    local total_transactions=$(grep "transactions:" "$output_file" | grep -o "^[0-9]*" | head -1)
    
    if [[ -n "$tps" ]]; then
        log_info "TPS: $tps"
        local test_case="${mode}_${threads}threads"
        save_result_to_csv "$test_case" "$command" "TPS" "$tps"
    else
        log_error "Failed to extract TPS from output"
    fi
    
    if [[ -n "$latency_99th" ]]; then
        log_info "99th Percentile Latency: ${latency_99th}ms"
        local test_case="${mode}_${threads}threads_99th_latency"
        save_result_to_csv "$test_case" "$command" "99th_Percentile_Latency_ms" "$latency_99th"
    fi
    
    if [[ -n "$avg_latency" ]]; then
        log_info "Average Latency: ${avg_latency}ms"
        local test_case="${mode}_${threads}threads_avg_latency"
        save_result_to_csv "$test_case" "$command" "Average_Latency_ms" "$avg_latency"
    fi
    
    if [[ -n "$total_transactions" ]]; then
        log_info "Total Transactions: $total_transactions"
        local test_case="${mode}_${threads}threads_total"
        save_result_to_csv "$test_case" "$command" "Total_Transactions" "$total_transactions"
    fi
    
    # Display summary
    echo "========================================="
    echo "Sysbench Results - $mode ($threads threads)"
    echo "========================================="
    echo "TPS: ${tps:-N/A}"
    echo "99th Percentile Latency: ${latency_99th:-N/A} ms"
    echo "Average Latency: ${avg_latency:-N/A} ms"
    echo "Min Latency: ${min_latency:-N/A} ms"
    echo "Max Latency: ${max_latency:-N/A} ms"
    echo "Total Transactions: ${total_transactions:-N/A}"
    echo "Output File: $output_file"
    echo "========================================="
    
    return 0
}

run_core_scaling_test() {
    local max_cores="$1"
    
    log_info "Running core scaling test up to $max_cores cores with step $SCALING_STEP..."
    
    # Prepare data once for scaling test
    prepare_sysbench_data "$max_cores" || return 1
    
    # Test with different core counts
    for ((cores = SCALING_STEP; cores <= max_cores; cores += SCALING_STEP)); do
        log_info "Testing with $cores cores..."
        
        # Run all test modes for this core count
        for mode in "${TEST_MODES[@]}"; do
            # Temporarily set CORES for this test
            local original_cores="$CORES"
            CORES="$cores"
            
            run_sysbench_test "$cores" "$mode"
            
            # Restore original CORES setting
            CORES="$original_cores"
            
            sleep 5  # Brief pause between tests
        done
    done
    
    # Cleanup data after scaling test
    cleanup_sysbench_data "$max_cores"
    
    log_info "Core scaling test completed"
}

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  --cores N              Number of CPU cores to use"
    echo "  --threads N            Number of database threads (default: same as cores)"
    echo "  --db-host HOST         Database host (default: 127.0.0.1)"
    echo "  --db-port PORT         Database port (default: 3306)"
    echo "  --db-name NAME         Database name (default: sysbench)"
    echo "  --db-user USER         Database user (default: root)"
    echo "  --db-password PASS     Database password (default: intel123)"
    echo "  --test-time N          Test duration in seconds (default: 60)"
    echo "  --tables N             Number of tables (default: 10)"
    echo "  --table-size N         Table size (default: 5000000)"
    echo "  --test-modes MODES     Test modes (default: oltp_read_only,oltp_write_only,oltp_read_write)"
    echo "  --core-scaling         Enable core scaling test"
    echo "  --scaling-step N       Core scaling step size (default: 16)"
    echo "  --emon                 Enable EMON performance monitoring"
    echo "  --emon-session NAME    EMON session name"
    echo "  --tmc                  Enable TMC monitoring"
    echo "  --workload-name NAME   Custom workload name"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "EXAMPLES:"
    echo "  $0 --cores 8 --threads 8"
    echo "  $0 --cores 32 --core-scaling --scaling-step 16"
    echo "  $0 --cores 16 --emon --emon-session sysbench_test"
    echo "  $0 --cores 8 --db-host 192.168.1.100 --db-password mypassword"
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cores)
                CORES="$2"
                shift 2
                ;;
            --threads)
                THREADS="$2"
                shift 2
                ;;
            --db-host)
                DB_HOST="$2"
                shift 2
                ;;
            --db-port)
                DB_PORT="$2"
                shift 2
                ;;
            --db-name)
                DB_NAME="$2"
                shift 2
                ;;
            --db-user)
                DB_USER="$2"
                shift 2
                ;;
            --db-password)
                DB_PASSWORD="$2"
                shift 2
                ;;
            --test-time)
                TEST_TIME="$2"
                shift 2
                ;;
            --tables)
                TABLES="$2"
                shift 2
                ;;
            --table-size)
                TABLE_SIZE="$2"
                shift 2
                ;;
            --test-modes)
                IFS=',' read -ra TEST_MODES <<< "$2"
                shift 2
                ;;
            --core-scaling)
                CORE_SCALING=true
                shift
                ;;
            --scaling-step)
                SCALING_STEP="$2"
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
    
    # Set default threads to cores if not specified
    if [[ -z "$THREADS" ]]; then
        THREADS="$CORES"
    fi
    
    # Check if Sysbench is installed
    if ! command_exists sysbench; then
        log_error "Sysbench not found. Please run setup_sysbench.sh first"
        exit 1
    fi
    
    # Setup results directory
    setup_results_dir
    
    # Check MySQL connection
    check_mysql_connection || exit 1
    
    log_info "Starting Sysbench benchmark..."
    log_info "Cores: $CORES"
    log_info "Threads: $THREADS"
    log_info "Database: $DB_HOST:$DB_PORT/$DB_NAME"
    log_info "User: $DB_USER"
    log_info "Test Time: $TEST_TIME seconds"
    log_info "Tables: $TABLES"
    log_info "Table Size: $TABLE_SIZE"
    log_info "Test Modes: ${TEST_MODES[*]}"
    log_info "Core Scaling: $CORE_SCALING"
    log_info "EMON: $([ $EMON_ENABLED -eq 1 ] && echo "Enabled ($EMON_SESSION)" || echo "Disabled")"
    log_info "TMC: $([ $TMC_ENABLED -eq 1 ] && echo "Enabled" || echo "Disabled")"
    log_info "Results will be saved to: $EXCEL_FILE"
    
    # Run benchmark
    if [[ "$CORE_SCALING" == "true" ]]; then
        run_core_scaling_test "$CORES"
    else
        # Prepare data
        prepare_sysbench_data "$THREADS" || exit 1
        
        # Run tests for each mode
        for mode in "${TEST_MODES[@]}"; do
            run_sysbench_test "$THREADS" "$mode" || {
                log_error "Test failed for mode: $mode"
                cleanup_sysbench_data "$THREADS"
                exit 1
            }
        done
        
        # Cleanup data
        cleanup_sysbench_data "$THREADS"
    fi
    
    log_info "Sysbench benchmark completed"
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
