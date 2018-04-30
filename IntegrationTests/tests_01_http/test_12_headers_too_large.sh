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
touch "$tmp/empty"
cr=$(echo -e '\r')
cat > "$tmp/headers_expected" <<EOF
HTTP/1.1 400 Bad Request$cr
Content-Length: 0$cr
Connection: close$cr
$cr
EOF
echo "FOO BAR" > "$htdocs/some_file.txt"
# headers have acceptable size
do_curl "$token" -H "$(python -c 'print "x"*80000'): x" \
    "http://foobar.com/fileio/some_file.txt" > "$tmp/out"
assert_equal_files "$htdocs/some_file.txt" "$tmp/out"

# headers too large
do_curl "$token" -H "$(python -c 'print "x"*90000'): x" \
    -D "$tmp/headers_actual" \
    "http://foobar.com/fileio/some_file.txt" > "$tmp/out"
assert_equal_files "$tmp/empty" "$tmp/out"

if ! grep -q 'HTTP/1.1 400 Bad Request' "$tmp/headers_actual"; then
    fail "couldn't find status line in response"
fi
if ! grep -q 'Content-Length: 0' "$tmp/headers_actual"; then
    fail "couldn't find content-length in response"
fi
if ! grep -q 'Connection: close' "$tmp/headers_actual"; then
    fail "couldn't find connection: close in response"
fi

linecount=$(wc "$tmp/headers_actual")
if [ $linecount -ne 4 ]; then
    fail "overlong response"
fi
stop_server "$token"
