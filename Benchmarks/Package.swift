// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Benchmarks",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/ordo-one/package-benchmark", .upToNextMajor(from: "1.0.0")),
        .package(path: "../../swift-nio")
    ],
    targets: [
        // Support target having fundamentally verbatim copies of NIOPerformanceTester sources
        .target(name: "NIOPerformanceTester",
                dependencies: [
                    .product(name: "NIOCore", package: "swift-nio"),
                    .product(name: "NIOPosix", package: "swift-nio"),
                    .product(name: "NIOHTTP1", package: "swift-nio"),
                    .product(name: "NIOFoundationCompat", package: "swift-nio"),
                    .product(name: "NIOWebSocket", package: "swift-nio"),
                    .product(name: "NIOEmbedded", package: "swift-nio")
                ]),

        // Benchmark targets
        .executableTarget(
            name: "ByteBuffer",
            dependencies: [
                "NIOPerformanceTester",
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "BenchmarkPlugin", package: "package-benchmark"),
            ],
            path: "Benchmarks/ByteBuffer"
        ),

        .executableTarget(
            name: "Futures",
            dependencies: [
                "NIOPerformanceTester",
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "BenchmarkPlugin", package: "package-benchmark"),
            ],
            path: "Benchmarks/Futures"
        ),

        .executableTarget(
            name: "HTTPRequests",
            dependencies: [
                "NIOPerformanceTester",
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "BenchmarkPlugin", package: "package-benchmark"),
            ],
            path: "Benchmarks/HTTPRequests"
        ),

        .executableTarget(
            name: "HTTPHeaders",
            dependencies: [
                "NIOPerformanceTester",
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "BenchmarkPlugin", package: "package-benchmark"),
            ],
            path: "Benchmarks/HTTPHeaders"
        ),

        .executableTarget(
            name: "WebSocket",
            dependencies: [
                "NIOPerformanceTester",
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "BenchmarkPlugin", package: "package-benchmark"),
            ],
            path: "Benchmarks/WebSocket"
        ),

        .executableTarget(
            name: "Miscellaneous",
            dependencies: [
                "NIOPerformanceTester",
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "BenchmarkPlugin", package: "package-benchmark"),
            ],
            path: "Benchmarks/Miscellaneous"
        ),

        .executableTarget(
            name: "UDPAndTCP",
            dependencies: [
                "NIOPerformanceTester",
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "BenchmarkPlugin", package: "package-benchmark"),
            ],
            path: "Benchmarks/UDPAndTCP"
        )

    ]
)
