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

set -eu

source defines.sh

swift_binary=swiftc
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ ! -z "${SWIFT_EXEC-}" ]]; then
    swift_binary="$(dirname "$SWIFT_EXEC")/swiftc"
elif [[ "$(uname -s)" == "Linux" ]]; then
    swift_binary=$(which swiftc)
fi

cp "$here/../../Sources/NIOConcurrencyHelpers/lock.swift" "$tmp"
cat > "$tmp/main.swift" <<"EOF"
let l = Lock()
l.lock()
l.lock()
EOF

"$swift_binary" -o "$tmp/test" "$tmp/main.swift" "$tmp/lock.swift"
if "$tmp/test"; then
    fail "should have crashed"
else
    exit_code=$?
    assert_equal $(( 128 + 4 )) $exit_code  # 4 == SIGILL
fi
