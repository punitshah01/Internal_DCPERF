#!/bin/bash
# ffmpeg_workload.sh - FFmpeg video encoding benchmark workload script with EMON integration

# =============================================================================
# FFMPEG WORKLOAD SCRIPT WITH EMON INTEGRATION
# =============================================================================
# This script runs FFmpeg video encoding benchmark and collects performance metrics
# Supports both standalone EMON execution and wrapper integration
# Compatible with main wrapper script that uses --cpu-cores parameter
# =============================================================================

# ------------------------------ DEFAULT VALUES -----------------------------------
DEFAULT_CODEC="x264"
DEFAULT_PRESET="medium"
DEFAULT_CRF=24
DEFAULT_TUNE="psnr"
DEFAULT_THREADS=16
DEFAULT_INSTANCES=1
DEFAULT_TEST_TYPE="single"

# Default EMON/TMC values
DEFAULT_EMON_USER="pshah"
DEFAULT_EMON_SERVER="metrics2"
DEFAULT_EMON_GROUP="ffmpeg"
DEFAULT_TMC_PATH="/root/tmc/tmc.py"

# ------------------------------ VARIABLES -----------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
RESULTS_FILE="$RESULTS_DIR/ffmpeg_results.csv"

# Core parameters
cores=""
cpu_cores=""  # For wrapper compatibility

# FFmpeg parameters
codec=$DEFAULT_CODEC
preset=$DEFAULT_PRESET
crf=$DEFAULT_CRF
tune=$DEFAULT_TUNE
threads=$DEFAULT_THREADS
input_file=""
test_type=$DEFAULT_TEST_TYPE
instances=$DEFAULT_INSTANCES
workload_name="FFmpeg"
metric_unit="FPS"
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
emon_upload=false

# ------------------------------ FUNCTIONS -----------------------------------
print_usage() {
    echo -e "
Usage: $0 --cores N [OPTIONS]
   or: $0 --cpu-cores RANGE [OPTIONS]  (for wrapper compatibility)

REQUIRED:
  --cores N              Number of cores to use (REQUIRED)
  --cpu-cores RANGE      CPU core range (e.g., 0-7 or 0,2,4) - wrapper format

FFMPEG OPTIONS:
  --codec CODEC          Video codec (x264 or x265, default: $DEFAULT_CODEC)
  --preset PRESET        Encoding preset (ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow)
  --crf N                Constant Rate Factor (0-51, default: $DEFAULT_CRF)
  --tune TUNE            Tune setting (film, animation, grain, stillimage, psnr, ssim, fastdecode, zerolatency)
  --threads N            FFmpeg threads (default: $DEFAULT_THREADS)
  --input FILE           Input video file
  --test-type TYPE       Test type: single, scaling, multi (default: $DEFAULT_TEST_TYPE)
  --instances N          Number of instances for multi test (default: $DEFAULT_INSTANCES)
  --workload-name NAME   Custom workload name (default: FFmpeg)
  --metric-unit UNIT     Metric unit for results (default: FPS)
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
  --emon-upload          Upload EMON data to metrics server (default: disabled)
  --tmc-path PATH        Path to TMC script (default: $DEFAULT_TMC_PATH)

EXAMPLES:
  # Basic usage
  $0 --cores 8 --codec x264 --preset medium
  
  # With EMON monitoring (local only)
  $0 --cores 8 --emon --emon-session \"ffmpeg_test\"
  
  # With EMON monitoring and upload to metrics server
  $0 --cores 8 --emon --emon-session \"ffmpeg_test\" --emon-upload
  
  # Wrapper compatibility
  $0 --cpu-cores 0-7 --name custom_test
  
  # Core scaling test with EMON
  $0 --cores 16 --test-type scaling --emon --emon-session \"scaling_test\" --emon-upload
  
  # Multiple instances with EMON
  $0 --cores 32 --test-type multi --instances 8 --emon --emon-session \"multi_test\" --emon-upload
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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

setup_system() {
    log "Setting up system for FFmpeg benchmark..."
    
    # Check if FFmpeg is installed
    if ! command_exists ffmpeg; then
        error_exit "FFmpeg not found. Please install FFmpeg first"
    fi
    
    # Check if taskset is available
    if ! command_exists taskset; then
        error_exit "taskset command not found. Please install util-linux package."
    fi
    
    # Create results directory
    mkdir -p "$RESULTS_DIR"
    
    # Create EMON output directory if EMON is enabled
    if [[ "$enable_emon" == true ]]; then
        mkdir -p "$emon_output_dir"
    fi
    
    # Set default input file if not provided
    if [[ -z "$input_file" ]]; then
        input_file=$(get_default_input_file)
        if [[ -z "$input_file" ]]; then
            error_exit "No input file found and failed to create test input"
        fi
    fi
    
    # Verify input file exists
    if [[ ! -f "$input_file" ]]; then
        error_exit "Input file not found: $input_file"
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
        log "Using fallback video file: sample_video.mp4"
        echo "$fallback_video"
        return 0
    fi
    
    # Look for any existing video files in the script directory
    for ext in mkv mp4 avi mov; do
        local file=$(find "$SCRIPT_DIR" -name "*.$ext" | head -1)
        if [[ -n "$file" ]]; then
            log "Using existing video file: $(basename "$file")"
            echo "$file"
            return 0
        fi
    done
    
    # If no video file found, create a test pattern
    local test_file="$SCRIPT_DIR/test_input.mp4"
    if [[ ! -f "$test_file" ]]; then
        log "No video file found. Creating test input video..."
        log "This may take a few moments..."
        
        # Create a 30-second 1080p test pattern
        ffmpeg -f lavfi -i testsrc2=duration=30:size=1920x1080:rate=30 \
               -c:v libx264 -preset fast -crf 23 \
               "$test_file" -y >/dev/null 2>&1 || {
            log "Failed to create test input video"
            return 1
        }
        
        log "Test input video created: $(basename "$test_file")"
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

# Create a wrapper script for EMON to execute
create_emon_wrapper_script() {
    local cores=$1
    local test_type=$2
    local instances=$3
    local results_dir=$4
    local emon_output_dir=$5
    local session_name=$6
    local wrapper_script="$results_dir/emon_wrapper.sh"
    
    mkdir -p "$results_dir"
    
    cat > "$wrapper_script" << EOF
#!/bin/bash
# EMON wrapper script for FFmpeg execution

set -euo pipefail

RESULTS_DIR="$results_dir"
EMON_OUTPUT_DIR="$emon_output_dir"
SESSION_NAME="$session_name"
CORES=$cores
TEST_TYPE="$test_type"
INSTANCES=$instances
CODEC="$codec"
PRESET="$preset"
CRF="$crf"
TUNE="$tune"
THREADS="$threads"
INPUT_FILE="$input_file"
WORKLOAD_NAME="$workload_name"

# Create results directory structure
TEST_DIR="\$RESULTS_DIR/\${TEST_TYPE}_test"
mkdir -p "\$TEST_DIR"

echo "Running FFmpeg \$TEST_TYPE test with \$CORES cores under EMON..."

# Function to extract FPS and speed from FFmpeg output
extract_fps_speed() {
    fps_log_file="\$1"
    
    fps_result=\$(grep "fps=" "\$fps_log_file" | tail -1 | sed -n 's/.*fps=\\s*\\([0-9.]*\\).*/\\1/p')
    speed_result=\$(grep "speed=" "\$fps_log_file" | tail -1 | sed -n 's/.*speed=\\s*\\([0-9.]*\\)x.*/\\1/p')
    
    if [[ -z "\$fps_result" ]] || [[ -z "\$speed_result" ]]; then
        summary_line=\$(grep "Lsize" "\$fps_log_file" | tail -1)
        if [[ -n "\$summary_line" ]]; then
            fps_result=\$(echo "\$summary_line" | sed -n 's/.*fps=\\s*\\([0-9.]*\\).*/\\1/p')
            speed_result=\$(echo "\$summary_line" | sed -n 's/.*speed=\\s*\\([0-9.]*\\)x.*/\\1/p')
        fi
    fi
    
    fps_result=\${fps_result:-0}
    speed_result=\${speed_result:-0}
    
    echo "\$fps_result \$speed_result"
}

RESULT_FPS=""
RESULT_SPEED=""

case "\$TEST_TYPE" in
    single)
        # Single instance test
        output_file="\$TEST_DIR/ffmpeg_single.log"
        encoded_file="\$TEST_DIR/output_single.\${CODEC}"
        
        # Set CPU affinity
        core_list=\$(seq -s, 0 \$((CORES-1)))
        
        # Run FFmpeg
        cmd="taskset -c \$core_list ffmpeg -y -i \"\$INPUT_FILE\" -c:v lib\${CODEC} -preset \$PRESET -crf \$CRF -tune \$TUNE -threads \$THREADS \"\$encoded_file\""
        echo "Executing: \$cmd"
        eval "\$cmd" > "\$output_file" 2>&1
        
        # Extract results
        fps_speed_result=\$(extract_fps_speed "\$output_file")
        RESULT_FPS=\$(echo "\$fps_speed_result" | cut -d' ' -f1)
        RESULT_SPEED=\$(echo "\$fps_speed_result" | cut -d' ' -f2)
        
        # Clean up encoded file
        rm -f "\$encoded_file"
        ;;
        
    multi)
        # Multiple instances test
        cores_per_instance=\$((CORES / INSTANCES))
        pids=()
        fps_files=()
        speed_files=()
        
        echo "Running \$INSTANCES instances with \$cores_per_instance cores each"
        
        # Launch multiple instances
        for i in \$(seq 1 \$INSTANCES); do
            start_core=\$(( (i-1) * cores_per_instance ))
            end_core=\$(( start_core + cores_per_instance - 1 ))
            core_list=\$(seq -s, \$start_core \$end_core)
            
            output_file="\$TEST_DIR/ffmpeg_multi_\${i}.log"
            encoded_file="\$TEST_DIR/output_\${i}.\${CODEC}"
            fps_file="/tmp/ffmpeg_fps_\$i"
            speed_file="/tmp/ffmpeg_speed_\$i"
            
            fps_files+=("\$fps_file")
            speed_files+=("\$speed_file")
            
            echo "Starting instance \$i on cores \$core_list"
            
            # Run instance in background
            (
                cmd="taskset -c \$core_list ffmpeg -y -i \"\$INPUT_FILE\" -c:v lib\${CODEC} -preset \$PRESET -crf \$CRF -tune \$TUNE -threads \$cores_per_instance \"\$encoded_file\""
                eval "\$cmd" > "\$output_file" 2>&1
                
                fps_speed_result=\$(extract_fps_speed "\$output_file")
                fps_val=\$(echo "\$fps_speed_result" | cut -d' ' -f1)
                speed_val=\$(echo "\$fps_speed_result" | cut -d' ' -f2)
                
                echo "\$fps_val" > "\$fps_file"
                echo "\$speed_val" > "\$speed_file"
                
                rm -f "\$encoded_file"
            ) &
            
            pids+=(\$!)
        done
        
        # Wait for all instances to complete
        echo "Waiting for all instances to complete..."
        for pid in "\${pids[@]}"; do
            wait \$pid
        done
        
        # Calculate total FPS and average speed
        total_fps=0
        total_speed=0
        valid_instances=0
        
        for i in \$(seq 1 \$INSTANCES); do
            fps_file="/tmp/ffmpeg_fps_\$i"
            speed_file="/tmp/ffmpeg_speed_\$i"
            
            if [[ -f "\$fps_file" ]] && [[ -f "\$speed_file" ]]; then
                fps_val=\$(cat "\$fps_file")
                speed_val=\$(cat "\$speed_file")
                
                if [[ -n "\$fps_val" ]] && [[ -n "\$speed_val" ]] && [[ "\$fps_val" != "0" ]]; then
                    total_fps=\$(echo "\$total_fps + \$fps_val" | bc -l)
                    total_speed=\$(echo "\$total_speed + \$speed_val" | bc -l)
                    ((valid_instances++))
                fi
            fi
            
            rm -f "\$fps_file" "\$speed_file"
        done
        
        if [[ \$valid_instances -gt 0 ]]; then
            RESULT_FPS="\$total_fps"
            RESULT_SPEED=\$(echo "scale=2; \$total_speed / \$valid_instances" | bc -l)
        else
            RESULT_FPS="0"
            RESULT_SPEED="0"
        fi
        ;;
        
    scaling)
        # Core scaling test - run with maximum cores
        output_file="\$TEST_DIR/ffmpeg_scaling.log"
        encoded_file="\$TEST_DIR/output_scaling.\${CODEC}"
        
        core_list=\$(seq -s, 0 \$((CORES-1)))
        
        cmd="taskset -c \$core_list ffmpeg -y -i \"\$INPUT_FILE\" -c:v lib\${CODEC} -preset \$PRESET -crf \$CRF -tune \$TUNE -threads \$THREADS \"\$encoded_file\""
        echo "Executing: \$cmd"
        eval "\$cmd" > "\$output_file" 2>&1
        
        fps_speed_result=\$(extract_fps_speed "\$output_file")
        RESULT_FPS=\$(echo "\$fps_speed_result" | cut -d' ' -f1)
        RESULT_SPEED=\$(echo "\$fps_speed_result" | cut -d' ' -f2)
        
        rm -f "\$encoded_file"
        ;;
esac

echo "FFmpeg test completed"
echo "Result FPS: \$RESULT_FPS"
echo "Result Speed: \$RESULT_SPEED"

# Create workload_result.txt in the EMON output directory
cat > "\$EMON_OUTPUT_DIR/workload_result.txt" << EOFRESULT
workload_name:"\$WORKLOAD_NAME \$CORES cores \$CODEC \$PRESET"
metric_type:"Throughput"
result:"\$RESULT_FPS"
metric:"FPS"
num_instances:\$INSTANCES
sockets:\$(lscpu | grep "Socket(s):" | awk '{print \$2}' || echo "1")
cores_used:\$CORES
total_cores:\$(nproc)
codec:"\$CODEC"
preset:"\$PRESET"
test_type:"\$TEST_TYPE"
notes:"FFmpeg encoding test with \$CORES cores, \$CODEC codec, \$PRESET preset, FPS=\$RESULT_FPS, Speed=\${RESULT_SPEED}x"
EOFRESULT

echo "FFmpeg encoding completed under EMON monitoring"
echo "FFmpeg Score (FPS): \$RESULT_FPS"
echo "FFmpeg Speed: \${RESULT_SPEED}x"
echo "Workload result file created: \$EMON_OUTPUT_DIR/workload_result.txt"

# Also create a summary file for easy reading
cat > "\$EMON_OUTPUT_DIR/benchmark_summary.txt" << EOFSUMMARY
=== FFmpeg Benchmark Summary ===
Session: \$SESSION_NAME
Cores: \$CORES
Test Type: \$TEST_TYPE
Instances: \$INSTANCES
Codec: \$CODEC
Preset: \$PRESET
FFmpeg Score: \$RESULT_FPS FPS
Speed: \${RESULT_SPEED}x
Date: \$(date '+%Y-%m-%d %H:%M:%S')
Hostname: \$(hostname)
Notes: Higher FPS is better performance
EOFSUMMARY

echo "Benchmark summary created: \$EMON_OUTPUT_DIR/benchmark_summary.txt"
exit 0
EOF
    
    chmod +x "$wrapper_script"
    echo "$wrapper_script"
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
codec: "$codec"
preset: "$preset"
crf: "$crf"
tune: "$tune"
threads: "$threads"
test_type: "$test_type"
instances: "$instances"
input_file: "$(basename "$input_file")"
emon_enabled: $enable_emon
emon_upload: $emon_upload
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

create_csv_output() {
    local cores=$1
    local fps=$2
    local speed=$3
    local test_case=$4
    
    local date_str=$(date '+%Y-%m-%d %H:%M:%S')
    local command="ffmpeg -c:v lib${codec} -preset ${preset}"
    
    # Create CSV header if file doesn't exist
    if [[ ! -f "$RESULTS_FILE" ]]; then
        echo "Date,Workload Name,Test Case,Command,KPI,Score(FPS),Score(Speed)" > "$RESULTS_FILE"
    fi
    
    # Append result
    echo "\"$date_str\",\"$workload_name\",\"$test_case\",\"$command\",\"Video Encoding\",\"$fps\",\"$speed\"" >> "$RESULTS_FILE"
    
    log "Results saved to: $RESULTS_FILE"
}

run_ffmpeg_benchmark() {
    local cores=$1
    
    echo "=========================================="
    echo "FFmpeg Benchmark"
    echo "Cores: $cores"
    echo "Test Type: $test_type"
    echo "Codec: $codec"
    echo "Preset: $preset"
    echo "EMON: $(if [[ "$enable_emon" == true ]]; then echo "ENABLED"; else echo "DISABLED"; fi)"
    if [[ "$enable_emon" == true ]]; then
        echo "Upload: $(if [[ "$emon_upload" == true ]]; then echo "ENABLED"; else echo "DISABLED"; fi)"
    fi
    echo "=========================================="
    
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local session_name="${emon_session}_${cores}cores_${codec}_${preset}_${test_type}"
    
    local results_dir="$RESULTS_DIR/ffmpeg_${timestamp}"
    local emon_output=""
    local result_fps=""
    local result_speed=""
    
    if [[ "$enable_emon" == true ]]; then
        # EMON-enabled execution
        emon_output="$emon_output_dir/${session_name}"
        mkdir -p "$emon_output"
        create_system_info_file "$emon_output" "$cores"
        
        # Create wrapper script for EMON to execute
        local wrapper_script=$(create_emon_wrapper_script "$cores" "$test_type" "$instances" "$results_dir" "$emon_output" "$session_name")
        
        log "Starting EMON collection for session: $session_name"
        
        # Build TMC command with the wrapper script
        local tmc_cmd="python3 $tmc_path -c \"$wrapper_script\" -d \"$emon_output\" -n"
        
        if [[ -n "$emon_user" ]]; then
            tmc_cmd="$tmc_cmd -x \"$emon_user\""
        fi
        
        if [[ -n "$emon_group" ]]; then
            tmc_cmd="$tmc_cmd -G \"$emon_group\""
        fi
        
        # Use the session name as identity comment
        tmc_cmd="$tmc_cmd -i \"$session_name\""
        
        # Also add as append string for better identification
        tmc_cmd="$tmc_cmd -a \"$session_name\""
        
        if [[ $emon_duration -gt 0 ]]; then
            tmc_cmd="$tmc_cmd -t $emon_duration"
        fi
        
        tmc_cmd="$tmc_cmd -w \"$emon_chart_views\""
        
        if [[ -n "$emon_server" ]]; then
            tmc_cmd="$tmc_cmd -Z \"$emon_server\""
        fi
        
        # Add upload flag if enabled
        if [[ "$emon_upload" == true ]]; then
            tmc_cmd="$tmc_cmd -u"
            log "EMON upload to metrics server: ENABLED"
        else
            log "EMON upload to metrics server: DISABLED (use --emon-upload to enable)"
        fi
        
        log "EMON Command: $tmc_cmd"
        
        # Execute TMC with the wrapper script
        if eval "$tmc_cmd"; then
            log "EMON collection completed successfully"
            
            # Check if workload_result.txt was created
            if [[ -f "$emon_output/workload_result.txt" ]]; then
                log "Workload result file created successfully:"
                cat "$emon_output/workload_result.txt"
                
                # Extract results for local CSV
                result_fps=$(grep "result:" "$emon_output/workload_result.txt" | cut -d'"' -f2)
                result_speed=$(grep "Speed=" "$emon_output/benchmark_summary.txt" | cut -d' ' -f2 | tr -d 'x' || echo "0")
            else
                log "WARNING: workload_result.txt not found in $emon_output"
                result_fps="0"
                result_speed="0"
            fi
            
            # Check if benchmark summary was created
            if [[ -f "$emon_output/benchmark_summary.txt" ]]; then
                log "Benchmark summary:"
                cat "$emon_output/benchmark_summary.txt"
            fi
            
            echo "EMON results saved to: $emon_output"
            
            if [[ "$emon_upload" == true ]]; then
                log "Data uploaded to metrics server: $emon_server"
                log "Session name on server: $session_name"
                log "FFmpeg Score (FPS) will appear in Score/TPS column: $result_fps FPS"
                log "Check metrics dashboard for results under session: $session_name"
            else
                log "Data saved locally. Use --emon-upload to upload to metrics server."
            fi
        else
            error_exit "EMON collection failed"
        fi
        
        # Clean up wrapper script
        rm -f "$wrapper_script"
        
    else
        # Non-EMON execution (original logic)
        mkdir -p "$results_dir"
        
        case "$test_type" in
            single)
                result_fps=$(run_single_instance "$cores" "$results_dir")
                ;;
            multi)
                result_fps=$(run_multiple_instances "$cores" "$instances" "$results_dir")
                ;;
            scaling)
                result_fps=$(run_core_scaling_test "$cores" "$results_dir")
                ;;
        esac
        
        result_speed="1.0"  # Default speed for non-EMON execution
    fi
    
    # Create CSV output for local results
    local test_case="${test_type}_${cores}cores_${codec}_${preset}"
    if [[ "$test_type" == "multi" ]]; then
        test_case="${test_type}_${instances}x${cores}cores_${codec}_${preset}"
    fi
    
    create_csv_output "$cores" "$result_fps" "$result_speed" "$test_case"
    
    # Output performance result in multiple formats for wrapper parsing
    echo "Performance: $result_fps"
    echo "Throughput: $result_fps"
    echo "Score: $result_fps"
    echo "FPS: $result_fps"
    
    return 0
}

run_single_instance() {
    local cores="$1"
    local results_dir="$2"
    local output_file="$results_dir/ffmpeg_single.log"
    local encoded_file="$results_dir/output_single.${codec}"
    
    log "Running single FFmpeg instance with $cores cores..."
    
    # Set CPU affinity if cores specified
    local taskset_cmd=""
    if [[ -n "$cores" ]] && [[ "$cores" != "0" ]]; then
        local core_list=$(seq -s, 0 $((cores-1)))
        taskset_cmd="taskset -c $core_list"
        log "Using CPU cores: $core_list"
    fi
    
    # Build FFmpeg command
    local cmd="$taskset_cmd ffmpeg -y -i \"$input_file\" -c:v lib${codec} -preset $preset -crf $crf -tune $tune -threads $threads \"$encoded_file\""
    log "Executing: $cmd"
    
    # Run the benchmark
    eval "$cmd" > "$output_file" 2>&1
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        log "FFmpeg encoding failed with exit code: $exit_code"
        echo "0"
        return 1
    fi
    
    # Parse results
    local fps_speed=$(extract_fps_speed "$output_file")
    local fps=$(echo "$fps_speed" | cut -d' ' -f1)
    
    # Clean up encoded file to save space
    rm -f "$encoded_file"
    
    log "Single instance benchmark completed successfully - FPS: $fps"
    echo "$fps"
    return 0
}

run_multiple_instances() {
    local cores="$1"
    local instances="$2"
    local results_dir="$3"
    local cores_per_instance=$((cores / instances))
    
    log "Running $instances FFmpeg instances with $cores_per_instance cores each..."
    
    local pids=()
    local fps_files=()
    
    # Launch multiple instances
    for i in $(seq 1 $instances); do
        local start_core=$(( (i-1) * cores_per_instance ))
        local end_core=$(( start_core + cores_per_instance - 1 ))
        local core_list=$(seq -s, $start_core $end_core)
        
        local output_file="$results_dir/ffmpeg_multi_${i}.log"
        local encoded_file="$results_dir/output_${i}.${codec}"
        local fps_file="/tmp/ffmpeg_fps_$i"
        
        fps_files+=("$fps_file")
        
        log "Starting instance $i on cores $core_list"
        
        # Run instance in background
        (
            local cmd="taskset -c $core_list ffmpeg -y -i \"$input_file\" -c:v lib${codec} -preset $preset -crf $crf -tune $tune -threads $cores_per_instance \"$encoded_file\""
            eval "$cmd" > "$output_file" 2>&1
            
            # Extract results for this instance
            local fps_speed=$(extract_fps_speed "$output_file")
            local fps=$(echo "$fps_speed" | cut -d' ' -f1)
            
            echo "$fps" > "$fps_file"
            
            # Clean up encoded file
            rm -f "$encoded_file"
        ) &
        
        pids+=($!)
    done
    
    # Wait for all instances to complete
    log "Waiting for all instances to complete..."
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    # Calculate total FPS
    local total_fps=0
    local valid_instances=0
    
    for i in $(seq 1 $instances); do
        local fps_file="/tmp/ffmpeg_fps_$i"
        
        if [[ -f "$fps_file" ]]; then
            local fps=$(cat "$fps_file")
            
            if [[ -n "$fps" ]] && [[ "$fps" != "0" ]]; then
                total_fps=$(echo "$total_fps + $fps" | bc -l)
                ((valid_instances++))
            fi
        fi
        
        # Clean up temp files
        rm -f "$fps_file"
    done
    
    if [[ $valid_instances -gt 0 ]]; then
        log "Multiple instances benchmark completed successfully - Total FPS: $total_fps"
        echo "$total_fps"
        return 0
    else
        log "No valid results from multiple instances"
        echo "0"
        return 1
    fi
}

run_core_scaling_test() {
    local max_cores="$1"
    local results_dir="$2"
    
    log "Running core scaling test up to $max_cores cores..."
    
    # For scaling test, just run with maximum cores
    local fps=$(run_single_instance "$max_cores" "$results_dir")
    
    log "Core scaling test completed - FPS: $fps"
    echo "$fps"
    return 0
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
        --codec)
            codec="$2"
            shift 2
            ;;
        --preset)
            preset="$2"
            shift 2
            ;;
        --crf)
            crf="$2"
            shift 2
            ;;
        --tune)
            tune="$2"
            shift 2
            ;;
        --threads)
            threads="$2"
            shift 2
            ;;
        --input)
            input_file="$2"
            shift 2
            ;;
        --test-type)
            test_type="$2"
            shift 2
            ;;
        --instances)
            instances="$2"
            shift 2
            ;;
        --workload-name)
            workload_name="$2"
            shift 2
            ;;
        --metric-unit)
            metric_unit="$2"
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
        --emon-upload)
            emon_upload=true
            shift
            ;;
        --tmc-path)
            tmc_path="$2"
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
    
    # Detect wrapper execution and handle EMON conflicts
    if [[ "$enable_emon" == true ]]; then
        log "WARNING: Detected execution through wrapper with internal EMON enabled."
        log "Disabling internal EMON to avoid conflicts with wrapper's EMON integration."
        log "Use wrapper's --emon flag instead for EMON monitoring."
        enable_emon=false
    fi
fi

if [[ -z "$cores" ]]; then
    error_exit "--cores or --cpu-cores parameter is required"
fi

if [[ $cores -le 0 ]]; then
    error_exit "cores must be a positive integer"
fi

# Validate test type
case "$test_type" in
    single|multi|scaling)
        ;;
    *)
        error_exit "Invalid test type: $test_type. Must be single, multi, or scaling"
        ;;
esac

# Validate instances for multi test
if [[ "$test_type" == "multi" ]] && [[ $instances -le 0 ]]; then
    error_exit "instances must be a positive integer for multi test"
fi

# Validate EMON parameters
validate_emon_params

# ------------------------------ EXECUTION -----------------------------------
echo "============================================="
echo "FFMPEG BENCHMARK"
echo "============================================="
echo "Script Directory: $SCRIPT_DIR"
echo "Results File: $RESULTS_FILE"
echo "Cores: $cores"
echo "Test Type: $test_type"
echo "Codec: $codec"
echo "Preset: $preset"
echo "CRF: $crf"
echo "Tune: $tune"
echo "Threads: $threads"
if [[ "$test_type" == "multi" ]]; then
    echo "Instances: $instances"
fi
echo "EMON Enabled: $enable_emon"
if [[ "$enable_emon" == true ]]; then
    echo "EMON Session: $emon_session"
    echo "EMON Output Dir: $emon_output_dir"
    echo "EMON Upload: $emon_upload"
    echo "EMON Server: $emon_server"
fi
if [[ -n "$custom_name" ]]; then
    echo "Custom Name: $custom_name"
fi
echo "============================================="
echo ""

# Setup system
setup_system

# Run benchmark
log "Starting FFmpeg benchmark..."

if run_ffmpeg_benchmark "$cores"; then
    log "FFmpeg benchmark completed successfully"
else
    error_exit "FFmpeg benchmark failed"
fi

# Summary
echo "============================================="
echo "FFMPEG BENCHMARK COMPLETED"
echo "============================================="
echo "Results saved to: $RESULTS_FILE"
if [[ "$enable_emon" == true ]]; then
    echo "EMON traces saved to: $emon_output_dir"
    if [[ "$emon_upload" == true ]]; then
        echo "Data uploaded to metrics server: $emon_server"
        echo "Session name on server: $emon_session"
        echo "FFmpeg FPS will appear in Score/TPS column on metrics dashboard"
    else
        echo "Data saved locally only. Use --emon-upload to upload to server."
    fi
fi
echo "============================================="
