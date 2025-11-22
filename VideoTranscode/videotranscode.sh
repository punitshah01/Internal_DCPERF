#!/bin/bash
# video_transcode_workload.sh - Video Transcode benchmark script for main wrapper

# =============================================================================
# VIDEO TRANSCODE WORKLOAD SCRIPT
# =============================================================================
# This script runs Video Transcode benchmarks with configurable core counts
# Compatible with the main wrapper script
# =============================================================================

# Determine script directory
MY_PATH="$(dirname -- "${BASH_SOURCE[0]}")"

# ------------------------------ DEFAULT VALUES -----------------------------------
DEFAULT_RUNS=1
DEFAULT_ENCODER="svt"  # svt, x264, aom
DEFAULT_RUNTIME="medium"  # short, medium, long
DEFAULT_LEVELS="0:0"

# Default EMON/TMC values (same as other workloads)
DEFAULT_EMON_USER="pshah"
DEFAULT_EMON_SERVER="metrics2"
DEFAULT_EMON_GROUP="videotranscode"

# ------------------------------ VARIABLES -----------------------------------
cores=""
runs=$DEFAULT_RUNS
encoder=$DEFAULT_ENCODER
runtime=$DEFAULT_RUNTIME
levels=$DEFAULT_LEVELS
metric_collection="none"  # none, emon, perf
custom_name=""

# EMON/TMC Variables with defaults
emon_user=$DEFAULT_EMON_USER
emon_server=$DEFAULT_EMON_SERVER
emon_group=$DEFAULT_EMON_GROUP

# Video Transcode specific settings
RAMP_STRING_START="start"
RAMP_FILE="/tmp/ffmpeg_log.txt"

# ------------------------------ FUNCTIONS -----------------------------------
print_usage(){
    echo -e "
Usage: $0 --cores N [OPTIONS]

REQUIRED:
  --cores N              Number of cores to use (REQUIRED)

OPTIONAL:
  --runs N               Number of test runs (default: $DEFAULT_RUNS)
  --encoder TYPE         Video encoder: svt/x264/aom (default: $DEFAULT_ENCODER)
  --runtime TYPE         Runtime duration: short/medium/long (default: $DEFAULT_RUNTIME)
  --levels LEVELS        Encoding levels (default: $DEFAULT_LEVELS)
  --name NAME            Custom name prefix for logs
  --metric TYPE          Direct metric collection: none/emon/perf (default: none)
                        Note: Use main wrapper --emon instead of --metric emon

EMON OPTIONS (with defaults):
  --emon-user USER       EMON username (default: $DEFAULT_EMON_USER)
  --emon-server SERVER   EMON server (default: $DEFAULT_EMON_SERVER)
  --emon-group GROUP     EMON group (default: $DEFAULT_EMON_GROUP)

EXAMPLES:
  $0 --cores 32 --encoder svt --runtime long --runs 3
  $0 --cores 64 --encoder x264 --runtime medium --name custom_test
"
}

setup_system() {
    echo "Setting up system for Video Transcode benchmark..."
    
    # System optimizations
    echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
    ulimit -n 655350 2>/dev/null || true
    
    # Clean up previous ramp file
    rm -rf "${RAMP_FILE}" 2>/dev/null || true
}

parse_transcode_results() {
    local logs_dir=$1
    
    # Extract performance metrics from Video Transcode results
    local fps=""
    local throughput=""
    local encoding_time=""
    local quality_score=""
    
    # Look for results in the benchmark results file
    local result_file="$logs_dir/video_transcode_bench_results.txt"
    
    if [[ -f "$result_file" ]]; then
        # Extract FPS (frames per second)
        fps=$(grep -i "fps\|frame.*per.*sec" "$result_file" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
        
        # Extract throughput
        throughput=$(grep -i "throughput\|speed" "$result_file" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
        
        # Extract encoding time
        encoding_time=$(grep -i "encoding.*time\|duration" "$result_file" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
        
        # Extract quality metrics (PSNR, SSIM, etc.)
        quality_score=$(grep -i "psnr\|ssim\|vmaf" "$result_file" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    fi
    
    # Alternative: parse from log files
    if [[ -z "$fps" ]]; then
        local log_files=$(find "$logs_dir" -name "vt_*.txt" 2>/dev/null)
        for log_file in $log_files; do
            fps=$(grep -i "fps\|frame.*rate" "$log_file" | grep -oE '[0-9]+\.?[0-9]*' | tail -1)
            if [[ -n "$fps" ]]; then
                break
            fi
        done
    fi
    
    # Output in parseable format
    if [[ -n "$fps" ]]; then
        echo "Performance: $fps FPS"
        echo "Throughput: $fps FPS"
    else
        echo "Performance: N/A FPS"
        echo "Throughput: N/A FPS"
    fi
    
    if [[ -n "$encoding_time" ]]; then
        echo "Encoding_Time: $encoding_time seconds"
    fi
    
    if [[ -n "$quality_score" ]]; then
        echo "Quality_Score: $quality_score"
    fi
    
    echo "Encoder: $encoder"
    echo "Runtime: $runtime"
}

run_transcode_benchmark() {
    local cores=$1
    local run_number=$2
    
    echo "=========================================="
    echo "Video Transcode Benchmark Run $run_number"
    echo "Cores: $cores"
    echo "Encoder: $encoder"
    echo "Runtime: $runtime"
    echo "=========================================="
    
    # Create session name and logs directory
    local name_prefix="${custom_name:-TRANSCODE}_${cores}cores"
    
    if [[ $metric_collection == "emon" ]]; then
        name_prefix="${name_prefix}_WEMON"
    elif [[ $metric_collection == "perf" ]]; then
        name_prefix="${name_prefix}_WPERF"
    fi
    
    local session_name="transcode_logs_${name_prefix}_${encoder}_${runtime}"
    local logs_root="${session_name}_$(date +%m%d%Y%H%M%S)"
    local logs_dir="$logs_root/run${run_number}"
    local logs_file="$logs_dir/vt_${name_prefix}_run${run_number}.txt"
    
    mkdir -p "$logs_dir"
    
    # Setup system
    setup_system
    
    # Build base command
    local base_cmd="./run.sh --encoder ${encoder} --runtime ${runtime} --levels ${levels} --output video_transcode_bench_results.txt"
    
    # Handle different metric collection types
    local final_cmd=""
    case $metric_collection in
        "emon")
            final_cmd="tmc -c \"$base_cmd\" -rl $RAMP_FILE -rs \"$RAMP_STRING_START\" -lt 200 -rt 100 -n -u -x $emon_user -a ${session_name}_RUN${run_number} -T emon,sar -v -w thread,socket,core -Z $emon_server -G ${emon_group}_"
            ;;
        "perf")
            # Note: PERF_START_DELAY and PERF_DURATION were commented out in original
            # Using default values if needed
            local perf_start_delay=30
            local perf_duration=240
            bash "$MY_PATH/collect_perf.sh" "$logs_dir" "$RAMP_FILE" "$RAMP_STRING_START" "${session_name}_run${run_number}" $perf_duration $perf_start_delay &
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
        # Copy Video Transcode result files
        cp benchmarks/video_transcode_bench/video_transcode_bench_results.txt "$logs_dir" 2>/dev/null || true
        cp "$RAMP_FILE" "$logs_dir" 2>/dev/null || true
        mv benchmarks/video_transcode_bench/generate_commands_all_parameters.txt "$logs_dir" 2>/dev/null || true
        
        # Copy any JSON results if they exist
        # mv results/video_transcode_bench_svt/*.json "$logs_dir" 2>/dev/null || true
        
        echo ""
        echo "Results for run $run_number:"
        parse_transcode_results "$logs_dir"
        
        # Sleep between runs
        sleep 30
    else
        echo "Error: Video Transcode run $run_number failed"
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
        --encoder)
            encoder="$2"
            shift 2
            ;;
        --runtime)
            runtime="$2"
            shift 2
            ;;
        --levels)
            levels="$2"
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

# Validate encoder
valid_encoders=("svt" "x264" "aom")
if [[ ! " ${valid_encoders[@]} " =~ " ${encoder} " ]]; then
    echo "Error: Invalid encoder '$encoder'. Valid options: ${valid_encoders[*]}"
    exit 1
fi

# Validate runtime
valid_runtimes=("short" "medium" "long")
if [[ ! " ${valid_runtimes[@]} " =~ " ${runtime} " ]]; then
    echo "Error: Invalid runtime '$runtime'. Valid options: ${valid_runtimes[*]}"
    exit 1
fi

# Check if required files exist
if [[ ! -f "./run.sh" ]]; then
    echo "Error: run.sh not found in current directory"
    exit 1
fi

# ------------------------------ EXECUTION -----------------------------------
echo "============================================="
echo "VIDEO TRANSCODE BENCHMARK"
echo "============================================="
echo "Cores: $cores"
echo "Encoder: $encoder"
echo "Runtime: $runtime"
echo "Levels: $levels"
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
    
    if run_transcode_benchmark "$cores" "$i"; then
        successful_runs=$((successful_runs + 1))
    else
        echo "Run $i failed"
    fi
    
    echo ""
done

# Summary
echo "============================================="
echo "VIDEO TRANSCODE BENCHMARK COMPLETED"
echo "============================================="
echo "Total runs: $runs"
echo "Successful runs: $successful_runs"
echo "Failed runs: $((runs - successful_runs))"
echo "Encoder: $encoder"
echo "Runtime: $runtime"
echo "============================================="
