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
backslash_r=$(echo -e '\r')
cat > "$tmp/expected" <<EOF
HTTP/1.0 400 Bad Request$backslash_r
Content-Length: 0$backslash_r
Connection: Close$backslash_r
X-HTTPServer-Error: strict mode assertion$backslash_r
$backslash_r
EOF
assert_equal_files "$tmp/expected" "$tmp/actual"
stop_server "$token"
