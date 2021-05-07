#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

# This script allows you to consume any Jenkins/alloc counter run output and
# convert it into the right for for the docker-compose script.

set -eu

mode_flag=${1---docker-compose}

function usage() {
    echo >&1 "Usage: $0 [--docker-compose|--export]"
    echo >&1
    echo >&1 "Example:"
    echo >&1 "  # copy the output from the Jenkins CI into your clipboard, then"
    echo >&1 "  pbpaste | $0 --docker-compose"
}

function die() {
    echo >&2 "ERROR: $*"
    exit 1
}

case "$mode_flag" in
    --docker-compose)
        mode=docker
        ;;
    --export)
        mode=export
        ;;
    *)
        usage
        exit 1
        ;;
esac

function allow_slack() {
    raw="$1"
    if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
        die "not a malloc count: '$raw'"
    fi
    if [[ "$raw" -lt 1000 ]]; then
        echo "$raw"
        return
    fi

    allocs=$raw
    while true; do
        allocs=$(( allocs + 1 ))
        if [[ "$allocs" =~ [0-9]+00$ || "$allocs" =~ [0-9]+50$ ]]; then
            echo "$allocs"
            return
        fi
    done
}

grep -e "total number of mallocs" -e ".total_allocations" -e "export MAX_ALLOCS_ALLOWED_" | \
    sed -e "s/: total number of mallocs: /=/g" \
        -e "s/.total_allocations: /=/g" \
        -e "s/info: /test_/g" \
        -e "s/export MAX_ALLOCS_ALLOWED_/test_/g" | \
    grep -Eo 'test_[a-zA-Z0-9_-]+=[0-9]+' | sort | uniq | while read info; do
    test_name=$(echo "$info" | sed "s/test_//g" | cut -d= -f1 )
    allocs=$(allow_slack "$(echo "$info" | cut -d= -f2 | sed "s/ //g")")
    case "$mode" in
        docker)
            echo "      - MAX_ALLOCS_ALLOWED_$test_name=$allocs"
            ;;
        export)
            echo "export MAX_ALLOCS_ALLOWED_$test_name=$allocs"
            ;;
        *)
            die "Unexpected mode: $mode"
            ;;
    esac
done
