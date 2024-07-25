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

swift_binary=swift
# shellcheck disable=SC2034 # Used in defines.sh
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ -n "${SWIFT_EXEC-}" ]]; then
    swift_binary="$(dirname "$SWIFT_EXEC")/swift"
elif [[ "$(uname -s)" == "Linux" ]]; then
    swift_binary=$(which swift)
fi

tmpdir=$(mktemp -d /tmp/.swift-nio-syscall-wrappers-sh-test_XXXXXX)
mkdir "$tmpdir/syscallwrapper"
cd "$tmpdir/syscallwrapper"
swift package init --type=executable

main_path="$tmpdir/syscallwrapper/Sources/main.swift"
if [[ -d "$tmpdir/syscallwrapper/Sources/syscallwrapper/" ]]; then
    main_path="$tmpdir/syscallwrapper/Sources/syscallwrapper/main.swift"
fi

cat > "$main_path" <<EOF
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
public typealias IOVector = iovec
runStandalone()
EOF

make_package

"$swift_binary" run -c release -Xswiftc -DRUNNING_INTEGRATION_TESTS

rm -rf "$tmpdir"
