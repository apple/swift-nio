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
import Dispatch

import BenchmarkSupport
@main
extension BenchmarkRunner {}


@_dynamicReplacement(for: registerBenchmarks)
func benchmarks() {
    Benchmark.defaultConfiguration = .init(metrics:[.wallClock, .mallocCountTotal, .throughput],
                                           warmupIterations: 0,
                                           maxDuration: .seconds(1),
                                           maxIterations: Int.max)

    Benchmark("websocket_encode_50b_space_at_front_100k_frames_cow") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameEncoderBenchmark(
                dataSize: 50,
                runCount: 100_000,
                dataStrategy: .spaceAtFront,
                cowStrategy: .always,
                maskingKeyStrategy: .never
            )
        )
    }
    
    Benchmark("websocket_encode_50b_space_at_front_1m_frames_cow_masking") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameEncoderBenchmark(
                dataSize: 50,
                runCount: 1_000_000,
                dataStrategy: .spaceAtFront,
                cowStrategy: .always,
                maskingKeyStrategy: .always
            )
        )
    }
    
    Benchmark("websocket_encode_1kb_space_at_front_1m_frames_cow") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameEncoderBenchmark(
                dataSize: 1024,
                runCount: 1_000_000,
                dataStrategy: .spaceAtFront,
                cowStrategy: .always,
                maskingKeyStrategy: .never
            )
        )
    }
    
    Benchmark("websocket_encode_50b_no_space_at_front_100k_frames_cow") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameEncoderBenchmark(
                dataSize: 50,
                runCount: 100_000,
                dataStrategy: .noSpaceAtFront,
                cowStrategy: .always,
                maskingKeyStrategy: .never
            )
        )
    }
    
    Benchmark("websocket_encode_1kb_no_space_at_front_100k_frames_cow") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameEncoderBenchmark(
                dataSize: 1024,
                runCount: 100_000,
                dataStrategy: .noSpaceAtFront,
                cowStrategy: .always,
                maskingKeyStrategy: .never
            )
        )
    }
    
    Benchmark("websocket_encode_50b_space_at_front_100k_frames") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameEncoderBenchmark(
                dataSize: 50,
                runCount: 100_000,
                dataStrategy: .spaceAtFront,
                cowStrategy: .never,
                maskingKeyStrategy: .never
            )
        )
    }
    
    Benchmark("websocket_encode_50b_space_at_front_10k_frames_masking") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameEncoderBenchmark(
                dataSize: 50,
                runCount: 10_000,
                dataStrategy: .spaceAtFront,
                cowStrategy: .never,
                maskingKeyStrategy: .always
            )
        )
    }
    
    Benchmark("websocket_encode_1kb_space_at_front_10k_frames") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameEncoderBenchmark(
                dataSize: 1024,
                runCount: 10_000,
                dataStrategy: .spaceAtFront,
                cowStrategy: .never,
                maskingKeyStrategy: .never
            )
        )
    }
    
    Benchmark("websocket_encode_50b_no_space_at_front_100k_frames") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameEncoderBenchmark(
                dataSize: 50,
                runCount: 100_000,
                dataStrategy: .noSpaceAtFront,
                cowStrategy: .never,
                maskingKeyStrategy: .never
            )
        )
    }
    
    Benchmark("websocket_encode_1kb_no_space_at_front_10k_frames") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameEncoderBenchmark(
                dataSize: 1024,
                runCount: 10_000,
                dataStrategy: .noSpaceAtFront,
                cowStrategy: .never,
                maskingKeyStrategy: .never
            )
        )
    }
    
    Benchmark("websocket_decode_125b_10k_frames") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameDecoderBenchmark(
                dataSize: 125,
                runCount: 10_000
            )
        )
    }
    
    Benchmark("websocket_decode_125b_with_a_masking_key_10k_frames") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameDecoderBenchmark(
                dataSize: 125,
                runCount: 10_000,
                maskingKey: [0x80, 0x08, 0x10, 0x01]
            )
        )
    }
    
    Benchmark("websocket_decode_64kb_10k_frames") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameDecoderBenchmark(
                dataSize: Int(UInt16.max),
                runCount: 10_000
            )
        )
    }
    
    Benchmark("websocket_decode_64kb_with_a_masking_key_10k_frames") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameDecoderBenchmark(
                dataSize: Int(UInt16.max),
                runCount: 10_000,
                maskingKey: [0x80, 0x08, 0x10, 0x01]
            )
        )
    }
    
    Benchmark("websocket_decode_64kb_+1_10k_frames") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameDecoderBenchmark(
                dataSize: Int(UInt16.max) + 1,
                runCount: 10_000
            )
        )
    }
    
    Benchmark("websocket_decode_64kb_+1_with_a_masking_key_10k_frames") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: WebSocketFrameDecoderBenchmark(
                dataSize: Int(UInt16.max) + 1,
                runCount: 10_000,
                maskingKey: [0x80, 0x08, 0x10, 0x01]
            )
        )
    }
}
