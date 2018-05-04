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
socket=$(get_socket "$token")
echo -ne 'HTTP/1.1 200 OK\r\ncontent-length: 12\r\n\r\nHello World!' > "$tmp/expected"
for f in $(seq 2000); do
    echo -e 'GET / HTTP/1.1\r\n\r\n' | nc -w10 -U "$socket" > "$tmp/actual"
    assert_equal_files "$tmp/expected" "$tmp/actual"
done
stop_server "$token"
