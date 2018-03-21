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

function check_does_not_link() {
    library="$1"
    binary="$1"

    case "$(uname -s)" in
        Darwin)
            assert_equal "" "$(otool -L "$binary" | grep "/$library")"
            ;;
        Linux)
            assert_equal "" "$($ldd "$binary" | grep "lib$library")"
            ;;
        *)
            fail "unsupported OS $(uname -s)"
            ;;
    esac
}

for binary in NIOEchoServer NIOEchoClient NIOChatServer NIOChatClient NIOHTTP1Server; do
    check_does_not_link Foundation "$bin_path/$binary"
done
