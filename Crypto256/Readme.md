# Crypto++ SHA-256 Benchmark

## Overview

Crypto++ SHA-256 benchmark is a cryptographic performance test that measures the throughput of SHA-256 hashing algorithm using the Crypto++ library. This benchmark evaluates CPU performance for cryptographic operations, specifically focusing on SHA-256 hash computation speed.

## Workload Description

The Crypto++ SHA-256 benchmark:
- Uses the Crypto++ library version 8.5.0 for cryptographic operations
- Measures SHA-256 hashing throughput in MB/s
- Tests CPU performance for cryptographic workloads
- Supports multi-core execution with CPU affinity control
- Provides detailed performance metrics and result logging

## Software Requirements

| Software | Version | Purpose |
|----------|---------|---------|
| Crypto++ | 8.5.0 | Cryptographic library for SHA-256 implementation |
| GCC/G++ | 4.8+ | C++ compiler for building the library |
| Make | - | Build system |
| wget | - | Download source code |
| tar/gzip | - | Archive extraction |

## Installation and Setup

### Automated Setup

Run the setup script to download, compile and install Crypto++:

```bash
# Make setup script executable
chmod +x setup_crypto256.sh

# Install dependencies and compile Crypto++
sudo ./setup_crypto256.sh

# Verify installation
./setup_crypto256.sh --verify-only

# Clean install (remove existing and reinstall)
sudo ./setup_crypto256.sh --clean
