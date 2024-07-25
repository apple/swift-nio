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

function make_package() {
    if [[ ! -d "${tmpdir:?"tmpdir variable not set"}/syscallwrapper/Sources/syscallwrapper/" ]]; then
        mkdir "$tmpdir/syscallwrapper/Sources/syscallwrapper/"
        mv "$tmpdir"/syscallwrapper/Sources/*.swift "$tmpdir/syscallwrapper/Sources/syscallwrapper/"
    fi

    cat > "$tmpdir/syscallwrapper/Package.swift" <<"EOF"
// swift-tools-version:5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "syscallwrapper",
    dependencies: [],
    targets: [
        .target(
            name: "syscallwrapper",
            dependencies: ["CNIOLinux", "CNIODarwin", "NIOCore"]),
        .target(
            name: "CNIOLinux",
            dependencies: [],
            cSettings: [
                .define("_GNU_SOURCE")
            ]),
        .target(
            name: "CNIODarwin",
            dependencies: []),
        // This target does nothing, it just makes imports work.
        .target(
            name: "NIOCore",
            dependencies: []),
    ]
)
EOF
    cp "${here:?"here variable not set"}/../../Tests/NIOPosixTests/SystemCallWrapperHelpers.swift" \
        "$here/../../Sources/NIOCore/BSDSocketAPI.swift" \
        "$here/../../Sources/NIOPosix/BSDSocketAPICommon.swift" \
        "$here/../../Sources/NIOPosix/BSDSocketAPIPosix.swift" \
        "$here/../../Sources/NIOPosix/System.swift" \
        "$here/../../Sources/NIOCore/IO.swift" \
        "$here/../../Sources/NIOCore/IPProtocol.swift" \
        "$here/../../Sources/NIOCore/NIOSendable.swift" \
        "$tmpdir/syscallwrapper/Sources/syscallwrapper"
    cp "$here/../../Sources/NIOPosix/IO.swift" "$tmpdir/syscallwrapper/Sources/syscallwrapper/NIOPosixIO.swift"
    ln -s "$here/../../Sources/CNIOLinux" "$tmpdir/syscallwrapper/Sources"
    ln -s "$here/../../Sources/CNIODarwin" "$tmpdir/syscallwrapper/Sources"
    mkdir "$tmpdir/syscallwrapper/Sources/NIOCore"
    touch "$tmpdir/syscallwrapper/Sources/NIOCore/empty.swift"
    rm -rf "$tmpdir/syscallwrapper/Sources/syscallwrapper/syscallwrapper.swift"
}
