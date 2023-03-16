//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOPerformanceTester
import NIOWebSocket
import NIOCore

import BenchmarkSupport
@main
extension BenchmarkRunner {}

@_dynamicReplacement(for: registerBenchmarks)
func benchmarks() {
    Benchmark.defaultConfiguration = .init(metrics:[.wallClock,
                                                    .mallocCountTotal,
                                                    .contextSwitches,
                                                    .threads,
                                                    .threadsRunning,
                                                    .syscalls,
                                                    .readSyscalls,
                                                    .writeSyscalls,
                                                    .throughput],
                                           warmupIterations: 0,
                                           maxDuration: .seconds(1),
                                           maxIterations: Int.max)

    let mediumConfiguration = Benchmark.Configuration(metrics:[.wallClock,
                                                               .mallocCountTotal,
                                                               .contextSwitches,
                                                               .threads,
                                                               .threadsRunning,
                                                               .syscalls,
                                                               .readSyscalls,
                                                               .writeSyscalls,
                                                               .throughput],
                                                      warmupIterations: 0,
                                                      scalingFactor: .kilo,
                                                      maxDuration: .seconds(1),
                                                      maxIterations: Int.max)

    Benchmark("udp_10k_writes") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: UDPBenchmark(
                data: ByteBuffer(repeating: 42, count: 1000),
                numberOfRequests: 10_000,
                vectorReads: 1,
                vectorWrites: 1
            )
        )
    }

    Benchmark("channel_pipeline_1m_events") { benchmark in
        try runNIOBenchmark(benchmark: benchmark,
                            running: ChannelPipelineBenchmark(runCount: 1_000_000))
    }

    Benchmark("circular_buffer_into_byte_buffer_1kb") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: CircularBufferIntoByteBufferBenchmark(
                iterations: 10_000,
                bufferSize: 1024
            )
        )
    }

    Benchmark("circular_buffer_into_byte_buffer_1mb") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: CircularBufferIntoByteBufferBenchmark(
                iterations: 20,
                bufferSize: 1024*1024
            )
        )
    }

    Benchmark("byte_to_message_decoder_decode_many_small") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: ByteToMessageDecoderDecodeManySmallsBenchmark(
                iterations: 200,
                bufferSize: 16384
            )
        )
    }

    // TODO: This needs extra validation
    Benchmark("generate_10k_random_request_keys") { benchmark in
        let numKeys = 10_000
        blackHole( (0 ..< numKeys).reduce(into: 0, { result, _ in
            result &+= NIOWebSocketClientUpgrader.randomRequestKey().count
        }))
    }

    Benchmark("lock_1_thread_10M_ops") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: NIOLockBenchmark(
                numberOfThreads: 1,
                lockOperationsPerThread: 10_000_000
            )
        )
    }

    Benchmark("lock_2_threads_10M_ops") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: NIOLockBenchmark(
                numberOfThreads: 2,
                lockOperationsPerThread: 5_000_000
            )
        )
    }

    Benchmark("lock_4_threads_10M_ops") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: NIOLockBenchmark(
                numberOfThreads: 4,
                lockOperationsPerThread: 2_500_000
            )
        )
    }

    Benchmark("lock_8_threads_10M_ops") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: NIOLockBenchmark(
                numberOfThreads: 8,
                lockOperationsPerThread: 1_250_000
            )
        )
    }

    Benchmark("schedule_100k_tasks") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: SchedulingBenchmark(numTasks: 100_000)
        )
    }

    Benchmark("schedule_and_run_100k_tasks") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: SchedulingAndRunningBenchmark(numTasks: 100_000)
        )
    }

    Benchmark("execute_100k_tasks") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: ExecuteBenchmark(numTasks: 100_000)
        )
    }

    Benchmark("circularbuffer_copy_to_array_10k_times_1kb") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: CircularBufferViewCopyToArrayBenchmark(
                iterations: 10_000,
                size: 1024
            )
        )
    }

    Benchmark("deadline_now_1M_times") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: DeadlineNowBenchmark(
                iterations: 1_000_000
            )
        )
    }

    Benchmark("asyncwriter_single_writes_1M_times") { benchmark in
        if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) {
            try await runNIOBenchmark(
                benchmark: benchmark,
                running: NIOAsyncWriterSingleWritesBenchmark(
                    iterations: 1_000_000
                )
            )
        }
    }

    Benchmark("asyncsequenceproducer_consume_1M_times") { benchmark in
        if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) {
            try await runNIOBenchmark(
                benchmark: benchmark,
                running: NIOAsyncSequenceProducerBenchmark(
                    iterations: 1_000_000
                )
            )
        }
    }
}
