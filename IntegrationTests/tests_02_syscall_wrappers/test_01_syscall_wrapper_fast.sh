#!/bin/bash

set -eu

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

cat > "$tmpdir/syscallwrapper/Package.swift" <<"EOF"
// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "syscallwrapper",
    dependencies: [],
    targets: [
        .target(
            name: "syscallwrapper",
            dependencies: ["CNIOLinux"]),
        .target(
            name: "CNIOLinux",
            dependencies: []),
    ]
)
EOF

cp "$here/../../Tests/NIOTests/SystemCallWrapperHelpers.swift" \
    "$here/../../Sources/NIO/System.swift" \
    "$here/../../Sources/NIO/IO.swift" \
    "$tmpdir/syscallwrapper/Sources/syscallwrapper"
ln -s "$here/../../Sources/CNIOLinux" "$tmpdir/syscallwrapper/Sources"
"$swift_binary" run -c release -Xswiftc -DRUNNING_INTEGRATION_TESTS

rm -rf "$tmpdir"
