#!/bin/bash
# Folly's exported folly-config.cmake can compute an empty install prefix,
# leaving INTERFACE_INCLUDE_DIRECTORIES set to the literal string "//include"
# instead of a real path. Downstream find_package(folly) consumers (fizz,
# wangle, rsocket-cpp, fbthrift) then fail with:
#   CMake Error: Imported target "Folly::folly" includes non-existent path "//include"
# Patch the exact broken literal to the real install prefix.
set -euo pipefail
install_dir="$1"
grep -rlF '"//include"' "${install_dir}/lib/cmake/folly" 2>/dev/null | while read -r f; do
    sed -i "s#\"//include\"#\"${install_dir}/include\"#g" "$f"
done
