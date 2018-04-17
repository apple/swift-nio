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
start_server --disable-half-closure "$token"
server_pid=$(get_server_pid "$token")
socket=$(get_socket "$token")

kill -0 "$server_pid"
echo -e 'GET /dynamic/write-delay/10000 HTTP/1.1\r\n\r\n' | nc -w1 -U "$socket"
sleep 0.2

# note: the way this test would fail is to leak file descriptors (ie. have some
# connections still open 0.2s after the request terminated). `stop_server`
# checks for that, hence there aren't any explicit asserts in here.
stop_server "$token"
