#!/bin/bash
# setup_superpi.sh - Super Pi benchmark setup script

# =============================================================================
# SUPER PI SETUP SCRIPT
# =============================================================================
# This script installs and configures Super Pi benchmark dependencies
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
    log_info "Installing Super Pi dependencies for CentOS/RHEL..."
    
    # Install bc and util-linux (for taskset)
    if command_exists dnf; then
        dnf install -y bc util-linux time || {
            log_error "Failed to install dependencies with dnf"
            return 1
        }
    elif command_exists yum; then
        yum install -y bc util-linux time || {
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
    log_info "Installing Super Pi dependencies for Ubuntu/Debian..."
    
    # Update package list
    apt update || {
        log_error "Failed to update package list"
        return 1
    }
    
    # Install bc and util-linux
    apt install -y bc util-linux time || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    log_info "Ubuntu/Debian dependencies installed successfully"
}

install_dependencies_suse() {
    log_info "Installing Super Pi dependencies for SUSE..."
    
    # Install bc and util-linux
    zypper install -y bc util-linux time || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    log_info "SUSE dependencies installed successfully"
}

verify_installation() {
    log_info "Verifying Super Pi dependencies..."
    
    local missing_deps=()
    
    if ! command_exists bc; then
        missing_deps+=("bc")
    fi
    
    if ! command_exists taskset; then
        missing_deps+=("taskset")
    fi
    
    if ! command_exists time; then
        missing_deps+=("time")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        return 1
    fi
    
    # Test bc functionality
    local test_result=$(echo "scale=2; 4*a(1)" | bc -l 2>/dev/null)
    if [[ -z "$test_result" ]]; then
        log_error "bc command test failed"
        return 1
    fi
    
    log_info "All dependencies verified successfully"
    return 0
}

print_usage() {
    echo -e "
Usage: $0 [OPTIONS]

OPTIONS:
  -h, --help     Show this help message
  --verify-only  Only verify existing installation

DESCRIPTION:
  This script installs Super Pi benchmark dependencies:
  - bc (basic calculator for pi calculation)
  - util-linux (provides taskset for CPU affinity)
  - time (for timing measurements)

EXAMPLES:
  $0                    # Install all dependencies
  $0 --verify-only      # Only verify installation

AFTER INSTALLATION:
  Use with main wrapper:
  ./main_wrapper.py --script ./superpi_workload.sh --cores 8 --workload-name \"Super Pi\" --metric-unit \"seconds\" --run
"
}

main() {
    local verify_only=0
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verify-only)
                verify_only=1
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
    
    log_info "Starting Super Pi benchmark setup..."
    
    if [[ $verify_only -eq 1 ]]; then
        verify_installation
        exit $?
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
    
    # Verify installation
    verify_installation || exit 1
    
    log_info "Super Pi benchmark setup completed successfully!"
    log_info ""
    log_info "Next steps:"
    log_info "1. Make sure superpi_workload.sh is executable: chmod +x superpi_workload.sh"
    log_info "2. Run with main wrapper: ./main_wrapper.py --script ./superpi.sh --cores 4 --workload-name \"Super Pi\" --metric-unit \"seconds\" --run"
}

# Run main function
main "$@"
