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
customer_name=""
metric_unit=""
metric_type=""
test_type="corescaling"
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
WORKLOAD_CONFIG_FILE="$SCRIPT_DIR/workload_config.txt"

# Debug mode
DEBUG_MODE=false

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

WORKLOAD CONFIGURATION:
  --customer-name NAME       Customer name (overrides config file)
  --test-type TYPE           Test type: corescaling/individual (default: corescaling)
  --metric-unit UNIT         Metric unit (overrides config file)
  --metric-type TYPE         Metric type (overrides config file)

SCRIPT PARAMETERS:
  --script-args "ARGS"       Additional arguments to pass to workload script

TMC OPTIONAL:
  --emon-duration SEC        Collection duration in seconds (default: $DEFAULT_EMON_DURATION = until completion)
  --emon-chart-views VIEWS   Chart views (default: $DEFAULT_EMON_CHART_VIEWS)
  --emon-output-dir DIR      Base output directory (default: $DEFAULT_EMON_OUTPUT_DIR)

DEBUG:
  --debug                    Enable debug mode for troubleshooting

CONFIGURATION FILE:
  Edit $WORKLOAD_CONFIG_FILE to configure workload settings.
  Format: workload_name|customer_name|metric_unit|metric_type|test_type|notes

EXAMPLES:
  # Basic SuperPi execution
  $0 --script ./SuperPi/superpi.sh --cores 8

  # With custom customer name
  $0 --script ./SuperPi/superpi.sh --cores 8 --customer-name "MyCompany"

  # Individual run instead of core scaling
  $0 --script ./SuperPi/superpi.sh --nproc 32 --test-type individual

  # With debug mode
  $0 --script ./SuperPi/superpi.sh --cores 8 --debug

  # With EMON integration
  $0 --script ./SuperPi/superpi.sh --cores 4 --emon \\
     --emon-session "superpi_test" --customer-name "Intel"

RESULTS:
  Master results are saved to: $MASTER_RESULTS_FILE
  Configuration file: $WORKLOAD_CONFIG_FILE
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
    
    # Get BIOS version - Fixed to handle multiline output
    if command -v dmidecode >/dev/null 2>&1; then
        bios_version=$(dmidecode -t bios 2>/dev/null | grep "Version:" | head -1 | cut -d':' -f2 | sed 's/^[[:space:]]*//' | tr -d '\n' || echo "Unknown")
        if [[ -z "$bios_version" || "$bios_version" == " " ]]; then
            bios_version="Unknown"
        fi
    else
        bios_version="Unknown"
    fi
    
    # Get microcode - Fixed to handle multiline output
    if [[ -f /proc/cpuinfo ]]; then
        microcode=$(grep "microcode" /proc/cpuinfo | head -1 | cut -d':' -f2 | sed 's/^[[:space:]]*//' | tr -d '\n' || echo "Unknown")
        if [[ -z "$microcode" || "$microcode" == " " ]]; then
            microcode="Unknown"
        fi
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
    debug_log "BIOS: '$bios_version', Microcode: '$microcode'"
}

load_workload_config() {
    local workload_basename="$1"
    
    debug_log "Loading config for workload: $workload_basename"
    
    # Check if config file exists
    if [[ ! -f "$WORKLOAD_CONFIG_FILE" ]]; then
        log "Warning: Configuration file not found: $WORKLOAD_CONFIG_FILE"
        log "Using default values. Create the config file to customize workload settings."
    else
        # Read configuration for this workload
        while IFS='|' read -r wl_name cust_name met_unit met_type tst_type notes; do
            # Skip comments and empty lines
            if [[ "$wl_name" =~ ^#.*$ ]] || [[ -z "$wl_name" ]]; then
                continue
            fi
            
            # Match workload name (case insensitive)
            if [[ "${wl_name,,}" == "${workload_basename,,}" ]]; then
                debug_log "Found config match for: $workload_basename"
                
                # Only set values if not already provided via command line
                if [[ -z "$customer_name" ]]; then
                    customer_name="$cust_name"
                fi
                if [[ -z "$metric_unit" ]]; then
                    metric_unit="$met_unit"
                fi
                if [[ -z "$metric_type" ]]; then
                    metric_type="$met_type"
                fi
                if [[ "$test_type" == "corescaling" ]]; then
                    test_type="$tst_type"
                fi
                
                debug_log "Loaded config: customer=$customer_name, unit=$metric_unit, type=$metric_type, test=$test_type"
                return 0
            fi
        done < "$WORKLOAD_CONFIG_FILE"
    fi
    
    # Set defaults if no config found
    if [[ -z "$customer_name" ]]; then
        customer_name="Generic"
    fi
    if [[ -z "$metric_unit" ]]; then
        metric_unit="units"
    fi
    if [[ -z "$metric_type" ]]; then
        metric_type="Performance"
    fi
    
    debug_log "Using defaults: customer=$customer_name, unit=$metric_unit, type=$metric_type, test=$test_type"
}

validate_emon_params() {
    local missing_params=()
    
    if [[ -z "$emon_session" ]]; then
        missing_params+=("--emon-session")
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
        test_type="individual"
    else
        for ((i=cores_step; i<=total_cores; i+=cores_step)); do
            core_list+=($i)
        done
        
        # Always include max cores if not already included
        if [[ $((total_cores % cores_step)) -ne 0 ]]; then
            core_list+=($total_cores)
        fi
        test_type="corescaling"
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
customer_name: "$customer_name"
test_type: "$test_type"
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
customer_name:"$customer_name"
test_type:"$test_type"
notes:"$test_type test with $cores cores using $(basename "$script_path")"
test_date:"$(date '+%Y-%m-%d %H:%M:%S')"
hostname:"$(hostname)"
EOF
}

initialize_master_results() {
    # Only create Excel file, no CSV needed
    log "Master results will be saved to: $MASTER_RESULTS_FILE"
}

add_result_to_master() {
    local cores="$1"
    local performance_result="$2"
    local run_id="$3"
    local test_case="$4"
    local notes="$5"
    
    # Create temporary CSV for Excel conversion
    local temp_csv=$(mktemp)
    local new_entry_csv=$(mktemp)
    
    # Create header if this is the first entry
    if [[ ! -f "$MASTER_RESULTS_FILE" ]]; then
        cat > "$temp_csv" << EOF
Timestamp,Hostname,Workload,Test_Case,Cores_Used,Total_Cores,CPU_Model,OS,Kernel,BIOS,Microcode,Sockets,NUMA_Nodes,Customer_Name,Metric_Unit,Score,Notes,Script_Path,Script_Args,EMON_Enabled,EMON_Session,Run_ID
EOF
    else
        # Extract existing data from Excel if it exists
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "
try:
    import pandas as pd
    df = pd.read_excel('$MASTER_RESULTS_FILE', sheet_name='Results')
    df.to_csv('$temp_csv', index=False)
except:
    # If Excel read fails, create new header
    with open('$temp_csv', 'w') as f:
        f.write('Timestamp,Hostname,Workload,Test_Case,Cores_Used,Total_Cores,CPU_Model,OS,Kernel,BIOS,Microcode,Sockets,NUMA_Nodes,Customer_Name,Metric_Unit,Score,Notes,Script_Path,Script_Args,EMON_Enabled,EMON_Session,Run_ID\n')
" 2>/dev/null || {
                # Fallback if Python fails
                cat > "$temp_csv" << EOF
Timestamp,Hostname,Workload,Test_Case,Cores_Used,Total_Cores,CPU_Model,OS,Kernel,BIOS,Microcode,Sockets,NUMA_Nodes,Customer_Name,Metric_Unit,Score,Notes,Script_Path,Script_Args,EMON_Enabled,EMON_Session,Run_ID
EOF
            }
        else
            cat > "$temp_csv" << EOF
Timestamp,Hostname,Workload,Test_Case,Cores_Used,Total_Cores,CPU_Model,OS,Kernel,BIOS,Microcode,Sockets,NUMA_Nodes,Customer_Name,Metric_Unit,Score,Notes,Script_Path,Script_Args,EMON_Enabled,EMON_Session,Run_ID
EOF
        fi
    fi
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname=$(hostname)
    
    # Clean up multiline values
    local clean_bios=$(echo "$bios_version" | tr -d '\n\r' | sed 's/[[:space:]]\+/ /g')
    local clean_microcode=$(echo "$microcode" | tr -d '\n\r' | sed 's/[[:space:]]\+/ /g')
    
    # Append new entry
    cat >> "$temp_csv" << EOF
"$timestamp","$hostname","$workload_name","$test_case",$cores,$total_cores,"$cpu_model_name","$operating_system","$kernel_version","$clean_bios","$clean_microcode",$total_sockets,$total_numa_nodes,"$customer_name","$metric_unit","$performance_result","$notes","$script_path","$script_args","$enable_emon","$emon_session","$run_id"
EOF
    
    # Convert to Excel
    convert_csv_to_excel "$temp_csv"
    
    # Clean up
    rm -f "$temp_csv" "$new_entry_csv"
    
    log "Added result to master Excel: $workload_name - $cores cores - $performance_result $metric_unit"
}

convert_csv_to_excel() {
    local csv_file="$1"
    
    if [[ "$dry_run" == true ]]; then
        echo "DRY RUN: Would convert CSV to Excel"
        return
    fi
    
    # Check if python3 is available
    if ! command -v python3 >/dev/null 2>&1; then
        log "Warning: python3 not found. Excel conversion skipped."
        return
    fi
    
    # Create Python script to convert CSV to Excel
    local python_script=$(mktemp)
    cat > "$python_script" << 'EOF'
import sys
import csv
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

def convert_csv_to_excel(csv_file, excel_file):
    if not EXCEL_AVAILABLE:
        print("Warning: pandas or openpyxl not available. Install with: pip3 install pandas openpyxl")
        return False
    
    try:
        # Read CSV
        df = pd.read_csv(csv_file)
        
        # Clean up any multiline values in dataframe
        for col in df.columns:
            if df[col].dtype == 'object':
                df[col] = df[col].astype(str).str.replace('\n', ' ').str.replace('\r', ' ')
        
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
                        cell_value = str(cell.value) if cell.value is not None else ""
                        if len(cell_value) > max_length:
                            max_length = len(cell_value)
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
                    # Group by workload and customer
                    summary_data = []
                    
                    for (workload, customer), group in df.groupby(['Workload', 'Customer_Name']):
                        summary_data.append({
                            'Workload': workload,
                            'Customer': customer,
                            'Total_Runs': len(group),
                            'Min_Cores': group['Cores_Used'].min(),
                            'Max_Cores': group['Cores_Used'].max(),
                            'Best_Score': group['Score'].min() if group['Score'].dtype in ['int64', 'float64'] else 'N/A',
                            'Worst_Score': group['Score'].max() if group['Score'].dtype in ['int64', 'float64'] else 'N/A',
                            'Avg_Score': round(group['Score'].mean(), 3) if group['Score'].dtype in ['int64', 'float64'] else 'N/A',
                            'First_Run': group['Timestamp'].min(),
                            'Last_Run': group['Timestamp'].max()
                        })
                    
                    if summary_data:
                        summary_df = pd.DataFrame(summary_data)
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
                                    cell_value = str(cell.value) if cell.value is not None else ""
                                    if len(cell_value) > max_length:
                                        max_length = len(cell_value)
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
        print("Usage: python3 script.py <csv_file> <excel_file>")
        sys.exit(1)
    
    csv_file = sys.argv[1]
    excel_file = sys.argv[2]
    
    if not os.path.exists(csv_file):
        print(f"CSV file not found: {csv_file}")
        sys.exit(1)
    
    convert_csv_to_excel(csv_file, excel_file)
EOF
    
    # Run the conversion
    if python3 "$python_script" "$csv_file" "$MASTER_RESULTS_FILE"; then
        debug_log "Excel file updated: $MASTER_RESULTS_FILE"
    else
        log "Excel conversion failed."
    fi
    
    # Clean up
    rm -f "$python_script"
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
    
    # Pattern 7: CSV format - look for Score column (6th column)
    local csv_match=$(echo "$content" | grep "," | grep -v "Date,Workload" | tail -1 | cut -d',' -f6)
    if [[ -n "$csv_match" && "$csv_match" =~ ^[0-9.]+$ ]]; then
        debug_log "Found CSV score pattern: $csv_match"
        echo "$csv_match"
        return
    fi
    
    # Pattern 8: Look for any standalone number on its own line (common in benchmark outputs)
    local number_match=$(echo "$content" | grep -E "^[0-9]+\.?[0-9]*$" | tail -1)
    if [[ -n "$number_match" && "$number_match" =~ ^[0-9.]+$ ]]; then
        debug_log "Found standalone number pattern: $number_match"
        echo "$number_match"
        return
    fi
    
    # Pattern 9: Look for numbers after common benchmark keywords
    local result_keywords=("result" "time" "duration" "elapsed" "total" "average" "avg")
    for keyword in "${result_keywords[@]}"; do
        local keyword_match=$(echo "$content" | grep -i "$keyword" | head -1 | grep -oE '[0-9]+\.?[0-9]*' | tail -1)
        if [[ -n "$keyword_match" && "$keyword_match" =~ ^[0-9.]+$ ]]; then
            debug_log "Found keyword ($keyword) pattern: $keyword_match"
            echo "$keyword_match"
            return
        fi
    done
    
    # Pattern 10: Look in any CSV files created by the workload
    if [[ -d "$output_dir" ]]; then
        for csv_file in "$output_dir"/*.csv; do
            if [[ -f "$csv_file" ]]; then
                debug_log "Checking CSV file: $csv_file"
                local csv_result=$(tail -1 "$csv_file" | cut -d',' -f6 2>/dev/null)
                if [[ -n "$csv_result" && "$csv_result" =~ ^[0-9.]+$ ]]; then
                    debug_log "Found result in CSV file: $csv_result"
                    echo "$csv_result"
                    return
                fi
            fi
        done
    fi
    
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
    echo "Customer: $customer_name"
    echo "Test Type: $test_type"
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
        
        # Add to master results
        local test_case="${test_type}"
        local notes="$test_type test with $cores cores using $(basename "$script_path")"
        if [[ -n "$script_args" ]]; then
            notes="$notes, args: $script_args"
        fi
        
        add_result_to_master "$cores" "$perf_result" "$run_id" "$test_case" "$notes"
        
        echo "Performance result: $perf_result $metric_unit"
        echo "Results saved to: $output_dir"
        echo "Added to master results file"
        
    elif [[ "$dry_run" == false ]]; then
        echo "Warning: Workload execution failed with exit code $exit_code"
        
        # Still add failed result to master results for tracking
        local test_case="${test_type}"
        local notes="FAILED: $test_type test with $cores cores using $(basename "$script_path"), exit code: $exit_code"
        add_result_to_master "$cores" "FAILED" "$run_id" "$test_case" "$notes"
        
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
        --workload-name)
            workload_name="$2"
            shift 2
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
        --customer-name)
            customer_name="$2"
            shift 2
            ;;
        --test-type)
            test_type="$2"
            shift 2
            ;;
        --metric-unit)
            metric_unit="$2"
            shift 2
            ;;
        --metric-type)
            metric_type="$2"
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

# Load workload configuration
workload_basename=$(basename "$(dirname "$script_path")")
if [[ -z "$workload_name" ]]; then
    workload_name="$workload_basename"
fi
load_workload_config "$workload_basename"

# Initialize master results file
initialize_master_results

# Print execution info
echo "============================================================"
echo "WORKLOAD WRAPPER SCRIPT (BASH VERSION)"
echo "============================================================"
echo "Script: $script_path"
echo "Workload: $workload_name"
echo "Customer: $customer_name"
echo "Mode: $(if [[ "$dry_run" == true ]]; then echo "DRY RUN"; else echo "EXECUTION"; fi)"
echo "Debug: $(if [[ "$DEBUG_MODE" == true ]]; then echo "ENABLED"; else echo "DISABLED"; fi)"
echo "EMON: $(if [[ "$enable_emon" == true ]]; then echo "ENABLED"; else echo "DISABLED"; fi)"
echo "Test Type: $test_type"
echo "Metric: $metric_unit ($metric_type)"
echo "System: $total_cores cores, $total_sockets sockets, $total_numa_nodes NUMA nodes"
echo "CPU: $cpu_model_name"
echo "OS: $operating_system"
echo "Master Results: $MASTER_RESULTS_FILE"
echo "Config File: $WORKLOAD_CONFIG_FILE"

if [[ -n "$script_args" ]]; then
    echo "Script Args: $script_args"
fi

if [[ "$enable_emon" == true ]]; then
    echo "EMON User: $emon_user"
    echo "EMON Group: $emon_group"
    echo "EMON Session: $emon_session"
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
    echo "  Configuration: $WORKLOAD_CONFIG_FILE"
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
    echo "CONFIGURATION:"
    echo "  Edit $WORKLOAD_CONFIG_FILE to customize workload settings"
    echo "  Format: workload_name|customer_name|metric_unit|metric_type|test_type|notes"
    
    echo ""
    echo "To install Excel dependencies:"
    echo "  pip3 install pandas openpyxl"
    
    echo ""
    echo "To enable debug mode for troubleshooting:"
    echo "  $0 --debug [other options]"
fi

echo "============================================================"
