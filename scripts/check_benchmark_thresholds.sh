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

# Accept either BENCHMARK_PACKAGE_PATHS (newline-separated list, or a JSON
# array of strings such as '["A", "B"]') or the legacy singular
# BENCHMARK_PACKAGE_PATH. The plural takes precedence; falling back to the
# singular preserves the original interface. The JSON form requires `jq`.
plural_paths="${BENCHMARK_PACKAGE_PATHS:-}"
singular_path="${BENCHMARK_PACKAGE_PATH:-.}"

trimmed="${plural_paths#"${plural_paths%%[![:space:]]*}"}"
if [[ "$trimmed" == \[* ]]; then
  command -v jq >/dev/null 2>&1 || fatal "BENCHMARK_PACKAGE_PATHS looks like a JSON array but \`jq\` is not installed."
  jq empty <<< "$plural_paths" 2>/dev/null || fatal "BENCHMARK_PACKAGE_PATHS is not valid JSON."
  jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null <<< "$plural_paths" \
    || fatal "BENCHMARK_PACKAGE_PATHS must be a JSON array of strings."
  if [[ "$(jq 'length' <<< "$plural_paths")" == "0" ]]; then
    benchmark_package_paths="$singular_path"
  else
    benchmark_package_paths=$(jq -r '.[]' <<< "$plural_paths")
  fi
elif [[ -n "$plural_paths" ]]; then
  benchmark_package_paths="$plural_paths"
else
  benchmark_package_paths="$singular_path"
fi

swift_version="${SWIFT_VERSION:-""}"

# Any parameters to the script are passed along to SwiftPM
swift_package_arguments=("$@")

run_one() {
  local benchmark_package_path="$1"

  #"swift package --package-path ${{ inputs.benchmark_package_path }} ${{ inputs.swift_package_arguments }} benchmark baseline check --check-absolute-path ${{ inputs.benchmark_package_path }}/Thresholds/${SWIFT_VERSION}/"
  swift package --package-path "$benchmark_package_path" "${swift_package_arguments[@]}" benchmark thresholds check --format metricP90AbsoluteThresholds --path "${benchmark_package_path}/Thresholds/${swift_version}/"
  local rc="$?"

  # Benchmarks are unchanged, nothing to recalculate
  if [[ "$rc" == 0 ]]; then
    return 0
  fi

  # Non-zero exit from 'thresholds check' means thresholds regressed or a build
  # error occurred. Try 'thresholds update' to distinguish: if it also fails, it
  # was a build error; if it succeeds, thresholds were updated.
  log "Recalculating thresholds for ${benchmark_package_path}..."

  swift package --package-path "$benchmark_package_path" "${swift_package_arguments[@]}" benchmark thresholds update --format metricP90AbsoluteThresholds --path "${benchmark_package_path}/Thresholds/${swift_version}/"
  local update_rc="$?"

  if [[ "$update_rc" != 0 ]]; then
    error "Benchmark in ${benchmark_package_path} failed to run due to build error."
    return "$update_rc"
  fi

  echo "=== BEGIN DIFF (${benchmark_package_path}) ==="  # use echo, not log for clean output to be scraped
  git add --intent-to-add "${benchmark_package_path}/Thresholds/"
  git diff HEAD -- "${benchmark_package_path}/Thresholds/"
  return 1
}

overall_rc=0
failed=()
while IFS= read -r path; do
  [ -z "$path" ] && continue
  echo "::group::Running benchmarks for $path"
  run_one "$path"
  rc=$?
  echo "::endgroup::"
  if [[ "$rc" -ne 0 ]]; then
    overall_rc=$rc
    failed+=("$path")
  fi
done <<< "$benchmark_package_paths"

if [[ "$overall_rc" -ne 0 ]]; then
  echo "::error::Benchmark failures in: ${failed[*]}"
fi
exit "$overall_rc"


