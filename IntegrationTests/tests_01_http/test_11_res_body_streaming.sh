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

cat > "$tmp/expected" <<EOF
line 1
line 2
line 3
line 4
line 5
line 6
line 7
EOF

{ do_curl "$token" -N http://test/dynamic/continuous || true; } | head -7 > "$tmp/actual"
assert_equal_files "$tmp/expected" "$tmp/actual"

sleep 1 # need to have the next write fail
stop_server "$token"
