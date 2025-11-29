#!/bin/bash
# ffmpeg_workload.sh - FFmpeg video encoding benchmark workload script

# =============================================================================
# FFMPEG WORKLOAD SCRIPT
# =============================================================================
# This script runs FFmpeg video encoding benchmark and collects performance metrics
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
EXCEL_FILE="$RESULTS_DIR/ffmpeg_results.csv"

# Default values
CORES=""
EMON_ENABLED=0
EMON_SESSION=""
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
    
    # Start monitoring
    start_emon
    start_tmc
    
    # Build FFmpeg command
    local cmd="$taskset_cmd ffmpeg -y -i \"$INPUT_FILE\" -c:v lib${CODEC} -preset $PRESET -crf $CRF -tune $TUNE -threads $THREADS \"$encoded_file\""
    log_info "Executing: $cmd"
    
    # Run the benchmark
    eval "$cmd" > "$output_file" 2>&1
    local exit_code=$?
    
    # Stop monitoring
    stop_tmc
    stop_emon
    
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
    
    # Start monitoring
    start_emon
    start_tmc
    
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
    
    # Stop monitoring
    stop_tmc
    stop_emon
    
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
    echo "OPTIONS:"
    echo "  --cores N              Number of CPU cores to use"
    echo "  --codec CODEC          Video codec (x264 or x265, default: x264)"
    echo "  --preset PRESET        Encoding preset (ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow)"
    echo "  --crf N                Constant Rate Factor (0-51, default: 24)"
    echo "  --tune TUNE            Tune setting (film, animation, grain, stillimage, psnr, ssim, fastdecode, zerolatency)"
    echo "  --threads N            FFmpeg threads (default: 16)"
    echo "  --input FILE           Input video file"
    echo "  --test-type TYPE       Test type: single, scaling, multi (default: single)"
    echo "  --instances N          Number of instances for multi test (default: 1)"
    echo "  --emon                 Enable EMON performance monitoring"
    echo "  --emon-session NAME    EMON session name"
    echo "  --tmc                  Enable TMC monitoring"
    echo "  --workload-name NAME   Custom workload name"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "EXAMPLES:"
    echo "  $0 --cores 8 --codec x264 --preset medium"
    echo "  $0 --cores 16 --test-type scaling"
    echo "  $0 --cores 32 --test-type multi --instances 8"
    echo "  $0 --cores 8 --emon --emon-session ffmpeg_test"
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cores)
                CORES="$2"
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
    
    # Check if FFmpeg is installed
    if ! command_exists ffmpeg; then
        log_error "FFmpeg not found. Please run setup_ffmpeg.sh first"
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
    
    # Setup results directory
    setup_results_dir
    
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
    
    log_info "FFmpeg benchmark completed"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up..."
    stop_tmc
    stop_emon
    
    # Clean up any remaining temp files
    rm -f /tmp/ffmpeg_fps_* /tmp/ffmpeg_speed_*
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Run main function
main "$@"
