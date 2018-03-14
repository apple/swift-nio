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
echo FOO BAR > "$htdocs/some_file.txt"
for method in sendfile fileio; do
    do_curl "$token" "http://foobar.com/$method/some_file.txt" > "$tmp/out.txt"
    assert_equal_files "$htdocs/some_file.txt" "$tmp/out.txt"
done
stop_server "$token"
