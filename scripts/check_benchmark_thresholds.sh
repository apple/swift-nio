#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -uo pipefail

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

# Parameter environment variables
if [ -z "$SWIFT_VERSION" ]; then
  fatal "SWIFT_VERSION must be specified."
fi

benchmark_package_path="${BENCHMARK_PACKAGE_PATH:-"."}"
swift_version="${SWIFT_VERSION:-""}"

# Any parameters to the script are passed along to SwiftPM
swift_package_arguments=("$@")

#"swift package --package-path ${{ inputs.benchmark_package_path }} ${{ inputs.swift_package_arguments }} benchmark baseline check --check-absolute-path ${{ inputs.benchmark_package_path }}/Thresholds/${SWIFT_VERSION}/"
swift package --package-path "$benchmark_package_path" "${swift_package_arguments[@]}" benchmark thresholds check --format metricP90AbsoluteThresholds --path "${benchmark_package_path}/Thresholds/${swift_version}/"
rc="$?"

# Benchmarks are unchanged, nothing to recalculate
if [[ "$rc"  == 0 ]]; then
  exit 0
fi

log "Recalculating thresholds..."

swift package --package-path "$benchmark_package_path" "${swift_package_arguments[@]}" benchmark thresholds update --format metricP90AbsoluteThresholds --path "${benchmark_package_path}/Thresholds/${swift_version}/"
echo "=== BEGIN DIFF ==="  # use echo, not log for clean output to be scraped
git diff --exit-code HEAD
