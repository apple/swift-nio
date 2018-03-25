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
base="s/o/m/e/r/a/n/d/o/m/f/o/l/d/e/r"
mkdir -p "$htdocs/$base"
dd if=/dev/urandom of="$htdocs/$base/random.bytes" bs=$((1024 * 1024)) count=2
for method in sendfile fileio; do
    do_curl "$token" "http://foobar.com/$method/$base/random.bytes" > "$tmp/random.bytes"
    assert_equal_files "$htdocs/$base/random.bytes" "$tmp/random.bytes"
done
stop_server "$token"
