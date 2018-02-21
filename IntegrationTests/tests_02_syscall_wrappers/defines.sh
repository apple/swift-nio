#!/bin/bash

set -eu

function make_package() {
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
            dependencies: ["CNIOLinux", "CNIODarwin"]),
        .target(
            name: "CNIOLinux",
            dependencies: []),
        .target(
            name: "CNIODarwin",
            dependencies: []),
    ]
)
EOF
    cp "$here/../../Tests/NIOTests/SystemCallWrapperHelpers.swift" \
        "$here/../../Sources/NIO/System.swift" \
        "$here/../../Sources/NIO/IO.swift" \
        "$tmpdir/syscallwrapper/Sources/syscallwrapper"
    ln -s "$here/../../Sources/CNIOLinux" "$tmpdir/syscallwrapper/Sources"
    ln -s "$here/../../Sources/CNIODarwin" "$tmpdir/syscallwrapper/Sources"
}
