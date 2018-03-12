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
do_curl "$token" "http://foobar.com/dynamic/pid" > "$tmp/out"
for f in $(seq 100); do
    do_curl "$token" "http://foobar.com/dynamic/pid" > "$tmp/out2"
    assert_equal_files "$tmp/out" "$tmp/out2"
done
stop_server "$token"
