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

# shellcheck source=IntegrationTests/tests_01_http/defines.sh
source defines.sh

swift_binary=swiftc
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ -n "${SWIFT_EXEC-}" ]]; then
    swift_binary="$(dirname "$SWIFT_EXEC")/swiftc"
elif [[ "$(uname -s)" == "Linux" ]]; then
    swift_binary=$(which swiftc)
fi

cp "$here/../../Sources/NIOConcurrencyHelpers/"{lock,NIOLock}.swift "${tmp:?"tmp variable not set"}"
cat > "$tmp/main.swift" <<"EOF"
let l = NIOLock()
l.lock()
l.lock()
EOF

"$swift_binary" -o "$tmp/test" "$tmp/main.swift" "$tmp/"{lock,NIOLock}.swift
if "$tmp/test"; then
    fail "should have crashed"
else
    exit_code=$?
    
    # expecting irrecoverable error as process should be terminated through fatalError/precondition/assert
    architecture=$(uname -m)
    if [[ $architecture =~ ^(arm|aarch) ]]; then
        assert_equal $exit_code $(( 128 + 5 )) # 5 == SIGTRAP aka trace trap, expected on ARM
    elif [[ $architecture =~ ^(x86|i386) ]]; then
        assert_equal $exit_code $(( 128 + 4 ))  # 4 == SIGILL aka illegal instruction, expected on x86
    else
        fail "unknown CPU architecture for which we don't know the expected signal for a crash"
    fi
fi
