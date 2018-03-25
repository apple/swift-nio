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
start_server "$token" tcp
htdocs=$(get_htdocs "$token")
echo -n '[IPv4]127.0.0.1' > "$tmp/expected_ipv4"
echo -n '[IPv6]::1' > "$tmp/expected_ipv6"
do_curl "$token" "http://localhost:$(get_server_port "$token")/dynamic/client-ip" > "$tmp/actual"
if grep -q '\[IPv4\]127.0.0.1' "$tmp/actual"; then
    true
elif grep -q '\[IPv6\]::1' "$tmp/actual"; then
    true
else
    fail "could not find client IP in $(cat "$tmp/actual")"
fi
stop_server "$token"
