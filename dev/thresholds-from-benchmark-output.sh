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

url="${URL:=""}"

if [ -z "$url" ]; then
  fatal "Pull request or workflow run URL must be specified."
fi

# Check for required tools
GH_BIN="${GH_BIN:-$(which gh)}" || fatal "GH_BIN unset and no gh on PATH"
JQ_BIN="${JQ_BIN:-$(which jq)}" || fatal "JQ_BIN unset and no jq on PATH"
YQ_BIN="${YQ_BIN:-$(which yq)}" || fatal "YQ_BIN unset and no yq on PATH"

fetch_checks_for_pr() {
    pr_url=$1

    "$GH_BIN" pr checks "$pr_url" | grep Benchmarks | grep -v Construct
}

parse_url() {
    workflow_url=$1
    # https://github.com/apple/swift-nio/actions/runs/15269806473
    # https://github.com/apple/swift-nio/pull/3257
    if [[ "$url" =~ pull ]]; then
        type="PR"
    elif [[ "$url" =~ actions/runs ]]; then
        type="run"
    else
        fatal "Cannot parse URL: $url"
    fi
    echo "$url" | awk -v type="$type" -F '/' '{print $4, $5, type}'
}

parse_check() {
    type=$1
    check_line=$2

    case "$type" in
    "PR")
        parse_check_for_pr "$check_line"
        ;;

    "run")
        parse_check_for_workflow "$check_line"
        ;;

    *)
        fatal "Unknown type '$type'"
        # Add error handling commands here
        ;;
    esac
}

parse_check_for_workflow() {
    check_line=$1

    # Something like:
    # ✓ Benchmarks / Benchmarks / Linux (5.10) in 5m10s (ID 42942543009)
    echo "$check_line" | sed -En 's/.*ID ([0-9][0-9]*).*/\1/p'
}

parse_check_for_pr() {
    check_line=$1

    # Something like:
    # Benchmarks / Benchmarks / Linux (5.10)	pass	4m21s	https://github.com/apple/swift-nio-ssl/actions/runs/13793783082/job/38580234681
    echo "$check_line" | sed -E 's/.*\(([^\)]+)\).*github\.com\/(.*)\/actions\/runs\/[0-9]+\/job\/([0-9]+)/\3/g'
}

parse_workflow_url() {
    workflow_url=$1
    # https://github.com/apple/swift-nio/actions/runs/15269806473
    echo "$workflow_url" | awk -F '/' '{print $8}'
}

fetch_checks_for_workflow() {
    repo=$1
    run=$2

    "$GH_BIN" --repo "$repo" run view "$run" | grep Benchmarks | grep ID | grep -v Construct
}

fetch_check_logs() {
    repo=$1
    job=$2

    log "Pulling logs for $repo job $job"
    # We use `gh api` rather than `gh run view --log` because of https://github.com/cli/cli/issues/5011.
    # Look for the table outputted by the benchmarks tool if there is a discrepancy
    "$GH_BIN" api "/repos/${repo}/actions/jobs/${job}/logs"
}

scrape_benchmarks_output_diff() {
    lines=$1
    job=$2

    log "Scraping diff from log"
    # Trim out everything but the diff
    git_diff="$(echo "$lines" | sed '1,/=== BEGIN DIFF ===/d' | sed '/Post job cleanup/,$d' | sed 's/^[0-9][0-9][0-9][0-9]-.*Z //')"

    echo "$git_diff"
}

apply_benchmarks_output_diff() {
    git_diff=$1

    if [ -z "$git_diff" ]; then
        log "No git diff found to apply"
        return
    fi

    log "Applying git diff"
    echo "$git_diff" | git apply
}

filter_thresholds_to_allowlist() {
    git_diff=$1

    log "Filtering thresholds"
    for thresholds_file in $(echo "$git_diff" | grep "+++" | sed -E 's/^\+\+\+ b\/(.*)$/\1/g'); do
        jq 'with_entries(select(.key | in({mallocCountTotal:1, memoryLeaked:1})))' "$thresholds_file" > temp.json && mv -f temp.json "$thresholds_file"
    done
}

####

read -r repo_org repo_name type <<< "$(parse_url "$url")"
repo="$repo_org/$repo_name"
log "URL is of type $type in $repo"

case "$type" in
"PR")
    log "Fetching checks for $url"
    check_lines="$(fetch_checks_for_pr "$url")"

    if [ -z "$check_lines" ]; then
        fatal "Could not locate benchmark checks on PR: $url"
    fi
    ;;

"run")
    run="$(parse_workflow_url "$url")"

    log "Fetching checks for $repo run $run"
    check_lines="$(fetch_checks_for_workflow "$repo" "$run")"

    if [ -z "$check_lines" ]; then
        fatal "Could not locate benchmark checks on workflow run: $url"
    fi
    ;;

*)
    fatal "Unknown type '$type'"
    ;;
esac

while read -r check_line; do
    job="$(parse_check "$type" "$check_line")"

    lines=$(fetch_check_logs "$repo" "$job")

    if [ -z "$lines" ]; then
        log "Nothing to update: $repo job: $job"
        continue
    fi

    git_diff="$(scrape_benchmarks_output_diff "$lines" "$job")"
    apply_benchmarks_output_diff "$git_diff"

    filter_thresholds_to_allowlist "$git_diff"

done <<< "$check_lines"
