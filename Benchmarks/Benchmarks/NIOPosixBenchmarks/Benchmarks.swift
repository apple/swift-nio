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
        .cpuTotal,
        .contextSwitches,
        .wallClock,
    ]

    Benchmark(
        "TCPEcho pure NIO 1M times",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .one
//            scalingFactor: .mega,
//            maxDuration: .seconds(10_000_000),
//            maxIterations: 5,
//            thresholds: [.mallocCountTotal: .init(absolute: [.p90: 50])]
        )
    ) { benchmark in
        try runTCPEcho(
            numberOfWrites: 1_000_000,
            eventLoop: eventLoop
        )
    }

    Benchmark(
        "TCPEchoAsyncChannel pure async/await 1M times",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .one
        )
    ) { benchmark in
        try await runTCPEchoAsyncChannel(
            numberOfWrites: 1_000_000,
            eventLoop: eventLoop
        )
    }

    Benchmark(
        "TCPEchoAsyncChannel using globalHook 1M times",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .one,
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
            numberOfWrites: 1_000_000,
            eventLoop: eventLoop
        )
    }

    if #available(macOS 15.0, *) {
        Benchmark(
            "TCPEchoAsyncChannel using task executor preference 1M times",
            configuration: .init(
                metrics: defaultMetrics,
                scalingFactor: .one
            )
        ) { benchmark in
            try await withTaskExecutorPreference(eventLoop.taskExecutor) {
                try await runTCPEchoAsyncChannel(
                    numberOfWrites: 1_000_000,
                    eventLoop: eventLoop
                )
            }
        }
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

    // MARK: - NIOThreadPool submit benchmarks

    // Serial wakeup: submit one item, wait for completion, repeat.
    // Every submit hits N sleeping threads — this is where wake-one
    // vs wake-all (thundering herd) matters most.
    let pool16 = NIOThreadPool(numberOfThreads: 16)
    let pool4 = NIOThreadPool(numberOfThreads: 4)

    Benchmark(
        "NIOThreadPool.serial_wakeup(16 threads)",
        configuration: .init(
            metrics: [.wallClock, .cpuUser, .cpuSystem, .cpuTotal, .contextSwitches, .syscalls],
            maxDuration: .seconds(30),
            maxIterations: 30,
            setup: { pool16.start() },
            teardown: { try! pool16.syncShutdownGracefully() }
        )
    ) { _ in
        runNIOThreadPoolSerialWakeup(pool: pool16, count: 10_000)
    }

    Benchmark(
        "NIOThreadPool.serial_wakeup(4 threads)",
        configuration: .init(
            metrics: [.wallClock, .cpuUser, .cpuSystem, .cpuTotal, .contextSwitches, .syscalls],
            maxDuration: .seconds(30),
            maxIterations: 30,
            setup: { pool4.start() },
            teardown: { try! pool4.syncShutdownGracefully() }
        )
    ) { _ in
        runNIOThreadPoolSerialWakeup(pool: pool4, count: 10_000)
    }
}
