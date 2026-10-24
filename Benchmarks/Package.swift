// swift-tools-version:6.1

import PackageDescription

let package = Package(
    name: "benchmarks",
    platforms: [
        .macOS("14")
    ],
    dependencies: [
        // The name is set explicitly: otherwise SwiftPM infers it from the directory name of the
        // checkout, which breaks in git worktrees (where the directory is named after the worktree).
        .package(name: "swift-nio", path: "../"),
        .package(url: "https://github.com/ordo-one/package-benchmark.git", from: "1.29.11"),
    ],
    targets: [
        .executableTarget(
            name: "NIOPosixBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Benchmarks/NIOPosixBenchmarks",
            swiftSettings: [.swiftLanguageMode(.v5)],
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        ),
        .executableTarget(
            name: "NIOCoreBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            path: "Benchmarks/NIOCoreBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        ),
    ]
)
