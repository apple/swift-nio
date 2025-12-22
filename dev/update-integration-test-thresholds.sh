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

# This script allows you to consume GitHub Actions integration test logs and
# update allocation threshold JSON files automatically

set -uo pipefail

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

usage() {
    echo >&2 "Usage: $0 <url>"
    echo >&2 "   or: URL=<url> $0"
    echo >&2
    echo >&2 "Example:"
    echo >&2 "  $0 https://github.com/apple/swift-nio/pull/3442"
    echo >&2 "  $0 https://github.com/apple/swift-nio/actions/runs/19234929677"
    echo >&2 "  URL=https://github.com/apple/swift-nio/pull/3442 $0"
}

url="${1:-${URL:-}}"

if [ -z "$url" ]; then
    usage
    fatal "Pull request or workflow run URL must be specified."
fi

# Check for required tools
GH_BIN="${GH_BIN:-$(which gh)}" || fatal "GH_BIN unset and no gh on PATH"
JQ_BIN="${JQ_BIN:-$(which jq)}" || fatal "JQ_BIN unset and no jq on PATH"

# Check repository and script paths
REPO_ROOT="$(git rev-parse --show-toplevel)" || fatal "Must be run from within git repository"
ALLOC_LIMITS_SCRIPT="$REPO_ROOT/dev/alloc-limits-from-test-output"

if [ ! -x "$ALLOC_LIMITS_SCRIPT" ]; then
    fatal "alloc-limits-from-test-output script not found at: $ALLOC_LIMITS_SCRIPT"
fi

THRESHOLDS_DIR="${THRESHOLDS_DIR:-$REPO_ROOT/IntegrationTests/tests_04_performance/Thresholds}"

if [ ! -d "$THRESHOLDS_DIR" ]; then
    fatal "Thresholds directory not found at: $THRESHOLDS_DIR"
fi

# Map job name pattern to threshold file name
map_version() {
    check_line=$1

    case "$check_line" in
        *"(5.8)"*)
            echo "5.8"
            ;;
        *"(5.10)"*)
            echo "5.10"
            ;;
        *"(6.0)"*)
            echo "6.0"
            ;;
        *"(6.1)"*)
            echo "6.1"
            ;;
        *"(6.2)"*)
            echo "6.2"
            ;;
        *"(nightly-6.1)"*)
            echo "nightly-6.1"
            ;;
        *"(nightly-next)"*)
            echo "nightly-next"
            ;;
        *"(nightly-main)"*)
            echo "nightly-main"
            ;;
        *)
            return 1
            ;;
    esac
}

# Track whether any files were updated
updated_count=0

parse_url() {
    workflow_url=$1
    # https://github.com/apple/swift-nio/actions/runs/15269806473
    # https://github.com/apple/swift-nio/actions/runs/19234929677/job/54982236271?pr=3442
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

parse_workflow_url() {
    workflow_url=$1
    # https://github.com/apple/swift-nio/actions/runs/15269806473
    # https://github.com/apple/swift-nio/actions/runs/19234929677/job/54982236271?pr=3442
    echo "$workflow_url" | sed -E 's|.*/actions/runs/([0-9]+).*|\1|'
}

fetch_checks_for_pr() {
    pr_url=$1

    "$GH_BIN" pr checks "$pr_url" | grep "Integration tests" | grep -v Construct
}

fetch_checks_for_workflow() {
    repo=$1
    run=$2

    "$GH_BIN" --repo "$repo" run view "$run" | grep "Integration tests" | grep ID | grep -v Construct
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
        ;;
    esac
}

parse_check_for_workflow() {
    check_line=$1

    # Something like:
    # ✓ Integration tests / Integration tests / Linux (5.10) in 5m10s (ID 42942543009)
    echo "$check_line" | sed -En 's/.*ID ([0-9][0-9]*).*/\1/p'
}

parse_check_for_pr() {
    check_line=$1

    # Something like:
    # Integration tests / Integration tests / Linux (5.10)	pass	4m21s	https://github.com/apple/swift-nio/actions/runs/13793783082/job/38580234681
    echo "$check_line" | sed -E 's/.*\(([^\)]+)\).*github\.com\/(.*)\/actions\/runs\/[0-9]+\/job\/([0-9]+)/\3/g'
}

extract_version_from_check_line() {
    check_line=$1

    # Extract version from job name like "Integration tests / Linux (6.0)" or "X Integration tests / Linux (6.0) in 22m31s (ID 123)"
    if version=$(map_version "$check_line"); then
        echo "$version"
        return 0
    fi

    error "Could not extract version from check line: $check_line"
    return 1
}

fetch_check_logs() {
    version=$1
    job=$2

    log "Pulling logs for Swift $version (job $job)"
    # We use `gh api` rather than `gh run view --log` because of https://github.com/cli/cli/issues/5011.
    "$GH_BIN" api "/repos/${repo}/actions/jobs/${job}/logs"
}

update_threshold_file() {
    version=$1
    logs=$2

    threshold_file="$THRESHOLDS_DIR/$version.json"

    # Compute relative path from repo root
    threshold_file_relative="${threshold_file#"$REPO_ROOT"/}"

    # Parse logs and update threshold file
    new_thresholds=$(echo "$logs" | "$ALLOC_LIMITS_SCRIPT" --json)

    if [ -z "$new_thresholds" ]; then
        error "No thresholds extracted from logs for version $version"
        return 1
    fi

    # Compare old and new files (both sorted with jq) and only overwrite if there are substantive differences
    if [ -f "$threshold_file" ]; then
        old_normalized=$("$JQ_BIN" -S . "$threshold_file" 2>/dev/null || echo "")
        new_normalized=$(echo "$new_thresholds" | "$JQ_BIN" -S . 2>/dev/null || echo "")

        if [ "$old_normalized" = "$new_normalized" ]; then
            log "No changes for $threshold_file_relative (skipping)"
            return 0
        fi
    fi

    echo "$new_thresholds" > "$threshold_file"
    log "Updated $threshold_file_relative"
    updated_count=$((updated_count + 1))
}

####

read -r repo_org repo_name type <<< "$(parse_url "$url")"
repo="$repo_org/$repo_name"
log "Processing $type in $repo"

case "$type" in
"PR")
    log "Fetching integration test checks from PR"
    check_lines="$(fetch_checks_for_pr "$url")"

    if [ -z "$check_lines" ]; then
        fatal "Could not locate integration test checks on PR: $url"
    fi
    ;;

"run")
    run="$(parse_workflow_url "$url")"

    log "Fetching integration test checks from workflow run $run"
    check_lines="$(fetch_checks_for_workflow "$repo" "$run")"

    if [ -z "$check_lines" ]; then
        fatal "Could not locate integration test checks on workflow run: $url"
    fi
    ;;

*)
    fatal "Unknown type '$type'"
    ;;
esac

while read -r check_line; do
    version="$(extract_version_from_check_line "$check_line")"

    if [ -z "$version" ]; then
        log "Skipping check line (couldn't extract version): $check_line"
        continue
    fi

    job="$(parse_check "$type" "$check_line")"

    if [ -z "$job" ]; then
        error "Could not extract job ID from check line: $check_line"
        continue
    fi

    logs=$(fetch_check_logs "$version" "$job")

    if [ -z "$logs" ]; then
        log "No logs found for Swift $version (job $job)"
        continue
    fi

    update_threshold_file "$version" "$logs"

done <<< "$check_lines"

if [ "$updated_count" -eq 0 ]; then
    log "Done! No updates necessary"
else
    log "Done! Updated $updated_count threshold file(s)"
fi
