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
dd if=/dev/urandom of="$tmp/random.bytes" bs=$((64*1024)) count=1
do_curl "$token" -X POST --header "Transfer-Encoding: chunked" \
    --data-binary "@$tmp/random.bytes" \
    "http://foobar.com/dynamic/echo" > "$tmp/random.bytes.out"
cmp "$tmp/random.bytes" "$tmp/random.bytes.out"
stop_server "$token"
