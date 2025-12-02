#!/bin/bash
# ffmpeg_workload.sh - FFmpeg video encoding benchmark workload script with EMON integration

# =============================================================================
# FFMPEG WORKLOAD SCRIPT WITH EMON INTEGRATION
# =============================================================================
# This script runs FFmpeg video encoding benchmark and collects performance metrics
# Supports both standalone EMON execution and wrapper integration
# Compatible with main wrapper script that uses --cpu-cores parameter
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
EXCEL_FILE="$RESULTS_DIR/ffmpeg_results.csv"

# Default values
CORES=""
CPU_CORES=""  # New parameter for wrapper compatibility
EMON_ENABLED=0
EMON_SESSION=""
EMON_USER=""
EMON_SERVER=""
EMON_GROUP=""
EMON_DURATION=""
EMON_CHART_VIEWS="core,socket"
EMON_OUTPUT_DIR=""
TMC_PATH="/root/tmc/tmc.py"
TMC_ENABLED=0
CODEC="x264"
PRESET="medium"
CRF=24
TUNE="psnr"
THREADS=16
INPUT_FILE=""
WORKLOAD_NAME="FFmpeg"
TEST_TYPE="single"  # single or scaling or all_cores
INSTANCES=1
METRIC_UNIT="FPS"

# EMON variables
EMON_PID=""
TMC_PID=""
WRAPPER_SCRIPT=""

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Parse CPU cores parameter (supports both --cores N and --cpu-cores 0-N formats)
parse_cpu_cores() {
    if [[ -n "$CPU_CORES" ]]; then
        # Handle range format from wrapper (e.g., "0-7")
        if [[ "$CPU_CORES" =~ ^[0-9]+-[0-9]+$ ]]; then
            local start_core=$(echo "$CPU_CORES" | cut -d'-' -f1)
            local end_core=$(echo "$CPU_CORES" | cut -d'-' -f2)
            CORES=$((end_core - start_core + 1))
            log_info "Parsed CPU cores range $CPU_CORES to $CORES cores"
        # Handle single core number
        elif [[ "$CPU_CORES" =~ ^[0-9]+$ ]]; then
            CORES="$CPU_CORES"
            log_info "Using $CORES cores from cpu-cores parameter"
        else
            log_error "Invalid cpu-cores format: $CPU_CORES (expected: N or N-M)"
            return 1
        fi
    fi
    
    # Validate cores parameter
    if [[ -z "$CORES" ]] || [[ ! "$CORES" =~ ^[0-9]+$ ]] || [[ "$CORES" -le 0 ]]; then
        log_error "Invalid cores value: $CORES"
        return 1
    fi
    
    return 0
}

validate_emon_params() {
    if [[ $EMON_ENABLED -eq 1 ]]; then
        if [[ -z "$EMON_SESSION" ]]; then
            log_error "EMON session name is required when --emon is enabled. Use --emon-session"
            return 1
        fi
        
        # Check if TMC script exists and is executable
        if [[ ! -f "$TMC_PATH" ]]; then
            log_error "TMC script not found at: $TMC_PATH"
            log_error "Use --tmc-path to specify correct path"
            return 1
        fi
        
        if [[ ! -x "$TMC_PATH" ]]; then
            log_error "TMC script is not executable: $TMC_PATH"
            return 1
        fi
        
        # Set default EMON output directory if not specified
        if [[ -z "$EMON_OUTPUT_DIR" ]]; then
            EMON_OUTPUT_DIR="$RESULTS_DIR/emon_${EMON_SESSION}_$(date +%Y%m%d_%H%M%S)"
        fi
        
        # Create EMON output directory
        mkdir -p "$EMON_OUTPUT_DIR"
        
        log_info "EMON validation passed"
        log_info "EMON Session: $EMON_SESSION"
        log_info "EMON Output Dir: $EMON_OUTPUT_DIR"
        log_info "TMC Path: $TMC_PATH"
    fi
    
    return 0
}

create_system_info_file() {
    local output_file="$EMON_OUTPUT_DIR/system_info.txt"
    
    log_info "Creating system info file: $output_file"
    
    cat > "$output_file" << EOF
# System Information for EMON Session: $EMON_SESSION
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

[SYSTEM_INFO]
Hostname: $(hostname)
OS: $(uname -a)
CPU_Info: $(lscpu | grep "Model name" | cut -d: -f2 | xargs)
CPU_Cores: $(nproc)
Memory: $(free -h | grep "Mem:" | awk '{print $2}')
Kernel: $(uname -r)

[WORKLOAD_CONFIG]
Workload_Name: $WORKLOAD_NAME
Test_Type: $TEST_TYPE
Cores_Used: $CORES
Codec: $CODEC
Preset: $PRESET
CRF: $CRF
Tune: $TUNE
Threads: $THREADS
Input_File: $(basename "$INPUT_FILE")
Instances: $INSTANCES

[EMON_CONFIG]
Session: $EMON_SESSION
User: $EMON_USER
Server: $EMON_SERVER
Group: $EMON_GROUP
Duration: $EMON_DURATION
Chart_Views: $EMON_CHART_VIEWS
Output_Dir: $EMON_OUTPUT_DIR

[TIMESTAMPS]
Start_Time: $(date '+%Y-%m-%d %H:%M:%S')
EOF

    log_info "System info file created successfully"
}

create_workload_result_file() {
    local fps="$1"
    local speed="$2"
    local test_case="$3"
    local output_file="$EMON_OUTPUT_DIR/workload_result.txt"
    
    log_info "Creating workload result file: $output_file"
    
    cat > "$output_file" << EOF
# Workload Results for EMON Session: $EMON_SESSION
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

workload_name:"$WORKLOAD_NAME"
metric_type:"Throughput"
result:"$fps"
metric:"$METRIC_UNIT"
num_instances:$INSTANCES
sockets:1
cores_used:$CORES
total_cores:$(nproc)
notes:"FFmpeg encoding test with $CORES cores, $CODEC codec, $PRESET preset"
test_date:"$(date '+%Y-%m-%d %H:%M:%S')"
hostname:"$(hostname)"

[PERFORMANCE_RESULTS]
Test_Case: $test_case
FPS: $fps
Speed: ${speed}x
Metric_Unit: $METRIC_UNIT
Workload_Name: $WORKLOAD_NAME

[EXECUTION_DETAILS]
Cores_Used: $CORES
Codec: $CODEC
Preset: $PRESET
Success: $([ -n "$fps" ] && [ "$fps" != "0" ] && echo "true" || echo "false")
Completion_Time: $(date '+%Y-%m-%d %H:%M:%S')

[SUMMARY]
Primary_Metric: $fps $METRIC_UNIT
Secondary_Metric: ${speed}x Speed
Test_Status: COMPLETED
EOF

    log_info "Workload result file created successfully"
}

create_emon_wrapper_script() {
    WRAPPER_SCRIPT="/tmp/ffmpeg_emon_wrapper_$$.sh"
    
    log_info "Creating EMON wrapper script: $WRAPPER_SCRIPT"
    
    cat > "$WRAPPER_SCRIPT" << 'EOF'
#!/bin/bash
# Auto-generated EMON wrapper script for FFmpeg workload

# Source the original script functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_SCRIPT="__ORIGINAL_SCRIPT__"

# Import variables and functions from original script
source "$ORIGINAL_SCRIPT"

# Override some variables for EMON execution
EMON_ENABLED=1
EMON_SESSION="__EMON_SESSION__"
EMON_OUTPUT_DIR="__EMON_OUTPUT_DIR__"
CORES="__CORES__"
CODEC="__CODEC__"
PRESET="__PRESET__"
CRF="__CRF__"
TUNE="__TUNE__"
THREADS="__THREADS__"
INPUT_FILE="__INPUT_FILE__"
TEST_TYPE="__TEST_TYPE__"
INSTANCES="__INSTANCES__"
WORKLOAD_NAME="__WORKLOAD_NAME__"

# Main execution function for EMON
main_emon_execution() {
    log_info "Starting EMON wrapper execution"
    
    # Create system info file
    create_system_info_file
    
    # Setup results directory
    setup_results_dir
    
    # Run the actual workload based on test type
    local fps speed test_case
    
    case "$TEST_TYPE" in
        single)
            run_single_instance "$CORES"
            # Extract results from the last CSV entry
            local last_result=$(tail -1 "$EXCEL_FILE")
            fps=$(echo "$last_result" | cut -d',' -f6 | tr -d '"')
            speed=$(echo "$last_result" | cut -d',' -f7 | tr -d '"')
            test_case="Single_${CORES}cores_${CODEC}_${PRESET}"
            ;;
        scaling)
            run_core_scaling_test "$CORES"
            # For scaling test, use the highest core count result
            local last_result=$(tail -1 "$EXCEL_FILE")
            fps=$(echo "$last_result" | cut -d',' -f6 | tr -d '"')
            speed=$(echo "$last_result" | cut -d',' -f7 | tr -d '"')
            test_case="Scaling_up_to_${CORES}cores"
            ;;
        multi)
            run_multiple_instances "$CORES" "$INSTANCES"
            local last_result=$(tail -1 "$EXCEL_FILE")
            fps=$(echo "$last_result" | cut -d',' -f6 | tr -d '"')
            speed=$(echo "$last_result" | cut -d',' -f7 | tr -d '"')
            test_case="Multi_${INSTANCES}x${CORES}cores"
            ;;
    esac
    
    # Create workload result file
    create_workload_result_file "$fps" "$speed" "$test_case"
    
    # Output performance result for wrapper parsing
    echo "Performance: $fps"
    echo "Throughput: $fps"
    echo "Score: $fps"
    
    log_info "EMON wrapper execution completed"
    
    # Return success/failure based on results
    if [[ -n "$fps" ]] && [[ "$fps" != "0" ]]; then
        return 0
    else
        return 1
    fi
}

# Execute main function
main_emon_execution
EOF

    # Replace placeholders in the wrapper script
    sed -i "s|__ORIGINAL_SCRIPT__|$0|g" "$WRAPPER_SCRIPT"
    sed -i "s|__EMON_SESSION__|$EMON_SESSION|g" "$WRAPPER_SCRIPT"
    sed -i "s|__EMON_OUTPUT_DIR__|$EMON_OUTPUT_DIR|g" "$WRAPPER_SCRIPT"
    sed -i "s|__CORES__|$CORES|g" "$WRAPPER_SCRIPT"
    sed -i "s|__CODEC__|$CODEC|g" "$WRAPPER_SCRIPT"
    sed -i "s|__PRESET__|$PRESET|g" "$WRAPPER_SCRIPT"
    sed -i "s|__CRF__|$CRF|g" "$WRAPPER_SCRIPT"
    sed -i "s|__TUNE__|$TUNE|g" "$WRAPPER_SCRIPT"
    sed -i "s|__THREADS__|$THREADS|g" "$WRAPPER_SCRIPT"
    sed -i "s|__INPUT_FILE__|$INPUT_FILE|g" "$WRAPPER_SCRIPT"
    sed -i "s|__TEST_TYPE__|$TEST_TYPE|g" "$WRAPPER_SCRIPT"
    sed -i "s|__INSTANCES__|$INSTANCES|g" "$WRAPPER_SCRIPT"
    sed -i "s|__WORKLOAD_NAME__|$WORKLOAD_NAME|g" "$WRAPPER_SCRIPT"
    
    chmod +x "$WRAPPER_SCRIPT"
    log_info "EMON wrapper script created and made executable"
}

execute_with_tmc() {
    log_info "Executing workload with TMC/EMON integration"
    
    # Build TMC command with correct parameter mapping
    local tmc_cmd="python3 \"$TMC_PATH\""
    
    # Required parameters
    tmc_cmd="$tmc_cmd -c \"$WRAPPER_SCRIPT\""  # TARGET_CMD
    tmc_cmd="$tmc_cmd -d \"$EMON_OUTPUT_DIR\""  # DIR
    
    # Optional parameters with proper TMC argument mapping
    if [[ -n "$EMON_SESSION" ]]; then
        tmc_cmd="$tmc_cmd -i \"$EMON_SESSION\""  # IDENTITY_COMMENT
    fi
    
    if [[ -n "$EMON_USER" ]]; then
        tmc_cmd="$tmc_cmd -x \"$EMON_USER\""  # USER
    fi
    
    if [[ -n "$EMON_SERVER" ]]; then
        tmc_cmd="$tmc_cmd -Z \"$EMON_SERVER\""  # SERVER
    fi
    
    if [[ -n "$EMON_GROUP" ]]; then
        tmc_cmd="$tmc_cmd -G \"$EMON_GROUP\""  # GROUP
    fi
    
    if [[ -n "$EMON_DURATION" ]] && [[ "$EMON_DURATION" =~ ^[0-9]+$ ]] && [[ "$EMON_DURATION" -gt 0 ]]; then
        tmc_cmd="$tmc_cmd -t $EMON_DURATION"  # TIME_DURATION
    fi
    
    if [[ -n "$EMON_CHART_VIEWS" ]]; then
        tmc_cmd="$tmc_cmd -w \"$EMON_CHART_VIEWS\""  # CHART_VIEWS
    fi
    
    log_info "TMC Command: $tmc_cmd"
    
    # Execute TMC command
    eval "$tmc_cmd"
    local tmc_exit_code=$?
    
    if [[ $tmc_exit_code -eq 0 ]]; then
        log_info "TMC execution completed successfully"
        
        # Display EMON results summary
        echo "========================================="
        echo "EMON Integration Results"
        echo "========================================="
        echo "Session: $EMON_SESSION"
        echo "Output Directory: $EMON_OUTPUT_DIR"
        echo "System Info: $EMON_OUTPUT_DIR/system_info.txt"
        echo "Results: $EMON_OUTPUT_DIR/workload_result.txt"
        
        if [[ -f "$EMON_OUTPUT_DIR/workload_result.txt" ]]; then
            echo ""
            echo "Performance Results:"
            grep -E "(FPS|Speed|Primary_Metric|result:)" "$EMON_OUTPUT_DIR/workload_result.txt" | sed 's/^/  /'
        fi
        echo "========================================="
        
        return 0
    else
        log_error "TMC execution failed with exit code: $tmc_exit_code"
        log_info "Check TMC logs in: $EMON_OUTPUT_DIR"
        return 1
    fi
}

setup_results_dir() {
    mkdir -p "$RESULTS_DIR"
    
    # Create CSV header if file doesn't exist
    if [ ! -f "$EXCEL_FILE" ]; then
        echo "Date,Workload Name,Test Case,Command,KPI,Score(FPS),Score(Speed)" > "$EXCEL_FILE"
        log_info "Created results CSV file: $EXCEL_FILE"
    fi
}

save_result_to_csv() {
    local test_case="$1"
    local command="$2"
    local fps="$3"
    local speed="$4"
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "\"$date\",\"$WORKLOAD_NAME\",\"$test_case\",\"$command\",\"Video Encoding\",\"$fps\",\"$speed\"" >> "$EXCEL_FILE"
    log_info "Result saved to CSV: $test_case - FPS: $fps, Speed: $speed"
}

start_emon() {
    if [[ $EMON_ENABLED -eq 1 ]] && [[ $EMON_ENABLED -ne 2 ]] && command_exists emon; then
        log_info "Starting EMON collection with session: $EMON_SESSION"
        emon -i "$EMON_SESSION" &
        EMON_PID=$!
        sleep 2
        log_info "EMON started with PID: $EMON_PID"
    fi
}

stop_emon() {
    if [[ $EMON_ENABLED -eq 1 ]] && [[ $EMON_ENABLED -ne 2 ]] && [[ -n "$EMON_PID" ]]; then
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

get_default_input_file() {
    # Primary video file from Intel Artifactory
    local primary_video="$SCRIPT_DIR/lg_4k_oled_paris_hevc_1920x1080_420_8_23.98_25.9.mkv"
    
    if [[ -f "$primary_video" ]]; then
        echo "$primary_video"
        return 0
    fi
    
    # Look for fallback sample video
    local fallback_video="$SCRIPT_DIR/sample_video.mp4"
    if [[ -f "$fallback_video" ]]; then
        log_info "Using fallback video file: sample_video.mp4"
        echo "$fallback_video"
        return 0
    fi
    
    # Look for any existing video files in the script directory
    for ext in mkv mp4 avi mov; do
        local file=$(find "$SCRIPT_DIR" -name "*.$ext" | head -1)
        if [[ -n "$file" ]]; then
            log_info "Using existing video file: $(basename "$file")"
            echo "$file"
            return 0
        fi
    done
    
    # If no video file found, create a test pattern
    local test_file="$SCRIPT_DIR/test_input.mp4"
    if [[ ! -f "$test_file" ]]; then
        log_info "No video file found. Creating test input video..."
        log_info "This may take a few moments..."
        
        # Create a 30-second 1080p test pattern
        ffmpeg -f lavfi -i testsrc2=duration=30:size=1920x1080:rate=30 \
               -c:v libx264 -preset fast -crf 23 \
               "$test_file" -y >/dev/null 2>&1 || {
            log_error "Failed to create test input video"
            return 1
        }
        
        log_info "Test input video created: $(basename "$test_file")"
    fi
    
    echo "$test_file"
}

extract_fps_speed() {
    local log_file="$1"
    
    # Extract FPS and speed from FFmpeg output
    local fps=$(grep "fps=" "$log_file" | tail -1 | sed -n 's/.*fps=\s*\([0-9.]*\).*/\1/p')
    local speed=$(grep "speed=" "$log_file" | tail -1 | sed -n 's/.*speed=\s*\([0-9.]*\)x.*/\1/p')
    
    # If not found in progress lines, try final summary line
    if [[ -z "$fps" ]] || [[ -z "$speed" ]]; then
        local summary_line=$(grep "Lsize" "$log_file" | tail -1)
        if [[ -n "$summary_line" ]]; then
            fps=$(echo "$summary_line" | sed -n 's/.*fps=\s*\([0-9.]*\).*/\1/p')
            speed=$(echo "$summary_line" | sed -n 's/.*speed=\s*\([0-9.]*\)x.*/\1/p')
        fi
    fi
    
    # Default values if extraction failed
    fps=${fps:-0}
    speed=${speed:-0}
    
    echo "$fps $speed"
}

run_single_instance() {
    local cores="$1"
    local output_file="$RESULTS_DIR/ffmpeg_single_${cores}cores_$(date +%Y%m%d_%H%M%S).txt"
    local encoded_file="$RESULTS_DIR/output_${cores}cores.${CODEC}"
    
    log_info "Running single FFmpeg instance with $cores cores..."
    
    # Set CPU affinity if cores specified
    local taskset_cmd=""
    if [[ -n "$cores" ]] && [[ "$cores" != "0" ]]; then
        local core_list=$(seq -s, 0 $((cores-1)))
        taskset_cmd="taskset -c $core_list"
        log_info "Using CPU cores: $core_list"
    fi
    
    # Start monitoring (only if not using TMC integration)
    if [[ $EMON_ENABLED -ne 2 ]]; then
        start_emon
        start_tmc
    fi
    
    # Build FFmpeg command
    local cmd="$taskset_cmd ffmpeg -y -i \"$INPUT_FILE\" -c:v lib${CODEC} -preset $PRESET -crf $CRF -tune $TUNE -threads $THREADS \"$encoded_file\""
    log_info "Executing: $cmd"
    
    # Run the benchmark
    eval "$cmd" > "$output_file" 2>&1
    local exit_code=$?
    
    # Stop monitoring (only if not using TMC integration)
    if [[ $EMON_ENABLED -ne 2 ]]; then
        stop_tmc
        stop_emon
    fi
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "FFmpeg encoding failed with exit code: $exit_code"
        return 1
    fi
    
    # Parse results
    local fps_speed=$(extract_fps_speed "$output_file")
    local fps=$(echo "$fps_speed" | cut -d' ' -f1)
    local speed=$(echo "$fps_speed" | cut -d' ' -f2)
    
    # Save results
    local test_case="Single_${cores}cores_${CODEC}_${PRESET}"
    save_result_to_csv "$test_case" "$cmd" "$fps" "$speed"
    
    # Output performance result in multiple formats for wrapper parsing
    echo "Performance: $fps"
    echo "Throughput: $fps"
    echo "Score: $fps"
    echo "FPS: $fps"
    
    # Display results
    echo "========================================="
    echo "FFmpeg Single Instance Results"
    echo "========================================="
    echo "Cores Used: $cores"
    echo "Codec: $CODEC"
    echo "Preset: $PRESET"
    echo "FPS: $fps"
    echo "Speed: ${speed}x"
    echo "Output File: $output_file"
    echo "Encoded File: $encoded_file"
    echo "========================================="
    
    # Clean up encoded file to save space
    rm -f "$encoded_file"
    
    log_info "Single instance benchmark completed successfully"
    return 0
}

run_multiple_instances() {
    local cores="$1"
    local instances="$2"
    local cores_per_instance=$((cores / instances))
    
    log_info "Running $instances FFmpeg instances with $cores_per_instance cores each..."
    
    local pids=()
    local fps_files=()
    local speed_files=()
    
    # Start monitoring (only if not using TMC integration)
    if [[ $EMON_ENABLED -ne 2 ]]; then
        start_emon
        start_tmc
    fi
    
    # Launch multiple instances
    for i in $(seq 1 $instances); do
        local start_core=$(( (i-1) * cores_per_instance ))
        local end_core=$(( start_core + cores_per_instance - 1 ))
        local core_list=$(seq -s, $start_core $end_core)
        
        local output_file="$RESULTS_DIR/ffmpeg_multi_${i}_${cores_per_instance}cores_$(date +%Y%m%d_%H%M%S).txt"
        local encoded_file="$RESULTS_DIR/output_${i}_${cores_per_instance}cores.${CODEC}"
        local fps_file="/tmp/ffmpeg_fps_$i"
        local speed_file="/tmp/ffmpeg_speed_$i"
        
        fps_files+=("$fps_file")
        speed_files+=("$speed_file")
        
        log_info "Starting instance $i on cores $core_list"
        
        # Run instance in background
        (
            local cmd="taskset -c $core_list ffmpeg -y -i \"$INPUT_FILE\" -c:v lib${CODEC} -preset $PRESET -crf $CRF -tune $TUNE -threads $cores_per_instance \"$encoded_file\""
            eval "$cmd" > "$output_file" 2>&1
            
            # Extract results for this instance
            local fps_speed=$(extract_fps_speed "$output_file")
            local fps=$(echo "$fps_speed" | cut -d' ' -f1)
            local speed=$(echo "$fps_speed" | cut -d' ' -f2)
            
            echo "$fps" > "$fps_file"
            echo "$speed" > "$speed_file"
            
            # Clean up encoded file
            rm -f "$encoded_file"
        ) &
        
        pids+=($!)
    done
    
    # Wait for all instances to complete
    log_info "Waiting for all instances to complete..."
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    # Stop monitoring (only if not using TMC integration)
    if [[ $EMON_ENABLED -ne 2 ]]; then
        stop_tmc
        stop_emon
    fi
    
    # Calculate total FPS and average speed
    local total_fps=0
    local total_speed=0
    local valid_instances=0
    
    for i in $(seq 1 $instances); do
        local fps_file="/tmp/ffmpeg_fps_$i"
        local speed_file="/tmp/ffmpeg_speed_$i"
        
        if [[ -f "$fps_file" ]] && [[ -f "$speed_file" ]]; then
            local fps=$(cat "$fps_file")
            local speed=$(cat "$speed_file")
            
            if [[ -n "$fps" ]] && [[ -n "$speed" ]] && [[ "$fps" != "0" ]]; then
                total_fps=$(echo "$total_fps + $fps" | bc -l)
                total_speed=$(echo "$total_speed + $speed" | bc -l)
                ((valid_instances++))
            fi
        fi
        
        # Clean up temp files
        rm -f "$fps_file" "$speed_file"
    done
    
    if [[ $valid_instances -gt 0 ]]; then
        local avg_speed=$(echo "scale=2; $total_speed / $valid_instances" | bc -l)
        
        # Save results
        local test_case="Multi_${instances}x${cores_per_instance}cores_${CODEC}_${PRESET}"
        local cmd="ffmpeg (${instances} instances)"
        save_result_to_csv "$test_case" "$cmd" "$total_fps" "$avg_speed"
        
        # Output performance result in multiple formats for wrapper parsing
        echo "Performance: $total_fps"
        echo "Throughput: $total_fps"
        echo "Score: $total_fps"
        echo "FPS: $total_fps"
        
        # Display results
        echo "========================================="
        echo "FFmpeg Multiple Instances Results"
        echo "========================================="
        echo "Total Cores Used: $cores"
        echo "Instances: $instances"
        echo "Cores per Instance: $cores_per_instance"
        echo "Codec: $CODEC"
        echo "Preset: $PRESET"
        echo "Total FPS: $total_fps"
        echo "Average Speed: ${avg_speed}x"
        echo "Valid Instances: $valid_instances"
        echo "========================================="
    else
        log_error "No valid results from multiple instances"
        return 1
    fi
    
    # Clean up temp files
    rm -f /tmp/ffmpeg_fps_* /tmp/ffmpeg_speed_*
    
    log_info "Multiple instances benchmark completed successfully"
    return 0
}

run_core_scaling_test() {
    local max_cores="$1"
    
    log_info "Running core scaling test up to $max_cores cores..."
    
    # Test with different core counts: 4, 8, 16, etc.
    local core_counts=(4 8 16 32 64 128)
    
    for cores in "${core_counts[@]}"; do
        if [[ $cores -le $max_cores ]]; then
            log_info "Testing with $cores cores..."
            run_single_instance "$cores"
            sleep 5  # Brief pause between tests
        fi
    done
    
    log_info "Core scaling test completed"
}

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "BASIC OPTIONS:"
    echo "  --cores N              Number of CPU cores to use"
    echo "  --cpu-cores RANGE      CPU cores range (e.g., 0-7) - for wrapper compatibility"
    echo "  --codec CODEC          Video codec (x264 or x265, default: x264)"
    echo "  --preset PRESET        Encoding preset (ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow)"
    echo "  --crf N                Constant Rate Factor (0-51, default: 24)"
    echo "  --tune TUNE            Tune setting (film, animation, grain, stillimage, psnr, ssim, fastdecode, zerolatency)"
    echo "  --threads N            FFmpeg threads (default: 16)"
    echo "  --input FILE           Input video file"
    echo "  --test-type TYPE       Test type: single, scaling, multi (default: single)"
    echo "  --instances N          Number of instances for multi test (default: 1)"
    echo "  --workload-name NAME   Custom workload name (default: FFmpeg)"
    echo ""
    echo "EMON INTEGRATION OPTIONS:"
    echo "  --emon                 Enable EMON performance monitoring"
    echo "  --emon-session NAME    EMON session name (required with --emon)"
    echo "  --emon-user USER       EMON user"
    echo "  --emon-server SERVER   EMON server"
    echo "  --emon-group GROUP     EMON group"
    echo "  --emon-duration SEC    EMON collection duration in seconds"
    echo "  --emon-chart-views V   EMON chart views (default: core,socket)"
    echo "  --emon-output-dir DIR  EMON output directory"
    echo "  --tmc-path PATH        Path to TMC script (default: /root/tmc/tmc.py)"
    echo ""
    echo "OTHER OPTIONS:"
    echo "  --tmc                  Enable TMC monitoring (standalone)"
    echo "  --metric-unit UNIT     Metric unit for results (default: FPS)"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "EXAMPLES:"
    echo "  # Basic usage"
    echo "  $0 --cores 8 --codec x264 --preset medium"
    echo ""
    echo "  # Wrapper compatibility (cores range format)"
    echo "  $0 --cpu-cores 0-7 --codec x264 --preset medium"
    echo ""
    echo "  # Standalone EMON execution"
    echo "  $0 --cores 8 --emon --emon-session \"ffmpeg_test\""
    echo ""
    echo "  # Through wrapper with EMON"
    echo "  ./main_wrapper.sh --script $0 --cores 4 --emon --emon-session \"test\" --workload-name \"FFmpeg\" --metric-unit \"fps\""
    echo ""
    echo "  # Core scaling test with EMON"
    echo "  $0 --cores 16 --test-type scaling --emon --emon-session \"scaling_test\""
    echo ""
    echo "  # Multiple instances with EMON"
    echo "  $0 --cores 32 --test-type multi --instances 8 --emon --emon-session \"multi_test\""
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cores)
                CORES="$2"
                shift 2
                ;;
            --cpu-cores)
                CPU_CORES="$2"
                shift 2
                ;;
            --codec)
                CODEC="$2"
                shift 2
                ;;
            --preset)
                PRESET="$2"
                shift 2
                ;;
            --crf)
                CRF="$2"
                shift 2
                ;;
            --tune)
                TUNE="$2"
                shift 2
                ;;
            --threads)
                THREADS="$2"
                shift 2
                ;;
            --input)
                INPUT_FILE="$2"
                shift 2
                ;;
            --test-type)
                TEST_TYPE="$2"
                shift 2
                ;;
            --instances)
                INSTANCES="$2"
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
            --emon-user)
                EMON_USER="$2"
                shift 2
                ;;
            --emon-server)
                EMON_SERVER="$2"
                shift 2
                ;;
            --emon-group)
                EMON_GROUP="$2"
                shift 2
                ;;
            --emon-duration)
                EMON_DURATION="$2"
                shift 2
                ;;
            --emon-chart-views)
                EMON_CHART_VIEWS="$2"
                shift 2
                ;;
            --emon-output-dir)
                EMON_OUTPUT_DIR="$2"
                shift 2
                ;;
            --tmc-path)
                TMC_PATH="$2"
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
            --metric-unit)
                METRIC_UNIT="$2"
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
    
    # Parse CPU cores parameter (handles both --cores and --cpu-cores)
    if ! parse_cpu_cores; then
        exit 1
    fi
    
    # Validate required parameters
    if [[ -z "$CORES" ]]; then
        log_error "Number of cores must be specified with --cores or --cpu-cores"
        print_usage
        exit 1
    fi
    
    # Validate EMON parameters
    if ! validate_emon_params; then
        exit 1
    fi
    
    # Check if FFmpeg is installed
    if ! command_exists ffmpeg; then
        log_error "FFmpeg not found. Please install FFmpeg first"
        exit 1
    fi
    
    # Set default input file if not provided
    if [[ -z "$INPUT_FILE" ]]; then
        INPUT_FILE=$(get_default_input_file)
        if [[ -z "$INPUT_FILE" ]]; then
            log_error "No input file found and failed to create test input"
            exit 1
        fi
    fi
    
    # Verify input file exists
    if [[ ! -f "$INPUT_FILE" ]]; then
        log_error "Input file not found: $INPUT_FILE"
        exit 1
    fi
    
    log_info "Starting FFmpeg benchmark..."
    log_info "Cores: $CORES"
    log_info "Codec: $CODEC"
    log_info "Preset: $PRESET"
    log_info "CRF: $CRF"
    log_info "Tune: $TUNE"
    log_info "Threads: $THREADS"
    log_info "Input File: $INPUT_FILE"
    log_info "Test Type: $TEST_TYPE"
    log_info "EMON: $([ $EMON_ENABLED -eq 1 ] && echo "Enabled ($EMON_SESSION)" || echo "Disabled")"
    log_info "TMC: $([ $TMC_ENABLED -eq 1 ] && echo "Enabled" || echo "Disabled")"
    
    # Execute based on EMON mode
    if [[ $EMON_ENABLED -eq 1 ]]; then
        # EMON mode - use TMC integration
        EMON_ENABLED=2  # Set to 2 to indicate TMC integration mode
        
        log_info "Running with EMON/TMC integration"
        log_info "Results will be saved to: $EMON_OUTPUT_DIR"
        
        # Create wrapper script and execute with TMC
        create_emon_wrapper_script
        execute_with_tmc
        local exit_code=$?
        
        # Cleanup wrapper script
        rm -f "$WRAPPER_SCRIPT"
        
        exit $exit_code
    else
        # Standard mode
        setup_results_dir
        log_info "Results will be saved to: $EXCEL_FILE"
        
        # Run benchmark based on test type
        case "$TEST_TYPE" in
            single)
                run_single_instance "$CORES"
                ;;
            scaling)
                run_core_scaling_test "$CORES"
                ;;
            multi)
                run_multiple_instances "$CORES" "$INSTANCES"
                ;;
            *)
                log_error "Invalid test type: $TEST_TYPE"
                print_usage
                exit 1
                ;;
        esac
    fi
    
    log_info "FFmpeg benchmark completed"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up..."
    stop_tmc
    stop_emon
    
    # Clean up any remaining temp files
    rm -f /tmp/ffmpeg_fps_* /tmp/ffmpeg_speed_*
    
    # Clean up wrapper script if it exists
    if [[ -n "$WRAPPER_SCRIPT" ]] && [[ -f "$WRAPPER_SCRIPT" ]]; then
        rm -f "$WRAPPER_SCRIPT"
    fi
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Run main function
main "$@"
