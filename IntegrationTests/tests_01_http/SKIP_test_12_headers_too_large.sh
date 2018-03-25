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
HTTP/1.0 431 Request Header Fields Too Large$cr
Content-Length: 0$cr
Connection: Close$cr
X-HTTPServer-Error: too many header bytes seen; overflow detected$cr
$cr
EOF
echo "FOO BAR" > "$htdocs/some_file.txt"
# headers have acceptable size
do_curl "$token" -H "$(python -c 'print "x"*80000'): x" \
    "http://foobar.com/some_file.txt" > "$tmp/out"
assert_equal_files "$htdocs/some_file.txt" "$tmp/out"

# headers too large
do_curl "$token" -H "$(python -c 'print "x"*90000'): x" \
    -D "$tmp/headers_actual" \
    "http://foobar.com/some_file.txt" > "$tmp/out"
assert_equal_files "$tmp/empty" "$tmp/out"
assert_equal_files "$tmp/headers_expected" "$tmp/headers_actual"
stop_server "$token"
