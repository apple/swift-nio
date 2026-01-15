//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// NOTE: By and large the benchmarks here were ported from swift-nio
// to allow side-by-side performance comparison
//
// See https://github.com/apple/swift-nio/blob/main/Benchmarks/Benchmarks/NIOPosixBenchmarks/Benchmarks.swift

import Benchmark
import NIOAsyncRuntime
import NIOCore

private let eventLoop = MultiThreadedEventLoopGroup.singleton.next()

let benchmarks = {
    let defaultMetrics: [BenchmarkMetric] = [
        .mallocCountTotal,
        .contextSwitches,
        .wallClock,
    ]

    Benchmark(
        "MTELG.immediateTasksThroughput",
        configuration: Benchmark.Configuration(
            metrics: defaultMetrics,
            scalingFactor: .mega,
            maxDuration: .seconds(10_000_000),
            maxIterations: 5
        )
    ) { benchmark in
        func noOp() {}
        for _ in benchmark.scaledIterations {
            eventLoop.execute { noOp() }
        }
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
