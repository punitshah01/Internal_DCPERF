# FFmpeg Video Encoding Benchmark

## Overview

FFmpeg is a complete, cross-platform solution to record, convert and stream audio and video. This benchmark measures video encoding performance using FFmpeg with H.264 (x264) and H.265 (x265) codecs, testing both single-threaded and multi-threaded encoding scenarios.

## Workload Description

The FFmpeg benchmark supports multiple test scenarios:

### Test Types
1. **Single Instance Performance**: Tests performance of a single FFmpeg process with specified core count
2. **Core Scaling Test**: Tests performance scaling across different core counts (4, 8, 16, 32, etc.)
3. **Multiple Instance Test**: Tests overall machine performance by running multiple FFmpeg instances simultaneously

### Key Features
- H.264 (x264) and H.265 (x265) codec support
- Configurable encoding presets and quality settings
- CPU affinity control for consistent performance
- EMON and TMC monitoring integration
- Automatic result logging to CSV format

## Software Requirements

| Software | Version | Purpose |
|----------|---------|---------|
| FFmpeg | 6.0 | Video encoding framework |
| libx264 | Latest | H.264 video encoder |
| libx265 | Latest | H.265/HEVC video encoder |
| YASM | 1.3.0+ | Assembler for codec optimization |
| NASM | 2.15+ | Assembler for codec optimization |
| GCC/G++ | 4.8+ | C/C++ compiler |

## Installation and Setup

### Automated Setup

Run the setup script to install all dependencies and compile FFmpeg:

```bash
# Make setup script executable
chmod +x setup_ffmpeg.sh

# Install dependencies and compile FFmpeg
sudo ./setup_ffmpeg.sh

# Verify installation
./setup_ffmpeg.sh --verify-only

# Clean install (remove existing and reinstall)
sudo ./setup_ffmpeg.sh --clean

# Setup without sample video
sudo ./setup_ffmpeg.sh --no-sample
