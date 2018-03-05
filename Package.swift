// swift-tools-version:4.0

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

let package = Package(
    name: "swift-nio",
    products: [
        .library(name: "NIO", targets: ["NIO"]),
        .library(name: "NIOTLS", targets: ["NIOTLS"]),
        .library(name: "NIOHTTP1", targets: ["NIOHTTP1"]),
        .library(name: "NIOConcurrencyHelpers", targets: ["NIOConcurrencyHelpers"]),
        .library(name: "NIOFoundationCompat", targets: ["NIOFoundationCompat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-zlib-support.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "NIO",
            dependencies: ["CNIOLinux", "CNIODarwin", "NIOConcurrencyHelpers", "CNIOAtomics", "NIOPriorityQueue"]),
        .target(
            name: "NIOFoundationCompat",
            dependencies: ["NIO"]),
        .target(
            name: "CNIOAtomics",
            dependencies: []),
        .target(
            name: "CNIOLinux",
            dependencies: []),
        .target(
            name: "CNIODarwin",
            dependencies: []),
        .target(
            name: "NIOConcurrencyHelpers",
            dependencies: ["CNIOAtomics"]),
        .target(
            name: "NIOPriorityQueue",
            dependencies: []),
        .target(
            name: "NIOHTTP1",
            dependencies: ["NIO", "NIOConcurrencyHelpers", "CNIOHTTPParser", "CNIOZlib"]),
        .target(
            name: "CNIOHTTPParser",
            dependencies: []),
        .target(
            name: "CNIOZlib",
            dependencies: []),
        .target(
            name: "NIOTLS",
            dependencies: ["NIO"]),

        // MARK:- Sample code.

        .target(
            name: "NIOChatServer",
            dependencies: ["NIO", "NIOConcurrencyHelpers"]),
        .target(
            name: "NIOChatClient",
            dependencies: ["NIO", "NIOConcurrencyHelpers"]),
        .target(
            name: "NIOEchoServer",
            dependencies: ["NIO", "NIOConcurrencyHelpers"]),
        .target(
            name: "NIOEchoClient",
            dependencies: ["NIO", "NIOConcurrencyHelpers"]),
        .target(
            name: "NIOHTTP1Server",
            dependencies: ["NIO", "NIOHTTP1", "NIOConcurrencyHelpers"]),


        // MARK:- Test targets.

        .testTarget(
            name: "NIOTests",
            dependencies: ["NIO", "NIOFoundationCompat"]),
        .testTarget(
            name: "NIOConcurrencyHelpersTests",
            dependencies: ["NIOConcurrencyHelpers"]),
        .testTarget(
            name: "NIOPriorityQueueTests",
            dependencies: ["NIOPriorityQueue"]),
        .testTarget(
            name: "NIOHTTP1Tests",
            dependencies: ["NIOHTTP1", "NIOFoundationCompat"]),
        .testTarget(
            name: "NIOTLSTests",
            dependencies: ["NIO", "NIOTLS", "NIOFoundationCompat"]),
    ]
)
