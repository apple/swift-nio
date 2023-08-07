// swift-tools-version:5.6
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

let swiftAtomics: PackageDescription.Target.Dependency = .product(name: "Atomics", package: "swift-atomics")
let swiftCollections: PackageDescription.Target.Dependency = .product(name: "DequeModule", package: "swift-collections")

var targets: [PackageDescription.Target] = [
    .target(name: "NIOCore",
            dependencies: ["NIOConcurrencyHelpers", "CNIOLinux", "CNIOWindows", swiftCollections, swiftAtomics]),
    .target(name: "_NIODataStructures"),
    .target(name: "NIOEmbedded",
            dependencies: ["NIOCore",
                           "NIOConcurrencyHelpers",
                           "_NIODataStructures",
                           swiftAtomics,
                           swiftCollections]),
    .target(name: "NIOPosix",
            dependencies: ["CNIOLinux",
                           "CNIODarwin",
                           "CNIOWindows",
                           "NIOConcurrencyHelpers",
                           "NIOCore",
                           "_NIODataStructures",
                           swiftAtomics]),
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
            dependencies: ["NIO", "NIOCore", "NIOConcurrencyHelpers", "CNIOLLHTTP"]),
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
    .target(
        name: "CNIOLLHTTP",
        cSettings: [.define("LLHTTP_STRICT_MODE")]
    ),
    .target(name: "NIOTLS", dependencies: ["NIO", "NIOCore", swiftCollections]),
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
            dependencies: ["NIOPosix", "NIOCore", "NIOEmbedded", "NIOHTTP1", swiftAtomics]),
    .executableTarget(name: "NIOCrashTester",
            dependencies: ["NIOPosix", "NIOCore", "NIOEmbedded", "NIOHTTP1", "NIOWebSocket", "NIOFoundationCompat"]),
    .executableTarget(name: "NIOAsyncAwaitDemo",
            dependencies: ["NIOPosix", "NIOCore", "NIOHTTP1"]),
    .testTarget(name: "NIOCoreTests",
                dependencies: ["NIOCore", "NIOEmbedded", "NIOFoundationCompat", swiftAtomics]),
    .testTarget(name: "NIOEmbeddedTests",
                dependencies: ["NIOConcurrencyHelpers", "NIOCore", "NIOEmbedded"]),
    .testTarget(name: "NIOPosixTests",
                dependencies: ["NIOPosix", "NIOCore", "NIOFoundationCompat", "NIOTestUtils", "NIOConcurrencyHelpers", "NIOEmbedded", "CNIOLinux", "NIOTLS"]),
    .testTarget(name: "NIOConcurrencyHelpersTests",
                dependencies: ["NIOConcurrencyHelpers", "NIOCore"]),
    .testTarget(name: "NIODataStructuresTests",
                dependencies: ["_NIODataStructures"]),
    .testTarget(name: "NIOHTTP1Tests",
                dependencies: ["NIOCore", "NIOEmbedded", "NIOPosix", "NIOHTTP1", "NIOFoundationCompat", "NIOTestUtils"]),
    .testTarget(name: "NIOTLSTests",
                dependencies: ["NIOCore", "NIOEmbedded", "NIOTLS", "NIOFoundationCompat", "NIOTestUtils"]),
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
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.2"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: targets
)
