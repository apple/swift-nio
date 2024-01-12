//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Benchmark
import NIOPosix

private let eventLoop = MultiThreadedEventLoopGroup.singleton.next()

let benchmarks = {
    let defaultMetrics: [BenchmarkMetric] = [
        .mallocCountTotal,
    ]

    Benchmark(
        "TCPEcho",
        configuration: .init(
            metrics: defaultMetrics,
            timeUnits: .milliseconds,
            scalingFactor: .mega
        )
    ) { benchmark in
        try runTCPEcho(
            numberOfWrites: benchmark.scaledIterations.upperBound,
            eventLoop: eventLoop
        )
    }

    // This benchmark is only available above 5.9 since our EL conformance
    // to serial executor is also gated behind 5.9.
    #if compiler(>=5.9)
    Benchmark(
        "TCPEchoAsyncChannel",
        configuration: .init(
            metrics: defaultMetrics,
            timeUnits: .milliseconds,
            scalingFactor: .mega,
            // We are expecting a bit of allocation variance due to an allocation
            // in the Concurrency runtime which happens when resuming a continuation.
            thresholds: [.mallocCountTotal: .init(absolute: [.p90: 2000])],
            setup: {
                swiftTaskEnqueueGlobalHook = { job, _ in
                    eventLoop.executor.enqueue(job)
                }
            },
            teardown: {
                swiftTaskEnqueueGlobalHook = nil
            }
        )
    ) { benchmark in
        try await runTCPEchoAsyncChannel(
            numberOfWrites: benchmark.scaledIterations.upperBound,
            eventLoop: eventLoop
        )
    }
    #endif
}
