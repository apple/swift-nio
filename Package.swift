// swift-tools-version:5.0
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
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
    .target(name: "_NIO1APIShims",
            dependencies: ["NIO", "NIOHTTP1", "NIOTLS", "NIOFoundationCompat", "NIOWebSocket"]),
    .target(name: "NIO",
            dependencies: ["CNIOLinux",
                           "CNIODarwin",
                           "NIOConcurrencyHelpers",
                           "CNIOAtomics",
                           "CNIOSHA1"]),
    .target(name: "NIOFoundationCompat", dependencies: ["NIO"]),
    .target(name: "CNIOAtomics", dependencies: []),
    .target(name: "CNIOSHA1", dependencies: []),
    .target(name: "CNIOLinux", dependencies: []),
    .target(name: "CNIODarwin", dependencies: []),
    .target(name: "NIOConcurrencyHelpers",
            dependencies: ["CNIOAtomics"]),
    .target(name: "NIOHTTP1",
            dependencies: ["NIO", "NIOConcurrencyHelpers", "CNIOHTTPParser"]),
    .target(name: "NIOEchoServer",
            dependencies: ["NIO", "NIOConcurrencyHelpers"]),
    .target(name: "NIOEchoClient",
            dependencies: ["NIO", "NIOConcurrencyHelpers"]),
    .target(name: "NIOHTTP1Server",
            dependencies: ["NIO", "NIOHTTP1", "NIOConcurrencyHelpers"]),
    .target(name: "NIOHTTP1Client",
            dependencies: ["NIO", "NIOHTTP1", "NIOConcurrencyHelpers"]),
    .target(name: "CNIOHTTPParser"),
    .target(name: "NIOTLS", dependencies: ["NIO"]),
    .target(name: "NIOChatServer",
            dependencies: ["NIO", "NIOConcurrencyHelpers"]),
    .target(name: "NIOChatClient",
            dependencies: ["NIO", "NIOConcurrencyHelpers"]),
    .target(name: "NIOWebSocket",
            dependencies: ["NIO", "NIOHTTP1", "CNIOSHA1"]),
    .target(name: "NIOWebSocketServer",
            dependencies: ["NIO", "NIOHTTP1", "NIOWebSocket"]),
    .target(name: "NIOWebSocketClient",
            dependencies: ["NIO", "NIOHTTP1", "NIOWebSocket"]),
    .target(name: "NIOPerformanceTester",
            dependencies: ["NIO", "NIOHTTP1", "NIOFoundationCompat", "NIOWebSocket"]),
    .target(name: "NIOMulticastChat",
            dependencies: ["NIO"]),
    .target(name: "NIOUDPEchoServer",
            dependencies: ["NIO"]),
    .target(name: "NIOUDPEchoClient",
            dependencies: ["NIO"]),
    .target(name: "NIOTestUtils",
            dependencies: ["NIO", "NIOHTTP1"]),
    .testTarget(name: "NIOTests",
                dependencies: ["NIO", "NIOFoundationCompat", "NIOTestUtils", "NIOConcurrencyHelpers"]),
    .testTarget(name: "NIOConcurrencyHelpersTests",
                dependencies: ["NIOConcurrencyHelpers"]),
    .testTarget(name: "NIOHTTP1Tests",
                dependencies: ["NIOHTTP1", "NIOFoundationCompat", "NIOTestUtils"]),
    .testTarget(name: "NIOTLSTests",
                dependencies: ["NIO", "NIOTLS", "NIOFoundationCompat"]),
    .testTarget(name: "NIOWebSocketTests",
                dependencies: ["NIO", "NIOWebSocket"]),
    .testTarget(name: "NIOTestUtilsTests",
                dependencies: ["NIOTestUtils"]),
]

let package = Package(
    name: "swift-nio",
    products: [
        .executable(name: "NIOEchoServer", targets: ["NIOEchoServer"]),
        .executable(name: "NIOEchoClient", targets: ["NIOEchoClient"]),
        .executable(name: "NIOChatServer", targets: ["NIOChatServer"]),
        .executable(name: "NIOChatClient", targets: ["NIOChatClient"]),
        .executable(name: "NIOHTTP1Server", targets: ["NIOHTTP1Server"]),
        .executable(name: "NIOHTTP1Client", targets: ["NIOHTTP1Client"]),
        .executable(name: "NIOWebSocketServer", targets: ["NIOWebSocketServer"]),
        .executable(name: "NIOWebSocketClient", targets: ["NIOWebSocketClient"]),
        .executable(name: "NIOPerformanceTester",
                    targets: ["NIOPerformanceTester"]),
        .executable(name: "NIOMulticastChat", targets: ["NIOMulticastChat"]),
        .executable(name: "NIOUDPEchoServer", targets: ["NIOUDPEchoServer"]),
        .executable(name: "NIOUDPEchoClient", targets: ["NIOUDPEchoClient"]),
        .library(name: "NIO", targets: ["NIO"]),
        .library(name: "_NIO1APIShims", targets: ["_NIO1APIShims"]),
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
