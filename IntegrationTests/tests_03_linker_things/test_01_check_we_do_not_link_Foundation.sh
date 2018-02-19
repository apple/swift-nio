#!/bin/bash

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
