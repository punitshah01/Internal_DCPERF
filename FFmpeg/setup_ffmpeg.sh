#!/bin/bash
# setup_ffmpeg.sh - FFmpeg benchmark setup script with enhanced download and skip logic

# =============================================================================
# FFMPEG SETUP SCRIPT WITH SMART INSTALLATION DETECTION
# =============================================================================
# This script downloads, compiles and configures FFmpeg for video encoding benchmark
# Enhanced with hardcoded Intel credentials and intelligent skip logic
# =============================================================================

# Intel Artifactory credentials (hardcoded)
INTEL_USERNAME="pshah"
INTEL_TOKEN="cmVmdGtuOjAxOjE3OTYxODkyNDA6S2ptczFxVmpkM0ZJZ"

log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_warning() {
    echo "[WARNING] $1"
}

log_success() {
    echo "[SUCCESS] $1"
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

# Check if FFmpeg is already properly installed
check_ffmpeg_installation() {
    log_info "Checking existing FFmpeg installation..."
    
    # Check if ffmpeg command exists
    if ! command_exists ffmpeg; then
        log_info "FFmpeg not found in PATH"
        return 1
    fi
    
    # Check FFmpeg version and capabilities
    local version_output=$(ffmpeg -version 2>/dev/null | head -1)
    if [[ -z "$version_output" ]]; then
        log_info "FFmpeg found but not working properly"
        return 1
    fi
    
    log_info "Found FFmpeg: $version_output"
    
    # Check for required codecs
    local codecs_output=$(ffmpeg -codecs 2>/dev/null)
    local has_x264=false
    local has_x265=false
    
    if echo "$codecs_output" | grep -q "libx264"; then
        has_x264=true
        log_info "✓ libx264 codec available"
    else
        log_info "✗ libx264 codec not available"
    fi
    
    if echo "$codecs_output" | grep -q "libx265"; then
        has_x265=true
        log_info "✓ libx265 codec available"
    else
        log_info "✗ libx265 codec not available"
    fi
    
    # Test basic functionality
    if ffmpeg -f lavfi -i testsrc=duration=1:size=320x240:rate=1 -f null - >/dev/null 2>&1; then
        log_info "✓ FFmpeg basic functionality test passed"
    else
        log_info "✗ FFmpeg basic functionality test failed"
        return 1
    fi
    
    # Consider installation good if we have at least x264
    if [[ "$has_x264" == true ]]; then
        log_success "FFmpeg installation is adequate (has x264 support)"
        return 0
    else
        log_info "FFmpeg installation lacks required codecs"
        return 1
    fi
}

# Check if development tools are already installed
check_development_tools() {
    log_info "Checking development tools..."
    
    local essential_tools=("gcc" "make" "git" "wget" "curl")
    local missing_tools=()
    
    for tool in "${essential_tools[@]}"; do
        if ! command_exists "$tool"; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -eq 0 ]; then
        log_success "All essential development tools are available"
        return 0
    else
        log_info "Missing development tools: ${missing_tools[*]}"
        return 1
    fi
}

# Check if specific codec libraries are installed
check_codec_libraries() {
    log_info "Checking codec libraries..."
    
    local x264_installed=false
    local x265_installed=false
    
    # Check x264
    if pkg-config --exists x264 2>/dev/null; then
        local x264_version=$(pkg-config --modversion x264 2>/dev/null)
        log_info "✓ libx264 found: $x264_version"
        x264_installed=true
    elif [ -f "/usr/local/lib/libx264.so" ] || [ -f "/usr/lib/libx264.so" ] || [ -f "/usr/lib64/libx264.so" ]; then
        log_info "✓ libx264 library files found"
        x264_installed=true
    else
        log_info "✗ libx264 not found"
    fi
    
    # Check x265
    if pkg-config --exists x265 2>/dev/null; then
        local x265_version=$(pkg-config --modversion x265 2>/dev/null)
        log_info "✓ libx265 found: $x265_version"
        x265_installed=true
    elif [ -f "/usr/local/lib/libx265.so" ] || [ -f "/usr/lib/libx265.so" ] || [ -f "/usr/lib64/libx265.so" ]; then
        log_info "✓ libx265 library files found"
        x265_installed=true
    else
        log_info "✗ libx265 not found"
    fi
    
    # Return success if at least x264 is available
    if [[ "$x264_installed" == true ]]; then
        log_success "Codec libraries check passed (x264 available)"
        return 0
    else
        log_info "Codec libraries need installation"
        return 1
    fi
}

fix_centos_repos() {
    log_info "Attempting to fix CentOS repository conflicts..."
    
    # Try to resolve glibc conflicts
    log_info "Checking for glibc conflicts..."
    
    # First, try to update the system
    dnf update -y --allowerasing glibc glibc-devel 2>/dev/null || {
        log_warning "Failed to update glibc with --allowerasing, trying alternative approach..."
        
        # Try to skip broken packages
        dnf update -y --skip-broken 2>/dev/null || {
            log_warning "Standard update failed, continuing with existing packages..."
        }
    }
    
    # Clean DNF cache
    dnf clean all
    
    log_info "Repository fix attempt completed"
}

install_dependencies_centos() {
    log_info "Installing FFmpeg dependencies for CentOS/RHEL..."
    
    # Check if already installed
    if check_development_tools; then
        log_success "Development tools already available, skipping installation"
        return 0
    fi
    
    # First attempt to fix repository issues
    fix_centos_repos
    
    if command_exists dnf; then
        # Try with --allowerasing first
        log_info "Attempting to install Development Tools with conflict resolution..."
        if ! dnf groupinstall -y "Development Tools" --allowerasing 2>/dev/null; then
            log_warning "Failed with --allowerasing, trying --skip-broken..."
            if ! dnf groupinstall -y "Development Tools" --skip-broken 2>/dev/null; then
                log_warning "Group install failed, trying individual packages..."
                
                # Install essential development packages individually
                local essential_packages=(
                    "gcc" "gcc-c++" "make" "autoconf" "automake" "libtool"
                    "pkgconfig" "git" "wget" "which" "tar" "gzip" "curl"
                )
                
                for package in "${essential_packages[@]}"; do
                    if ! command_exists "${package}"; then
                        log_info "Installing $package..."
                        dnf install -y "$package" --skip-broken 2>/dev/null || {
                            log_warning "Failed to install $package, continuing..."
                        }
                    else
                        log_info "✓ $package already installed"
                    fi
                done
            fi
        fi
        
        # Install FFmpeg-specific dependencies
        log_info "Installing FFmpeg-specific dependencies..."
        local ffmpeg_deps=(
            "cmake" "libass-devel" "freetype-devel" "gnutls-devel"
            "lame-devel" "SDL2-devel" "libva-devel" "libvdpau-devel"
            "libvorbis-devel" "libxcb-devel" "meson" "ninja-build"
            "texinfo" "yasm" "zlib-devel" "nasm" "bc"
        )
        
        for dep in "${ffmpeg_deps[@]}"; do
            log_info "Installing $dep..."
            dnf install -y "$dep" --skip-broken 2>/dev/null || {
                log_warning "Failed to install $dep, will compile from source if needed"
            }
        done
        
    elif command_exists yum; then
        # Fallback to yum
        log_info "Using yum package manager..."
        yum groupinstall -y "Development Tools" || {
            log_warning "Group install failed with yum, installing individual packages..."
            yum install -y gcc gcc-c++ make autoconf automake libtool pkgconfig git wget curl
        }
        
        yum install -y cmake libass-devel freetype-devel gnutls-devel \
            lame-devel SDL2-devel libva-devel libvdpau-devel \
            libvorbis-devel libxcb-devel texinfo yasm zlib-devel nasm bc || {
            log_warning "Some yum packages failed to install"
        }
    else
        log_error "Neither dnf nor yum found"
        return 1
    fi
    
    # Verify essential tools are available
    if check_development_tools; then
        log_success "CentOS/RHEL dependencies installation completed"
        return 0
    else
        log_error "Some essential tools are still missing after installation"
        return 1
    fi
}

install_dependencies_ubuntu() {
    log_info "Installing FFmpeg dependencies for Ubuntu/Debian..."
    
    # Check if already installed
    if check_development_tools; then
        log_success "Development tools already available, skipping installation"
        return 0
    fi
    
    apt update || {
        log_error "Failed to update package list"
        return 1
    }
    
    apt install -y autoconf automake build-essential cmake git-core libass-dev \
        libfreetype6-dev libgnutls28-dev libmp3lame-dev libsdl2-dev libtool \
        libva-dev libvdpau-dev libvorbis-dev libxcb1-dev libxcb-shm0-dev \
        libxcb-xfixes0-dev meson ninja-build pkg-config texinfo wget yasm \
        zlib1g-dev nasm bc curl || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    log_success "Ubuntu/Debian dependencies installed successfully"
}

install_dependencies_suse() {
    log_info "Installing FFmpeg dependencies for SUSE..."
    
    # Check if already installed
    if check_development_tools; then
        log_success "Development tools already available, skipping installation"
        return 0
    fi
    
    zypper install -y -t pattern devel_basis || {
        log_error "Failed to install development pattern"
        return 1
    }
    
    zypper install -y autoconf automake cmake git libass-devel freetype2-devel \
        libgnutls-devel lame-devel SDL2-devel libtool libva-devel libvdpau-devel \
        libvorbis-devel libxcb-devel meson ninja pkgconfig texinfo wget yasm \
        zlib-devel nasm bc curl || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    log_success "SUSE dependencies installed successfully"
}

install_yasm() {
    log_info "Checking YASM assembler..."
    
    if command_exists yasm; then
        local yasm_version=$(yasm --version 2>/dev/null | head -1)
        log_success "YASM already installed: $yasm_version"
        return 0
    fi
    
    log_info "Installing YASM from source..."
    local yasm_version="1.3.0"
    local yasm_url="http://www.tortall.net/projects/yasm/releases/yasm-${yasm_version}.tar.gz"
    local build_dir="/tmp/yasm_build_$$"
    
    mkdir -p "$build_dir"
    cd "$build_dir" || {
        log_error "Failed to create build directory"
        return 1
    }
    
    log_info "Downloading YASM $yasm_version..."
    wget "$yasm_url" -O "yasm-${yasm_version}.tar.gz" || {
        log_error "Failed to download YASM"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    tar zxf "yasm-${yasm_version}.tar.gz" || {
        log_error "Failed to extract YASM"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    cd "yasm-${yasm_version}" || {
        log_error "Failed to enter YASM directory"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    log_info "Configuring and compiling YASM..."
    ./configure --prefix=/usr/local && make -j$(nproc) && make install || {
        log_error "Failed to compile and install YASM"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    cd - >/dev/null
    rm -rf "$build_dir"
    
    # Update PATH and library cache
    export PATH="/usr/local/bin:$PATH"
    ldconfig 2>/dev/null || true
    
    log_success "YASM installed successfully"
    return 0
}

install_nasm() {
    log_info "Checking NASM assembler..."
    
    if command_exists nasm; then
        local nasm_version=$(nasm -v 2>/dev/null)
        log_success "NASM already installed: $nasm_version"
        return 0
    fi
    
    log_info "Installing NASM from source..."
    local nasm_version="2.15.05"
    local nasm_url="https://www.nasm.us/pub/nasm/releasebuilds/${nasm_version}/nasm-${nasm_version}.tar.gz"
    local build_dir="/tmp/nasm_build_$$"
    
    mkdir -p "$build_dir"
    cd "$build_dir" || {
        log_error "Failed to create build directory"
        return 1
    }
    
    log_info "Downloading NASM $nasm_version..."
    wget "$nasm_url" -O "nasm-${nasm_version}.tar.gz" || {
        log_error "Failed to download NASM"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    tar xzf "nasm-${nasm_version}.tar.gz" || {
        log_error "Failed to extract NASM"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    cd "nasm-${nasm_version}" || {
        log_error "Failed to enter NASM directory"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    log_info "Configuring and compiling NASM..."
    ./configure --prefix=/usr/local && make -j$(nproc) && make install || {
        log_error "Failed to compile and install NASM"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    cd - >/dev/null
    rm -rf "$build_dir"
    
    # Update PATH and library cache
    export PATH="/usr/local/bin:$PATH"
    ldconfig 2>/dev/null || true
    
    log_success "NASM installed successfully"
    return 0
}

install_x264() {
    log_info "Checking libx264..."
    
    # Check if already installed
    if pkg-config --exists x264 2>/dev/null; then
        local x264_version=$(pkg-config --modversion x264 2>/dev/null)
        log_success "libx264 already installed: $x264_version"
        return 0
    fi
    
    log_info "Installing libx264 from source..."
    local build_dir="/tmp/x264_build_$$"
    mkdir -p "$build_dir"
    cd "$build_dir" || {
        log_error "Failed to create build directory"
        return 1
    }
    
    log_info "Cloning x264 repository..."
    git clone --depth 1 https://code.videolan.org/videolan/x264.git || {
        log_error "Failed to clone x264 repository"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    cd x264 || {
        log_error "Failed to enter x264 directory"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    log_info "Configuring and compiling x264..."
    ./configure --prefix=/usr/local --enable-static --enable-shared --enable-pic && \
    make -j$(nproc) && make install || {
        log_error "Failed to compile and install x264"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    cd - >/dev/null
    rm -rf "$build_dir"
    
    # Update library cache
    ldconfig 2>/dev/null || true
    
    log_success "libx264 installed successfully"
    return 0
}

install_x265() {
    log_info "Checking libx265..."
    
    # Check if already installed
    if pkg-config --exists x265 2>/dev/null; then
        local x265_version=$(pkg-config --modversion x265 2>/dev/null)
        log_success "libx265 already installed: $x265_version"
        return 0
    fi
    
    # Check if cmake is available
    if ! command_exists cmake; then
        log_error "CMake is required for x265 but not found"
        return 1
    fi
    
    log_info "Installing libx265 from source..."
    local build_dir="/tmp/x265_build_$$"
    mkdir -p "$build_dir"
    cd "$build_dir" || {
        log_error "Failed to create build directory"
        return 1
    }
    
    log_info "Cloning x265 repository..."
    git clone --depth 1 https://bitbucket.org/multicoreware/x265_git.git || {
        log_error "Failed to clone x265 repository"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    cd x265_git/build/linux || {
        log_error "Failed to enter x265 build directory"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    log_info "Configuring and compiling x265..."
    cmake -DCMAKE_INSTALL_PREFIX=/usr/local -DENABLE_SHARED=ON ../../source && \
    make -j$(nproc) && make install || {
        log_error "Failed to compile and install x265"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    cd - >/dev/null
    rm -rf "$build_dir"
    
    # Update library cache
    ldconfig 2>/dev/null || true
    
    log_success "libx265 installed successfully"
    return 0
}

download_and_compile_ffmpeg() {
    log_info "Checking FFmpeg installation..."
    
    # Check if FFmpeg is already properly installed
    if check_ffmpeg_installation; then
        log_success "FFmpeg is already properly installed, skipping compilation"
        return 0
    fi
    
    log_info "Downloading and compiling FFmpeg..."
    
    local ffmpeg_version="6.0"
    local ffmpeg_url="https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz"
    local build_dir="/tmp/ffmpeg_build_$$"
    
    mkdir -p "$build_dir"
    cd "$build_dir" || {
        log_error "Failed to create build directory"
        return 1
    }
    
    # Download source
    log_info "Downloading FFmpeg $ffmpeg_version source..."
    wget "$ffmpeg_url" -O "ffmpeg-${ffmpeg_version}.tar.xz" || {
        log_error "Failed to download FFmpeg source"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    # Extract
    log_info "Extracting FFmpeg source..."
    tar -xf "ffmpeg-${ffmpeg_version}.tar.xz" || {
        log_error "Failed to extract FFmpeg source"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    # Configure and compile
    log_info "Configuring and compiling FFmpeg..."
    cd "ffmpeg-${ffmpeg_version}" || {
        log_error "Failed to enter FFmpeg directory"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    # Update library path
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
    export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
    export PATH="/usr/local/bin:$PATH"
    
    # Configure with available codecs
    local configure_options="--prefix=/usr/local --enable-gpl --enable-shared --enable-pic"
    
    # Check for x264
    if pkg-config --exists x264 2>/dev/null; then
        configure_options="$configure_options --enable-libx264"
        log_info "x264 support enabled"
    else
        log_warning "x264 not found, skipping x264 support"
    fi
    
    # Check for x265
    if pkg-config --exists x265 2>/dev/null; then
        configure_options="$configure_options --enable-libx265"
        log_info "x265 support enabled"
    else
        log_warning "x265 not found, skipping x265 support"
    fi
    
    log_info "FFmpeg configure options: $configure_options"
    
    ./configure $configure_options || {
        log_error "Failed to configure FFmpeg"
        log_info "Configuration log:"
        tail -20 ffbuild/config.log 2>/dev/null || echo "No config.log found"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    local cpu_count=$(nproc 2>/dev/null || echo "4")
    log_info "Compiling FFmpeg with $cpu_count parallel jobs..."
    make -j "$cpu_count" || {
        log_error "Failed to compile FFmpeg"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    log_info "Installing FFmpeg..."
    make install || {
        log_error "Failed to install FFmpeg"
        cd - >/dev/null
        rm -rf "$build_dir"
        return 1
    }
    
    cd - >/dev/null
    rm -rf "$build_dir"
    
    # Update library cache and PATH
    ldconfig 2>/dev/null || true
    
    # Add to system PATH if not already there
    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        export PATH="/usr/local/bin:$PATH"
        echo 'export PATH="/usr/local/bin:$PATH"' >> ~/.bashrc
    fi
    
    log_success "FFmpeg compiled and installed successfully"
    return 0
}

verify_installation() {
    log_info "Verifying FFmpeg installation..."
    
    # Update PATH
    export PATH="/usr/local/bin:$PATH"
    
    # Use the existing check function
    if check_ffmpeg_installation; then
        log_success "FFmpeg installation verification passed"
        return 0
    else
        log_error "FFmpeg installation verification failed"
        return 1
    fi
}

# Enhanced video download function with hardcoded Intel credentials
download_sample_video() {
    local video_name="lg_4k_oled_paris_hevc_1920x1080_420_8_23.98_25.9.mkv"
    local video_path="$video_name"
    local artifactory_url="https://ubit-artifactory-ba.intel.com/artifactory/dcso_pnp_workspace-ba-local/WLS/FFmpeg/lg_4k_oled_paris_hevc_1920x1080_420_8_23.98_25.9.mkv"
    
    if [ -f "$video_path" ]; then
        local file_size=$(du -h "$video_path" | cut -f1)
        log_success "Video file already exists: $video_name ($file_size)"
        return 0
    fi
    
    log_info "Downloading test video file: $video_name"
    log_info "Using Intel Artifactory with hardcoded credentials..."
    log_info "This may take several minutes depending on your connection..."
    
    # Method 1: curl with Intel credentials (primary method)
    log_info "Attempting download with Intel credentials..."
    if curl -u"$INTEL_USERNAME:$INTEL_TOKEN" -L -O "$artifactory_url" --connect-timeout 60 --max-time 1200 --retry 3 --retry-delay 10 --progress-bar; then
        if [ -f "$video_path" ] && [ -s "$video_path" ]; then
            local file_size=$(du -h "$video_path" | cut -f1)
            log_success "✓ Download successful with Intel credentials: $video_name ($file_size)"
            return 0
        fi
    fi
    rm -f "$video_path" 2>/dev/null
    
    # Method 2: wget with Intel credentials
    log_info "Trying wget with Intel credentials..."
    if wget --user="$INTEL_USERNAME" --password="$INTEL_TOKEN" --no-check-certificate --timeout=120 --tries=3 --continue --progress=bar:force:noscroll "$artifactory_url" -O "$video_path"; then
        if [ -f "$video_path" ] && [ -s "$video_path" ]; then
            local file_size=$(du -h "$video_path" | cut -f1)
            log_success "✓ Download successful with wget: $video_name ($file_size)"
            return 0
        fi
    fi
    rm -f "$video_path" 2>/dev/null
    
    # Method 3: curl with additional headers
    log_info "Trying curl with additional headers..."
    if curl -u"$INTEL_USERNAME:$INTEL_TOKEN" -L -O "$artifactory_url" \
           --connect-timeout 60 --max-time 1200 --retry 2 \
           --user-agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
           --header "Accept: */*" \
           --header "Accept-Encoding: identity" \
           --progress-bar; then
        if [ -f "$video_path" ] && [ -s "$video_path" ]; then
            local file_size=$(du -h "$video_path" | cut -f1)
            log_success "✓ Download successful with headers: $video_name ($file_size)"
            return 0
        fi
    fi
    rm -f "$video_path" 2>/dev/null
    
    # Method 4: Try fallback public videos
    log_info "Intel Artifactory download failed, trying fallback videos..."
    local fallback_urls=(
        "https://sample-videos.com/zip/10/mp4/SampleVideo_1280x720_5mb.mp4"
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"
        "https://www.learningcontainer.com/wp-content/uploads/2020/05/sample-mp4-file.mp4"
    )
    
    for fallback_url in "${fallback_urls[@]}"; do
        log_info "Trying fallback: $(basename "$fallback_url")"
        if wget --timeout=60 --tries=2 "$fallback_url" -O "sample_video.mp4" 2>/dev/null; then
            if [ -f "sample_video.mp4" ] && [ -s "sample_video.mp4" ]; then
                local file_size=$(du -h "sample_video.mp4" | cut -f1)
                log_success "✓ Fallback video downloaded: sample_video.mp4 ($file_size)"
                return 0
            fi
        fi
        rm -f "sample_video.mp4" 2>/dev/null
    done
    
    # All methods failed
    log_warning "All download methods failed."
    log_info ""
    log_info "Troubleshooting options:"
    log_info "1. Check network connectivity to Intel Artifactory"
    log_info "2. Verify Intel credentials are still valid"
    log_info "3. Try manual download: curl -u$INTEL_USERNAME:$INTEL_TOKEN -L -O \"$artifactory_url\""
    log_info "4. Copy any existing video file to this directory as 'sample_video.mp4'"
    log_info "5. The benchmark will create a test pattern video automatically if no video is found"
    log_info ""
    
    return 1
}

# Create a standalone video download script with hardcoded credentials
create_video_download_script() {
    local download_script="download_video.sh"
    
    log_info "Creating standalone video download script: $download_script"
    
    cat > "$download_script" << EOF
#!/bin/bash
# download_video.sh - Standalone video download script with Intel credentials

INTEL_USERNAME="$INTEL_USERNAME"
INTEL_TOKEN="$INTEL_TOKEN"
VIDEO_URL="https://ubit-artifactory-ba.intel.com/artifactory/dcso_pnp_workspace-ba-local/WLS/FFmpeg/lg_4k_oled_paris_hevc_1920x1080_420_8_23.98_25.9.mkv"
VIDEO_NAME="lg_4k_oled_paris_hevc_1920x1080_420_8_23.98_25.9.mkv"

echo "=== FFmpeg Benchmark Video Downloader ==="
echo "Target file: \$VIDEO_NAME"
echo "Source URL: \$VIDEO_URL"
echo "Using Intel credentials: \$INTEL_USERNAME"
echo ""

if [ -f "\$VIDEO_NAME" ]; then
    file_size=\$(du -h "\$VIDEO_NAME" | cut -f1)
    echo "✓ Video file already exists: \$VIDEO_NAME (\$file_size)"
    exit 0
fi

echo "Attempting to download video file with Intel credentials..."
echo "This may take several minutes depending on your connection..."
echo ""

# Method 1: curl with Intel credentials
echo "Method 1: curl with Intel credentials..."
if curl -u"\$INTEL_USERNAME:\$INTEL_TOKEN" -L -O "\$VIDEO_URL" --connect-timeout 60 --max-time 1200 --retry 3 --progress-bar; then
    if [ -f "\$VIDEO_NAME" ] && [ -s "\$VIDEO_NAME" ]; then
        file_size=\$(du -h "\$VIDEO_NAME" | cut -f1)
        echo "✓ Download successful: \$VIDEO_NAME (\$file_size)"
        exit 0
    fi
fi
rm -f "\$VIDEO_NAME" 2>/dev/null

# Method 2: wget with Intel credentials
echo "Method 2: wget with Intel credentials..."
if wget --user="\$INTEL_USERNAME" --password="\$INTEL_TOKEN" --no-check-certificate --timeout=120 --tries=3 --progress=bar:force:noscroll "\$VIDEO_URL" -O "\$VIDEO_NAME"; then
    if [ -f "\$VIDEO_NAME" ] && [ -s "\$VIDEO_NAME" ]; then
        file_size=\$(du -h "\$VIDEO_NAME" | cut -f1)
        echo "✓ Download successful: \$VIDEO_NAME (\$file_size)"
        exit 0
    fi
fi
rm -f "\$VIDEO_NAME" 2>/dev/null

# Method 3: Fallback video
echo "Method 3: Downloading fallback video..."
if wget --timeout=60 --tries=2 "https://sample-videos.com/zip/10/mp4/SampleVideo_1280x720_5mb.mp4" -O "sample_video.mp4"; then
    if [ -f "sample_video.mp4" ] && [ -s "sample_video.mp4" ]; then
        file_size=\$(du -h "sample_video.mp4" | cut -f1)
        echo "✓ Fallback video downloaded: sample_video.mp4 (\$file_size)"
        exit 0
    fi
fi

echo "✗ All download methods failed"
echo ""
echo "Manual download command:"
echo "curl -u\$INTEL_USERNAME:\$INTEL_TOKEN -L -O \"\$VIDEO_URL\""
echo ""
echo "Or run benchmark anyway - it will create a test pattern"
exit 1
EOF

    chmod +x "$download_script"
    log_success "✓ Standalone download script created: $download_script"
    log_info "  You can run it later with: ./$download_script"
}

print_usage() {
    echo -e "
Usage: $0 [OPTIONS]

OPTIONS:
  -h, --help     Show this help message
  --verify-only  Only verify existing installation
  --clean        Clean existing installation before setup
  --no-sample    Skip downloading sample video
  --force        Force installation even if conflicts exist
  --download-only Download video file only (skip FFmpeg setup)
  --skip-existing Skip components that are already installed (default: enabled)

DESCRIPTION:
  This script intelligently sets up FFmpeg with x264/x265 support:
  - Automatically detects existing installations and skips them
  - Installs build dependencies (with conflict resolution)
  - Downloads and compiles YASM/NASM assemblers (if needed)
  - Downloads and compiles libx264/libx265 codecs (if needed)
  - Downloads and compiles FFmpeg 6.0 (if needed)
  - Downloads sample video using hardcoded Intel credentials

SMART INSTALLATION:
  The script automatically detects and skips:
  ✓ Existing FFmpeg installations with codec support
  ✓ Already installed development tools
  ✓ Pre-existing codec libraries (x264/x265)
  ✓ Available assemblers (YASM/NASM)

EXAMPLES:
  $0                    # Smart setup (skips existing components)
  $0 --verify-only      # Only verify installation
  $0 --clean            # Clean and reinstall everything
  $0 --no-sample        # Setup without sample video
  $0 --force            # Force installation with conflict resolution
  $0 --download-only    # Only download video file

INTEL ARTIFACTORY:
  Uses hardcoded Intel credentials for video download:
  - Username: $INTEL_USERNAME
  - Token: [REDACTED]
  - No manual input required

TROUBLESHOOTING:
  If you encounter glibc conflicts on CentOS/RHEL:
  1. Try: $0 --force
  2. Or manually resolve: dnf update --allowerasing

AFTER INSTALLATION:
  Use with main wrapper:
  ./main_wrapper.sh --script ./ffmpeg_workload.sh --cores 8 --workload-name \"FFmpeg\" --metric-unit \"fps\"
"
}

main() {
    local verify_only=0
    local clean_install=0
    local no_sample=0
    local force_install=0
    local download_only=0
    local skip_existing=1  # Default to true for smart installation
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verify-only)
                verify_only=1
                shift
                ;;
            --clean)
                clean_install=1
                skip_existing=0  # Force reinstall everything
                shift
                ;;
            --no-sample)
                no_sample=1
                shift
                ;;
            --force)
                force_install=1
                shift
                ;;
            --download-only)
                download_only=1
                shift
                ;;
            --skip-existing)
                skip_existing=1
                shift
                ;;
            --no-skip-existing)
                skip_existing=0
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
    log_info "Smart installation mode: $([ $skip_existing -eq 1 ] && echo "ENABLED" || echo "DISABLED")"
    
    if [[ $download_only -eq 1 ]]; then
        log_info "Download-only mode selected"
        download_sample_video
        create_video_download_script
        exit $?
    fi
    
    if [[ $verify_only -eq 1 ]]; then
        verify_installation
        exit $?
    fi
    
    if [[ $clean_install -eq 1 ]]; then
        log_info "Clean installation mode - removing temporary build directories..."
        rm -rf /tmp/*_build_* 2>/dev/null || true
    fi
    
    # Quick check if everything is already installed
    if [[ $skip_existing -eq 1 ]]; then
        log_info "Performing smart installation check..."
        if check_ffmpeg_installation && check_development_tools && check_codec_libraries; then
            log_success "All components are already properly installed!"
            log_info "FFmpeg setup is complete. Skipping compilation steps."
            
            # Still try to download video if requested
            if [[ $no_sample -eq 0 ]]; then
                download_sample_video || log_warning "Video download failed, but setup is otherwise complete"
                create_video_download_script
            fi
            
            log_success "Setup completed successfully (using existing installations)"
            exit 0
        fi
    fi
    
    # Detect OS
    local os_info=$(detect_os)
    local os_id=$(echo "$os_info" | cut -d: -f1)
    local os_version=$(echo "$os_info" | cut -d: -f2)
    
    log_info "Detected OS: $os_id $os_version"
    
    # Install dependencies based on OS (with smart skipping)
    case "$os_id" in
        centos|rhel|rocky|almalinux)
            install_dependencies_centos || {
                if [[ $force_install -eq 1 ]]; then
                    log_warning "Dependency installation had issues but continuing due to --force flag"
                else
                    log_error "Dependency installation failed. Try with --force flag to continue anyway"
                    exit 1
                fi
            }
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
                install_dependencies_centos || {
                    if [[ $force_install -eq 1 ]]; then
                        log_warning "Dependency installation had issues but continuing due to --force flag"
                    else
                        exit 1
                    fi
                }
            elif command_exists zypper; then
                install_dependencies_suse || exit 1
            else
                log_error "No supported package manager found"
                exit 1
            fi
            ;;
    esac
    
    # Install assemblers and codecs (with smart skipping)
    install_yasm || {
        log_warning "YASM installation failed, but continuing..."
    }
    
    install_nasm || {
        log_warning "NASM installation failed, but continuing..."
    }
    
    install_x264 || {
        log_warning "x264 installation failed, FFmpeg will be built without x264 support"
    }
    
    install_x265 || {
        log_warning "x265 installation failed, FFmpeg will be built without x265 support"
    }
    
    # Download and compile FFmpeg (with smart skipping)
    download_and_compile_ffmpeg || {
        log_error "FFmpeg compilation failed"
        exit 1
    }
    
    # Verify installation
    verify_installation || {
        log_error "FFmpeg verification failed"
        exit 1
    }
    
    # Download sample video and create download script
    if [[ $no_sample -eq 0 ]]; then
        download_sample_video || {
            log_warning "Sample video download failed, but setup can continue"
        }
        create_video_download_script
    fi
    
    log_success "FFmpeg benchmark setup completed successfully!"
    log_info ""
    log_info "=== SETUP SUMMARY ==="
    log_info "✓ FFmpeg compiled and installed"
    log_info "✓ x264 codec: $(pkg-config --exists x264 && echo "Available" || echo "Not available")"
    log_info "✓ x265 codec: $(pkg-config --exists x265 && echo "Available" || echo "Not available")"
    log_info "✓ FFmpeg location: $(which ffmpeg 2>/dev/null || echo '/usr/local/bin/ffmpeg')"
    
    if [ -f "lg_4k_oled_paris_hevc_1920x1080_420_8_23.98_25.9.mkv" ]; then
        local video_size=$(du -h "lg_4k_oled_paris_hevc_1920x1080_420_8_23.98_25.9.mkv" | cut -f1)
        log_info "✓ Primary video: lg_4k_oled_paris_hevc_1920x1080_420_8_23.98_25.9.mkv ($video_size)"
    elif [ -f "sample_video.mp4" ]; then
        local video_size=$(du -h "sample_video.mp4" | cut -f1)
        log_info "✓ Fallback video: sample_video.mp4 ($video_size)"
    else
        log_info "⚠ No video file downloaded (will create test pattern during benchmark)"
    fi
    
    if [ -f "download_video.sh" ]; then
        log_info "✓ Standalone download script: download_video.sh"
    fi
    
    log_info ""
    log_info "=== NEXT STEPS ==="
    log_info "1. Make workload script executable:"
    log_info "   chmod +x ffmpeg_workload.sh"
    log_info ""
    log_info "2. Test FFmpeg workload:"
    log_info "   ./ffmpeg_workload.sh --cores 4 --codec x264 --preset medium"
    log_info ""
    log_info "3. Run with main wrapper:"
    log_info "   ./main_wrapper.sh --script ./ffmpeg_workload.sh --cores 8 --workload-name \"FFmpeg\" --metric-unit \"fps\""
    log_info ""
    log_info "4. If video download failed, try:"
    log_info "   ./download_video.sh"
    log_info ""
    log_info "5. Add FFmpeg to PATH permanently:"
    log_info "   echo 'export PATH=\"/usr/local/bin:\$PATH\"' >> ~/.bashrc"
    log_info "   source ~/.bashrc"
    log_info ""
    log_info "=== SMART INSTALLATION NOTES ==="
    log_info "• Next run will be much faster (skips existing components)"
    log_info "• Use --clean to force reinstall everything"
    log_info "• Use --verify-only to check current installation"
}

# Run main function
main "$@"
