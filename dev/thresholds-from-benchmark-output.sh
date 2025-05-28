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

pr_url="${PR_URL:=""}"
run_url="${RUN_URL:=""}"

output_dir="${OUTPUT_DIRECTORY:=""}"

if [ -z "$pr_url" ] && [ -z "$run_url" ]; then
  fatal "Pull request URL or workflow run URL must be specified."
fi

if [ -n "$pr_url" ] && [ -z "$output_dir" ]; then
  fatal "Output directory must be specified."
fi

# Check for required tools
GH_BIN="${GH_BIN:-$(which gh)}" || fatal "GH_BIN unset and no gh on PATH"
JQ_BIN="${JQ_BIN:-$(which jq)}" || fatal "JQ_BIN unset and no jq on PATH"
YQ_BIN="${YQ_BIN:-$(which yq)}" || fatal "YQ_BIN unset and no yq on PATH"

fetch_checks_for_pr() {
    pr_url=$1

    "$GH_BIN" pr checks "$pr_url" | grep Benchmarks | grep -v Construct
}

parse_check_for_pr() {
    check_line=$1

    # Something like:
    # Benchmarks / Benchmarks / Linux (5.10)	pass	4m21s	https://github.com/apple/swift-nio-ssl/actions/runs/13793783082/job/38580234681
    echo "$check_line" | sed -E 's/.*\(([^\)]+)\).*github\.com\/(.*)\/actions\/runs\/[0-9]+\/job\/([0-9]+)/\1 \2 \3/g'
}

parse_workflow_url() {
    workflow_url=$1
    # https://github.com/apple/swift-nio/actions/runs/15269806473
    echo "$workflow_url" | awk -F'/' '{print $4, $5, $8}'
}

fetch_checks_for_workflow() {
    repo=$1
    run=$2

    "$GH_BIN" --repo "$repo" run view "$run" | grep Benchmarks | grep ID | grep -v Construct
}

parse_check_for_workflow() {
    check_line=$1

    # Something like:
    # ✓ Benchmarks / Benchmarks / Linux (5.10) in 5m10s (ID 42942543009)
    echo "$check_line" | sed -En 's/.*ID ([0-9][0-9]*).*/\1/p'
}

fetch_check_logs() {
    repo=$1
    job=$2

    # We use `gh api` rather than `gh run view --log` because of https://github.com/cli/cli/issues/5011.
    # Look for the table outputted by the benchmarks tool if there is a discrepancy
    "$GH_BIN" api "/repos/${repo}/actions/jobs/${job}/logs"
}

apply_benchmarks_output_diff() {
    lines=$1
    job=$2

    # Trim out everything but the diff
    git_diff="$(echo "$lines" | sed '1,/=== BEGIN DIFF ===/d' | sed '/Post job cleanup/,$d' | sed 's/^[0-9][0-9][0-9][0-9]-.*Z //')"
    if [ -z "$git_diff" ]; then
        log "No git diff found to apply for job $job"
        return
    fi

    log "Applying diff:
    ${git_diff}"

    echo "$git_diff" | git apply
}

####

if [ -n "$pr_url" ]; then
    log "Fetching checks for $pr_url"
    check_lines="$(fetch_checks_for_pr "$pr_url")"

    if [ -z "$check_lines" ]; then
        fatal "Could not locate benchmark checks on PR: $pr_url"
    fi

    while read -r check_line; do
        read -r swift_version repo job <<< "$(parse_check_for_pr "$check_line")"

        lines=$(fetch_check_logs "$repo" "$job")

        if [ -z "$lines" ]; then
            log "Nothing to update: $repo $swift_version job: $job"
            continue
        fi

        parse_benchmarks_output "$lines" "$job" "$swift_version"

    done <<< "$check_lines"

elif [ -n "$run_url" ]; then
    read -r repo_org repo_name run <<< "$(parse_workflow_url "$run_url")"
    repo="$repo_org/$repo_name"

    log "Fetching checks for $repo run $run"
    check_lines="$(fetch_checks_for_workflow "$repo" "$run")"

    if [ -z "$check_lines" ]; then
        fatal "Could not locate benchmark checks on workflow run: $run_url"
    fi

    while read -r check_line; do
        job="$(parse_check_for_workflow "$check_line")"

        lines=$(fetch_check_logs "$repo" "$job")

        if [ -z "$lines" ]; then
            log "Nothing to update: $repo $swift_version job: $job"
            continue
        fi

        apply_benchmarks_output_diff "$lines" "$job"

    done <<< "$check_lines"

else
    fatal "Either pull request or workflow run URL must be specified."
fi
