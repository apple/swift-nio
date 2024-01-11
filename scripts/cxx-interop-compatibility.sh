#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu

sourcedir=$(pwd)
workingdir=$(mktemp -d)
projectname=$(basename $workingdir)

cd $workingdir
swift package init

cat << EOF > Package.swift
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "interop",
    products: [
        .library(
            name: "interop",
            targets: ["interop"]
        ),
    ],
    dependencies: [
        .package(path: "$sourcedir")
    ],
    targets: [
        .target(
            name: "interop",
            // Depend on all products of swift-nio to make sure they're all
            // compatible with cxx interop.
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOTestUtils", package: "swift-nio"),
                .product(name: "_NIOConcurrency", package: "swift-nio")
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        )
    ]
)
EOF

cat << EOF > Sources/$projectname/$(echo $projectname | tr . _).swift
import NIO
import NIOCore
import NIOConcurrencyHelpers
import NIOTLS
import NIOEmbedded
import NIOPosix
import NIOHTTP1
import NIOFoundationCompat
import NIOWebSocket
import NIOTestUtils
import _NIOConcurrency
EOF

swift build
