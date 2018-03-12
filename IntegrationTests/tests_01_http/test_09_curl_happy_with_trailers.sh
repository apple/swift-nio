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
server_pid=$(get_server_pid "$token")
backslash_r=$(echo -ne '\r')
cat > "$htdocs/some_file.txt" <<EOF
$server_pid$backslash_r
$server_pid$backslash_r
$server_pid$backslash_r
$server_pid$backslash_r
EOF
do_curl "$token" \
    "http://foobar.com/dynamic/trailers" \
    "http://foobar.com/dynamic/trailers" \
    "http://foobar.com/dynamic/trailers" \
    "http://foobar.com/dynamic/trailers" \
    > "$tmp/out.txt"
assert_equal_files "$htdocs/some_file.txt" "$tmp/out.txt"
stop_server "$token"
