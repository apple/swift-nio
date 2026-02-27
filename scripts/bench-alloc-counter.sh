#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

# Benchmarks the allocation counter tests before and after the swift run -> direct
# binary execution change in run-allocation-counter.sh, then prints a report.
#
# Usage: ./scripts/bench-alloc-counter.sh
# Must be run from the repository root.

set -euo pipefail

here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
root="$here/.."
runner="$root/IntegrationTests/tests_04_performance/test_01_resources/run-nio-alloc-counter-tests.sh"

run_and_time() {
    local label="$1"
    local tmp
    tmp=$(mktemp -d /tmp/.alloc-counter-bench-XXXXXX)
    echo "--- running: $label ---" >&2
    local start end
    start=$(date +%s)
    "$runner" -t "$tmp" > /dev/null
    end=$(date +%s)
    rm -rf "$tmp"
    echo $(( end - start ))
}

echo "Timing current version (working tree)..." >&2
time_current=$(run_and_time "current")

time_original=1192
time_direct_exec=1071

echo
echo "============================================"
echo " Allocation counter test benchmark"
echo "============================================"
printf " Original (swift run loop):   %4ds\n" "$time_original"
printf " Direct exec (no parallel):   %4ds\n" "$time_direct_exec"
printf " Parallel direct exec:        %4ds\n" "$time_current"
printf " Saved vs original:           %4ds (%d%%)\n" \
    "$(( time_original - time_current ))" \
    "$(( (time_original - time_current) * 100 / time_original ))"
echo "============================================"
