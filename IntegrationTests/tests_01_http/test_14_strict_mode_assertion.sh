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
socket=$(get_socket "$token")
echo -e 'GET / HTT\r\n\r\n' | nc -U "$socket" > "$tmp/actual"

if ! grep -q 'HTTP/1.1 400 Bad Request' "$tmp/actual"; then
    fail "couldn't find status line in response"
fi
if ! grep -q 'Content-Length: 0' "$tmp/actual"; then
    fail "couldn't find Content-Length in response"
fi
if ! grep -q 'Connection: close' "$tmp/actual"; then
    fail "couldn't find Connection: close in response"
fi

linecount=$(wc "$tmp/actual")
if [[ $linecount -ne 4 ]]; then
    fail "overlong response"
fi
stop_server "$token"
