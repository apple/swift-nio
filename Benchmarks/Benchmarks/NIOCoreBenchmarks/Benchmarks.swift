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

    Benchmark(
        "NIOAsyncChannel.init",
        configuration: Benchmark.Configuration(metrics: defaultMetrics)
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
}
