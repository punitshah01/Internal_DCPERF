#!/bin/bash
# setup_multichase.sh - Multichase benchmark setup script

# =============================================================================
# MULTICHASE SETUP SCRIPT
# =============================================================================
# This script downloads and compiles Multichase benchmark for memory latency testing
# =============================================================================

log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_warning() {
    echo "[WARNING] $1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID}:${VERSION_ID}"
    else
        log_error "Cannot determine the operating system."
        exit 1
    fi
}

install_dependencies_centos() {
    log_info "Installing Multichase dependencies for CentOS/RHEL..."
    
    if command_exists dnf; then
        dnf groupinstall -y "Development Tools" || {
            log_error "Failed to install Development Tools with dnf"
            return 1
        }
        dnf install -y gcc gcc-c++ make wget unzip glibc-static libstdc++-static numactl || {
            log_error "Failed to install dependencies with dnf"
            return 1
        }
    elif command_exists yum; then
        yum groupinstall -y "Development Tools" || {
            log_error "Failed to install Development Tools with yum"
            return 1
        }
        yum install -y gcc gcc-c++ make wget unzip glibc-static libstdc++-static numactl || {
            log_error "Failed to install dependencies with yum"
            return 1
        }
    else
        log_error "Neither dnf nor yum found"
        return 1
    fi
    
    log_info "CentOS/RHEL dependencies installed successfully"
}

install_dependencies_ubuntu() {
    log_info "Installing Multichase dependencies for Ubuntu/Debian..."
    
    apt update || {
        log_error "Failed to update package list"
        return 1
    }
    
    apt install -y build-essential gcc g++ make wget unzip libc6-dev libstdc++-dev numactl || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    log_info "Ubuntu/Debian dependencies installed successfully"
}

install_dependencies_suse() {
    log_info "Installing Multichase dependencies for SUSE..."
    
    zypper install -y -t pattern devel_basis || {
        log_error "Failed to install development pattern"
        return 1
    }
    
    zypper install -y gcc gcc-c++ make wget unzip glibc-devel-static libstdc++-devel numactl || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    log_info "SUSE dependencies installed successfully"
}

download_and_compile() {
    log_info "Downloading and compiling Multichase..."
    
    local multichase_url="https://github.com/google/multichase/archive/refs/heads/master.zip"
    local multichase_dir="multichase-master"
    
    # Clean up any existing installation
    if [ -d "$multichase_dir" ]; then
        log_info "Removing existing Multichase directory..."
        rm -rf "$multichase_dir"
    fi
    
    # Download source
    log_info "Downloading Multichase source..."
    wget "$multichase_url" -O "multichase-master.zip" || {
        log_error "Failed to download Multichase source"
        return 1
    }
    
    # Extract
    log_info "Extracting Multichase source..."
    unzip "multichase-master.zip" || {
        log_error "Failed to extract Multichase source"
        return 1
    }
    
    # Compile
    log_info "Compiling Multichase..."
    cd "$multichase_dir" || {
        log_error "Failed to enter Multichase directory"
        return 1
    }
    
    local cpu_count=$(nproc 2>/dev/null || echo "4")
    make -j "$cpu_count" || {
        log_error "Failed to compile Multichase"
        return 1
    }
    
    # Verify compilation
    if [ ! -f "multiload" ] || [ ! -f "pingpong" ]; then
        log_error "Multichase compilation failed - executables not found"
        return 1
    fi
    
    cd ..
    log_info "Multichase compiled successfully"
    return 0
}

verify_installation() {
    log_info "Verifying Multichase installation..."
    
    local multichase_dir="multichase-master"
    
    if [ ! -d "$multichase_dir" ]; then
        log_error "Multichase directory not found: $multichase_dir"
        return 1
    fi
    
    if [ ! -f "$multichase_dir/multiload" ]; then
        log_error "Multiload executable not found: $multichase_dir/multiload"
        return 1
    fi
    
    if [ ! -f "$multichase_dir/pingpong" ]; then
        log_error "Pingpong executable not found: $multichase_dir/pingpong"
        return 1
    fi
    
    # Test basic functionality
    cd "$multichase_dir" || {
        log_error "Failed to enter Multichase directory"
        return 1
    }
    
    # Quick test run
    timeout 10 ./multiload -s 1 -n 1 -t 1 -m 1m -c chaseload >/dev/null 2>&1 || {
        log_warning "Multiload test run failed, but executables exist"
    }
    
    cd ..
    log_info "Multichase installation verified successfully"
    return 0
}

check_numa_support() {
    log_info "Checking NUMA support..."
    
    if ! command_exists numactl; then
        log_warning "numactl not found - NUMA binding may not work"
        return 1
    fi
    
    local numa_nodes=$(numactl --hardware 2>/dev/null | grep "available:" | awk '{print $2}')
    if [[ -n "$numa_nodes" ]] && [[ "$numa_nodes" -gt 0 ]]; then
        log_info "NUMA support detected: $numa_nodes nodes available"
    else
        log_warning "NUMA nodes not detected or numactl failed"
    fi
    
    return 0
}

print_usage() {
    echo -e "
Usage: $0 [OPTIONS]

OPTIONS:
  -h, --help     Show this help message
  --verify-only  Only verify existing installation
  --clean        Clean existing installation before setup

DESCRIPTION:
  This script downloads and compiles Multichase benchmark for memory testing:
  - Downloads Multichase source from GitHub (commit 6188a9f)
  - Installs build dependencies (GCC, make, etc.)
  - Compiles multiload and pingpong executables
  - Verifies NUMA support for memory binding

EXAMPLES:
  $0                    # Full setup
  $0 --verify-only      # Only verify installation
  $0 --clean            # Clean and reinstall

AFTER INSTALLATION:
  Use with main wrapper:
  ./main_wrapper.py --script ./multichase_workload.sh --cores 8 --workload-name \"Multichase\" --metric-unit \"ns\" --run
"
}

main() {
    local verify_only=0
    local clean_install=0
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verify-only)
                verify_only=1
                shift
                ;;
            --clean)
                clean_install=1
                shift
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
    
    log_info "Starting Multichase benchmark setup..."
    
    if [[ $verify_only -eq 1 ]]; then
        verify_installation
        check_numa_support
        exit $?
    fi
    
    if [[ $clean_install -eq 1 ]]; then
        log_info "Cleaning existing installation..."
        rm -rf multichase-master* master.zip
    fi
    
    # Detect OS
    local os_info=$(detect_os)
    local os_id=$(echo "$os_info" | cut -d: -f1)
    local os_version=$(echo "$os_info" | cut -d: -f2)
    
    log_info "Detected OS: $os_id $os_version"
    
    # Install dependencies based on OS
    case "$os_id" in
        centos|rhel|rocky|almalinux)
            install_dependencies_centos || exit 1
            ;;
        ubuntu|debian)
            install_dependencies_ubuntu || exit 1
            ;;
        opensuse*|sles)
            install_dependencies_suse || exit 1
            ;;
        *)
            log_warning "Unsupported OS: $os_id. Attempting generic installation..."
            if command_exists apt; then
                install_dependencies_ubuntu || exit 1
            elif command_exists dnf || command_exists yum; then
                install_dependencies_centos || exit 1
            elif command_exists zypper; then
                install_dependencies_suse || exit 1
            else
                log_error "No supported package manager found"
                exit 1
            fi
            ;;
    esac
    
    # Download and compile
    download_and_compile || exit 1
    
    # Verify installation
    verify_installation || exit 1
    
    # Check NUMA support
    check_numa_support
    
    log_info "Multichase benchmark setup completed successfully!"
    log_info ""
    log_info "Next steps:"
    log_info "1. Make sure multichase_workload.sh is executable: chmod +x multichase_workload.sh"
    log_info "2. Run with main wrapper: ./main_wrapper.py --script ./multichase_workload.sh --cores 4 --workload-name \"Multichase\" --metric-unit \"ns\" --run"
    log_info "3. Executables are located in: multichase-master/"
}

# Run main function
main "$@"
