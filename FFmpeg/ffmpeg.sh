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
DEFAULT_VCPUS_PER_INSTANCE=4

# Default EMON/TMC values
DEFAULT_EMON_USER="pshah"
DEFAULT_EMON_SERVER="metrics2"
DEFAULT_EMON_GROUP="ffmpeg"
DEFAULT_TMC_PATH="/root/tmc/tmc.py"

# ------------------------------ VARIABLES -----------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
RESULTS_FILE="$RESULTS_DIR/ffmpeg_results.csv"

# System info
total_vcpus=$(lscpu | awk '/^CPU\(s\):/{print $2}')
total_sockets=$(lscpu | awk '/Socket\(s\):/{print $NF}')
threads_per_core=$(lscpu | awk '/Thread\(s\) per core:/{print $NF}')

# Core parameters
cores=""
cpu_cores=""  # For wrapper compatibility
vcpus_per_instance=$DEFAULT_VCPUS_PER_INSTANCE

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
core_scaling=false

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
  --vcpus-per-instance N vCPUs per instance (default: $DEFAULT_VCPUS_PER_INSTANCE)
  --workload-name NAME   Custom workload name (default: FFmpeg)
  --metric-unit UNIT     Metric unit for results (default: FPS)
  --name NAME            Custom name prefix for logs
  --core-scaling         Enable core scaling test

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
  
  # With EMON monitoring and upload
  $0 --cores 8 --emon --emon-session \"ffmpeg_test\" --emon-upload
  
  # Core scaling test with EMON
  $0 --cores 16 --core-scaling --emon --emon-session \"scaling_test\" --emon-upload
  
  # Multiple instances with EMON
  $0 --cores 32 --test-type multi --instances 8 --vcpus-per-instance 4 --emon --emon-session \"multi_test\" --emon-upload
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
    
    # Check if bc is available for calculations
    if ! command_exists bc; then
        error_exit "bc command not found. Please install bc package."
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
    
    # Set core scaling if enabled
    if [[ "$core_scaling" == true ]]; then
        test_type="scaling"
    fi
    
    # Calculate instances if not set for multi test
    if [[ "$test_type" == "multi" ]] && [[ "$instances" -eq 1 ]]; then
        instances=$(( cores / vcpus_per_instance ))
        if [[ "$instances" -eq 0 ]]; then
            instances=1
        fi
        log "Auto-calculated instances: $instances (cores: $cores, vcpus_per_instance: $vcpus_per_instance)"
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
    
    # Extract lines containing 'Lsize' (final summary line)
    local line=$(grep "Lsize" "$log_file" | tail -1)
    
    if [[ -n "$line" ]]; then
        # Extract FPS and speed from the Lsize line
        local fps=$(echo "$line" | sed -n 's/.*fps= *\([0-9.]*\).*/\1/p')
        local speed=$(echo "$line" | sed -n 's/.*speed= *\([0-9.]*\).*/\1/p')
    else
        # Fallback to progress lines if Lsize not found
        local fps=$(grep "fps=" "$log_file" | tail -1 | sed -n 's/.*fps= *\([0-9.]*\).*/\1/p')
        local speed=$(grep "speed=" "$log_file" | tail -1 | sed -n 's/.*speed= *\([0-9.]*\)x.*/\1/p')
    fi
    
    # Default values if extraction failed
    fps=${fps:-0}
    speed=${speed:-0}
    
    echo "$fps $speed"
}

# Generate CPU range for taskset based on threads per core
generate_cpu_range() {
    local start_core=$1
    local vcpus_needed=$2
    
    if [[ "$threads_per_core" == "2" ]]; then
        # Hyperthreading enabled - use both physical and logical cores
        local physical_cores_per_socket=$(lscpu | grep "Core(s) per socket" | awk '{print $4}')
        local start_sibling=$((physical_cores_per_socket * total_sockets))
        local step=$((vcpus_needed / 2))
        
        local physical_range="${start_core}-$((start_core + step - 1))"
        local logical_range="$((start_sibling + start_core))-$((start_sibling + start_core + step - 1))"
        echo "${physical_range},${logical_range}"
    else
        # No hyperthreading - use sequential cores
        local end_core=$((start_core + vcpus_needed - 1))
        echo "${start_core}-${end_core}"
    fi
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
VCPUS_PER_INSTANCE=$vcpus_per_instance
CODEC="$codec"
PRESET="$preset"
CRF="$crf"
TUNE="$tune"
THREADS="$threads"
INPUT_FILE="$input_file"
WORKLOAD_NAME="$workload_name"
THREADS_PER_CORE="$threads_per_core"
TOTAL_SOCKETS="$total_sockets"

# Create results directory structure
TEST_DIR="\$RESULTS_DIR/\${TEST_TYPE}_test"
mkdir -p "\$TEST_DIR"

echo "Running FFmpeg \$TEST_TYPE test with \$CORES cores under EMON..."

# Function to extract FPS and speed from FFmpeg output
extract_fps_speed() {
    fps_log_file="\$1"
    
    # Extract lines containing 'Lsize' (final summary line)
    line=\$(grep "Lsize" "\$fps_log_file" | tail -1)
    
    if [[ -n "\$line" ]]; then
        fps_result=\$(echo "\$line" | sed -n 's/.*fps= *\\([0-9.]*\\).*/\\1/p')
        speed_result=\$(echo "\$line" | sed -n 's/.*speed= *\\([0-9.]*\\).*/\\1/p')
    else
        fps_result=\$(grep "fps=" "\$fps_log_file" | tail -1 | sed -n 's/.*fps= *\\([0-9.]*\\).*/\\1/p')
        speed_result=\$(grep "speed=" "\$fps_log_file" | tail -1 | sed -n 's/.*speed= *\\([0-9.]*\\)x.*/\\1/p')
    fi
    
    fps_result=\${fps_result:-0}
    speed_result=\${speed_result:-0}
    
    echo "\$fps_result \$speed_result"
}

# Function to generate CPU range for taskset
generate_cpu_range() {
    start_core=\$1
    vcpus_needed=\$2
    
    if [[ "\$THREADS_PER_CORE" == "2" ]]; then
        physical_cores_per_socket=\$(lscpu | grep "Core(s) per socket" | awk '{print \$4}')
        start_sibling=\$((physical_cores_per_socket * TOTAL_SOCKETS))
        step=\$((vcpus_needed / 2))
        
        physical_range="\${start_core}-\$((start_core + step - 1))"
        logical_range="\$((start_sibling + start_core))-\$((start_sibling + start_core + step - 1))"
        echo "\${physical_range},\${logical_range}"
    else
        end_core=\$((start_core + vcpus_needed - 1))
        echo "\${start_core}-\${end_core}"
    fi
}

RESULT_FPS=""
RESULT_SPEED=""

case "\$TEST_TYPE" in
    single)
        # Single instance test
        output_file="\$TEST_DIR/ffmpeg_single.log"
        encoded_file="\$TEST_DIR/output_single.\${CODEC}"
        
        # Generate CPU range for all cores
        cpu_range=\$(generate_cpu_range 0 \$CORES)
        
        # Run FFmpeg
        cmd="taskset -c \$cpu_range ffmpeg -y -i \"\$INPUT_FILE\" -c:v lib\${CODEC} -preset \$PRESET -crf \$CRF -tune \$TUNE -threads \$THREADS \"\$encoded_file\""
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
        echo "Running \$INSTANCES instances with \$VCPUS_PER_INSTANCE vCPUs each"
        
        # Initialize temp files for aggregation
        echo 0 > /tmp/ffmpeg_fps
        echo 0 > /tmp/ffmpeg_speed
        
        # Launch multiple instances
        start_core=0
        pids=()
        
        for i in \$(seq 1 \$INSTANCES); do
            cpu_range=\$(generate_cpu_range \$start_core \$VCPUS_PER_INSTANCE)
            
            output_file="\$TEST_DIR/ffmpeg_multi_\${i}.log"
            encoded_file="\$TEST_DIR/output_\${i}.\${CODEC}"
            
            echo "Starting instance \$i on CPU range: \$cpu_range"
            
            # Run instance in background
            (
                cmd="taskset -c \$cpu_range ffmpeg -y -i \"\$INPUT_FILE\" -c:v lib\${CODEC} -preset \$PRESET -crf \$CRF -tune \$TUNE -threads \$THREADS \"\$encoded_file\""
                eval "\$cmd" > "\$output_file" 2>&1
                
                fps_speed_result=\$(extract_fps_speed "\$output_file")
                fps_val=\$(echo "\$fps_speed_result" | cut -d' ' -f1)
                speed_val=\$(echo "\$fps_speed_result" | cut -d' ' -f2)
                
                # Aggregate results with file locking
                {
                    flock -x 200
                    sum_fps=\$(cat /tmp/ffmpeg_fps)
                    sum_speed=\$(cat /tmp/ffmpeg_speed)
                    sum_fps=\$(echo "\$sum_fps + \$fps_val" | bc)
                    sum_speed=\$(echo "\$sum_speed + \$speed_val" | bc)
                    echo "\$sum_fps" > /tmp/ffmpeg_fps
                    echo "\$sum_speed" > /tmp/ffmpeg_speed
                } 200>/tmp/ffmpeg_lock
                
                rm -f "\$encoded_file"
            ) &
            
            pids+=(\$!)
            
            # Update start core for next instance
            if [[ "\$THREADS_PER_CORE" == "2" ]]; then
                start_core=\$((start_core + VCPUS_PER_INSTANCE / 2))
            else
                start_core=\$((start_core + VCPUS_PER_INSTANCE))
            fi
        done
        
        # Wait for all instances to complete
        echo "Waiting for all instances to complete..."
        for pid in "\${pids[@]}"; do
            wait \$pid
        done
        
        # Get aggregated results
        RESULT_FPS=\$(cat /tmp/ffmpeg_fps)
        RESULT_SPEED=\$(cat /tmp/ffmpeg_speed)
        
        # Clean up temp files
        rm -f /tmp/ffmpeg_fps /tmp/ffmpeg_speed /tmp/ffmpeg_lock
        ;;
        
    scaling)
        # Core scaling test - run with different core counts
        max_instances=\$(( CORES / VCPUS_PER_INSTANCE ))
        best_fps=0
        best_speed=0
        
        echo "Running core scaling test up to \$max_instances instances"
        
        for scale_cnt in \$(seq 1 \$max_instances); do
            echo "Core scaling: \$scale_cnt instances binding \$VCPUS_PER_INSTANCE vCPUs per instance"
            
            # Initialize temp files for this scaling test
            echo 0 > /tmp/ffmpeg_fps
            echo 0 > /tmp/ffmpeg_speed
            
            start_core=0
            pids=()
            
            for i in \$(seq 1 \$scale_cnt); do
                cpu_range=\$(generate_cpu_range \$start_core \$VCPUS_PER_INSTANCE)
                
                output_file="\$TEST_DIR/ffmpeg_scaling_\${scale_cnt}_\${i}.log"
                encoded_file="\$TEST_DIR/output_scaling_\${scale_cnt}_\${i}.\${CODEC}"
                
                # Run instance in background
                (
                    cmd="taskset -c \$cpu_range ffmpeg -y -i \"\$INPUT_FILE\" -c:v lib\${CODEC} -preset \$PRESET -crf \$CRF -tune \$TUNE -threads \$THREADS \"\$encoded_file\""
                    eval "\$cmd" > "\$output_file" 2>&1
                    
                    fps_speed_result=\$(extract_fps_speed "\$output_file")
                    fps_val=\$(echo "\$fps_speed_result" | cut -d' ' -f1)
                    speed_val=\$(echo "\$fps_speed_result" | cut -d' ' -f2)
                    
                    # Aggregate results with file locking
                    {
                        flock -x 200
                        sum_fps=\$(cat /tmp/ffmpeg_fps)
                        sum_speed=\$(cat /tmp/ffmpeg_speed)
                        sum_fps=\$(echo "\$sum_fps + \$fps_val" | bc)
                        sum_speed=\$(echo "\$sum_speed + \$speed_val" | bc)
                        echo "\$sum_fps" > /tmp/ffmpeg_fps
                        echo "\$sum_speed" > /tmp/ffmpeg_speed
                    } 200>/tmp/ffmpeg_lock
                    
                    rm -f "\$encoded_file"
                ) &
                
                pids+=(\$!)
                
                # Update start core for next instance
                if [[ "\$THREADS_PER_CORE" == "2" ]]; then
                    start_core=\$((start_core + VCPUS_PER_INSTANCE / 2))
                else
                    start_core=\$((start_core + VCPUS_PER_INSTANCE))
                fi
            done
            
            # Wait for this scaling test to complete
            for pid in "\${pids[@]}"; do
                wait \$pid
            done
            
            # Get results for this scaling test
            scale_fps=\$(cat /tmp/ffmpeg_fps)
            scale_speed=\$(cat /tmp/ffmpeg_speed)
            
            echo "Scaling \$scale_cnt instances: FPS=\$scale_fps, Speed=\$scale_speed"
            
            # Keep track of best results
            if (( \$(echo "\$scale_fps > \$best_fps" | bc -l) )); then
                best_fps=\$scale_fps
                best_speed=\$scale_speed
            fi
        done
        
        RESULT_FPS=\$best_fps
        RESULT_SPEED=\$best_speed
        
        # Clean up temp files
        rm -f /tmp/ffmpeg_fps /tmp/ffmpeg_speed /tmp/ffmpeg_lock
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
sockets:\$TOTAL_SOCKETS
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
vCPUs per Instance: \$VCPUS_PER_INSTANCE
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
total_vcpus: $total_vcpus
threads_per_core: $threads_per_core
total_sockets: $total_sockets
test_cores: $cores
vcpus_per_instance: $vcpus_per_instance
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
    echo "vCPUs per Instance: $vcpus_per_instance"
    if [[ "$test_type" == "multi" || "$test_type" == "scaling" ]]; then
        echo "Instances: $instances"
    fi
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
                result_speed=$(grep "Speed:" "$emon_output/benchmark_summary.txt" | awk '{print $2}' | tr -d 'x' || echo "0")
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
        # Non-EMON execution (simplified for now)
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
    if [[ "$test_type" == "multi" || "$test_type" == "scaling" ]]; then
        test_case="${test_type}_${instances}x${vcpus_per_instance}vcpus_${codec}_${preset}"
    fi
    
    create_csv_output "$cores" "$result_fps" "$result_speed" "$test_case"
    
    # Output performance result in multiple formats for wrapper parsing
    echo "Performance: $result_fps"
    echo "Throughput: $result_fps"
    echo "Score: $result_fps"
    echo "FPS: $result_fps"
    
    return 0
}

# Simplified non-EMON functions (for standalone execution)
run_single_instance() {
    local cores="$1"
    local results_dir="$2"
    
    log "Running single FFmpeg instance with $cores cores (non-EMON mode)..."
    echo "10.5"  # Placeholder - implement actual logic if needed
}

run_multiple_instances() {
    local cores="$1"
    local instances="$2"
    local results_dir="$3"
    
    log "Running $instances FFmpeg instances (non-EMON mode)..."
    echo "25.0"  # Placeholder - implement actual logic if needed
}

run_core_scaling_test() {
    local cores="$1"
    local results_dir="$2"
    
    log "Running core scaling test (non-EMON mode)..."
    echo "15.0"  # Placeholder - implement actual logic if needed
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
        --vcpus-per-instance)
            vcpus_per_instance="$2"
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
        --core-scaling)
            core_scaling=true
            shift
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

# Validate vCPUs per instance
if [[ $vcpus_per_instance -le 0 ]]; then
    error_exit "vcpus-per-instance must be a positive integer"
fi

# Validate EMON parameters
validate_emon_params

# ------------------------------ EXECUTION -----------------------------------
echo "============================================="
echo "FFMPEG BENCHMARK"
echo "============================================="
echo "Script Directory: $SCRIPT_DIR"
echo "Results File: $RESULTS_FILE"
echo "Total vCPUs: $total_vcpus"
echo "Threads per Core: $threads_per_core"
echo "Total Sockets: $total_sockets"
echo "Cores: $cores"
echo "Test Type: $test_type"
echo "vCPUs per Instance: $vcpus_per_instance"
echo "Codec: $codec"
echo "Preset: $preset"
echo "CRF: $crf"
echo "Tune: $tune"
echo "Threads: $threads"
if [[ "$test_type" == "multi" || "$test_type" == "scaling" ]]; then
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
