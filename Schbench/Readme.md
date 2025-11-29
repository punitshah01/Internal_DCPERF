# Schbench Scheduler Benchmark

## Overview

Schbench is a scheduler benchmark designed to reproduce the scheduler characteristics of production web workloads. It focuses on saturating all CPUs with long time slices and low scheduling delays, making it an excellent tool for evaluating Linux scheduler performance under realistic workload conditions.

## Workload Description

The Schbench benchmark:

### Key Characteristics
- **Scheduler Stress Testing**: Evaluates Linux scheduler performance under load
- **Web Workload Simulation**: Mimics production web server scheduling patterns
- **CPU Saturation**: Designed to fully utilize all available CPU cores
- **Low Latency Focus**: Measures scheduling delays and response times
- **Multi-threaded Design**: Uses message threads and worker threads

### Test Scenarios
1. **Default Test**: Simple execution with automatic parameter selection
2. **Custom Configuration**: Configurable message threads, worker threads, and timing
3. **Core Scaling**: Performance analysis across different core counts
4. **Pipe Test Mode**: Alternative communication mechanism testing

## Software Requirements

| Software | Version | Purpose |
|----------|---------|---------|
| Schbench | 1.0 | Scheduler benchmark tool |
| GCC | 8.3.0+ | C compiler for building |
| pthread | - | POSIX threads library |
| libm | - | Math library |

## Installation and Setup

### Automated Setup

Run the setup script to download and compile Schbench:

```bash
# Make setup script executable
chmod +x setup_schbench.sh

# Install dependencies and compile Schbench
sudo ./setup_schbench.sh

# Verify installation
./setup_schbench.sh --verify-only

# Clean install (remove existing and reinstall)
sudo ./setup_schbench.sh --clean
