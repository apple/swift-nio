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

# This script allows you to consume swift package benchmark output and 
# update JSON threshold files

set -uo pipefail

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

pr_url="${FETCH_PR_URL:=""}"
output_dir="${OUTPUT_DIRECTORY:=""}"

if [ -z "$pr_url" ]; then
  fatal "Pull request URL must be specified."
fi

if [ -z "$output_dir" ]; then
  fatal "Output directory must be specified."
fi

# Check for required tools
GH_BIN="${GH_BIN:-$(which gh)}" || fatal "GH_BIN unset and no gh on PATH"
JQ_BIN="${JQ_BIN:-$(which jq)}" || fatal "JQ_BIN unset and no jq on PATH"
YQ_BIN="${YQ_BIN:-$(which yq)}" || fatal "YQ_BIN unset and no yq on PATH"

# Parsing constants
readonly benchmark_title_name_prefix="than threshold for "
readonly table_pipe="│"
readonly table_current_run_heading="Current_run"

fetch_checks_for_pr() {
    pr_url=$1

    "$GH_BIN" pr checks "$pr_url" | grep Benchmarks | grep -v Construct
}

fetch_check_logs() {
    repo=$1
    job=$2

    # We use `gh api` rather than `gh run view --log` because of https://github.com/cli/cli/issues/5011.
    # Look for the table outputted by the benchmarks tool if there is a discrepancy
    "$GH_BIN" api "/repos/${repo}/actions/jobs/${job}/logs" | grep -e "$benchmark_title_name_prefix" -e "$table_pipe"
}

parse_check() {
    check_line=$1

    # Something like:
    # Benchmarks / Benchmarks / Linux (5.10)	pass	4m21s	https://github.com/apple/swift-nio-ssl/actions/runs/13793783082/job/38580234681
    echo "$check_line" | sed -E 's/.*\(([^\)]+)\).*github\.com\/(.*)\/actions\/runs\/[0-9]+\/job\/([0-9]+)/\1 \2 \3/g'
}

parse_benchmark_header() {
    line=$1

    echo "$line" | grep "$table_pipe" | grep "$table_current_run_heading" > /dev/null || fatal "Unexpected line format when expecting benchmark table header: $line"

    # Something like:
    # │ Malloc (total) (#, %)                    │   p90 threshold │     Current_run │    Difference % │     Threshold % │
    benchmark_header_name="$(echo "$line" | awk '{split($0,a,"│"); print a[2]}' | xargs)"
    
    case "$benchmark_header_name" in
        "Malloc (total) (#, Δ)")
            benchmark_metric_name="mallocCountTotal"
            scale=1
        ;;

        "Malloc (total) (K, Δ)")
            benchmark_metric_name="mallocCountTotal"
            scale=1000
        ;;

        "Malloc / free Δ (#, Δ)")
            benchmark_metric_name="memoryLeaked"
            scale=1
        ;;
    esac
    echo "$benchmark_metric_name" "$scale"
}

parse_benchmark_value() {
    line=$1
    echo "$line" | grep "$table_pipe" | grep -v "$table_current_run_heading" > /dev/null || fatal "Unexpected line format when expecting benchmark table values: $line"
    
    # Something like:
    # │ p90                                      │            8000 │            6000 │           -2000 │               0 │
    echo "$line" | awk '{split($0,a,"│"); print a[4]}'
}

parse_benchmark_title() {
    line=$1 
    echo "$line" | grep -q "$benchmark_title_name_prefix" || fatal "Unexpected line format when expecting threshold title: $line"

    # Something like:
    # Deviations better than threshold for NIOCoreBenchmarks:WaitOnPromise
    benchmark_title="$(echo "$line" | sed -E 's/.*than threshold for ([^:]*)\:(.*)$/\1.\2/g')"
    threshold_file="${benchmark_title}.p90.json"

    echo "$threshold_file"
}

# States for the output parsing state machine
readonly STATE_EXPECTING_BENCHMARK_TITLE=0
readonly STATE_EXPECTING_BENCHMARK_HEADER_ROW=1
readonly STATE_EXPECTING_BENCHMARK_VALUE_ROW=2
readonly STATE_PROCESSED_VALUE_ROW=3

parse_benchmarks_output() {
    lines=$1
    job=$2
    swift_version=$3

    # We can ignore the percentage difference rows (with '#, %' in the title)
    lines="$(echo "$lines" | sed -e '/#, %/,+1d')"

    state=$STATE_EXPECTING_BENCHMARK_TITLE
    while read -r line; do
        case "$state" in
            "$STATE_EXPECTING_BENCHMARK_TITLE")
                output_file="$(parse_benchmark_title "$line")"
                output_path="${output_dir}/${swift_version}/${output_file}"
                output=""
                state=$STATE_EXPECTING_BENCHMARK_HEADER_ROW
                ;;

            "$STATE_EXPECTING_BENCHMARK_HEADER_ROW")
                read -r benchmark_metric_name scale <<< "$(parse_benchmark_header "$line")"
                output="${output}\"${benchmark_metric_name}\":"

                state=$STATE_EXPECTING_BENCHMARK_VALUE_ROW
                ;;

            "$STATE_EXPECTING_BENCHMARK_VALUE_ROW")
                benchmark_metric_value=$(parse_benchmark_value "$line")
                benchmark_metric_scaled_value="$(( benchmark_metric_value * scale ))"
                
                output="${output}${benchmark_metric_scaled_value},"

                state=$STATE_PROCESSED_VALUE_ROW
                ;;

            "$STATE_PROCESSED_VALUE_ROW")
                # next up is either another metric in the same benchmark or a new benchmark
                if [[ "$line" =~ $table_current_run_heading ]]; then
                    # this is a BENCHMARK_HEADER_ROW
                    output="${output}\"$(parse_benchmark_header "$line")\":"
                    state=$STATE_EXPECTING_BENCHMARK_VALUE_ROW
                else
                    # this is a new BENCHMARK_TITLE, finish-up the old benchmarK
                    write_output "$output" "$output_path" "$job"

                    # reset state and output JSON buffer
                    output=""
                    state=$STATE_EXPECTING_BENCHMARK_HEADER_ROW

                    # new benchmark means a new output file
                    output_file="$(parse_benchmark_title "$line")"
                    output_path="${output_dir}/${swift_version}/${output_file}"
                fi
                ;;

            *)
                fatal "Unexpected state: $state"
                ;;
        esac
    done <<< "$lines"

    write_output "$output" "$output_path" "$job"
}

write_output() {
    output=$1
    output_path=$2
    job=$3

    log "Updating: $output_path job:$job"
    # go via `yq` to clean up the trailing comma
    echo "{$output}" | "$YQ_BIN" . | "$JQ_BIN" . > "$output_path"
}

####

check_lines="$(fetch_checks_for_pr "$pr_url")"

if [ -z "$check_lines" ]; then
    fatal "Could not locate benchmark checks on PR: $pr_url"
fi

while read -r check_line; do
    read -r swift_version repo job <<< "$(parse_check "$check_line")"

    lines=$(fetch_check_logs "$repo" "$job")

    if [ -z "$lines" ]; then
        log "Nothing to update: $repo $swift_version job:$job"
        continue
    fi

    parse_benchmarks_output "$lines" "$job" "$swift_version"

done <<< "$check_lines"
