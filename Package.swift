// swift-tools-version:5.7
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2023 Apple Inc. and the SwiftNIO project authors
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
let swiftSystem: PackageDescription.Target.Dependency = .product(
  name: "SystemPackage",
  package: "swift-system",
  condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .linux, .android])
)


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
        .library(name: "_NIOFileSystem", targets: ["NIOFileSystem"]),
        .library(name: "_NIOFileSystemFoundationCompat", targets: ["NIOFileSystemFoundationCompat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.2"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        // MARK: - Targets

        .target(
            name: "NIOCore",
            dependencies: [
                "NIOConcurrencyHelpers",
                "_NIOBase64",
                "CNIODarwin",
                "CNIOLinux",
                "CNIOWindows",
                "_NIODataStructures",
                swiftCollections,
                swiftAtomics,
            ]
        ),
        .target(
            name: "_NIODataStructures"
        ),
        .target(
            name: "_NIOBase64"
        ),
        .target(
            name: "NIOEmbedded",
            dependencies: [
                "NIOCore",
                "NIOConcurrencyHelpers",
                "_NIODataStructures",
                swiftAtomics,
                swiftCollections,
            ]
        ),
        .target(
            name: "NIOPosix",
            dependencies: [
                "CNIOLinux",
                "CNIODarwin",
                "CNIOWindows",
                "NIOConcurrencyHelpers",
                "NIOCore",
                "_NIODataStructures",
                swiftAtomics,
            ]
        ),
        .target(
            name: "NIO",
            dependencies: [
                "NIOCore",
                "NIOEmbedded",
                "NIOPosix",
            ]
        ),
        .target(
            name: "_NIOConcurrency",
            dependencies: [
                "NIO",
                "NIOCore",
            ]
        ),
        .target(
            name: "NIOFoundationCompat",
            dependencies: [
                "NIO",
                "NIOCore",
            ]
        ),
        .target(
            name: "CNIOAtomics",
            dependencies: [],
            cSettings: [
                .define("_GNU_SOURCE"),
            ]
        ),
        .target(
            name: "CNIOSHA1",
            dependencies: []
        ),
        .target(
            name: "CNIOLinux",
            dependencies: [],
            cSettings: [
                .define("_GNU_SOURCE"),
            ]
        ),
        .target(
            name: "CNIODarwin",
            dependencies: [],
            cSettings: [
                .define("__APPLE_USE_RFC_3542"),
            ]
        ),
        .target(
            name: "CNIOWindows",
            dependencies: []
        ),
        .target(
            name: "NIOConcurrencyHelpers",
            dependencies: [
                "CNIOAtomics",
            ]
        ),
        .target(
            name: "NIOHTTP1",
            dependencies: [
                "NIO",
                "NIOCore",
                "NIOConcurrencyHelpers",
                "CNIOLLHTTP",
                swiftCollections
            ]
        ),
        .target(
            name: "NIOWebSocket",
            dependencies: [
                "NIO",
                "NIOCore",
                "NIOHTTP1",
                "CNIOSHA1",
                "_NIOBase64"
            ]
        ),
        .target(
            name: "CNIOLLHTTP",
            cSettings: [
              .define("_GNU_SOURCE"),
              .define("LLHTTP_STRICT_MODE")
            ]
        ),
        .target(
            name: "NIOTLS",
            dependencies: [
                "NIO",
                "NIOCore",
                swiftCollections,
            ]
        ),
        .target(
            name: "NIOTestUtils",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOEmbedded",
                "NIOHTTP1",
                swiftAtomics,
            ]
        ),
        .target(
            name: "NIOFileSystem",
            dependencies: [
                "NIOCore",
                "CNIOLinux",
                "CNIODarwin",
                swiftAtomics,
                swiftCollections,
                swiftSystem,
            ],
            swiftSettings: [
                .define("ENABLE_MOCKING", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "NIOFileSystemFoundationCompat",
            dependencies: [
                "NIOFileSystem",
            ]
        ),

        // MARK: - Examples

        .executableTarget(
            name: "NIOTCPEchoServer",
            dependencies: [
                "NIOPosix",
                "NIOCore",
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "NIOTCPEchoClient",
            dependencies: [
                "NIOPosix",
                "NIOCore",
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "NIOEchoServer",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOConcurrencyHelpers",
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "NIOEchoClient",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOConcurrencyHelpers",
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "NIOHTTP1Server",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOHTTP1",
                "NIOConcurrencyHelpers",
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "NIOHTTP1Client",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOHTTP1",
                "NIOConcurrencyHelpers",
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "NIOChatServer",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOConcurrencyHelpers",
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "NIOChatClient",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOConcurrencyHelpers",
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "NIOWebSocketServer",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOHTTP1",
                "NIOWebSocket",
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "NIOWebSocketClient",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOHTTP1",
                "NIOWebSocket",
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "NIOMulticastChat",
            dependencies: [
                "NIOPosix",
                "NIOCore",
            ]
        ),
        .executableTarget(
            name: "NIOUDPEchoServer",
            dependencies: [
                "NIOPosix",
                "NIOCore",
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "NIOUDPEchoClient",
            dependencies: [
                "NIOPosix",
                "NIOCore",
            ],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "NIOAsyncAwaitDemo",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOHTTP1",
            ]
        ),

        // MARK: - Tests

        .executableTarget(
            name: "NIOPerformanceTester",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOEmbedded",
                "NIOHTTP1",
                "NIOFoundationCompat",
                "NIOWebSocket",
            ]
        ),
        .executableTarget(
            name: "NIOCrashTester",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOEmbedded",
                "NIOHTTP1",
                "NIOWebSocket",
                "NIOFoundationCompat",
            ]
        ),
        .testTarget(
            name: "NIOCoreTests",
            dependencies: [
                "NIOCore",
                "NIOEmbedded",
                "NIOFoundationCompat",
                swiftAtomics,
            ]
        ),
        .testTarget(
            name: "NIOEmbeddedTests",
            dependencies: [
                "NIOConcurrencyHelpers",
                "NIOCore",
                "NIOEmbedded",
            ]
        ),
        .testTarget(
            name: "NIOPosixTests",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOFoundationCompat",
                "NIOTestUtils",
                "NIOConcurrencyHelpers",
                "NIOEmbedded",
                "CNIOLinux",
                "NIOTLS",
            ]
        ),
        .testTarget(
            name: "NIOConcurrencyHelpersTests",
            dependencies: [
                "NIOConcurrencyHelpers",
                "NIOCore",
            ]
        ),
        .testTarget(
            name: "NIODataStructuresTests",
            dependencies: ["_NIODataStructures"]
        ),
        .testTarget(
            name: "NIOBase64Tests",
            dependencies: ["_NIOBase64"]
        ),
        .testTarget(
            name: "NIOHTTP1Tests",
            dependencies: [
                "NIOCore",
                "NIOEmbedded",
                "NIOPosix",
                "NIOHTTP1",
                "NIOFoundationCompat",
                "NIOTestUtils",
            ]
        ),
        .testTarget(
            name: "NIOTLSTests",
            dependencies: [
                "NIOCore",
                "NIOEmbedded",
                "NIOTLS",
                "NIOFoundationCompat",
                "NIOTestUtils",
            ]
        ),
        .testTarget(
            name: "NIOWebSocketTests",
            dependencies: [
                "NIOCore",
                "NIOEmbedded",
                "NIOWebSocket",
            ]
        ),
        .testTarget(
            name: "NIOTestUtilsTests",
            dependencies: [
                "NIOTestUtils",
                "NIOCore",
                "NIOEmbedded",
                "NIOPosix",
            ]
        ),
        .testTarget(
            name: "NIOFoundationCompatTests",
            dependencies: [
                "NIOCore",
                "NIOFoundationCompat",
            ]
        ),
        .testTarget(
            name: "NIOTests",
            dependencies: ["NIO"]
        ),
        .testTarget(
            name: "NIOSingletonsTests",
            dependencies: ["NIOCore", "NIOPosix"]
        ),
        .testTarget(
            name: "NIOFileSystemTests",
            dependencies: [
                "NIOCore",
                "NIOFileSystem",
                swiftAtomics,
                swiftCollections,
                swiftSystem,
            ],
            swiftSettings: [
                .define("ENABLE_MOCKING", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "NIOFileSystemIntegrationTests",
            dependencies: [
                "NIOCore",
                "NIOFileSystem",
                "NIOFoundationCompat",
            ],
            exclude: [
                // Contains known files and directory structures used
                // for the integration tests. Exclude the whole tree from
                // the build.
                "Test Data",
            ]
        ),
        .testTarget(
            name: "NIOFileSystemFoundationCompatTests",
            dependencies: [
                "NIOFileSystem",
                "NIOFileSystemFoundationCompat",
            ]
        )
    ]
)
