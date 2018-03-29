// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-malloc-info",
    dependencies: [
        .package(url: "HookedFunctions/", .branch("master")),
        .package(url: "swift-nio/", .branch("master")),
    ],
    targets: [
        .target(
            name: "SwiftBootstrap",
            dependencies: ["NIO", "NIOHTTP1"]),
        .target(
            name: "bootstrap",
            dependencies: ["SwiftBootstrap", "HookedFunctions"]),
    ]
)
