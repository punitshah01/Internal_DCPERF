#!/bin/bash
# setup_sysbench.sh - Sysbench database benchmark setup script

# =============================================================================
# SYSBENCH SETUP SCRIPT
# =============================================================================
# This script installs Sysbench and Percona MySQL Server for database benchmarking
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
    log_info "Installing Sysbench dependencies for CentOS/RHEL..."
    
    if command_exists dnf; then
        dnf groupinstall -y "Development Tools" || {
            log_error "Failed to install Development Tools with dnf"
            return 1
        }
        dnf install -y automake libtool pkgconfig mysql-devel wget tar gzip curl gnupg2 || {
            log_error "Failed to install dependencies with dnf"
            return 1
        }
    elif command_exists yum; then
        yum groupinstall -y "Development Tools" || {
            log_error "Failed to install Development Tools with yum"
            return 1
        }
        yum install -y automake libtool pkgconfig mysql-devel wget tar gzip curl gnupg2 || {
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
    log_info "Installing Sysbench dependencies for Ubuntu/Debian..."
    
    apt update || {
        log_error "Failed to update package list"
        return 1
    }
    
    apt install -y automake libtool pkg-config libmysqlclient-dev build-essential \
        wget tar gzip curl gnupg2 lsb-release || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    log_info "Ubuntu/Debian dependencies installed successfully"
}

install_dependencies_suse() {
    log_info "Installing Sysbench dependencies for SUSE..."
    
    zypper install -y -t pattern devel_basis || {
        log_error "Failed to install development pattern"
        return 1
    }
    
    zypper install -y automake libtool pkgconfig libmysqlclient-devel \
        wget tar gzip curl gpg2 || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    log_info "SUSE dependencies installed successfully"
}

download_and_compile_sysbench() {
    log_info "Downloading and compiling Sysbench..."
    
    local sysbench_version="1.0.20"
    local sysbench_url="https://github.com/akopytov/sysbench/archive/${sysbench_version}.tar.gz"
    local sysbench_dir="sysbench-${sysbench_version}"
    
    # Clean up any existing installation
    if [ -d "$sysbench_dir" ]; then
        log_info "Removing existing Sysbench directory..."
        rm -rf "$sysbench_dir"
    fi
    
    # Download source
    log_info "Downloading Sysbench source..."
    wget "$sysbench_url" -O "sysbench.tar.gz" || {
        log_error "Failed to download Sysbench source"
        return 1
    }
    
    # Extract
    log_info "Extracting Sysbench source..."
    tar -zxf "sysbench.tar.gz" || {
        log_error "Failed to extract Sysbench source"
        return 1
    }
    
    # Compile
    log_info "Compiling Sysbench..."
    cd "$sysbench_dir" || {
        log_error "Failed to enter Sysbench directory"
        return 1
    }
    
    ./autogen.sh || {
        log_error "Failed to run autogen.sh"
        return 1
    }
    
    ./configure || {
        log_error "Failed to configure Sysbench"
        return 1
    }
    
    local cpu_count=$(nproc 2>/dev/null || echo "4")
    make -j "$cpu_count" || {
        log_error "Failed to compile Sysbench"
        return 1
    }
    
    make install || {
        log_error "Failed to install Sysbench"
        return 1
    }
    
    cd ..
    log_info "Sysbench compiled and installed successfully"
    return 0
}

install_percona_server_ubuntu() {
    log_info "Installing Percona Server for MySQL on Ubuntu/Debian..."
    
    # Install prerequisites
    apt install -y gnupg2 curl lsb-release || {
        log_error "Failed to install prerequisites"
        return 1
    }
    
    # Download and install Percona repository
    local release_file="percona-release_latest.$(lsb_release -sc)_all.deb"
    wget "https://repo.percona.com/apt/$release_file" || {
        log_error "Failed to download Percona repository package"
        return 1
    }
    
    dpkg -i "$release_file" || {
        log_error "Failed to install Percona repository package"
        return 1
    }
    
    # Setup Percona Server 8.0
    percona-release setup ps80 || {
        log_error "Failed to setup Percona Server repository"
        return 1
    }
    
    # Update package list
    apt update || {
        log_error "Failed to update package list after adding Percona repository"
        return 1
    }
    
    # Install Percona Server (non-interactive)
    export DEBIAN_FRONTEND=noninteractive
    echo "percona-server-server percona-server-server/root_password password intel123" | debconf-set-selections
    echo "percona-server-server percona-server-server/root_password_again password intel123" | debconf-set-selections
    
    apt install -y percona-server-server || {
        log_error "Failed to install Percona Server"
        return 1
    }
    
    log_info "Percona Server installed successfully with default password 'intel123'"
    return 0
}

install_percona_server_centos() {
    log_info "Installing Percona Server for MySQL on CentOS/RHEL..."
    
    # Install Percona repository
    if command_exists dnf; then
        dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm || {
            log_error "Failed to install Percona repository"
            return 1
        }
    else
        yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm || {
            log_error "Failed to install Percona repository"
            return 1
        }
    fi
    
    # Setup Percona Server 8.0
    percona-release setup ps80 || {
        log_error "Failed to setup Percona Server repository"
        return 1
    }
    
    # Install Percona Server
    if command_exists dnf; then
        dnf install -y percona-server-server || {
            log_error "Failed to install Percona Server"
            return 1
        }
    else
        yum install -y percona-server-server || {
            log_error "Failed to install Percona Server"
            return 1
        }
    fi
    
    log_info "Percona Server installed successfully"
    return 0
}

setup_mysql_service() {
    log_info "Setting up MySQL service..."
    
    # Start MySQL service
    systemctl start mysql || systemctl start mysqld || {
        log_error "Failed to start MySQL service"
        return 1
    }
    
    # Enable MySQL service
    systemctl enable mysql || systemctl enable mysqld || {
        log_warning "Failed to enable MySQL service"
    }
    
    # Check service status
    if systemctl is-active --quiet mysql || systemctl is-active --quiet mysqld; then
        log_info "MySQL service is running"
    else
        log_error "MySQL service is not running"
        return 1
    fi
    
    return 0
}

create_sysbench_database() {
    log_info "Creating Sysbench database..."
    
    # Try to create database with default password
    mysql -u root -pintel123 -e "CREATE DATABASE IF NOT EXISTS sysbench;" 2>/dev/null || {
        log_warning "Failed to create database with default password"
        log_info "Please create the database manually:"
        log_info "mysql -u root -p"
        log_info "CREATE DATABASE sysbench;"
        return 1
    }
    
    log_info "Sysbench database created successfully"
    return 0
}

verify_installation() {
    log_info "Verifying Sysbench installation..."
    
    # Check if sysbench command exists
    if ! command_exists sysbench; then
        log_error "Sysbench command not found"
        return 1
    fi
    
    # Check sysbench version
    local version_output=$(sysbench --version 2>/dev/null)
    if [[ -z "$version_output" ]]; then
        log_error "Failed to get Sysbench version"
        return 1
    fi
    
    log_info "Sysbench version: $version_output"
    
    # Check MySQL service
    if systemctl is-active --quiet mysql || systemctl is-active --quiet mysqld; then
        log_info "MySQL service is running"
    else
        log_error "MySQL service is not running"
        return 1
    fi
    
    # Test MySQL connection
    mysql -u root -pintel123 -e "SHOW DATABASES;" >/dev/null 2>&1 || {
        log_warning "Cannot connect to MySQL with default credentials"
        log_info "Please verify MySQL root password and database setup"
    }
    
    log_info "Sysbench installation verified successfully"
    return 0
}

print_usage() {
    echo -e "
Usage: $0 [OPTIONS]

OPTIONS:
  -h, --help     Show this help message
  --verify-only  Only verify existing installation
  --clean        Clean existing installation before setup
  --skip-mysql   Skip MySQL/Percona Server installation

DESCRIPTION:
  This script installs Sysbench and Percona MySQL Server for database benchmarking:
  - Downloads and compiles Sysbench 1.0.20
  - Installs build dependencies
  - Installs Percona Server for MySQL 8.0.33-25
  - Sets up MySQL service and creates sysbench database
  - Default MySQL root password: intel123

EXAMPLES:
  $0                    # Full setup
  $0 --verify-only      # Only verify installation
  $0 --clean            # Clean and reinstall
  $0 --skip-mysql       # Install only Sysbench

AFTER INSTALLATION:
  Use with main wrapper:
  ./main_wrapper.py --script ./sysbench_workload.sh --cores 8 --workload-name \"Sysbench\" --metric-unit \"TPS\" --run
"
}

main() {
    local verify_only=0
    local clean_install=0
    local skip_mysql=0
    
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
            --skip-mysql)
                skip_mysql=1
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
    
    log_info "Starting Sysbench benchmark setup..."
    
    if [[ $verify_only -eq 1 ]]; then
        verify_installation
        exit $?
    fi
    
    if [[ $clean_install -eq 1 ]]; then
        log_info "Cleaning existing installation..."
        rm -rf sysbench-* sysbench.tar.gz percona-release_*
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
    
    # Download and compile Sysbench
    download_and_compile_sysbench || exit 1
    
    # Install MySQL/Percona Server if not skipped
    if [[ $skip_mysql -eq 0 ]]; then
        case "$os_id" in
            centos|rhel|rocky|almalinux)
                install_percona_server_centos || exit 1
                ;;
            ubuntu|debian)
                install_percona_server_ubuntu || exit 1
                ;;
            *)
                log_warning "MySQL installation not supported for $os_id"
                log_info "Please install MySQL manually"
                ;;
        esac
        
        # Setup MySQL service
        setup_mysql_service || exit 1
        
        # Create sysbench database
        create_sysbench_database
    fi
    
    # Verify installation
    verify_installation || exit 1
    
    log_info "Sysbench benchmark setup completed successfully!"
    log_info ""
    log_info "Next steps:"
    log_info "1. Make sure sysbench_workload.sh is executable: chmod +x sysbench_workload.sh"
    log_info "2. Verify MySQL connection: mysql -u root -pintel123"
    log_info "3. Run with main wrapper: ./main_wrapper.py --script ./sysbench_workload.sh --cores 8 --workload-name \"Sysbench\" --metric-unit \"TPS\" --run"
    log_info "4. Default MySQL credentials: root/intel123"
}

# Run main function
main "$@"
