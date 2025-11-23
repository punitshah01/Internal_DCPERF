#!/bin/bash
# dcperf_setup.sh - DCPerf workloads installation script

# =============================================================================
# DCPERF WORKLOADS SETUP SCRIPT
# =============================================================================
# This script installs and configures DCPerf workloads on CentOS/Ubuntu
# =============================================================================

# ------------------------------ CONFIGURATION -----------------------------------
# Base directory for DCPerf installation
BASE_DIR="/home/ps"

# Artifactory credentials (UPDATE THESE AS NEEDED)
ARTIFACTORY_USER="pshah"
ARTIFACTORY_TOKEN="cmVmdGtuOjAxOjE3OTU0NDE5NTI6T0xGdDI0QzFXWTk2bnU5OEZubVlIZ0NEQ1k5"
ARTIFACTORY_BASE_URL="https://ubit-artifactory-ba.intel.com/artifactory/dcso_pnp_workspace-ba-local"

# File URLs (easy to update)
HHVM_FILE_PATH="DCPerf/Mediawiki/hhvm-3.30-multplatform-binary.tar.xz"
NGINX_FILE_PATH="DCPerf/Mediawiki/nginx-1.22.tar.gz"

# Workload script paths (UPDATE THESE AS NEEDED)
MEDIAWIKI_SCRIPT_PATH="DCPerf/Mediawiki/mediawiki.sh"
FEEDSIM_SCRIPT_PATH="DCPerf/Feedsim/feedsim.sh"
VIDEO_TRANSCODE_SCRIPT_PATH="DCPerf/VideoTranscode/videotranscode.sh"
DJANGO_SCRIPT_PATH="DCPerf/Django/django.sh"
SPARK_SCRIPT_PATH="DCPerf/Spark/spark.sh"
TAO_BENCH_SCRIPT_PATH="DCPerf/TaoBench/taobench.sh"

# ------------------------------ UTILITY FUNCTIONS -----------------------------------
log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_warning() {
    echo "[WARNING] $1"
}

# Function to download files from Artifactory
download_from_artifactory() {
    local file_path="$1"
    local output_dir="${2:-.}"  # Default to current directory
    local filename=$(basename "$file_path")
    
    log_info "Downloading $filename from Artifactory..."
    
    local full_url="${ARTIFACTORY_BASE_URL}/${file_path}"
    local curl_cmd="curl -u${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN} -L -o \"${output_dir}/${filename}\" \"${full_url}\""
    
    if eval "$curl_cmd"; then
        log_info "Successfully downloaded $filename"
        return 0
    else
        log_error "Failed to download $filename"
        return 1
    fi
}

# Function to download and install workload script
install_workload_script() {
    local workload_name="$1"
    local script_path="$2"
    local target_dir="$3"
    local script_filename=$(basename "$script_path")
    
    log_info "Installing $workload_name workload script..."
    
    # Create target directory if it doesn't exist
    mkdir -p "$target_dir" || {
        log_error "Failed to create directory: $target_dir"
        return 1
    }
    
    # Download the workload script
    if download_from_artifactory "$script_path" "$target_dir"; then
        # Make script executable
        chmod +x "$target_dir/$script_filename" || {
            log_warning "Failed to make $script_filename executable"
        }
        log_info "$workload_name script installed successfully at $target_dir/$script_filename"
        return 0
    else
        log_error "Failed to download $workload_name script"
        return 1
    fi
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID}:${VERSION_ID}"
    else
        log_error "Cannot determine the operating system."
        exit 1
    fi
}

# ------------------------------ OS INSTALLATION FUNCTIONS -----------------------------------
install_centos8() {
    log_info "Installing packages for CentOS 8..."
    
    # Install basic packages
    dnf install -y python38 python38-pip git wget curl || {
        log_error "Failed to install basic packages"
        return 1
    }
    
    # Set Python alternatives
    alternatives --set python3 /usr/bin/python3.8 2>/dev/null || true
    
    # Install Python packages
    pip-3.8 install click pyyaml tabulate pandas || {
        log_error "Failed to install Python packages"
        return 1
    }
    
    # Enable repositories
    dnf install -y epel-release || return 1
    dnf install -y 'dnf-command(config-manager)' || return 1
    dnf config-manager --set-enabled PowerTools || return 1

    # Install GCC 11 toolset
    log_info "Installing GCC 11 toolset..."
    dnf install -y gcc-toolset-11 || {
        log_warning "Failed to install GCC 11 toolset"
    }
    
    log_info "CentOS 8 packages installed successfully"
}

install_centos9() {
    log_info "Installing packages for CentOS 9..."
    
    # Install basic packages
    dnf install -y git python3-click python3-pyyaml python3-tabulate python3-pip wget curl || {
        log_error "Failed to install basic packages"
        return 1
    }
    
    # Install pandas
    pip-3.9 install pandas || {
        log_error "Failed to install pandas"
        return 1
    }
    
    # Enable repositories
    dnf install -y epel-release || return 1
    dnf install -y 'dnf-command(config-manager)' || return 1
    dnf config-manager --set-enabled crb || return 1
    
    log_info "CentOS 9 packages installed successfully"
}

install_ubuntu() {
    log_info "Installing packages for Ubuntu 22.04..."
    
    # Update package list
    sudo apt update || {
        log_error "Failed to update package list"
        return 1
    }
    
    # Install packages
    sudo apt install -y python3-pip git wget curl || {
        log_error "Failed to install basic packages"
        return 1
    }
    
    # Install Python packages
    sudo pip3 install click pyyaml tabulate pandas || {
        log_error "Failed to install Python packages"
        return 1
    }
    
    log_info "Ubuntu packages installed successfully"
}

# ------------------------------ SYSTEM CONFIGURATION -----------------------------------
set_ulimit() {
    log_info "Configuring ulimit for nofile..."
    
    local limits_conf="/etc/security/limits.conf"
    local ulimit_setting="root            hard    nofile          10485760\nroot            soft    nofile          10485760"

    if ! grep -q "root.*nofile" "$limits_conf"; then
        echo -e "$ulimit_setting" | sudo tee -a "$limits_conf" > /dev/null
        log_info "Ulimit for nofile configured successfully"
    else
        log_info "Ulimit for nofile already configured"
    fi
}

disable_selinux() {
    log_info "Disabling SELinux..."
    
    if [ -f /etc/selinux/config ]; then
        sudo sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
        log_info "SELinux disabled. Reboot required for changes to take effect."
    else
        log_warning "SELinux config file not found"
    fi
}

update_grub_config() {
    log_info "Updating GRUB configuration..."
    
    if [ -f /etc/default/grub ]; then
        if ! grep -q "iommu=pt" /etc/default/grub; then
            log_info "Adding iommu=pt to GRUB configuration..."
            sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&intel_iommu=on,sm_on iommu=pt /' /etc/default/grub
            
            # Update GRUB
            if command_exists grub2-mkconfig; then
                sudo grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
                sudo grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg 2>/dev/null || true
            elif command_exists update-grub; then
                sudo update-grub 2>/dev/null || true
            fi
            
            log_info "GRUB configuration updated"
        else
            log_info "GRUB configuration already includes iommu=pt"
        fi
    else
        log_warning "GRUB configuration file not found"
    fi
}

# ------------------------------ DCPERF REPOSITORY -----------------------------------
setup_dcperf_repo() {
    log_info "Setting up DCPerf repository..."
    
    cd "$BASE_DIR" || {
        log_error "Cannot access base directory: $BASE_DIR"
        return 1
    }
    
    # Remove existing DCPerf directory
    if [ -d "DCPerf" ]; then
        log_info "Removing existing DCPerf directory..."
        rm -rf DCPerf
    fi
    
    # Clone repository
    log_info "Cloning DCPerf repository..."
    if git clone https://github.com/facebookresearch/DCPerf.git DCPerf; then
        log_info "DCPerf repository cloned successfully"
        return 0
    else
        log_error "Failed to clone DCPerf repository"
        return 1
    fi
}

# ------------------------------ WORKLOAD INSTALLATIONS -----------------------------------
install_hhvm() {
    log_info "Installing HHVM..."
    
    cd "$BASE_DIR" || return 1
    
    # Remove existing HHVM file
    [ -f "hhvm-3.30-multplatform-binary.tar.xz" ] && rm -f "hhvm-3.30-multplatform-binary.tar.xz"
    
    # Download HHVM from Artifactory
    if ! download_from_artifactory "$HHVM_FILE_PATH" "$BASE_DIR"; then
        log_error "Failed to download HHVM"
        return 1
    fi
    
    # Extract and install HHVM
    log_info "Extracting HHVM..."
    tar -Jxf hhvm-3.30-multplatform-binary.tar.xz || {
        log_error "Failed to extract HHVM"
        return 1
    }
    
    cd hhvm || {
        log_error "HHVM directory not found after extraction"
        return 1
    }
    
    sudo ./pour-hhvm.sh || {
        log_error "Failed to run pour-hhvm.sh"
        return 1
    }
    
    sudo mkdir -p /opt/local/hhvm-3.30/
    sudo cp -r * /opt/local/hhvm-3.30/ || {
        log_error "Failed to copy HHVM files"
        return 1
    }
    
    cd "$BASE_DIR"
    log_info "HHVM installed successfully"
}

configure_hhvm_libraries() {
    log_info "Configuring HHVM libraries..."

    # Check for libgflags
    if ! ldconfig -p | grep -q libgflags.so.2.1; then
        log_warning "libgflags.so.2.1 is missing. Installing gflags-devel..."
        if command_exists dnf; then
            sudo dnf install -y gflags-devel || log_warning "Failed to install gflags-devel"
        elif command_exists apt; then
            sudo apt install -y libgflags-dev || log_warning "Failed to install libgflags-dev"
        fi
    fi

    # Set LD_LIBRARY_PATH for libicudata
    export LD_LIBRARY_PATH="/opt/local/hhvm-3.30/lib:$LD_LIBRARY_PATH"
    
    # Add to bashrc for persistence
    if ! grep -q "/opt/local/hhvm-3.30/lib" ~/.bashrc 2>/dev/null; then
        echo 'export LD_LIBRARY_PATH="/opt/local/hhvm-3.30/lib:$LD_LIBRARY_PATH"' >> ~/.bashrc
    fi
    
    log_info "HHVM libraries configured"
}

install_nginx() {
    log_info "Installing Nginx..."
    
    cd "$BASE_DIR" || return 1
    
    # Remove existing Nginx file
    [ -f "nginx-1.22.tar.gz" ] && rm -f "nginx-1.22.tar.gz"
    
    # Download Nginx from Artifactory
    if ! download_from_artifactory "$NGINX_FILE_PATH" "$BASE_DIR"; then
        log_error "Failed to download Nginx"
        return 1
    fi
    
    # Move and extract Nginx
    sudo mv nginx-1.22.tar.gz /usr/local/ || {
        log_error "Failed to move Nginx archive"
        return 1
    }
    
    cd /usr/local || return 1
    sudo tar -xf nginx-1.22.tar.gz || {
        log_error "Failed to extract Nginx"
        return 1
    }
    
    cd "$BASE_DIR"
    log_info "Nginx installed successfully"
}

install_mediawiki_workload() {
    log_info "Installing MediaWiki workload..."
    
    # Install dependencies
    install_hhvm || return 1
    configure_hhvm_libraries
    install_nginx || return 1
    disable_selinux

    # Install MediaWiki
    if [ -d "$BASE_DIR/DCPerf/packages/mediawiki/" ]; then
        cd "$BASE_DIR/DCPerf/packages/mediawiki/" || return 1
        
        log_info "Cleaning up existing MediaWiki installation..."
        ./cleanup_oss_performance_mediawiki.sh || log_warning "Cleanup script failed"
        
        log_info "Installing MediaWiki..."
        ./install_oss_performance_mediawiki.sh || {
            log_error "MediaWiki installation failed"
            return 1
        }
        
        cd "$BASE_DIR/DCPerf/packages/mediawiki" || return 1
        log_info "MediaWiki workload installed successfully"
    else
        log_error "MediaWiki package directory not found"
        return 1
    fi
    
    # Install MediaWiki workload script
    local mediawiki_script_dir="$BASE_DIR/DCPerf/packages/mediawiki"
    install_workload_script "MediaWiki" "$MEDIAWIKI_SCRIPT_PATH" "$mediawiki_script_dir" || {
        log_warning "Failed to install MediaWiki workload script"
    }
}

install_feedsim_workload() {
    log_info "Installing Feedsim workload..."
    
    if [ -d "$BASE_DIR/DCPerf/packages/feedsim/" ]; then
        cd "$BASE_DIR/DCPerf/packages/feedsim/" || return 1
        
        log_info "Cleaning up existing Feedsim installation..."
        ./cleanup_feedsim.sh || log_warning "Cleanup script failed"
        
        log_info "Installing Feedsim..."
        ./install_feedsim.sh || {
            log_error "Feedsim installation failed"
            return 1
        }
        
        log_info "Feedsim workload installed successfully"
    else
        log_error "Feedsim package directory not found"
        return 1
    fi
    
    # Install Feedsim workload script to benchmarks directory
    local feedsim_script_dir="$BASE_DIR/DCPerf/benchmarks/feedsim"
    install_workload_script "Feedsim" "$FEEDSIM_SCRIPT_PATH" "$feedsim_script_dir" || {
        log_warning "Failed to install Feedsim workload script"
    }
}

install_django_workload() {
    log_info "Installing Django workload..."
    
    if [ -d "$BASE_DIR/DCPerf/packages/django_workload/" ]; then
        cd "$BASE_DIR/DCPerf/packages/django_workload/" || return 1
        
        log_info "Cleaning up existing Django installation..."
        ./cleanup_django_workload.sh || log_warning "Cleanup script failed"
        
        log_info "Installing Django..."
        ./install_django_workload.sh || {
            log_error "Django installation failed"
            return 1
        }
        
        cd "$BASE_DIR/DCPerf" || return 1

        # Configure Java version
        log_info "Configuring Java version to 1.8..."
        local java_path="/usr/lib/jvm/java-1.8.0-openjdk*/jre/bin"
        if ls $java_path >/dev/null 2>&1; then
            export PATH="$(ls -d $java_path | head -1):${PATH}"
            java -version 2>&1 | head -1
        else
            log_warning "Java 1.8 not found in expected location"
        fi
        
        log_info "Django workload installed successfully"
    else
        log_error "Django package directory not found"
        return 1
    fi
    
    # Install Django workload script
    local django_script_dir="$BASE_DIR/DCPerf/packages/django_workload"
    install_workload_script "Django" "$DJANGO_SCRIPT_PATH" "$django_script_dir" || {
        log_warning "Failed to install Django workload script"
    }
}

install_spark_workload() {
    log_info "Installing Spark workload..."
    
    update_grub_config

    # Install git-lfs
    if command_exists dnf; then
        sudo dnf install -y git-lfs || log_warning "Failed to install git-lfs"
    elif command_exists apt; then
        sudo apt install -y git-lfs || log_warning "Failed to install git-lfs"
    fi

    # Download dataset
    cd "$BASE_DIR" || return 1
    
    log_info "Downloading Spark dataset..."
    [ -d "DCPerf-datasets" ] && rm -rf "DCPerf-datasets"
    
    if git clone https://github.com/facebookresearch/DCPerf-datasets; then
        [ -d "bpc_t93586_s2_synthetic" ] && rm -rf "bpc_t93586_s2_synthetic"
        mv DCPerf-datasets/bpc_t93586_s2_synthetic ./bpc_t93586_s2_synthetic
        rm -rf "DCPerf-datasets"
        log_info "Dataset downloaded successfully"
    else
        log_warning "Failed to download dataset"
    fi

    # Install Spark workload
    if [ -d "$BASE_DIR/DCPerf/packages/spark_standalone/" ]; then
        cd "$BASE_DIR/DCPerf/packages/spark_standalone/" || return 1
        
        log_info "Cleaning up existing Spark installation..."
        ./cleanup_spark_standalone.sh || log_warning "Cleanup script failed"
        
        log_info "Installing Spark..."
        ./install_spark_standalone.sh || {
            log_error "Spark installation failed"
            return 1
        }
        
        cd "$BASE_DIR/DCPerf" || return 1
        log_info "Spark workload installed successfully"
    else
        log_error "Spark package directory not found"
        return 1
    fi
    
    # Install Spark workload script
    local spark_script_dir="$BASE_DIR/DCPerf/packages/spark_standalone"
    install_workload_script "Spark" "$SPARK_SCRIPT_PATH" "$spark_script_dir" || {
        log_warning "Failed to install Spark workload script"
    }
}

install_tao_bench_workload() {
    log_info "Installing Tao Bench workload..."
    
    update_grub_config

    # Install gflags-devel
    log_info "Installing gflags-devel-2.2.2..."
    if command_exists dnf; then
        sudo dnf install -y gflags-devel-2.2.2 || log_warning "Failed to install gflags-devel-2.2.2"
    elif command_exists apt; then
        sudo apt install -y libgflags-dev || log_warning "Failed to install libgflags-dev"
    fi

    if [ -d "$BASE_DIR/DCPerf/packages/tao_bench/" ]; then
        cd "$BASE_DIR/DCPerf/packages/tao_bench/" || return 1
        
        log_info "Cleaning up existing Tao Bench installation..."
        ./cleanup_tao_bench.sh || log_warning "Cleanup script failed"
        
        log_info "Installing Tao Bench..."
        ./install_tao_bench.sh || {
            log_error "Tao Bench installation failed"
            return 1
        }
        
        cd "$BASE_DIR/DCPerf" || return 1
        log_info "Tao Bench workload installed successfully"
    else
        log_error "Tao Bench package directory not found"
        return 1
    fi
    
    # Install Tao Bench workload script
    local tao_bench_script_dir="$BASE_DIR/DCPerf/packages/tao_bench"
    install_workload_script "Tao Bench" "$TAO_BENCH_SCRIPT_PATH" "$tao_bench_script_dir" || {
        log_warning "Failed to install Tao Bench workload script"
    }
}

install_video_transcode_workload() {
    log_info "Installing Video Transcode workload..."
    
    if [ -d "$BASE_DIR/DCPerf/packages/video_transcode_bench/" ]; then
        cd "$BASE_DIR/DCPerf/packages/video_transcode_bench/" || return 1
        
        log_info "Cleaning up existing Video Transcode installation..."
        ./cleanup_video_transcode_bench.sh || log_warning "Cleanup script failed"
        
        log_info "Installing Video Transcode..."
        ./install_video_transcode_bench.sh || {
            log_error "Video Transcode installation failed"
            return 1
        }
        
        cd "$BASE_DIR/DCPerf" || return 1
        log_info "Video Transcode workload installed successfully"
    else
        log_error "Video Transcode package directory not found"
        return 1
    fi
    
    # Install Video Transcode workload script
    local video_transcode_script_dir="$BASE_DIR/DCPerf/packages/video_transcode_bench"
    install_workload_script "Video Transcode" "$VIDEO_TRANSCODE_SCRIPT_PATH" "$video_transcode_script_dir" || {
        log_warning "Failed to install Video Transcode workload script"
    }
}

# ------------------------------ MAIN EXECUTION -----------------------------------
print_usage() {
    echo -e "
Usage: $0 [workload1] [workload2] ...

Available workloads:
  mediawiki        - MediaWiki workload
  feedsim          - Feedsim workload  
  django           - Django workload
  spark            - Spark workload
  tao_bench        - Tao Bench workload
  video_transcode  - Video Transcode workload

If no workloads are specified, all workloads will be installed.

Examples:
  $0                           # Install all workloads
  $0 mediawiki feedsim         # Install only MediaWiki and Feedsim
  $0 video_transcode           # Install only Video Transcode

Workload scripts will be installed at:
  MediaWiki:       $BASE_DIR/DCPerf/packages/mediawiki/mediawiki.sh
  Feedsim:         $BASE_DIR/DCPerf/packages/feedsim/feedsim.sh
  Django:          $BASE_DIR/DCPerf/packages/django_workload/django.sh
  Spark:           $BASE_DIR/DCPerf/packages/spark_standalone/spark.sh
  Tao Bench:       $BASE_DIR/DCPerf/packages/tao_bench/taobench.sh
  Video Transcode: $BASE_DIR/DCPerf/packages/video_transcode_bench/videotranscode.sh
"
}

main() {
    log_info "Starting DCPerf workloads installation..."
    
    # Create base directory
    mkdir -p "$BASE_DIR" || {
        log_error "Cannot create base directory: $BASE_DIR"
        exit 1
    }

    # Detect OS and install packages
    local os_info=$(detect_os)
    local os_id=$(echo "$os_info" | cut -d: -f1)
    local os_version=$(echo "$os_info" | cut -d: -f2)
    
    log_info "Detected OS: $os_id $os_version"
    
    case "$os_id" in
        centos)
            if [[ "$os_version" == "8" ]]; then
                install_centos8 || exit 1
            elif [[ "$os_version" == "9" ]]; then
                install_centos9 || exit 1
            else
                log_error "Unsupported CentOS version: $os_version"
                exit 1
            fi
            ;;
        ubuntu)
            if [[ "$os_version" == "22.04" ]]; then
                install_ubuntu || exit 1
            else
                log_error "Unsupported Ubuntu version: $os_version"
                exit 1
            fi
            ;;
        *)
            log_error "Unsupported operating system: $os_id"
            exit 1
            ;;
    esac

    # Configure system
    set_ulimit

    # Setup DCPerf repository
    setup_dcperf_repo || exit 1

    # Parse workload arguments
    local workloads=("$@")
    if [ ${#workloads[@]} -eq 0 ]; then
        workloads=("mediawiki" "feedsim" "django" "spark" "tao_bench" "video_transcode")
        log_info "No workloads specified, installing all workloads"
    fi

    # Install specified workloads
    local failed_workloads=()
    local installed_scripts=()
    
    for workload in "${workloads[@]}"; do
        log_info "Installing workload: $workload"
        case $workload in
            mediawiki)
                if install_mediawiki_workload; then
                    installed_scripts+=("$BASE_DIR/DCPerf/packages/mediawiki/mediawiki.sh")
                else
                    failed_workloads+=("$workload")
                fi
                ;;
            feedsim)
                if install_feedsim_workload; then
                    installed_scripts+=("$BASE_DIR/DCPerf/packages/feedsim/feedsim.sh")
                else
                    failed_workloads+=("$workload")
                fi
                ;;
            django)
                if install_django_workload; then
                    installed_scripts+=("$BASE_DIR/DCPerf/packages/django_workload/django.sh")
                else
                    failed_workloads+=("$workload")
                fi
                ;;
            spark)
                if install_spark_workload; then
                    installed_scripts+=("$BASE_DIR/DCPerf/packages/spark_standalone/spark.sh")
                else
                    failed_workloads+=("$workload")
                fi
                ;;
            tao_bench)
                if install_tao_bench_workload; then
                    installed_scripts+=("$BASE_DIR/DCPerf/packages/tao_bench/taobench.sh")
                else
                    failed_workloads+=("$workload")
                fi
                ;;
            video_transcode)
                if install_video_transcode_workload; then
                    installed_scripts+=("$BASE_DIR/DCPerf/packages/video_transcode_bench/videotranscode.sh")
                else
                    failed_workloads+=("$workload")
                fi
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown workload: $workload"
                failed_workloads+=("$workload")
                ;;
        esac
    done

    # Summary
    log_info "Installation completed!"
    
    if [ ${#installed_scripts[@]} -gt 0 ]; then
        log_info "Installed workload scripts:"
        for script in "${installed_scripts[@]}"; do
            log_info "  - $script"
        done
    fi
    
    if [ ${#failed_workloads[@]} -gt 0 ]; then
        log_warning "Failed workloads: ${failed_workloads[*]}"
    fi
    
    log_info "Please reboot your system if SELinux was disabled or GRUB configuration was changed."
    log_info "Use the installed workload scripts with the main wrapper for core scaling tests."
}

# Check for help argument
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    print_usage
    exit 0
fi

# Run main function
main "$@"
