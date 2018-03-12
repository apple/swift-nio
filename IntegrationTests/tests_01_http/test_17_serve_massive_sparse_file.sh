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

source defines.sh

token=$(create_token)
start_server "$token"
htdocs=$(get_htdocs "$token")
# create a 3GB sparse file, this is above the 2,147,479,552 mentioned in the
# BUGS section of Linux's sendfile(2) man page.
dd if=/dev/zero of="$htdocs/lots_of_zeroes" seek=$((3 * 1024)) bs=$((1024 * 1024)) count=1
for method in fileio; do
    do_curl "$token" "http://foobar.com/$method/lots_of_zeroes" | shasum > "$tmp/actual_sha"
    echo "bf184d91c8f82092198e4d8e1d029e576dbec3bc  -" > "$tmp/expected_sha"
    assert_equal_files "$tmp/expected_sha" "$tmp/actual_sha"
done
sleep 3 # wait for all the fds to be closed
stop_server "$token"
