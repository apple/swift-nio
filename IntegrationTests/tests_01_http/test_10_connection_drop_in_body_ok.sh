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
socket=$(get_socket "$token")

kill -0 $server_pid
(
    echo -e 'POST /dynamic/echo HTTP/1.1\r\nContent-Length: 400000\r\n\r\nsome_bytes'
    for f in $(seq 5); do
        echo $f
        sleep 0.1
    done
) | nc -U "$socket"
sleep 0.1
kill -0 $server_pid
stop_server "$token"
