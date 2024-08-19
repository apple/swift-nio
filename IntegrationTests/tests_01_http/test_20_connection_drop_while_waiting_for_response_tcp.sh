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

# shellcheck source=IntegrationTests/tests_01_http/defines.sh
source defines.sh

token=$(create_token)
start_server --disable-half-closure "$token" tcp
# shellcheck disable=SC2034
htdocs=$(get_htdocs "$token")
server_pid=$(get_server_pid "$token")
ip=$(get_server_ip "$token")
port=$(get_server_port "$token")

kill -0 "$server_pid" # ignore-unacceptable-language
echo -e 'GET /dynamic/write-delay/10000 HTTP/1.1\r\n\r\n' | do_nc -w1 "$ip" "$port"
sleep 0.2
stop_server "$token"
