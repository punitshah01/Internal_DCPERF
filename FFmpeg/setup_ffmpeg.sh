#!/bin/bash
# setup_ffmpeg.sh - FFmpeg benchmark setup script

# =============================================================================
# FFMPEG SETUP SCRIPT
# =============================================================================
# This script downloads, compiles and configures FFmpeg for video encoding benchmark
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
    log_info "Installing FFmpeg dependencies for CentOS/RHEL..."
    
    if command_exists dnf; then
        dnf groupinstall -y "Development Tools" || {
            log_error "Failed to install Development Tools with dnf"
            return 1
        }
        dnf install -y autoconf automake cmake git libass-devel freetype-devel \
            gnutls-devel lame-devel SDL2-devel libtool libva-devel libvdpau-devel \
            libvorbis-devel libxcb-devel meson ninja-build pkgconfig texinfo \
            wget yasm zlib-devel nasm bc || {
            log_error "Failed to install dependencies with dnf"
            return 1
        }
    elif command_exists yum; then
        yum groupinstall -y "Development Tools" || {
            log_error "Failed to install Development Tools with yum"
            return 1
        }
        yum install -y autoconf automake cmake git libass-devel freetype-devel \
            gnutls-devel lame-devel SDL2-devel libtool libva-devel libvdpau-devel \
            libvorbis-devel libxcb-devel pkgconfig texinfo wget yasm zlib-devel \
            nasm bc || {
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
    log_info "Installing FFmpeg dependencies for Ubuntu/Debian..."
    
    apt update || {
        log_error "Failed to update package list"
        return 1
    }
    
    apt install -y autoconf automake build-essential cmake git-core libass-dev \
        libfreetype6-dev libgnutls28-dev libmp3lame-dev libsdl2-dev libtool \
        libva-dev libvdpau-dev libvorbis-dev libxcb1-dev libxcb-shm0-dev \
        libxcb-xfixes0-dev meson ninja-build pkg-config texinfo wget yasm \
        zlib1g-dev nasm bc || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    log_info "Ubuntu/Debian dependencies installed successfully"
}

install_dependencies_suse() {
    log_info "Installing FFmpeg dependencies for SUSE..."
    
    zypper install -y -t pattern devel_basis || {
        log_error "Failed to install development pattern"
        return 1
    }
    
    zypper install -y autoconf automake cmake git libass-devel freetype2-devel \
        libgnutls-devel lame-devel SDL2-devel libtool libva-devel libvdpau-devel \
        libvorbis-devel libxcb-devel meson ninja pkgconfig texinfo wget yasm \
        zlib-devel nasm bc || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    log_info "SUSE dependencies installed successfully"
}

install_yasm() {
    log_info "Installing YASM assembler..."
    
    if command_exists yasm; then
        log_info "YASM already installed"
        return 0
    fi
    
    local yasm_version="1.3.0"
    local yasm_url="http://www.tortall.net/projects/yasm/releases/yasm-${yasm_version}.tar.gz"
    
    wget "$yasm_url" || {
        log_error "Failed to download YASM"
        return 1
    }
    
    tar zxvf "yasm-${yasm_version}.tar.gz" || {
        log_error "Failed to extract YASM"
        return 1
    }
    
    cd "yasm-${yasm_version}" || {
        log_error "Failed to enter YASM directory"
        return 1
    }
    
    ./configure && make && make install || {
        log_error "Failed to compile and install YASM"
        cd ..
        return 1
    }
    
    cd ..
    rm -rf "yasm-${yasm_version}" "yasm-${yasm_version}.tar.gz"
    log_info "YASM installed successfully"
}

install_nasm() {
    log_info "Installing NASM assembler..."
    
    if command_exists nasm; then
        log_info "NASM already installed"
        return 0
    fi
    
    local nasm_version="2.15.05"
    local nasm_url="https://www.nasm.us/pub/nasm/releasebuilds/${nasm_version}/nasm-${nasm_version}.tar.gz"
    
    wget "$nasm_url" || {
        log_error "Failed to download NASM"
        return 1
    }
    
    tar xzf "nasm-${nasm_version}.tar.gz" || {
        log_error "Failed to extract NASM"
        return 1
    }
    
    cd "nasm-${nasm_version}" || {
        log_error "Failed to enter NASM directory"
        return 1
    }
    
    ./configure --prefix=/usr/local && make && make install || {
        log_error "Failed to compile and install NASM"
        cd ..
        return 1
    }
    
    cd ..
    rm -rf "nasm-${nasm_version}" "nasm-${nasm_version}.tar.gz"
    log_info "NASM installed successfully"
}

install_x264() {
    log_info "Installing libx264..."
    
    if pkg-config --exists x264; then
        log_info "libx264 already installed"
        return 0
    fi
    
    git clone --depth 1 https://code.videolan.org/videolan/x264.git || {
        log_error "Failed to clone x264 repository"
        return 1
    }
    
    cd x264 || {
        log_error "Failed to enter x264 directory"
        return 1
    }
    
    ./configure --enable-static --enable-shared && make && make install || {
        log_error "Failed to compile and install x264"
        cd ..
        return 1
    }
    
    cd ..
    rm -rf x264
    log_info "libx264 installed successfully"
}

install_x265() {
    log_info "Installing libx265..."
    
    if pkg-config --exists x265; then
        log_info "libx265 already installed"
        return 0
    fi
    
    git clone --depth 1 https://bitbucket.org/multicoreware/x265_git.git || {
        log_error "Failed to clone x265 repository"
        return 1
    }
    
    cd x265_git/build/linux || {
        log_error "Failed to enter x265 build directory"
        return 1
    }
    
    cmake ../../source && make && make install || {
        log_error "Failed to compile and install x265"
        cd ../../..
        return 1
    }
    
    cd ../../..
    rm -rf x265_git
    log_info "libx265 installed successfully"
}

download_and_compile_ffmpeg() {
    log_info "Downloading and compiling FFmpeg..."
    
    local ffmpeg_version="6.0"
    local ffmpeg_url="https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz"
    
    # Clean up any existing installation
    if [ -d "ffmpeg-${ffmpeg_version}" ]; then
        log_info "Removing existing FFmpeg directory..."
        rm -rf "ffmpeg-${ffmpeg_version}"
    fi
    
    # Download source
    log_info "Downloading FFmpeg source..."
    wget "$ffmpeg_url" || {
        log_error "Failed to download FFmpeg source"
        return 1
    }
    
    # Extract
    log_info "Extracting FFmpeg source..."
    tar -xf "ffmpeg-${ffmpeg_version}.tar.xz" || {
        log_error "Failed to extract FFmpeg source"
        return 1
    }
    
    # Configure and compile
    log_info "Configuring and compiling FFmpeg..."
    cd "ffmpeg-${ffmpeg_version}" || {
        log_error "Failed to enter FFmpeg directory"
        return 1
    }
    
    # Update library path
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
    export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
    
    ./configure --enable-gpl --enable-libx264 --enable-libx265 --enable-shared || {
        log_error "Failed to configure FFmpeg"
        return 1
    }
    
    local cpu_count=$(nproc 2>/dev/null || echo "4")
    make -j "$cpu_count" || {
        log_error "Failed to compile FFmpeg"
        return 1
    }
    
    make install || {
        log_error "Failed to install FFmpeg"
        return 1
    }
    
    # Update library cache
    ldconfig
    
    cd ..
    log_info "FFmpeg compiled and installed successfully"
    return 0
}

verify_installation() {
    log_info "Verifying FFmpeg installation..."
    
    # Check if ffmpeg command exists
    if ! command_exists ffmpeg; then
        log_error "FFmpeg command not found in PATH"
        return 1
    fi
    
    # Check FFmpeg version
    local version_output=$(ffmpeg -version 2>/dev/null | head -1)
    if [[ -z "$version_output" ]]; then
        log_error "Failed to get FFmpeg version"
        return 1
    fi
    
    log_info "FFmpeg version: $version_output"
    
    # Check for required codecs
    if ! ffmpeg -codecs 2>/dev/null | grep -q "libx264"; then
        log_error "libx264 codec not available in FFmpeg"
        return 1
    fi
    
    if ! ffmpeg -codecs 2>/dev/null | grep -q "libx265"; then
        log_error "libx265 codec not available in FFmpeg"
        return 1
    fi
    
    log_info "FFmpeg installation verified successfully"
    return 0
}

download_sample_video() {
    local video_name="lg_4k_oled_paris_hevc_1920x1080_420_8_23.98_25.9.mkv"
    local video_path="$video_name"
    
    if [ -f "$video_path" ]; then
        log_info "Video file already exists: $video_name"
        return 0
    fi
    
    log_info "Downloading test video file: $video_name"
    
    # Primary source: Intel Artifactory
    local artifactory_url="https://ubit-artifactory-ba.intel.com/artifactory/dcso_pnp_workspace-ba-local/WLS/FFmpeg/lg_4k_oled_paris_hevc_1920x1080_420_8_23.98_25.9.mkv"
    
    wget "$artifactory_url" -O "$video_path" || {
        log_warning "Failed to download from Intel Artifactory. Trying fallback sources..."
        
        # Fallback: Public sample video
        log_info "Downloading fallback sample video..."
        wget "https://sample-videos.com/zip/10/mp4/SampleVideo_1280x720_5mb.mp4" -O "sample_video.mp4" || {
            log_warning "Failed to download fallback video."
            log_info "Will create test pattern video during benchmark execution"
            return 1
        }
        
        log_info "Fallback video downloaded as sample_video.mp4"
        return 0
    }
    
    if [ -f "$video_path" ]; then
        local file_size=$(du -h "$video_path" | cut -f1)
        log_info "Video file downloaded successfully: $video_name ($file_size)"
        return 0
    else
        log_error "Failed to download video file"
        return 1
    fi
}
print_usage() {
    echo -e "
Usage: $0 [OPTIONS]

OPTIONS:
  -h, --help     Show this help message
  --verify-only  Only verify existing installation
  --clean        Clean existing installation before setup
  --no-sample    Skip downloading sample video

DESCRIPTION:
  This script downloads and compiles FFmpeg with x264/x265 support:
  - Installs build dependencies
  - Downloads and compiles YASM/NASM assemblers
  - Downloads and compiles libx264/libx265 codecs
  - Downloads and compiles FFmpeg 6.0
  - Downloads sample video for testing

EXAMPLES:
  $0                    # Full setup
  $0 --verify-only      # Only verify installation
  $0 --clean            # Clean and reinstall
  $0 --no-sample        # Setup without sample video

AFTER INSTALLATION:
  Use with main wrapper:
  ./main_wrapper.py --script ./ffmpeg_workload.sh --cores 8 --workload-name \"FFmpeg\" --metric-unit \"fps\" --run
"
}

main() {
    local verify_only=0
    local clean_install=0
    local no_sample=0
    
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
            --no-sample)
                no_sample=1
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
    
    log_info "Starting FFmpeg benchmark setup..."
    
    if [[ $verify_only -eq 1 ]]; then
        verify_installation
        exit $?
    fi
    
    if [[ $clean_install -eq 1 ]]; then
        log_info "Cleaning existing installation..."
        rm -rf ffmpeg-* x264 x265_git yasm-* nasm-*
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
    
    # Install assemblers and codecs
    install_yasm || exit 1
    install_nasm || exit 1
    install_x264 || exit 1
    install_x265 || exit 1
    
    # Download and compile FFmpeg
    download_and_compile_ffmpeg || exit 1
    
    # Verify installation
    verify_installation || exit 1
    
    # Download sample video
    if [[ $no_sample -eq 0 ]]; then
        download_sample_video
    fi
    
    log_info "FFmpeg benchmark setup completed successfully!"
    log_info ""
    log_info "Next steps:"
    log_info "1. Make sure ffmpeg_workload.sh is executable: chmod +x ffmpeg_workload.sh"
    log_info "2. Run with main wrapper: ./main_wrapper.py --script ./ffmpeg_workload.sh --cores 8 --workload-name \"FFmpeg\" --metric-unit \"fps\" --run"
    log_info "3. FFmpeg is installed at: $(which ffmpeg)"
}

# Run main function
main "$@"
