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

swift build
echo -ne "::: HELLO\n::: WORLD\n:::\n" > "${tmp:?"tmp variable not set"}/file"
lines_in_file="$(wc -l < "$tmp/file"  | tr -d '\t ')"
function echo_request_close() {
    echo -e 'GET /fileio/file HTTP/1.1\r\nconnection: close\r\nhost: stdio\r\n\r\n'
}

function echo_request_keep_alive() {
    echo -e 'GET /fileio/file HTTP/1.1\r\nconnection: keep-alive\r\nhost: stdio\r\n\r\n'
}

echo_request_close | "$(swift build --show-bin-path)/NIOHTTP1Server" - "$tmp" | cat > "$tmp/output"

tail -n "$lines_in_file" "$tmp/output" > "$tmp/output-just-file"
assert_equal_files "$tmp/file" "$tmp/output-just-file"

how_many=100
{
    for _ in $(seq "$(( how_many - 1 ))" ); do
        echo_request_keep_alive
    done
    echo_request_close
} | "$(swift build --show-bin-path)/NIOHTTP1Server" - "$tmp" | grep ^::: > "$tmp/multi-actual"

set +o pipefail # we know that 'yes' will fail with SIGPIPE
yes "$(cat "$tmp/file")" | head -n $(( lines_in_file * how_many )) > "$tmp/multi-expected"
assert_equal_files "$tmp/multi-expected" "$tmp/multi-actual"
