# Sysbench Database Benchmark

## Overview

Sysbench is a comprehensive stress testing tool that evaluates system performance across multiple dimensions including CPU, memory, disk I/O, and database operations. This benchmark focuses on database performance testing using OLTP (Online Transaction Processing) workloads with MySQL/Percona Server, measuring transaction throughput (TPS) and latency characteristics.

## Workload Description

The Sysbench benchmark provides:

### Test Types
1. **OLTP Read-Only**: Pure read operations testing database read performance
2. **OLTP Write-Only**: Pure write operations testing database write performance  
3. **OLTP Read-Write**: Mixed read/write operations simulating real-world OLTP workloads

### Key Features
- Configurable table count and size for different memory footprints
- Multi-threaded execution with CPU affinity control
- Comprehensive latency analysis (average, 99th percentile, min/max)
- Transaction throughput measurement (TPS)
- Core scaling analysis support
- NUMA-aware execution capabilities

## Software Requirements

| Software | Version | Purpose |
|----------|---------|---------|
| Sysbench | 1.0.20 | Database benchmark tool |
| Percona Server for MySQL | 8.0.33-25 | High-performance MySQL server |
| GCC | 4.8+ | C/C++ compiler for building Sysbench |
| MySQL Client Libraries | - | Database connectivity |

## Installation and Setup

### Automated Setup

Run the setup script to install Sysbench and Percona MySQL Server:

```bash
# Make setup script executable
chmod +x setup_sysbench.sh

# Full installation (Sysbench + MySQL)
sudo ./setup_sysbench.sh

# Install only Sysbench (skip MySQL)
sudo ./setup_sysbench.sh --skip-mysql

# Verify installation
./setup_sysbench.sh --verify-only

# Clean install
sudo ./setup_sysbench.sh --clean
