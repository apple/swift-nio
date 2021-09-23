// swift-tools-version:5.2
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
    .target(name: "NIOEmbedded", dependencies: ["NIOCore", "_NIODataStructures"]),
    .target(name: "NIOPosix",
            dependencies: ["CNIOLinux",
                           "CNIODarwin",
                           "CNIOWindows",
                           "NIOConcurrencyHelpers",
                           "NIOCore",
                           "_NIODataStructures"]),
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
    .target(name: "NIOEchoServer",
            dependencies: ["NIOPosix", "NIOCore", "NIOConcurrencyHelpers"]),
    .target(name: "NIOEchoClient",
            dependencies: ["NIOPosix", "NIOCore", "NIOConcurrencyHelpers"]),
    .target(name: "NIOHTTP1Server",
            dependencies: ["NIOPosix", "NIOCore", "NIOHTTP1", "NIOConcurrencyHelpers"]),
    .target(name: "NIOHTTP1Client",
            dependencies: ["NIOPosix", "NIOCore", "NIOHTTP1", "NIOConcurrencyHelpers"]),
    .target(name: "CNIOHTTPParser"),
    .target(name: "NIOTLS", dependencies: ["NIO", "NIOCore"]),
    .target(name: "NIOChatServer",
            dependencies: ["NIOPosix", "NIOCore", "NIOConcurrencyHelpers"]),
    .target(name: "NIOChatClient",
            dependencies: ["NIOPosix", "NIOCore", "NIOConcurrencyHelpers"]),
    .target(name: "NIOWebSocket",
            dependencies: ["NIO", "NIOCore", "NIOHTTP1", "CNIOSHA1"]),
    .target(name: "NIOWebSocketServer",
            dependencies: ["NIOPosix", "NIOCore", "NIOHTTP1", "NIOWebSocket"]),
    .target(name: "NIOWebSocketClient",
            dependencies: ["NIOPosix", "NIOCore", "NIOHTTP1", "NIOWebSocket"]),
    .target(name: "NIOPerformanceTester",
            dependencies: ["NIOPosix", "NIOCore", "NIOEmbedded", "NIOHTTP1", "NIOFoundationCompat", "NIOWebSocket"]),
    .target(name: "NIOMulticastChat",
            dependencies: ["NIOPosix", "NIOCore"]),
    .target(name: "NIOUDPEchoServer",
            dependencies: ["NIOPosix", "NIOCore"]),
    .target(name: "NIOUDPEchoClient",
            dependencies: ["NIOPosix", "NIOCore"]),
    .target(name: "NIOTestUtils",
            dependencies: ["NIOPosix", "NIOCore", "NIOEmbedded", "NIOHTTP1"]),
    .target(name: "NIOCrashTester",
            dependencies: ["NIOPosix", "NIOCore", "NIOEmbedded", "NIOHTTP1", "NIOWebSocket", "NIOFoundationCompat"]),
    .target(name: "NIOAsyncAwaitDemo",
            dependencies: ["NIOPosix", "NIOCore", "NIOHTTP1"]),
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
    ],
    targets: targets
)
