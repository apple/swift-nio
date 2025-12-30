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
import NIOCore
import NIOPosix

private let eventLoop = MultiThreadedEventLoopGroup.singleton.next()

let benchmarks = {
    let defaultMetrics: [BenchmarkMetric] = [
        .mallocCountTotal,
        .contextSwitches,
        .wallClock,
    ]

    Benchmark(
        "TCPEcho",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .mega,
            maxDuration: .seconds(10_000_000),
            maxIterations: 5,
            thresholds: [.mallocCountTotal: .init(absolute: [.p90: 50])]
        )
    ) { benchmark in
        try runTCPEcho(
            numberOfWrites: benchmark.scaledIterations.upperBound,
            eventLoop: eventLoop
        )
    }

    Benchmark(
        "TCPEchoAsyncChannel",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .mega,
            maxDuration: .seconds(10_000_000),
            maxIterations: 5,
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

    Benchmark(
        "UDPEcho",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .kilo,
            maxDuration: .seconds(10_000_000),
            maxIterations: 5
        )
    ) { benchmark in
        try runUDPEcho(
            numberOfWrites: benchmark.scaledIterations.upperBound,
            eventLoop: eventLoop
        )
    }

    Benchmark(
        "UDPEchoPacketInfo",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .kilo,
            maxDuration: .seconds(10_000_000),
            maxIterations: 5
        )
    ) { benchmark in
        try runUDPEchoPacketInfo(
            numberOfWrites: benchmark.scaledIterations.upperBound,
            eventLoop: eventLoop
        )
    }

    Benchmark(
        "MTELG.scheduleTask(in:_:)",
        configuration: Benchmark.Configuration(
            metrics: defaultMetrics,
            scalingFactor: .mega,
            maxDuration: .seconds(10_000_000),
            maxIterations: 5
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            eventLoop.scheduleTask(in: .hours(1), {})
        }
    }

    Benchmark(
        "MTELG.scheduleCallback(in:_:)",
        configuration: Benchmark.Configuration(
            metrics: defaultMetrics,
            scalingFactor: .mega,
            maxDuration: .seconds(10_000_000),
            maxIterations: 5
        )
    ) { benchmark in
        final class Timer: NIOScheduledCallbackHandler {
            func handleScheduledCallback(eventLoop: some EventLoop) {}
        }
        let timer = Timer()

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            let handle = try! eventLoop.scheduleCallback(in: .hours(1), handler: timer)
        }
    }

    Benchmark(
        "Jump to EL and back using execute and unsafecontinuation",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
                eventLoop.execute {
                    continuation.resume()
                }
            }
        }
    }

    final actor Foo {
        nonisolated public let unownedExecutor: UnownedSerialExecutor

        init(eventLoop: any EventLoop) {
            self.unownedExecutor = eventLoop.executor.asUnownedSerialExecutor()
        }

        func foo() {
            blackHole(Void())
        }
    }

    Benchmark(
        "Jump to EL and back using actor with EL executor",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .kilo
        )
    ) { benchmark in
        let actor = Foo(eventLoop: eventLoop)
        for _ in benchmark.scaledIterations {
            await actor.foo()
        }
    }
}
