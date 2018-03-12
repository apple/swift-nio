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

junit_testsuite_time=0

function junit_output_write() {
    extra_flags=""
    if [[ "$1" == "-n" ]]; then
        extra_flags="-n"
        shift
    fi
    test -n "$junit_xml_output"
    echo $extra_flags "$*" >> "$junit_xml_output"
}

function junit_output_cat() {
    cat "$@" >> "$junit_xml_output"
}

# search, replace
function junit_output_replace() {
    test -n "$junit_xml_output"
    case "$(uname -s)" in
        Linux)
            sed -i "s/$1/$2/g" "$junit_xml_output"
            ;;
        *)
            sed -i "" "s/$1/$2/g" "$junit_xml_output"
            ;;
    esac
}

function plugin_junit_xml_test_suite_begin() {
    junit_testsuite_time=0
    junit_output_write "<testsuite name='$1' hostname='$(hostname)' "\
"timestamp='$(date -u +"%Y-%m-%dT%H:%M:%S")' tests='XXX-TESTS-XXX' "\
"failures='XXX-FAILURES-XXX' time='XXX-TIME-XXX' errors='0' id='$(date +%s)'"\
" package='NIOIntegrationTests.$1'>"
}

function plugin_junit_xml_test_suite_end() {
    junit_repl_success_and_fail "$1" "$2"
    junit_output_write "</testsuite>"
}

# test_name
function plugin_junit_xml_test_begin() {
    junit_output_write -n "  <testcase classname='NIOIntegrationTests.$2' name='$1'"
}

function plugin_junit_xml_test_skip() {
    true
}

function plugin_junit_xml_test_ok() {
    time_ms=$1
    junit_output_write " time='$time_ms'>"
    junit_testsuite_time=$((junit_testsuite_time + time_ms))
}

function plugin_junit_xml_test_fail() {
    time_ms=$1
    junit_output_write " time='$time_ms'>"
    junit_output_write "  <failure type='test_fail'>"
    junit_output_write "    <system-out>"
    junit_output_write '      <![CDATA['
    junit_output_cat "$2"
    junit_output_write '      ]]>'
    junit_output_write "    </system-out>"
    junit_output_write "  </failure>"
}

function plugin_junit_xml_test_end() {
    junit_output_write "  </testcase>"
}

function junit_repl_success_and_fail() {
    junit_output_replace XXX-TESTS-XXX "$(($1 + $2))"
    junit_output_replace XXX-FAILURES-XXX "$2"
    junit_output_replace XXX-TIME-XXX "$junit_testsuite_time"
}

function plugin_junit_xml_summary_ok() {
    junit_output_write "</testsuites>"
}

function plugin_junit_xml_summary_fail() {
    junit_output_write "</testsuites>"
}

function plugin_junit_xml_init() {
    junit_xml_output=""
    for f in "$@"; do
        if [[ "$junit_xml_output" = "PLACEHOLDER" ]]; then
            junit_xml_output="$f"
        fi
        if [[ "$f" == "--junit-xml" && -z "$junit_xml_output" ]]; then
            junit_xml_output="PLACEHOLDER"
        fi
    done

    if [[ -z "$junit_xml_output" || "$junit_xml_output" = "PLACEHOLDER" ]]; then
        echo >&2 "ERROR: you need to specify the output after the --junit-xml argument"
        false
    fi
    echo "<testsuites>" > "$junit_xml_output"
}
