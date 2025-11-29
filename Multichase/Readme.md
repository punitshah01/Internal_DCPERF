# Multichase Memory Benchmark

## Overview

Multichase is a pointer chaser benchmark that measures memory latency and bandwidth performance. It includes multiple tools: `multiload` (a superset that runs latency, memory bandwidth and loaded-latency tests) and `pingpong` (measures inter-core memory access latency). This benchmark is essential for evaluating memory subsystem performance and NUMA characteristics.

## Workload Description

The Multichase benchmark suite includes:

### Test Types
1. **Multiload**: Comprehensive memory benchmark measuring latency and bandwidth with configurable thread counts
2. **Pingpong**: Inter-core latency measurement showing access latency matrix between cores
3. **Basic Multichase**: Simple pointer chaser through 256MB array with 256-byte stride

### Key Features
- Memory latency measurement in nanoseconds
- Memory bandwidth testing with multiple threads
- Inter-core communication latency analysis
- NUMA-aware memory binding support
- Configurable memory sizes and stride patterns

## Software Requirements

| Software | Version | Purpose |
|----------|---------|---------|
| Multichase | GitHub commit 6188a9f | Memory benchmark suite |
| GCC | 8.3.0+ | C/C++ compiler |
| Make | - | Build system |
| numactl | - | NUMA policy control |
| glibc-static | - | Static C library (CentOS/RHEL) |
| libstdc++-static | - | Static C++ library (CentOS/RHEL) |

## Installation and Setup

### Automated Setup

Run the setup script to download and compile Multichase:

```bash
# Make setup script executable
chmod +x setup_multichase.sh

# Install dependencies and compile Multichase
sudo ./setup_multichase.sh

# Verify installation
./setup_multichase.sh --verify-only

# Clean install (remove existing and reinstall)
sudo ./setup_multichase.sh --clean
