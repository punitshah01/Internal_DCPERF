#!/bin/bash
# setup_crypto256.sh - Crypto++ SHA-256 benchmark setup script

# =============================================================================
# CRYPTO++ SHA-256 SETUP SCRIPT
# =============================================================================
# This script downloads, compiles and configures Crypto++ library for SHA-256 benchmark
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
    log_info "Installing Crypto++ dependencies for CentOS/RHEL..."
    
    if command_exists dnf; then
        dnf groupinstall -y "Development Tools" || {
            log_error "Failed to install Development Tools with dnf"
            return 1
        }
        dnf install -y gcc-c++ make wget tar gzip || {
            log_error "Failed to install dependencies with dnf"
            return 1
        }
    elif command_exists yum; then
        yum groupinstall -y "Development Tools" || {
            log_error "Failed to install Development Tools with yum"
            return 1
        }
        yum install -y gcc-c++ make wget tar gzip || {
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
    log_info "Installing Crypto++ dependencies for Ubuntu/Debian..."
    
    apt update || {
        log_error "Failed to update package list"
        return 1
    }
    
    apt install -y build-essential g++ make wget tar gzip || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    log_info "Ubuntu/Debian dependencies installed successfully"
}

install_dependencies_suse() {
    log_info "Installing Crypto++ dependencies for SUSE..."
    
    zypper install -y -t pattern devel_basis || {
        log_error "Failed to install development pattern"
        return 1
    }
    
    zypper install -y gcc-c++ make wget tar gzip || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    log_info "SUSE dependencies installed successfully"
}

download_and_compile() {
    log_info "Downloading and compiling Crypto++ library..."
    
    local crypto_version="CRYPTOPP_8_5_0"
    local crypto_url="https://github.com/weidai11/cryptopp/archive/refs/tags/${crypto_version}.tar.gz"
    local crypto_dir="cryptopp-${crypto_version}"
    
    # Clean up any existing installation
    if [ -d "$crypto_dir" ]; then
        log_info "Removing existing Crypto++ directory..."
        rm -rf "$crypto_dir"
    fi
    
    # Download source
    log_info "Downloading Crypto++ source..."
    wget "$crypto_url" -O "cryptopp-${crypto_version}.tar.gz" || {
        log_error "Failed to download Crypto++ source"
        return 1
    }
    
    # Extract
    log_info "Extracting Crypto++ source..."
    tar zxf "cryptopp-${crypto_version}.tar.gz" || {
        log_error "Failed to extract Crypto++ source"
        return 1
    }
    
    # Compile
    log_info "Compiling Crypto++ library..."
    cd "$crypto_dir" || {
        log_error "Failed to enter Crypto++ directory"
        return 1
    }
    
    local cpu_count=$(nproc 2>/dev/null || echo "4")
    make -j "$cpu_count" || {
        log_error "Failed to compile Crypto++ library"
        return 1
    }
    
    # Verify compilation
    if [ ! -f "cryptest.exe" ]; then
        log_error "Crypto++ compilation failed - cryptest.exe not found"
        return 1
    fi
    
    cd ..
    log_info "Crypto++ library compiled successfully"
    return 0
}

verify_installation() {
    log_info "Verifying Crypto++ installation..."
    
    local crypto_dir="cryptopp-CRYPTOPP_8_5_0"
    
    if [ ! -d "$crypto_dir" ]; then
        log_error "Crypto++ directory not found: $crypto_dir"
        return 1
    fi
    
    if [ ! -f "$crypto_dir/cryptest.exe" ]; then
        log_error "Crypto++ test executable not found: $crypto_dir/cryptest.exe"
        return 1
    fi
    
    # Test basic functionality
    cd "$crypto_dir" || {
        log_error "Failed to enter Crypto++ directory"
        return 1
    }
    
    # Quick test run
    timeout 30 ./cryptest.exe b 2>&1 | grep -q "SHA-256" || {
        log_error "Crypto++ SHA-256 test failed"
        cd ..
        return 1
    }
    
    cd ..
    log_info "Crypto++ installation verified successfully"
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
  This script downloads and compiles Crypto++ library for SHA-256 benchmarking:
  - Downloads Crypto++ 8.5.0 source code
  - Installs build dependencies (gcc, make, etc.)
  - Compiles the library with optimal settings
  - Verifies SHA-256 functionality

EXAMPLES:
  $0                    # Full setup
  $0 --verify-only      # Only verify installation
  $0 --clean            # Clean and reinstall

AFTER INSTALLATION:
  Use with main wrapper:
  ./main_wrapper.py --script ./crypto256_workload.sh --cores 8 --workload-name \"Crypto++ SHA-256\" --metric-unit \"MB/s\" --run
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
    
    log_info "Starting Crypto++ SHA-256 benchmark setup..."
    
    if [[ $verify_only -eq 1 ]]; then
        verify_installation
        exit $?
    fi
    
    if [[ $clean_install -eq 1 ]]; then
        log_info "Cleaning existing installation..."
        rm -rf cryptopp-CRYPTOPP_8_5_0*
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
    
    log_info "Crypto++ SHA-256 benchmark setup completed successfully!"
    log_info ""
    log_info "Next steps:"
    log_info "1. Make sure crypto256_workload.sh is executable: chmod +x crypto256_workload.sh"
    log_info "2. Run with main wrapper: ./main_wrapper.py --script ./crypto256_workload.sh --cores 4 --workload-name \"Crypto++ SHA-256\" --metric-unit \"MB/s\" --run"
}

# Run main function
main "$@"
