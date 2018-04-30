#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu

shopt -s nullglob

here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
tmp=$(mktemp -d /tmp/.swift-nio-http1-server-sh-tests_XXXXXX)

# start_time
function time_diff_to_now() {
    echo "$(( $(date +%s) - $1 ))"
}

function plugins_do() {
    local method
    method="$1"
    shift
    for plugin in $plugins; do
        cd "$orig_cwd"
        "plugin_${plugin}_${method}" "$@"
        cd - > /dev/null
    done
}

source "$here/plugin_echo.sh"
source "$here/plugin_junit_xml.sh"

plugins="echo"
plugin_opts_ind=0
if [[ "${1-default}" == "--junit-xml" ]]; then
    plugins="echo junit_xml"
    plugin_opts_ind=2
fi

function usage() {
    echo >&2 "Usage: $0 [OPTIONS]"
    echo >&2
    echo >&2 "OPTIONS:"
    echo >&2 "  -f FILTER: Only run tests matching FILTER (regex)"
}

orig_cwd=$(pwd)
cd "$here"

plugins_do init "$@"
shift $plugin_opts_ind

filter="."
verbose=false
show_info=false
while getopts "f:vi" opt; do
    case $opt in
        f)
            filter="$OPTARG"
            ;;
        v)
            verbose=true
            ;;
        i)
            show_info=true
            ;;
        \?)
            usage
            exit 1
            ;;
    esac
done

function run_test() {
    if $verbose; then
        "$@" 2>&1 | tee -a "$out"
        # we need to return the return value of the first command
        return ${PIPESTATUS[0]}
    else
        "$@" >> "$out" 2>&1
    fi
}

exec 3>&1 4>&2 # copy stdout/err to fd 3/4 to we can output control messages
cnt_ok=0
cnt_fail=0
for f in tests_*; do
    suite_ok=0
    suite_fail=0
    plugins_do test_suite_begin "$f"
    start_suite=$(date +%s)
    cd "$f"
    for t in test_*.sh; do
        if [[ ! "$f/$t" =~ $filter ]]; then
            plugins_do test_skip "$t"
            continue
        fi
        out=$(mktemp "$tmp/test.out_XXXXXX")
        test_tmp=$(mktemp -d "$tmp/test.tmp_XXXXXX")
        plugins_do test_begin "$t" "$f"
        start=$(date +%s)
        if run_test "$here/run-single-test.sh" "$here/$f/$t" "$test_tmp" "$here/.." "$show_info"; then
            plugins_do test_ok "$(time_diff_to_now $start)"
            suite_ok=$((suite_ok+1))
            if $verbose; then
                cat "$out"
            fi
        else
            plugins_do test_fail "$(time_diff_to_now $start)" "$out"
            suite_fail=$((suite_fail+1))
        fi
        rm "$out"
        rm -rf "$test_tmp"
        plugins_do test_end
    done
    cnt_ok=$((cnt_ok + suite_ok))
    cnt_fail=$((cnt_fail + suite_fail))
    cd ..
    plugins_do test_suite_end "$(time_diff_to_now $start_suite)" "$suite_ok" "$suite_fail"
done

rm -rf "$tmp"


# report
if [[ $cnt_fail > 0 ]]; then
    # kill leftovers (the whole process group)
    trap '' TERM
    kill 0

    plugins_do summary_fail "$cnt_ok" "$cnt_fail"
else
    plugins_do summary_ok "$cnt_ok" "$cnt_fail"
fi

if [[ $cnt_fail > 0 ]]; then
    exit 1
else
    exit 0
fi
