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
echo foo > "$tmp/out_expected"
do_curl "$token" --data-binary "@$tmp/out_expected" --http1.0 \
    "http://foobar.com/dynamic/echo_balloon" > "$tmp/out_actual"
assert_equal_files "$tmp/out_expected" "$tmp/out_actual"
stop_server "$token"
