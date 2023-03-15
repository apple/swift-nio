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
import NIOCore
import Dispatch

import BenchmarkSupport
@main
extension BenchmarkRunner {}


@_dynamicReplacement(for: registerBenchmarks)
func benchmarks() {
    Benchmark.defaultConfiguration = .init(metrics:[.wallClock, .mallocCountTotal],
                                           warmupIterations: 0,
                                           scalingFactor: .one,
                                           maxDuration: .milliseconds(500),
                                           maxIterations: Int.max)
    
    func measureAndPrint<B: NIOPerformanceTester.Benchmark>(benchmark: BenchmarkSupport.Benchmark,
                                                            running: B) throws {
        try running.setUp()
        defer {
            running.tearDown()
        }
        
        blackHole(try running.run())
    }
    
    Benchmark("websocket_encode_50b_space_at_front_100k_frames_cow") { benchmark in
        try measureAndPrint(
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
        try measureAndPrint(
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
        try measureAndPrint(
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
        try measureAndPrint(
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
        try measureAndPrint(
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
        try measureAndPrint(
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
        try measureAndPrint(
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
        try measureAndPrint(
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
        try measureAndPrint(
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
        try measureAndPrint(
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
        try measureAndPrint(
            benchmark: benchmark,
            running: WebSocketFrameDecoderBenchmark(
                dataSize: 125,
                runCount: 10_000
            )
        )
    }
    
    Benchmark("websocket_decode_125b_with_a_masking_key_10k_frames") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: WebSocketFrameDecoderBenchmark(
                dataSize: 125,
                runCount: 10_000,
                maskingKey: [0x80, 0x08, 0x10, 0x01]
            )
        )
    }
    
    Benchmark("websocket_decode_64kb_10k_frames") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: WebSocketFrameDecoderBenchmark(
                dataSize: Int(UInt16.max),
                runCount: 10_000
            )
        )
    }
    
    Benchmark("websocket_decode_64kb_with_a_masking_key_10k_frames") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: WebSocketFrameDecoderBenchmark(
                dataSize: Int(UInt16.max),
                runCount: 10_000,
                maskingKey: [0x80, 0x08, 0x10, 0x01]
            )
        )
    }
    
    Benchmark("websocket_decode_64kb_+1_10k_frames") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: WebSocketFrameDecoderBenchmark(
                dataSize: Int(UInt16.max) + 1,
                runCount: 10_000
            )
        )
    }
    
    Benchmark("websocket_decode_64kb_+1_with_a_masking_key_10k_frames") { benchmark in
        try measureAndPrint(
            benchmark: benchmark,
            running: WebSocketFrameDecoderBenchmark(
                dataSize: Int(UInt16.max) + 1,
                runCount: 10_000,
                maskingKey: [0x80, 0x08, 0x10, 0x01]
            )
        )
    }
}
