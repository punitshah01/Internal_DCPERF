# Super Pi Benchmark

## Overview

Super Pi is a CPU benchmark that calculates the mathematical constant π (pi) to 5000 decimal places using the Bailey–Borwein–Plouffe formula. This benchmark measures single-threaded CPU performance by timing how long it takes to perform this calculation using the `bc` (basic calculator) command.

## Workload Description

The Super Pi benchmark:
- Calculates π to exactly 5000 decimal places after the decimal point
- Uses the mathematical formula `4*a(1)` where `a(1)` is the arctangent of 1 (π/4)
- Measures the time required for this calculation
- Can run on single core or multiple cores simultaneously
- Reports execution time in seconds as the primary performance metric

## Software Requirements

| Software | Version | Purpose |
|----------|---------|---------|
| bc | 1.07.1+ | Basic calculator for pi calculation |
| taskset | - | CPU affinity control (from util-linux) |
| time | - | Execution time measurement |

## Installation and Setup

### Automated Setup

Run the setup script to install all dependencies:

```bash
# Make setup script executable
chmod +x setup_superpi.sh

# Install dependencies
sudo ./setup_superpi.sh

# Verify installation
./setup_superpi.sh --verify-only
