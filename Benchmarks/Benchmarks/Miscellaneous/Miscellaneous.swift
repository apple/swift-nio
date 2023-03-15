//
// Copyright (c) 2022 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//

import NIOPerformanceTester
import NIOWebSocket
import NIOCore

import BenchmarkSupport
@main
extension BenchmarkRunner {}

@_dynamicReplacement(for: registerBenchmarks)
func benchmarks() {
    Benchmark.defaultConfiguration = .init(warmupIterations: 0,
                                           maxDuration: .seconds(1),
                                           maxIterations: Int.max,
                                           thresholds: [.wallClock: BenchmarkResult.PercentileThresholds.strict])

    func measureAndPrint<B: NIOPerformanceTester.Benchmark>(benchmark: BenchmarkSupport.Benchmark,
                                                            running: B) throws {
        try running.setUp()
        defer {
            running.tearDown()
        }

        blackHole(try running.run())
    }

    func measureAndPrint<B: NIOPerformanceTester.AsyncBenchmark>(benchmark: BenchmarkSupport.Benchmark,
                                                            running: B) async throws {
        try await running.setUp()
        defer {
            running.tearDown()
        }

        blackHole(try await running.run())
    }


    Benchmark("udp_10k_writes") { benchmark in
        try measureAndPrint(
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
        try measureAndPrint(benchmark: benchmark,
                            running: ChannelPipelineBenchmark(runCount: 1_000_000))
    }

    Benchmark("circular_buffer_into_byte_buffer_1kb") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: CircularBufferIntoByteBufferBenchmark(
                iterations: 10_000,
                bufferSize: 1024
            )
        )
    }

    Benchmark("circular_buffer_into_byte_buffer_1mb") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: CircularBufferIntoByteBufferBenchmark(
                iterations: 20,
                bufferSize: 1024*1024
            )
        )
    }

    Benchmark("byte_to_message_decoder_decode_many_small") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: ByteToMessageDecoderDecodeManySmallsBenchmark(
                iterations: 200,
                bufferSize: 16384
            )
        )
    }

    // TODO: This needs extra validation
    Benchmark("generate_10k_random_request_keys",
              configuration: .init(scalingFactor:.kilo)) { benchmark in
        let numKeys = 10_000
        for _ in benchmark.scaledIterations {
            blackHole( (0 ..< numKeys).reduce(into: 0, { result, _ in
                result &+= NIOWebSocketClientUpgrader.randomRequestKey().count
            }))
        }
    }

    Benchmark("lock_1_thread_10M_ops") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: NIOLockBenchmark(
                numberOfThreads: 1,
                lockOperationsPerThread: 10_000_000
            )
        )
    }

    Benchmark("lock_2_threads_10M_ops") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: NIOLockBenchmark(
                numberOfThreads: 2,
                lockOperationsPerThread: 5_000_000
            )
        )
    }

    Benchmark("lock_4_threads_10M_ops") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: NIOLockBenchmark(
                numberOfThreads: 4,
                lockOperationsPerThread: 2_500_000
            )
        )
    }

    Benchmark("lock_8_threads_10M_ops") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: NIOLockBenchmark(
                numberOfThreads: 8,
                lockOperationsPerThread: 1_250_000
            )
        )
    }

    Benchmark("schedule_100k_tasks") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: SchedulingBenchmark(numTasks: 100_000)
        )
    }

    Benchmark("schedule_and_run_100k_tasks") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: SchedulingAndRunningBenchmark(numTasks: 100_000)
        )
    }

    Benchmark("execute_100k_tasks") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: ExecuteBenchmark(numTasks: 100_000)
        )
    }

    Benchmark("circularbuffer_copy_to_array_10k_times_1kb") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: CircularBufferViewCopyToArrayBenchmark(
                iterations: 10_000,
                size: 1024
            )
        )
    }

    Benchmark("deadline_now_1M_times") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: DeadlineNowBenchmark(
                iterations: 1_000_000
            )
        )
    }

    Benchmark("asyncwriter_single_writes_1M_times") { benchmark in
        if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) {
            try await measureAndPrint(
                benchmark: benchmark,
                running: NIOAsyncWriterSingleWritesBenchmark(
                    iterations: 1_000_000
                )
            )
        }
    }

    Benchmark("asyncsequenceproducer_consume_1M_times") { benchmark in
        if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) {
            try await measureAndPrint(
                benchmark: benchmark,
                running: NIOAsyncSequenceProducerBenchmark(
                    iterations: 1_000_000
                )
            )
        }
    }

}
