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

function check_does_not_link() {
    local library="$1"
    local binary="$2"

    case "$(uname -s)" in
        Darwin)
            otool -L "$binary" > "${tmp:?"tmp variable not set"}/linked_libs"
            ;;
        Linux)
            ldd "$binary" > "$tmp/linked_libs"
            ;;
        *)
            fail "unsupported OS $(uname -s)"
            ;;
    esac
    echo -n > "$tmp/expected"
    ! grep "$library" "$tmp/linked_libs" > "$tmp/linked_checked_lib"

    assert_equal_files "$tmp/expected" "$tmp/linked_checked_lib"
}

for binary in NIOEchoServer NIOEchoClient NIOChatServer NIOChatClient NIOHTTP1Server; do
    check_does_not_link /Foundation "${bin_path:?"tmp variable not set"}/$binary" # Darwin (old)
    check_does_not_link libFoundation "$bin_path/$binary" # Linux
    check_does_not_link swiftFoundation "$bin_path/$binary" # Darwin (new)
done
