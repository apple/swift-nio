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

function plugin_echo_test_suite_begin() {
    echo "Running test suite '$1'"
}

function plugin_echo_test_suite_end() {
    true
}

# test_name
function plugin_echo_test_begin() {
    echo -n "Running test '$1'... "
}

function plugin_echo_test_skip() {
    echo "Skipping test '$1'"
}

function plugin_echo_test_ok() {
    echo "OK (${1}s)"
}

function plugin_echo_test_fail() {
    echo "FAILURE ($1)"
    echo "--- OUTPUT BEGIN ---"
    cat "$2"
    echo "--- OUTPUT  END  ---"
}

function plugin_echo_test_end() {
    true
}

function plugin_echo_summary_ok() {
    echo "OK (ran $1 tests successfully)"
}

function plugin_echo_summary_fail() {
    echo "FAILURE (oks: $1, failures: $2)"
}

function plugin_echo_init() {
    true
}
