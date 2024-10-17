//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Benchmark
import NIOCore
import NIOEmbedded

let benchmarks = {
    let defaultMetrics: [BenchmarkMetric] = [
        .mallocCountTotal
    ]

    let leakMetrics: [BenchmarkMetric] = [
        .mallocCountTotal,
        .memoryLeaked,
    ]

    Benchmark(
        "NIOAsyncChannel.init",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .kilo,
            maxDuration: .seconds(10_000_000),
            maxIterations: 10
        )
    ) { benchmark in
        // Elide the cost of the 'EmbeddedChannel'. It's only used for its pipeline.
        var channels: [EmbeddedChannel] = []
        channels.reserveCapacity(benchmark.scaledIterations.count)
        for _ in 0..<benchmark.scaledIterations.count {
            channels.append(EmbeddedChannel())
        }

        benchmark.startMeasurement()
        defer {
            benchmark.stopMeasurement()
        }
        for channel in channels {
            let asyncChanel = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            blackHole(asyncChanel)
        }
    }

    Benchmark(
        "WaitOnPromise",
        configuration: .init(
            metrics: leakMetrics,
            scalingFactor: .kilo,
            maxDuration: .seconds(10_000_000),
            maxIterations: 10_000  // need 10k to get a signal
        )
    ) { benchmark in
        // Elide the cost of the 'EmbeddedEventLoop'.
        let el = EmbeddedEventLoop()

        benchmark.startMeasurement()
        defer {
            benchmark.stopMeasurement()
        }

        for _ in 0..<benchmark.scaledIterations.count {
            let p = el.makePromise(of: Int.self)
            p.succeed(0)
            do { _ = try! p.futureResult.wait() }
        }
    }
}
