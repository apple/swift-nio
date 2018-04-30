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
start_server --disable-half-closure "$token" tcp
htdocs=$(get_htdocs "$token")
server_pid=$(get_server_pid "$token")
ip=$(get_server_ip "$token")
port=$(get_server_port "$token")

kill -0 $server_pid
# try to simulate a TCP connection reset, works really well on Darwin but not on
# Linux over loopback. On Linux however
# `test_19_connection_drop_while_waiting_for_response_uds.sh` tests a very
# similar situation.
yes "$( echo -e 'GET /dynamic/write-delay HTTP/1.1\r\n\r\n')" | nc "$ip" "$port" > /dev/null & sleep 0.5; kill -9 $!
sleep 0.2
stop_server "$token"
