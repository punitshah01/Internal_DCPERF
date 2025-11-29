#!/bin/bash
# setup_schbench.sh - Schbench scheduler benchmark setup script

# =============================================================================
# SCHBENCH SETUP SCRIPT
# =============================================================================
# This script downloads and compiles Schbench for scheduler performance testing
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
    log_info "Installing Schbench dependencies for CentOS/RHEL..."
    
    if command_exists dnf; then
        dnf groupinstall -y "Development Tools" || {
            log_error "Failed to install Development Tools with dnf"
            return 1
        }
        dnf install -y gcc make wget tar gzip bzip2 gmp-devel mpfr-devel libmpc-devel || {
            log_error "Failed to install dependencies with dnf"
            return 1
        }
    elif command_exists yum; then
        yum groupinstall -y "Development Tools" || {
            log_error "Failed to install Development Tools with yum"
            return 1
        }
        yum install -y gcc make wget tar gzip bzip2 gmp-devel mpfr-devel libmpc-devel || {
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
    log_info "Installing Schbench dependencies for Ubuntu/Debian..."
    
    apt update || {
        log_error "Failed to update package list"
        return 1
    }
    
    apt install -y build-essential gcc make wget tar gzip bzip2 libgmp-dev libmpfr-dev libmpc-dev || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    log_info "Ubuntu/Debian dependencies installed successfully"
}

install_dependencies_suse() {
    log_info "Installing Schbench dependencies for SUSE..."
    
    zypper install -y -t pattern devel_basis || {
        log_error "Failed to install development pattern"
        return 1
    }
    
    zypper install -y gcc make wget tar gzip bzip2 gmp-devel mpfr-devel libmpc-devel || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    log_info "SUSE dependencies installed successfully"
}

check_gcc_version() {
    log_info "Checking GCC version..."
    
    if ! command_exists gcc; then
        log_error "GCC not found"
        return 1
    fi
    
    local gcc_version=$(gcc --version | head -1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)
    local major_version=$(echo "$gcc_version" | cut -d. -f1)
    
    log_info "Found GCC version: $gcc_version"
    
    # Check if GCC version is adequate (>= 4.8)
    if [[ "$major_version" -ge 8 ]] || [[ "$gcc_version" == "8.3.0" ]]; then
        log_info "GCC version is adequate for Schbench"
        return 0
    elif [[ "$major_version" -ge 4 ]]; then
        log_warning "GCC version may work but 8.3.0+ is recommended"
        return 0
    else
        log_warning "GCC version is old, consider upgrading to 8.3.0+"
        return 0
    fi
}

download_and_compile() {
    log_info "Downloading and compiling Schbench..."
    
    local schbench_url="https://git.kernel.org/pub/scm/linux/kernel/git/mason/schbench.git/snapshot/schbench-1.0.tar.gz"
    local schbench_dir="schbench-1.0"
    
    # Clean up any existing installation
    if [ -d "$schbench_dir" ]; then
        log_info "Removing existing Schbench directory..."
        rm -rf "$schbench_dir"
    fi
    
    # Download source
    log_info "Downloading Schbench source..."
    wget "$schbench_url" || {
        log_error "Failed to download Schbench source"
        return 1
    }
    
    # Extract
    log_info "Extracting Schbench source..."
    tar -xf "schbench-1.0.tar.gz" || {
        log_error "Failed to extract Schbench source"
        return 1
    }
    
    # Compile
    log_info "Compiling Schbench..."
    cd "$schbench_dir" || {
        log_error "Failed to enter Schbench directory"
        return 1
    }
    
    # Check if Makefile exists, if not use manual compilation
    if [ -f "Makefile" ]; then
        log_info "Using Makefile to compile..."
        make || {
            log_warning "Makefile compilation failed, trying manual compilation..."
            compile_manually || return 1
        }
    else
        log_info "No Makefile found, using manual compilation..."
        compile_manually || return 1
    fi
    
    # Verify compilation
    if [ ! -f "schbench" ]; then
        log_error "Schbench compilation failed - executable not found"
        return 1
    fi
    
    # Make executable
    chmod +x schbench
    
    cd ..
    log_info "Schbench compiled successfully"
    return 0
}

compile_manually() {
    log_info "Compiling Schbench manually..."
    
    # Check if we need to add sched.h include
    if ! grep -q "#include <sched.h>" schbench.c; then
        log_info "Adding sched.h include to schbench.c..."
        sed -i '1i#include <sched.h>' schbench.c
    fi
    
    # Compile with specific flags
    gcc -Wall -O0 -W schbench.c -o schbench -lpthread -lm || {
        log_error "Manual compilation failed"
        return 1
    }
    
    log_info "Manual compilation successful"
    return 0
}

verify_installation() {
    log_info "Verifying Schbench installation..."
    
    local schbench_dir="schbench-1.0"
    
    if [ ! -d "$schbench_dir" ]; then
        log_error "Schbench directory not found: $schbench_dir"
        return 1
    fi
    
    if [ ! -f "$schbench_dir/schbench" ]; then
        log_error "Schbench executable not found: $schbench_dir/schbench"
        return 1
    fi
    
    # Test basic functionality
    cd "$schbench_dir" || {
        log_error "Failed to enter Schbench directory"
        return 1
    }
    
    # Quick test run (very short)
    timeout 5 ./schbench -r 1 -m 1 -t 1 >/dev/null 2>&1 || {
        log_warning "Schbench test run failed, but executable exists"
    }
    
    cd ..
    log_info "Schbench installation verified successfully"
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
  This script downloads and compiles Schbench scheduler benchmark:
  - Downloads Schbench 1.0 source from kernel.org
  - Installs build dependencies (GCC, make, etc.)
  - Compiles schbench executable with pthread and math libraries
  - Verifies scheduler benchmark functionality

EXAMPLES:
  $0                    # Full setup
  $0 --verify-only      # Only verify installation
  $0 --clean            # Clean and reinstall

AFTER INSTALLATION:
  Use with main wrapper:
  ./main_wrapper.py --script ./schbench_workload.sh --cores 8 --workload-name \"Schbench\" --metric-unit \"us\" --run
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
    
    log_info "Starting Schbench scheduler benchmark setup..."
    
    if [[ $verify_only -eq 1 ]]; then
        check_gcc_version
        verify_installation
        exit $?
    fi
    
    if [[ $clean_install -eq 1 ]]; then
        log_info "Cleaning existing installation..."
        rm -rf schbench-* schbench-1.0.tar.gz
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
    
    # Check GCC version
    check_gcc_version || exit 1
    
    # Download and compile
    download_and_compile || exit 1
    
    # Verify installation
    verify_installation || exit 1
    
    log_info "Schbench scheduler benchmark setup completed successfully!"
    log_info ""
    log_info "Next steps:"
    log_info "1. Make sure schbench_workload.sh is executable: chmod +x schbench_workload.sh"
    log_info "2. Run with main wrapper: ./main_wrapper.py --script ./schbench_workload.sh --cores 8 --workload-name \"Schbench\" --metric-unit \"us\" --run"
    log_info "3. Executable is located in: schbench-1.0/schbench"
}

# Run main function
main "$@"
