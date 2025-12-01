#!/bin/bash

# =============================================================================
# MAIN WORKLOAD WRAPPER SCRIPT (BASH VERSION)
# =============================================================================
# This script orchestrates different workload scripts with core scaling,
# TMC/EMON integration, and comprehensive Excel results generation
# =============================================================================

set -euo pipefail

# ------------------------------ DEFAULT VALUES -----------------------------------
DEFAULT_CORES_STEP=4
DEFAULT_METRIC_TYPE="Throughput"
DEFAULT_EMON_CHART_VIEWS="core,socket"
DEFAULT_EMON_OUTPUT_DIR="./emon_traces"
DEFAULT_EMON_DURATION=0

# ------------------------------ VARIABLES -----------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Required parameters
script_path=""

# Core scaling parameters
cores_step=$DEFAULT_CORES_STEP
specific_nproc=""
dry_run=false  # false = actual execution (default), true = dry run with -r

# TMC/EMON parameters
enable_emon=false
emon_user=""
emon_group=""
emon_session=""
emon_server=""
workload_name=""
metric_type=$DEFAULT_METRIC_TYPE
metric_unit=""
emon_duration=$DEFAULT_EMON_DURATION
emon_chart_views=$DEFAULT_EMON_CHART_VIEWS
emon_output_dir=$DEFAULT_EMON_OUTPUT_DIR

# Script parameters
script_args=""

# System info variables
total_cores=0
total_sockets=0
total_numa_nodes=0
cpu_model_name=""
bios_version=""
microcode=""
operating_system=""
kernel_version=""

# Master results file
MASTER_RESULTS_FILE="$SCRIPT_DIR/master_results.xlsx"

# Debug mode
DEBUG_MODE=false

# Results data array for Excel generation
declare -a RESULTS_DATA

# ------------------------------ FUNCTIONS -----------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

debug_log() {
    if [[ "$DEBUG_MODE" == true ]]; then
        echo "[DEBUG $(date '+%H:%M:%S')] $1"
    fi
}

error_exit() {
    echo "Error: $1" >&2
    exit 1
}

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

REQUIRED:
  -s, --script PATH           Path to workload script to execute (REQUIRED)

CORE SCALING:
  -c, --cores N              Core stepping size (default: $DEFAULT_CORES_STEP)
  -n, --nproc N              Run only with specific nproc value (overrides stepping)
  -r, --dry-run              Show commands without executing (default: execute)

TMC/EMON INTEGRATION:
  -e, --emon                 Enable TMC/EMON integration (default: disabled)
  --emon-user USER           TMC username (optional, workload script default used)
  --emon-group GROUP         TMC group name (optional, workload script default used)
  --emon-server SERVER       Server identifier (optional, workload script default used)
  --emon-session SESSION     TMC session identifier (required if --emon)

WORKLOAD RESULTS:
  --workload-name NAME       Workload name for results file (required if --emon)
  --metric-type TYPE         Metric type: Throughput/Latency/etc (default: $DEFAULT_METRIC_TYPE)
  --metric-unit UNIT         Metric unit: ops/s, ms, GFLOPS, etc (required if --emon)

SCRIPT PARAMETERS:
  --script-args "ARGS"       Additional arguments to pass to workload script

TMC OPTIONAL:
  --emon-duration SEC        Collection duration in seconds (default: $DEFAULT_EMON_DURATION = until completion)
  --emon-chart-views VIEWS   Chart views (default: $DEFAULT_EMON_CHART_VIEWS)
  --emon-output-dir DIR      Base output directory (default: $DEFAULT_EMON_OUTPUT_DIR)

DEBUG:
  --debug                    Enable debug mode for troubleshooting

EXAMPLES:
  # Basic SuperPi execution
  $0 --script ./SuperPi/superpi.sh --cores 8

  # With debug mode
  $0 --script ./SuperPi/superpi.sh --cores 8 --debug

  # Dry run to check commands
  $0 --script ./SuperPi/superpi.sh --cores 8 --dry-run

  # Execution with specific nproc
  $0 --script ./SuperPi/superpi.sh --nproc 32

  # With EMON integration
  $0 --script ./SuperPi/superpi.sh --cores 4 --emon \\
     --emon-session "superpi_test" --workload-name "SuperPi" --metric-unit "seconds"

  # With additional script arguments
  $0 --script ./SuperPi/superpi.sh --cores 8 \\
     --script-args "--scale 10000 --runs 3"

AVAILABLE WORKLOADS:
  Look for workload scripts in subdirectories:
  - ./SuperPi/superpi.sh
  - ./ffmpeg/workload.sh
  - ./multichase/workload.sh
  - ./crypto++/workload.sh
  - ./sysbench/workload.sh
  - ./stream/workload.sh
  - ./stress-ng/workload.sh

RESULTS:
  Master results are saved to: $MASTER_RESULTS_FILE
EOF
}

get_system_info() {
    log "Gathering system information..."
    
    # Get total cores
    total_cores=$(nproc)
    
    # Get CPU information from lscpu
    if command -v lscpu >/dev/null 2>&1; then
        local lscpu_output=$(lscpu)
        
        total_sockets=$(echo "$lscpu_output" | grep "Socket(s):" | awk '{print $2}' || echo "1")
        total_numa_nodes=$(echo "$lscpu_output" | grep "NUMA node(s):" | awk '{print $3}' || echo "1")
        cpu_model_name=$(echo "$lscpu_output" | grep "Model name:" | cut -d':' -f2 | sed 's/^[[:space:]]*//' || echo "Unknown")
    else
        total_sockets=1
        total_numa_nodes=1
        cpu_model_name="Unknown"
    fi
    
    # Get BIOS version
    if command -v dmidecode >/dev/null 2>&1; then
        bios_version=$(dmidecode -t bios 2>/dev/null | grep "Version:" | head -1 | cut -d':' -f2 | sed 's/^[[:space:]]*//' || echo "Unknown")
    else
        bios_version="Unknown"
    fi
    
    # Get microcode
    if [[ -f /proc/cpuinfo ]]; then
        microcode=$(grep "microcode" /proc/cpuinfo | head -1 | cut -d':' -f2 | sed 's/^[[:space:]]*//' || echo "Unknown")
    else
        microcode="Unknown"
    fi
    
    # Get OS information
    if [[ -f /etc/os-release ]]; then
        operating_system=$(grep "PRETTY_NAME=" /etc/os-release | cut -d'=' -f2 | tr -d '"' || echo "Unknown")
    else
        operating_system="Unknown"
    fi
    
    # Get kernel version
    kernel_version=$(uname -r)
    
    log "System info gathered: $total_cores cores, $total_sockets sockets, $total_numa_nodes NUMA nodes"
}

validate_emon_params() {
    local missing_params=()
    
    if [[ -z "$emon_session" ]]; then
        missing_params+=("--emon-session")
    fi
    if [[ -z "$workload_name" ]]; then
        missing_params+=("--workload-name")
    fi
    if [[ -z "$metric_unit" ]]; then
        missing_params+=("--metric-unit")
    fi
    
    if [[ ${#missing_params[@]} -gt 0 ]]; then
        error_exit "EMON enabled but missing required parameters: ${missing_params[*]}"
    fi
}

validate_script() {
    if [[ -z "$script_path" ]]; then
        error_exit "--script parameter is required"
    fi
    
    # Handle relative paths
    if [[ ! "$script_path" = /* ]]; then
        script_path="$SCRIPT_DIR/$script_path"
    fi
    
    if [[ ! -f "$script_path" ]]; then
        echo "Error: Script file '$script_path' not found" >&2
        suggest_available_workloads
        exit 1
    fi
    
    if [[ ! -x "$script_path" ]]; then
        error_exit "Script file '$script_path' is not executable. Try: chmod +x $script_path"
    fi
}

suggest_available_workloads() {
    echo ""
    echo "Available workload scripts:"
    
    local found_workloads=false
    for dir in "$SCRIPT_DIR"/*; do
        if [[ -d "$dir" ]]; then
            local workload_script="$dir/workload.sh"
            local superpi_script="$dir/superpi.sh"
            
            if [[ -f "$workload_script" ]]; then
                echo "  ./${dir##*/}/workload.sh"
                found_workloads=true
            fi
            if [[ -f "$superpi_script" ]]; then
                echo "  ./${dir##*/}/superpi.sh"
                found_workloads=true
            fi
        fi
    done
    
    if [[ "$found_workloads" == false ]]; then
        echo "  No workload scripts found in subdirectories"
    fi
}

get_core_list() {
    local core_list=()
    
    if [[ -n "$specific_nproc" ]]; then
        if [[ $specific_nproc -gt $total_cores ]]; then
            error_exit "Specified nproc ($specific_nproc) exceeds available cores ($total_cores)"
        fi
        core_list=($specific_nproc)
    else
        for ((i=cores_step; i<=total_cores; i+=cores_step)); do
            core_list+=($i)
        done
        
        # Always include max cores if not already included
        if [[ $((total_cores % cores_step)) -ne 0 ]]; then
            core_list+=($total_cores)
        fi
    fi
    
    echo "${core_list[@]}"
}

create_system_info_file() {
    local output_dir="$1"
    local cores="$2"
    local system_info_file="$output_dir/system_info.txt"
    
    cat > "$system_info_file" << EOF
# System Configuration
timestamp: "$(date '+%Y-%m-%d %H:%M:%S')"
hostname: "$(hostname)"
bios_version: "$bios_version"
microcode: "$microcode"
operating_system: "$operating_system"
kernel: "$kernel_version"
cpu_model: "$cpu_model_name"
total_cores: $total_cores
total_sockets: $total_sockets
numa_nodes: $total_numa_nodes
test_cores: $cores
workload_script: "$script_path"
script_args: "$script_args"
EOF

    if [[ "$enable_emon" == true ]]; then
        cat >> "$system_info_file" << EOF
emon_user: "$emon_user"
emon_group: "$emon_group"
emon_session: "$emon_session"
emon_server: "$emon_server"
EOF
    fi
}

create_workload_result_file() {
    local output_dir="$1"
    local cores="$2"
    local performance_result="$3"
    local workload_result_file="$output_dir/workload_result.txt"
    
    cat > "$workload_result_file" << EOF
workload_name:"$workload_name"
metric_type:"$metric_type"
result:"$performance_result"
metric:"$metric_unit"
num_instances:1
sockets:$total_sockets
cores_used:$cores
total_cores:$total_cores
notes:"Core scaling test with $cores cores using $(basename "$script_path")"
test_date:"$(date '+%Y-%m-%d %H:%M:%S')"
hostname:"$(hostname)"
EOF
}

add_result_to_data() {
    local cores="$1"
    local performance_result="$2"
    local run_id="$3"
    local test_case="$4"
    local notes="$5"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname=$(hostname)
    local workload_basename=$(basename "$(dirname "$script_path")")
    
    # Auto-detect workload name if not provided
    if [[ -z "$workload_name" ]]; then
        workload_name="$workload_basename"
    fi
    
    # Auto-detect metric unit based on workload if not provided
    if [[ -z "$metric_unit" ]]; then
        case "$workload_basename" in
            "SuperPi"|"superpi")
                metric_unit="seconds"
                metric_type="Latency"
                ;;
            "stream")
                metric_unit="MB/s"
                metric_type="Throughput"
                ;;
            "sysbench")
                metric_unit="ops/s"
                metric_type="Throughput"
                ;;
            "stress-ng")
                metric_unit="bogo ops/s"
                metric_type="Throughput"
                ;;
            "ffmpeg")
                metric_unit="fps"
                metric_type="Throughput"
                ;;
            "crypto++")
                metric_unit="MB/s"
                metric_type="Throughput"
                ;;
            "multichase")
                metric_unit="ns"
                metric_type="Latency"
                ;;
            *)
                metric_unit="units"
                metric_type="Performance"
                ;;
        esac
    fi
    
    # Add to results data array
    RESULTS_DATA+=("$timestamp|$hostname|$workload_name|$test_case|$cores|$total_cores|$cpu_model_name|$operating_system|$kernel_version|$bios_version|$microcode|$total_sockets|$total_numa_nodes|$metric_type|$metric_unit|$performance_result|$performance_result|$performance_result|$notes|$script_path|$script_args|$enable_emon|$emon_session|$run_id")
    
    log "Added result to data: $workload_name - $cores cores - $performance_result $metric_unit"
}

create_excel_file() {
    if [[ "$dry_run" == true ]]; then
        echo "DRY RUN: Would create Excel file"
        return
    fi
    
    # Check if python3 is available
    if ! command -v python3 >/dev/null 2>&1; then
        log "Warning: python3 not found. Excel file creation skipped."
        return
    fi
    
    # Create Python script to generate Excel
    local python_script=$(mktemp)
    cat > "$python_script" << 'EOF'
import sys
import os
from datetime import datetime

try:
    import pandas as pd
    import openpyxl
    from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
    from openpyxl.utils.dataframe import dataframe_to_rows
    EXCEL_AVAILABLE = True
except ImportError:
    EXCEL_AVAILABLE = False

def create_excel_file(data_lines, excel_file):
    if not EXCEL_AVAILABLE:
        print("Warning: pandas or openpyxl not available. Install with: pip3 install pandas openpyxl")
        return False
    
    try:
        # Parse data lines
        headers = ["Timestamp", "Hostname", "Workload", "Test_Case", "Cores_Used", "Total_Cores", 
                  "CPU_Model", "OS", "Kernel", "BIOS", "Microcode", "Sockets", "NUMA_Nodes", 
                  "Metric_Type", "Metric_Unit", "Score", "Performance", "Throughput", "Notes", 
                  "Script_Path", "Script_Args", "EMON_Enabled", "EMON_Session", "Run_ID"]
        
        data_rows = []
        for line in data_lines:
            if line.strip():
                row = line.strip().split('|')
                if len(row) == len(headers):
                    data_rows.append(row)
        
        if not data_rows:
            print("No valid data to write to Excel")
            return False
        
        # Create DataFrame
        df = pd.DataFrame(data_rows, columns=headers)
        
        # Convert numeric columns
        numeric_cols = ["Cores_Used", "Total_Cores", "Sockets", "NUMA_Nodes"]
        for col in numeric_cols:
            df[col] = pd.to_numeric(df[col], errors='coerce')
        
        # Try to convert Score, Performance, Throughput to numeric
        for col in ["Score", "Performance", "Throughput"]:
            df[col] = pd.to_numeric(df[col], errors='ignore')
        
        # Create Excel writer
        with pd.ExcelWriter(excel_file, engine='openpyxl') as writer:
            # Write main data
            df.to_excel(writer, sheet_name='Results', index=False)
            
            # Get workbook and worksheet
            workbook = writer.book
            worksheet = writer.sheets['Results']
            
            # Style the header
            header_font = Font(bold=True, color="FFFFFF")
            header_fill = PatternFill(start_color="366092", end_color="366092", fill_type="solid")
            header_alignment = Alignment(horizontal="center", vertical="center")
            
            for cell in worksheet[1]:
                cell.font = header_font
                cell.fill = header_fill
                cell.alignment = header_alignment
            
            # Auto-adjust column widths
            for column in worksheet.columns:
                max_length = 0
                column_letter = column[0].column_letter
                
                for cell in column:
                    try:
                        if len(str(cell.value)) > max_length:
                            max_length = len(str(cell.value))
                    except:
                        pass
                
                adjusted_width = min(max_length + 2, 50)
                worksheet.column_dimensions[column_letter].width = adjusted_width
            
            # Add borders
            thin_border = Border(
                left=Side(style='thin'),
                right=Side(style='thin'),
                top=Side(style='thin'),
                bottom=Side(style='thin')
            )
            
            for row in worksheet.iter_rows():
                for cell in row:
                    cell.border = thin_border
            
            # Create summary sheet if we have data
            if len(df) > 0:
                try:
                    # Group by workload
                    workload_summary = df.groupby('Workload').agg({
                        'Cores_Used': ['min', 'max', 'count'],
                        'Score': ['min', 'max', 'mean'],
                        'Timestamp': ['min', 'max']
                    }).round(3)
                    
                    summary_df = pd.DataFrame({
                        'Workload': workload_summary.index,
                        'Min_Cores': workload_summary[('Cores_Used', 'min')].values,
                        'Max_Cores': workload_summary[('Cores_Used', 'max')].values,
                        'Total_Runs': workload_summary[('Cores_Used', 'count')].values,
                        'Best_Score': workload_summary[('Score', 'min')].values,
                        'Worst_Score': workload_summary[('Score', 'max')].values,
                        'Avg_Score': workload_summary[('Score', 'mean')].values,
                        'First_Run': workload_summary[('Timestamp', 'min')].values,
                        'Last_Run': workload_summary[('Timestamp', 'max')].values
                    })
                    
                    summary_df.to_excel(writer, sheet_name='Summary', index=False)
                    
                    # Style summary sheet
                    summary_ws = writer.sheets['Summary']
                    for cell in summary_ws[1]:
                        cell.font = header_font
                        cell.fill = header_fill
                        cell.alignment = header_alignment
                    
                    for column in summary_ws.columns:
                        max_length = 0
                        column_letter = column[0].column_letter
                        
                        for cell in column:
                            try:
                                if len(str(cell.value)) > max_length:
                                    max_length = len(str(cell.value))
                            except:
                                pass
                        
                        adjusted_width = min(max_length + 2, 30)
                        summary_ws.column_dimensions[column_letter].width = adjusted_width
                    
                    for row in summary_ws.iter_rows():
                        for cell in row:
                            cell.border = thin_border
                            
                except Exception as e:
                    print(f"Warning: Could not create summary sheet: {e}")
        
        print(f"Excel file created successfully: {excel_file}")
        return True
        
    except Exception as e:
        print(f"Error creating Excel file: {e}")
        return False

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 script.py <data_file> <excel_file>")
        sys.exit(1)
    
    data_file = sys.argv[1]
    excel_file = sys.argv[2]
    
    if not os.path.exists(data_file):
        print(f"Data file not found: {data_file}")
        sys.exit(1)
    
    with open(data_file, 'r') as f:
        data_lines = f.readlines()
    
    create_excel_file(data_lines, excel_file)
EOF
    
    # Write results data to temporary file
    local temp_data_file=$(mktemp)
    for result in "${RESULTS_DATA[@]}"; do
        echo "$result" >> "$temp_data_file"
    done
    
    # Run the conversion
    if python3 "$python_script" "$temp_data_file" "$MASTER_RESULTS_FILE"; then
        log "Excel file created: $MASTER_RESULTS_FILE"
    else
        log "Excel file creation failed."
    fi
    
    # Clean up
    rm -f "$python_script" "$temp_data_file"
}

parse_performance_output() {
    local output_file="$1"
    local output_dir="$2"
    
    debug_log "Starting performance parsing for: $output_file"
    
    if [[ ! -f "$output_file" ]]; then
        debug_log "Output file not found: $output_file"
        echo "N/A"
        return
    fi
    
    local content=$(cat "$output_file")
    debug_log "Output file size: $(wc -l < "$output_file") lines"
    
    if [[ "$DEBUG_MODE" == true ]]; then
        echo "=== DEBUG: Full output content ==="
        cat "$output_file"
        echo "=== END DEBUG OUTPUT ==="
    fi
    
    # Check for workload_result.txt file (created by EMON wrapper or workload)
    local workload_result_file="$output_dir/workload_result.txt"
    if [[ -f "$workload_result_file" ]]; then
        debug_log "Found workload_result.txt file"
        local result_from_file=$(grep "result:" "$workload_result_file" | cut -d'"' -f2)
        if [[ -n "$result_from_file" && "$result_from_file" != "N/A" && "$result_from_file" =~ ^[0-9.]+$ ]]; then
            debug_log "Extracted result from workload_result.txt: $result_from_file"
            echo "$result_from_file"
            return
        fi
    fi
    
    # Check for benchmark_summary.txt (SuperPi specific)
    local summary_file="$output_dir/benchmark_summary.txt"
    if [[ -f "$summary_file" ]]; then
        debug_log "Found benchmark_summary.txt file"
        local summary_result=$(grep "SuperPi Score:" "$summary_file" | awk '{print $3}')
        if [[ -n "$summary_result" && "$summary_result" =~ ^[0-9.]+$ ]]; then
            debug_log "Extracted result from benchmark_summary.txt: $summary_result"
            echo "$summary_result"
            return
        fi
    fi
    
    # Pattern 1: SuperPi specific patterns
    local superpi_score=$(echo "$content" | grep -i "superpi.*score" | head -1 | grep -oE '[0-9]+\.?[0-9]*')
    if [[ -n "$superpi_score" && "$superpi_score" =~ ^[0-9.]+$ ]]; then
        debug_log "Found SuperPi score pattern: $superpi_score"
        echo "$superpi_score"
        return
    fi
    
    # Pattern 2: "Performance: 1234.56 seconds" or "Performance: 1234.56"
    local perf_match=$(echo "$content" | grep -i "performance:" | head -1 | grep -oE '[0-9]+\.?[0-9]*')
    if [[ -n "$perf_match" && "$perf_match" =~ ^[0-9.]+$ ]]; then
        debug_log "Found performance pattern: $perf_match"
        echo "$perf_match"
        return
    fi
    
    # Pattern 3: "Throughput: 1234.56"
    local throughput_match=$(echo "$content" | grep -i "throughput:" | head -1 | grep -oE '[0-9]+\.?[0-9]*')
    if [[ -n "$throughput_match" && "$throughput_match" =~ ^[0-9.]+$ ]]; then
        debug_log "Found throughput pattern: $throughput_match"
        echo "$throughput_match"
        return
    fi
    
    # Pattern 4: "Score: 1234.56" or similar
    local score_match=$(echo "$content" | grep -i "score:" | head -1 | grep -oE '[0-9]+\.?[0-9]*')
    if [[ -n "$score_match" && "$score_match" =~ ^[0-9.]+$ ]]; then
        debug_log "Found score pattern: $score_match"
        echo "$score_match"
        return
    fi
    
    # Pattern 5: Look for "execution time" patterns
    local exec_time=$(echo "$content" | grep -i "execution.*time" | head -1 | grep -oE '[0-9]+\.?[0-9]*')
    if [[ -n "$exec_time" && "$exec_time" =~ ^[0-9.]+$ ]]; then
        debug_log "Found execution time pattern: $exec_time"
        echo "$exec_time"
        return
    fi
    
    # Pattern 6: Look for time format like "real 12.34"
    local time_match=$(echo "$content" | grep "real" | head -1 | awk '{print $2}')
    if [[ -n "$time_match" && "$time_match" =~ ^[0-9.]+$ ]]; then
        debug_log "Found real time pattern: $time_match"
        echo "$time_match"
        return
    fi
    
    # Pattern 7: Look for any standalone number on its own line (common in benchmark outputs)
    local number_match=$(echo "$content" | grep -E "^[0-9]+\.?[0-9]*$" | tail -1)
    if [[ -n "$number_match" && "$number_match" =~ ^[0-9.]+$ ]]; then
        debug_log "Found standalone number pattern: $number_match"
        echo "$number_match"
        return
    fi
    
    # Pattern 8: Look for numbers after common benchmark keywords
    local result_keywords=("result" "time" "duration" "elapsed" "total" "average" "avg")
    for keyword in "${result_keywords[@]}"; do
        local keyword_match=$(echo "$content" | grep -i "$keyword" | head -1 | grep -oE '[0-9]+\.?[0-9]*' | tail -1)
        if [[ -n "$keyword_match" && "$keyword_match" =~ ^[0-9.]+$ ]]; then
            debug_log "Found keyword ($keyword) pattern: $keyword_match"
            echo "$keyword_match"
            return
        fi
    done
    
    debug_log "No performance result found in any pattern"
    echo "N/A"
}

run_workload_with_cores() {
    local cores="$1"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local workload_basename=$(basename "$(dirname "$script_path")")
    local run_id="${workload_basename}_${cores}cores_${timestamp}"
    local output_dir="$emon_output_dir/$run_id"
    
    echo "=================================================="
    echo "Running $workload_basename with $cores cores"
    echo "Run ID: $run_id"
    echo "Output directory: $output_dir"
    echo "=================================================="
    
    # Create output directory
    if [[ "$dry_run" == false ]]; then
        mkdir -p "$output_dir"
        create_system_info_file "$output_dir" "$cores"
    fi
    
    # Prepare workload command - Fixed core range format
    local script_abs_path=$(readlink -f "$script_path")
    local core_range="0-$((cores-1))"
    local workload_cmd="$script_abs_path --cpu-cores $core_range"
    
    # Add additional script arguments if provided
    if [[ -n "$script_args" ]]; then
        workload_cmd="$workload_cmd $script_args"
    fi
    
    local output_file="$output_dir/workload_output.log"
    local exit_code=0
    
    if [[ "$enable_emon" == true ]]; then
        # TMC command
        local tmc_cmd="python3 /root/tmc/tmc.py -c \"$workload_cmd\" -d \"$(readlink -f "$output_dir")\" -n"
        
        # Add optional parameters only if provided
        if [[ -n "$emon_user" ]]; then
            tmc_cmd="$tmc_cmd -x \"$emon_user\""
        fi
        
        if [[ -n "$emon_group" ]]; then
            tmc_cmd="$tmc_cmd -G \"$emon_group\""
        fi
        
        if [[ -n "$emon_session" ]]; then
            tmc_cmd="$tmc_cmd -i \"${emon_session}_${cores}cores\""
        fi
        
        if [[ $emon_duration -gt 0 ]]; then
            tmc_cmd="$tmc_cmd -t $emon_duration"
        fi
        
        tmc_cmd="$tmc_cmd -w \"$emon_chart_views\""
        
        if [[ -n "$emon_server" ]]; then
            tmc_cmd="$tmc_cmd -Z \"$emon_server\""
        fi
        
        echo "TMC Command: $tmc_cmd"
        
        if [[ "$dry_run" == false ]]; then
            echo "Executing with TMC/EMON..."
            
            # Check if TMC script exists
            if [[ ! -f "/root/tmc/tmc.py" ]]; then
                echo "Error: TMC script not found at /root/tmc/tmc.py"
                echo "Please check TMC installation path"
                return 1
            fi
            
            # Check if workload script exists and is executable
            if [[ ! -f "$script_abs_path" ]]; then
                echo "Error: Workload script not found at $script_abs_path"
                return 1
            fi
            
            if [[ ! -x "$script_abs_path" ]]; then
                echo "Error: Workload script is not executable: $script_abs_path"
                echo "Try: chmod +x $script_abs_path"
                return 1
            fi
            
            if eval "$tmc_cmd" > "$output_file" 2>&1; then
                exit_code=0
            else
                exit_code=$?
                echo "TMC execution failed with exit code: $exit_code"
                if [[ -f "$output_file" ]]; then
                    echo "Last 20 lines of output:"
                    tail -20 "$output_file"
                fi
            fi
        else
            echo "DRY RUN: Would execute TMC command above"
            exit_code=0
        fi
    else
        # Direct workload execution
        echo "Workload Command: $workload_cmd"
        
        if [[ "$dry_run" == false ]]; then
            echo "Executing workload directly..."
            
            # Check if workload script exists and is executable
            if [[ ! -f "$script_abs_path" ]]; then
                echo "Error: Workload script not found at $script_abs_path"
                return 1
            fi
            
            if [[ ! -x "$script_abs_path" ]]; then
                echo "Error: Workload script is not executable: $script_abs_path"
                echo "Try: chmod +x $script_abs_path"
                return 1
            fi
            
            echo "Starting workload execution..."
            if eval "$workload_cmd" > "$output_file" 2>&1; then
                exit_code=0
                echo "Workload execution completed successfully"
            else
                exit_code=$?
                echo "Workload execution failed with exit code: $exit_code"
                if [[ -f "$output_file" ]]; then
                    echo "Last 20 lines of output:"
                    tail -20 "$output_file"
                fi
            fi
        else
            echo "DRY RUN: Would execute workload command above"
            exit_code=0
        fi
    fi
    
    # Process results if not dry run
    if [[ "$dry_run" == false && $exit_code -eq 0 ]]; then
        echo "Processing results..."
        
        # Parse performance output with enhanced debugging
        local perf_result=$(parse_performance_output "$output_file" "$output_dir")
        echo "Parsed performance result: $perf_result"
        
        if [[ "$DEBUG_MODE" == true ]]; then
            echo "=== DEBUG: Files in output directory ==="
            ls -la "$output_dir"
            echo "=== END DEBUG FILES ==="
        fi
        
        if [[ "$enable_emon" == true ]]; then
            create_workload_result_file "$output_dir" "$cores" "$perf_result"
        fi
        
        # Add to results data
        local test_case="${cores}cores"
        local notes="Core scaling test with $cores cores using $(basename "$script_path")"
        if [[ -n "$script_args" ]]; then
            notes="$notes, args: $script_args"
        fi
        
        add_result_to_data "$cores" "$perf_result" "$run_id" "$test_case" "$notes"
        
        echo "Performance result: $perf_result $metric_unit"
        echo "Results saved to: $output_dir"
        echo "Added to results data"
        
    elif [[ "$dry_run" == false ]]; then
        echo "Warning: Workload execution failed with exit code $exit_code"
        
        # Still add failed result to results data for tracking
        local test_case="${cores}cores"
        local notes="FAILED: Core scaling test with $cores cores using $(basename "$script_path"), exit code: $exit_code"
        add_result_to_data "$cores" "FAILED" "$run_id" "$test_case" "$notes"
        
        if [[ $exit_code -eq 126 ]]; then
            echo "Exit code 126 usually means 'Permission denied' or 'Command not executable'"
            echo "Check if the script is executable: ls -la $script_abs_path"
            echo "Make it executable with: chmod +x $script_abs_path"
        elif [[ $exit_code -eq 127 ]]; then
            echo "Exit code 127 usually means 'Command not found'"
            echo "Check if the script path is correct: $script_abs_path"
        fi
    fi
    
    echo ""
    return $exit_code
}

set_performance_governor() {
    if [[ "$dry_run" == true ]]; then
        echo "DRY RUN: Would set CPU governor to performance"
        return
    fi
    
    log "Setting CPU governor to performance..."
    
    local cpu_dirs=(/sys/devices/system/cpu/cpu[0-9]*)
    local governor_set=false
    
    for cpu_dir in "${cpu_dirs[@]}"; do
        local governor_file="$cpu_dir/cpufreq/scaling_governor"
        if [[ -f "$governor_file" ]]; then
            if echo "performance" > "$governor_file" 2>/dev/null; then
                governor_set=true
            fi
        fi
    done
    
    if [[ "$governor_set" == true ]]; then
        log "CPU governor set to performance"
    else
        log "Warning: Could not set CPU governor (may require root privileges)"
    fi
}

# ------------------------------ ARGUMENT PARSING -----------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--script)
            script_path="$2"
            shift 2
            ;;
        -c|--cores)
            cores_step="$2"
            shift 2
            ;;
        -n|--nproc)
            specific_nproc="$2"
            shift 2
            ;;
        -r|--dry-run)
            dry_run=true
            shift
            ;;
        -e|--emon)
            enable_emon=true
            shift
            ;;
        --emon-user)
            emon_user="$2"
            shift 2
            ;;
        --emon-group)
            emon_group="$2"
            shift 2
            ;;
        --emon-server)
            emon_server="$2"
            shift 2
            ;;
        --emon-session)
            emon_session="$2"
            shift 2
            ;;
        --workload-name)
            workload_name="$2"
            shift 2
            ;;
        --metric-type)
            metric_type="$2"
            shift 2
            ;;
        --metric-unit)
            metric_unit="$2"
            shift 2
            ;;
        --script-args)
            script_args="$2"
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
        --debug)
            DEBUG_MODE=true
            shift
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

# ------------------------------ MAIN EXECUTION -----------------------------------

# Validation
if [[ -z "$script_path" ]]; then
    error_exit "--script parameter is required. Use --help for usage information."
fi

validate_script

if [[ "$enable_emon" == true ]]; then
    validate_emon_params
fi

if [[ $cores_step -le 0 ]]; then
    error_exit "Core stepping size must be positive"
fi

if [[ -n "$specific_nproc" && $specific_nproc -le 0 ]]; then
    error_exit "nproc value must be positive"
fi

# Get system information
get_system_info

# Print execution info
echo "============================================================"
echo "WORKLOAD WRAPPER SCRIPT (BASH VERSION)"
echo "============================================================"
echo "Script: $script_path"
echo "Mode: $(if [[ "$dry_run" == true ]]; then echo "DRY RUN"; else echo "EXECUTION"; fi)"
echo "Debug: $(if [[ "$DEBUG_MODE" == true ]]; then echo "ENABLED"; else echo "DISABLED"; fi)"
echo "EMON: $(if [[ "$enable_emon" == true ]]; then echo "ENABLED"; else echo "DISABLED"; fi)"
echo "System: $total_cores cores, $total_sockets sockets, $total_numa_nodes NUMA nodes"
echo "CPU: $cpu_model_name"
echo "OS: $operating_system"
echo "Master Results: $MASTER_RESULTS_FILE"

if [[ -n "$script_args" ]]; then
    echo "Script Args: $script_args"
fi

if [[ "$enable_emon" == true ]]; then
    echo "EMON User: $emon_user"
    echo "EMON Group: $emon_group"
    echo "EMON Session: $emon_session"
    echo "Workload: $workload_name"
    echo "Metric: $metric_unit"
fi

echo "============================================================"
echo ""

# Get list of core counts to test
core_list=($(get_core_list))
echo "Testing with core counts: ${core_list[*]}"
echo ""

# Set performance governor
set_performance_governor

# Run workload for each core count
successful_runs=0
failed_runs=0

for cores in "${core_list[@]}"; do
    if run_workload_with_cores "$cores"; then
        successful_runs=$((successful_runs + 1))
    else
        failed_runs=$((failed_runs + 1))
    fi
done

# Create Excel file
if [[ "$dry_run" == false ]]; then
    log "Creating Excel results file..."
    create_excel_file
fi

echo "============================================================"
echo "WORKLOAD WRAPPER EXECUTION COMPLETED"
echo "============================================================"
echo "Total runs: $((successful_runs + failed_runs))"
echo "Successful runs: $successful_runs"
echo "Failed runs: $failed_runs"

if [[ "$dry_run" == false ]]; then
    echo ""
    echo "RESULTS FILES:"
    echo "  Master Excel: $MASTER_RESULTS_FILE"
    echo "  Individual run data: $emon_output_dir"
    
    if [[ "$enable_emon" == true ]]; then
        echo ""
        echo "Generated files per run:"
        echo "  - workload_result.txt (performance metrics)"
        echo "  - system_info.txt (system configuration)"
        echo "  - workload_output.log (execution log)"
        echo "  - EMON traces (if TMC enabled)"
    fi
    
    echo ""
    echo "To install Excel conversion dependencies:"
    echo "  pip3 install pandas openpyxl"
    
    echo ""
    echo "To enable debug mode for troubleshooting:"
    echo "  $0 --debug [other options]"
fi

echo "============================================================"
