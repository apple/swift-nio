#!/bin/bash

set -eu

source defines.sh

swift_binary=swift
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ ! -z "${SWIFT_EXEC-}" ]]; then
    swift_binary="$(dirname "$SWIFT_EXEC")/swift"
elif [[ "$(uname -s)" == "Linux" ]]; then
    swift_binary=$(which swift)
fi

tmpdir=$(mktemp -d /tmp/.swift-nio-syscall-wrappers-sh-test_XXXXXX)
mkdir "$tmpdir/syscallwrapper"
cd "$tmpdir/syscallwrapper"
swift package init --type=executable
cat > "$tmpdir/syscallwrapper/Sources/syscallwrapper/main.swift" <<EOF
#if os(macOS) || os(tvOS) || os(iOS) || os(watchOS)
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
