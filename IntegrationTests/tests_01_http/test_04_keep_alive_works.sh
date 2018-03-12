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
server_pid=$(get_server_pid "$token")
echo -n \
    "$server_pid$server_pid$server_pid$server_pid$server_pid$server_pid$server_pid$server_pid$server_pid$server_pid" \
    > "$tmp/out_expected"
do_curl "$token" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    "http://foobar.com/dynamic/pid" \
    > "$tmp/out_actual"
assert_equal_files "$tmp/out_expected" "$tmp/out_actual"
stop_server "$token"
