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

    func measureAndPrint<B: NIOPerformanceTester.Benchmark>(benchmark: BenchmarkSupport.Benchmark,
                                                            running: B) throws {
        try running.setUp()
        defer {
            running.tearDown()
        }

        blackHole(try running.run())
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

    Benchmark("udp_10k_vector_writes") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: UDPBenchmark(
                data: ByteBuffer(repeating: 42, count: 1000),
                numberOfRequests: 10_000,
                vectorReads: 1,
                vectorWrites: 10
            )
        )
    }

    Benchmark("udp_10k_vector_reads") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: UDPBenchmark(
                data: ByteBuffer(repeating: 42, count: 1000),
                numberOfRequests: 10_000,
                vectorReads: 10,
                vectorWrites: 1
            )
        )
    }

    Benchmark("udp_10k_vector_reads_and_writes") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: UDPBenchmark(
                data: ByteBuffer(repeating: 42, count: 1000),
                numberOfRequests: 10_000,
                vectorReads: 10,
                vectorWrites: 10
            )
        )
    }

    Benchmark("tcp_100k_messages_throughput") { benchmark in
        if #available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *) {
            try measureAndPrint(
                benchmark: benchmark,
                running: TCPThroughputBenchmark(messages: 100_000, messageSize: 500)
            )
        }
    }
}
