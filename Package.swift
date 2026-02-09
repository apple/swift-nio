// swift-tools-version:6.0
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
let swiftSystem: PackageDescription.Target.Dependency = .product(name: "SystemPackage", package: "swift-system")

// These platforms require a dependency on `NIOPosix` from `NIOHTTP1` to maintain backward
// compatibility with previous NIO versions.
let historicalNIOPosixDependencyRequired: [Platform] = [.macOS, .iOS, .tvOS, .watchOS, .linux, .android]

let swiftSettings: [SwiftSetting] = [
    // The Language Steering Group has promised that they won't break the APIs that currently exist under
    // this "experimental" feature flag without two subsequent releases. We assume they will respect that
    // promise, so we enable this here. For more, see:
    // https://forums.swift.org/t/experimental-support-for-lifetime-dependencies-in-swift-6-2-and-beyond/78638
    .enableExperimentalFeature("Lifetimes")
]

// This doesn't work when cross-compiling: the privacy manifest will be included in the Bundle and
// Foundation will be linked. This is, however, strictly better than unconditionally adding the
// resource.
#if canImport(Darwin)
let includePrivacyManifest = true
#else
let includePrivacyManifest = false
#endif

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
        .library(name: "_NIOFileSystem", targets: ["_NIOFileSystem", "NIOFileSystem"]),
        .library(name: "_NIOFileSystemFoundationCompat", targets: ["_NIOFileSystemFoundationCompat"]),
    ],
    targets: [
        // MARK: - Targets

        .target(
            name: "NIOCore",
            dependencies: [
                "NIOConcurrencyHelpers",
                "_NIOBase64",
                "CNIOOpenBSD",
                "CNIODarwin",
                "CNIOLinux",
                "CNIOWindows",
                "CNIOWASI",
                "_NIODataStructures",
                swiftCollections,
                swiftAtomics,
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "_NIODataStructures",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "_NIOBase64",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "NIOEmbedded",
            dependencies: [
                "NIOCore",
                "NIOConcurrencyHelpers",
                "_NIODataStructures",
                swiftAtomics,
                swiftCollections,
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "NIOPosix",
            dependencies: [
                "CNIOOpenBSD",
                "CNIOLinux",
                "CNIODarwin",
                "CNIOWindows",
                "NIOConcurrencyHelpers",
                "NIOCore",
                "_NIODataStructures",
                "CNIOPosix",
                swiftAtomics,
            ],
            exclude: includePrivacyManifest ? [] : ["PrivacyInfo.xcprivacy"],
            resources: includePrivacyManifest ? [.copy("PrivacyInfo.xcprivacy")] : [],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "NIO",
            dependencies: [
                "NIOCore",
                "NIOEmbedded",
                "NIOPosix",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "_NIOConcurrency",
            dependencies: [
                .target(name: "NIO", condition: .when(platforms: historicalNIOPosixDependencyRequired)),
                "NIOCore",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "NIOFoundationCompat",
            dependencies: [
                .target(name: "NIO", condition: .when(platforms: historicalNIOPosixDependencyRequired)),
                "NIOCore",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CNIOAtomics",
            dependencies: [],
            cSettings: [
                .define("_GNU_SOURCE")
            ]
        ),
        .target(
            name: "CNIOPosix",
            dependencies: [],
            cSettings: [
                .define("_GNU_SOURCE")
            ]
        ),
        .target(
            name: "CNIOSHA1",
            dependencies: []
        ),
        .target(
            name: "CNIOOpenBSD",
            dependencies: []
        ),
        .target(
            name: "CNIOLinux",
            dependencies: [],
            cSettings: [
                .define("_GNU_SOURCE")
            ]
        ),
        .target(
            name: "CNIODarwin",
            dependencies: [],
            cSettings: [
                .define("__APPLE_USE_RFC_3542")
            ]
        ),
        .target(
            name: "CNIOWindows",
            dependencies: []
        ),
        .target(
            name: "CNIOWASI",
            dependencies: []
        ),
        .target(
            name: "NIOConcurrencyHelpers",
            dependencies: [
                "CNIOAtomics"
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "NIOHTTP1",
            dependencies: [
                .target(name: "NIO", condition: .when(platforms: historicalNIOPosixDependencyRequired)),
                "NIOCore",
                "NIOConcurrencyHelpers",
                "CNIOLLHTTP",
                swiftCollections,
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "NIOWebSocket",
            dependencies: [
                .target(name: "NIO", condition: .when(platforms: historicalNIOPosixDependencyRequired)),
                "NIOCore",
                "NIOHTTP1",
                "CNIOSHA1",
                "_NIOBase64",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CNIOLLHTTP",
            cSettings: [
                .define("_GNU_SOURCE"),
                .define("LLHTTP_STRICT_MODE"),
            ]
        ),
        .target(
            name: "NIOTLS",
            dependencies: [
                .target(name: "NIO", condition: .when(platforms: historicalNIOPosixDependencyRequired)),
                "NIOCore",
                swiftCollections,
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "NIOTestUtils",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOEmbedded",
                "NIOHTTP1",
                swiftAtomics,
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "NIOFS",
            dependencies: [
                "NIOCore",
                "NIOPosix",
                "CNIOLinux",
                "CNIODarwin",
                swiftAtomics,
                swiftCollections,
                swiftSystem,
            ],
            path: "Sources/NIOFS",
            exclude: includePrivacyManifest ? [] : ["PrivacyInfo.xcprivacy"],
            resources: includePrivacyManifest ? [.copy("PrivacyInfo.xcprivacy")] : [],
            swiftSettings: swiftSettings + [
                .define("ENABLE_MOCKING", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "NIOFSFoundationCompat",
            dependencies: [
                "NIOFS",
                "NIOFoundationCompat",
            ],
            path: "Sources/NIOFSFoundationCompat",
            swiftSettings: swiftSettings
        ),

        .target(
            name: "_NIOFileSystem",
            dependencies: [
                "NIOCore",
                "NIOPosix",
                "CNIOLinux",
                "CNIODarwin",
                swiftAtomics,
                swiftCollections,
                swiftSystem,
            ],
            path: "Sources/_NIOFileSystem",
            exclude: includePrivacyManifest ? [] : ["PrivacyInfo.xcprivacy"],
            resources: includePrivacyManifest ? [.copy("PrivacyInfo.xcprivacy")] : [],
            swiftSettings: swiftSettings + [
                .define("ENABLE_MOCKING", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "_NIOFileSystemFoundationCompat",
            dependencies: [
                "_NIOFileSystem",
                "NIOFoundationCompat",
            ],
            path: "Sources/_NIOFileSystemFoundationCompat",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "NIOFileSystem",
            dependencies: ["_NIOFileSystem"],
            swiftSettings: swiftSettings
        ),

        // MARK: - Examples

        .executableTarget(
            name: "NIOTCPEchoServer",
            dependencies: [
                "NIOPosix",
                "NIOCore",
            ],
            exclude: ["README.md"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOTCPEchoClient",
            dependencies: [
                "NIOPosix",
                "NIOCore",
            ],
            exclude: ["README.md"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOEchoServer",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOConcurrencyHelpers",
            ],
            exclude: ["README.md"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOEchoClient",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOConcurrencyHelpers",
            ],
            exclude: ["README.md"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOHTTP1Server",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOHTTP1",
                "NIOConcurrencyHelpers",
            ],
            exclude: ["README.md"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOHTTP1Client",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOHTTP1",
                "NIOConcurrencyHelpers",
            ],
            exclude: ["README.md"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOChatServer",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOConcurrencyHelpers",
            ],
            exclude: ["README.md"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOChatClient",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOConcurrencyHelpers",
            ],
            exclude: ["README.md"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOWebSocketServer",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOHTTP1",
                "NIOWebSocket",
            ],
            exclude: ["README.md"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOWebSocketClient",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOHTTP1",
                "NIOWebSocket",
            ],
            exclude: ["README.md"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOMulticastChat",
            dependencies: [
                "NIOPosix",
                "NIOCore",
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOUDPEchoServer",
            dependencies: [
                "NIOPosix",
                "NIOCore",
            ],
            exclude: ["README.md"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOUDPEchoClient",
            dependencies: [
                "NIOPosix",
                "NIOCore",
            ],
            exclude: ["README.md"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "NIOAsyncAwaitDemo",
            dependencies: [
                "NIOPosix",
                "NIOCore",
                "NIOHTTP1",
            ],
            swiftSettings: swiftSettings
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
            ],
            swiftSettings: swiftSettings
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
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIOCoreTests",
            dependencies: [
                "NIOConcurrencyHelpers",
                "NIOCore",
                "NIOEmbedded",
                "NIOFoundationCompat",
                "NIOTestUtils",
                swiftAtomics,
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIOEmbeddedTests",
            dependencies: [
                "NIOConcurrencyHelpers",
                "NIOCore",
                "NIOEmbedded",
            ],
            swiftSettings: swiftSettings
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
                "CNIOOpenBSD",
                "CNIOLinux",
                "CNIODarwin",
                "NIOTLS",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIOConcurrencyHelpersTests",
            dependencies: [
                "NIOConcurrencyHelpers",
                "NIOCore",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIODataStructuresTests",
            dependencies: ["_NIODataStructures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIOBase64Tests",
            dependencies: ["_NIOBase64"],
            swiftSettings: swiftSettings
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
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIOTLSTests",
            dependencies: [
                "NIOCore",
                "NIOEmbedded",
                "NIOTLS",
                "NIOFoundationCompat",
                "NIOTestUtils",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIOWebSocketTests",
            dependencies: [
                "NIOCore",
                "NIOEmbedded",
                "NIOWebSocket",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIOTestUtilsTests",
            dependencies: [
                "NIOTestUtils",
                "NIOCore",
                "NIOEmbedded",
                "NIOPosix",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIOFoundationCompatTests",
            dependencies: [
                "NIOCore",
                "NIOFoundationCompat",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIOTests",
            dependencies: ["NIO"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIOSingletonsTests",
            dependencies: ["NIOCore", "NIOPosix"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIOFSTests",
            dependencies: [
                "NIOCore",
                "NIOFS",
                swiftAtomics,
                swiftCollections,
                swiftSystem,
            ],
            swiftSettings: swiftSettings + [
                .define("ENABLE_MOCKING", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "NIOFSIntegrationTests",
            dependencies: [
                "NIOCore",
                "NIOPosix",
                "NIOFS",
                "NIOFoundationCompat",
            ],
            exclude: [
                // Contains known files and directory structures used
                // for the integration tests. Exclude the whole tree from
                // the build.
                "Test Data"
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NIOFSFoundationCompatTests",
            dependencies: [
                "NIOFS",
                "NIOFSFoundationCompat",
            ],
            swiftSettings: swiftSettings
        ),
    ]
)

if Context.environment["SWIFTCI_USE_LOCAL_DEPS"] == nil {
    package.dependencies += [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
    ]
} else {
    package.dependencies += [
        .package(path: "../swift-atomics"),
        .package(path: "../swift-collections"),
        .package(path: "../swift-system"),
    ]
}

// ---    STANDARD CROSS-REPO SETTINGS DO NOT EDIT   --- //
for target in package.targets {
    switch target.type {
    case .regular, .test, .executable:
        var settings = target.swiftSettings ?? []
        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        settings.append(.enableUpcomingFeature("MemberImportVisibility"))
        target.swiftSettings = settings
    case .macro, .plugin, .system, .binary:
        ()  // not applicable
    @unknown default:
        ()  // we don't know what to do here, do nothing
    }
}
// --- END: STANDARD CROSS-REPO SETTINGS DO NOT EDIT --- //
