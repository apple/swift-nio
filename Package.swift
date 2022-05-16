// swift-tools-version:5.4
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import PackageDescription

var targets: [PackageDescription.Target] = [
    .target(name: "NIOCore",
            dependencies: ["NIOConcurrencyHelpers", "CNIOLinux"]),
    .target(name: "_NIODataStructures"),
    .target(name: "NIOEmbedded",
            dependencies: ["NIOCore",
                           "NIOConcurrencyHelpers",
                           "_NIODataStructures"]),
    .target(name: "NIOPosix",
            dependencies: ["CNIOLinux",
                           "CNIODarwin",
                           "CNIOWindows",
                           "NIOConcurrencyHelpers",
                           "NIOCore",
                           "_NIODataStructures",
                           .product(name: "SystemPackage", package: "swift-system")]),
    .target(name: "NIO",
            dependencies: ["NIOCore",
                           "NIOEmbedded",
                           "NIOPosix"]),
    .target(name: "_NIOConcurrency",
            dependencies: ["NIO", "NIOCore"]),
    .target(name: "NIOFoundationCompat", dependencies: ["NIO", "NIOCore"]),
    .target(name: "CNIOAtomics", dependencies: []),
    .target(name: "CNIOSHA1", dependencies: []),
    .target(name: "CNIOLinux", dependencies: []),
    .target(name: "CNIODarwin", dependencies: [], cSettings: [.define("__APPLE_USE_RFC_3542")]),
    .target(name: "CNIOWindows", dependencies: []),
    .target(name: "NIOConcurrencyHelpers",
            dependencies: ["CNIOAtomics"]),
    .target(name: "NIOHTTP1",
            dependencies: ["NIO", "NIOCore", "NIOConcurrencyHelpers", "CNIOHTTPParser"]),
    .executableTarget(name: "NIOEchoServer",
                      dependencies: ["NIOPosix", "NIOCore", "NIOConcurrencyHelpers"],
                      exclude: ["README.md"]),
    .executableTarget(name: "NIOEchoClient",
                      dependencies: ["NIOPosix", "NIOCore", "NIOConcurrencyHelpers"],
                      exclude: ["README.md"]),
    .executableTarget(name: "NIOHTTP1Server",
                      dependencies: ["NIOPosix", "NIOCore", "NIOHTTP1", "NIOConcurrencyHelpers"],
                      exclude: ["README.md"]),
    .executableTarget(name: "NIOHTTP1Client",
                      dependencies: ["NIOPosix", "NIOCore", "NIOHTTP1", "NIOConcurrencyHelpers"],
                      exclude: ["README.md"]),
    .target(name: "CNIOHTTPParser"),
    .target(name: "NIOTLS", dependencies: ["NIO", "NIOCore"]),
    .executableTarget(name: "NIOChatServer",
                      dependencies: ["NIOPosix", "NIOCore", "NIOConcurrencyHelpers"],
                      exclude: ["README.md"]),
    .executableTarget(name: "NIOChatClient",
                      dependencies: ["NIOPosix", "NIOCore", "NIOConcurrencyHelpers"],
                      exclude: ["README.md"]),
    .target(name: "NIOWebSocket",
            dependencies: ["NIO", "NIOCore", "NIOHTTP1", "CNIOSHA1"]),
    .executableTarget(name: "NIOWebSocketServer",
                      dependencies: ["NIOPosix", "NIOCore", "NIOHTTP1", "NIOWebSocket"],
                      exclude: ["README.md"]),
    .executableTarget(name: "NIOWebSocketClient",
                      dependencies: ["NIOPosix", "NIOCore", "NIOHTTP1", "NIOWebSocket"],
                      exclude: ["README.md"]),
    .executableTarget(name: "NIOPerformanceTester",
            dependencies: ["NIOPosix", "NIOCore", "NIOEmbedded", "NIOHTTP1", "NIOFoundationCompat", "NIOWebSocket"]),
    .executableTarget(name: "NIOMulticastChat",
            dependencies: ["NIOPosix", "NIOCore"]),
    .executableTarget(name: "NIOUDPEchoServer",
                      dependencies: ["NIOPosix", "NIOCore"],
                      exclude: ["README.md"]),
    .executableTarget(name: "NIOUDPEchoClient",
                      dependencies: ["NIOPosix", "NIOCore"],
                      exclude: ["README.md"]),
    .target(name: "NIOTestUtils",
            dependencies: ["NIOPosix", "NIOCore", "NIOEmbedded", "NIOHTTP1"]),
    .executableTarget(name: "NIOCrashTester",
            dependencies: ["NIOPosix", "NIOCore", "NIOEmbedded", "NIOHTTP1", "NIOWebSocket", "NIOFoundationCompat"]),
    .executableTarget(name: "NIOAsyncAwaitDemo",
            dependencies: ["NIOPosix", "NIOCore", "NIOHTTP1"]),
    .testTarget(name: "NIOCoreTests",
                dependencies: ["NIOCore", "NIOEmbedded", "NIOFoundationCompat"]),
    .testTarget(name: "NIOEmbeddedTests",
                dependencies: ["NIOConcurrencyHelpers", "NIOCore", "NIOEmbedded"]),
    .testTarget(name: "NIOPosixTests",
                dependencies: ["NIOPosix", "NIOCore", "NIOFoundationCompat", "NIOTestUtils", "NIOConcurrencyHelpers", "NIOEmbedded"]),
    .testTarget(name: "NIOConcurrencyHelpersTests",
                dependencies: ["NIOConcurrencyHelpers", "NIOCore"]),
    .testTarget(name: "NIODataStructuresTests",
                dependencies: ["_NIODataStructures"]),
    .testTarget(name: "NIOHTTP1Tests",
                dependencies: ["NIOCore", "NIOEmbedded", "NIOPosix", "NIOHTTP1", "NIOFoundationCompat", "NIOTestUtils"]),
    .testTarget(name: "NIOTLSTests",
                dependencies: ["NIOCore", "NIOEmbedded", "NIOTLS", "NIOFoundationCompat"]),
    .testTarget(name: "NIOWebSocketTests",
                dependencies: ["NIOCore", "NIOEmbedded", "NIOWebSocket"]),
    .testTarget(name: "NIOTestUtilsTests",
                dependencies: ["NIOTestUtils", "NIOCore", "NIOEmbedded", "NIOPosix"]),
    .testTarget(name: "NIOFoundationCompatTests",
                dependencies: ["NIOCore", "NIOFoundationCompat"]),
    .testTarget(name: "NIOTests",
                dependencies: ["NIO"]),
]

let package = Package(
    name: "swift-nio",
    products: [
        .library(name: "NIOCore", targets: ["NIOCore"]),
        .library(name: "NIO", targets: ["NIO"]),
        .library(name: "NIOEmbedded", targets: ["NIOEmbedded"]),
        .library(name: "NIOPosix", targets: ["NIOPosix"]),
        .library(name: "_NIOConcurrency", targets: ["_NIOConcurrency"]),
        .library(name: "NIOTLS", targets: ["NIOTLS"]),
        .library(name: "NIOHTTP1", targets: ["NIOHTTP1"]),
        .library(name: "NIOConcurrencyHelpers", targets: ["NIOConcurrencyHelpers"]),
        .library(name: "NIOFoundationCompat", targets: ["NIOFoundationCompat"]),
        .library(name: "NIOWebSocket", targets: ["NIOWebSocket"]),
        .library(name: "NIOTestUtils", targets: ["NIOTestUtils"]),
    ],
    dependencies: [
        .package(
            /// Using open pull request apple/swift-system#82:
            ///
            /// ```
            /// $ git ls-remote https://github.com/apple/swift-system refs/pull/82/head
            /// 5d3519dcef5c4a650c34b7a9bec70942d7975d22        refs/pull/82/head
            /// ```
            ///
            /// If/when the above pull request is merged we should nail this down to a released version.
            url: "https://github.com/apple/swift-system",
            // .upToNextMajor(from: "1.1.1")
            .branchItem("refs/pull/82/head")
        ),
    ],
    targets: targets
)
