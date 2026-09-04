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

// Benchmarks that stress the small-read accessors on `ByteBuffer` from a *different*
// module than `NIOCore`. That distinction matters: inside `NIOCore` whole-module
// optimisation can discharge the exclusivity check on `_Storage._bytes` statically,
// but a client module inlining the same `@inlinable` accessor cannot, and pays a
// `swift_beginAccess` runtime call per out-of-line function.

private let payload: [UInt8] = (0..<1024).map { UInt8($0 % 251) }

/// A QUIC-style variable length integer decode: byte-at-a-time, branchy, tiny reads.
@inline(never)
private func decodeQUICVarint(_ buffer: inout ByteBuffer) -> UInt64? {
    guard let first: UInt8 = buffer.getInteger(at: buffer.readerIndex) else { return nil }
    let prefix = first >> 6
    let length = 1 << prefix
    guard buffer.readableBytes >= length else { return nil }
    var value = UInt64(first & 0x3F)
    buffer.moveReaderIndex(forwardBy: 1)
    for _ in 1..<length {
        guard let next: UInt8 = buffer.readInteger() else { return nil }
        value = (value << 8) | UInt64(next)
    }
    return value
}

let byteBufferBenchmarks: @Sendable () -> Void = {
    #if LOCAL_TESTING
    let metrics: [BenchmarkMetric] = [.mallocCountTotal, .wallClock, .instructions]
    #else
    let metrics: [BenchmarkMetric] = [.mallocCountTotal]
    #endif

    Benchmark(
        "ByteBuffer.readInteger(UInt8) x1024",
        configuration: .init(metrics: metrics, scalingFactor: .kilo, maxDuration: .seconds(3))
    ) { benchmark in
        let source = ByteBuffer(bytes: payload)
        benchmark.startMeasurement()
        defer { benchmark.stopMeasurement() }
        for _ in benchmark.scaledIterations {
            var buffer = source
            var acc: UInt64 = 0
            while let byte: UInt8 = buffer.readInteger() {
                acc &+= UInt64(byte)
            }
            blackHole(acc)
        }
    }

    Benchmark(
        "ByteBuffer.getInteger(UInt32) random access x1024",
        configuration: .init(metrics: metrics, scalingFactor: .kilo, maxDuration: .seconds(3))
    ) { benchmark in
        let buffer = ByteBuffer(bytes: payload)
        benchmark.startMeasurement()
        defer { benchmark.stopMeasurement() }
        for _ in benchmark.scaledIterations {
            var acc: UInt32 = 0
            for i in stride(from: 0, to: 1020, by: 4) {
                acc &+= buffer.getInteger(at: i) ?? 0
            }
            blackHole(acc)
        }
    }

    Benchmark(
        "ByteBuffer.readableBytesView iterate x1024",
        configuration: .init(metrics: metrics, scalingFactor: .kilo, maxDuration: .seconds(3))
    ) { benchmark in
        let buffer = ByteBuffer(bytes: payload)
        benchmark.startMeasurement()
        defer { benchmark.stopMeasurement() }
        for _ in benchmark.scaledIterations {
            var acc: UInt64 = 0
            for byte in buffer.readableBytesView {
                acc &+= UInt64(byte)
            }
            blackHole(acc)
        }
    }

    Benchmark(
        "ByteBuffer.QUIC varint decode x256",
        configuration: .init(metrics: metrics, scalingFactor: .kilo, maxDuration: .seconds(3))
    ) { benchmark in
        var encoded = ByteBuffer()
        for i in 0..<256 {
            // 4-byte form: 0b10xxxxxx
            encoded.writeInteger(UInt32(0x8000_0000 | UInt32(i)))
        }
        benchmark.startMeasurement()
        defer { benchmark.stopMeasurement() }
        for _ in benchmark.scaledIterations {
            var buffer = encoded
            var acc: UInt64 = 0
            while let v = decodeQUICVarint(&buffer) {
                acc &+= v
            }
            blackHole(acc)
        }
    }

    Benchmark(
        "ByteBuffer.writeInteger(UInt8) x1024",
        configuration: .init(metrics: metrics, scalingFactor: .kilo, maxDuration: .seconds(3))
    ) { benchmark in
        var scratch = ByteBuffer()
        scratch.reserveCapacity(2048)
        benchmark.startMeasurement()
        defer { benchmark.stopMeasurement() }
        for _ in benchmark.scaledIterations {
            scratch.clear()
            for byte in payload {
                scratch.writeInteger(byte)
            }
            blackHole(scratch.readableBytes)
        }
    }

    Benchmark(
        "ByteBuffer.getString x1024",
        configuration: .init(metrics: metrics, scalingFactor: .kilo, maxDuration: .seconds(3))
    ) { benchmark in
        let buffer = ByteBuffer(repeating: UInt8(ascii: "a"), count: 1024)
        benchmark.startMeasurement()
        defer { benchmark.stopMeasurement() }
        for _ in benchmark.scaledIterations {
            blackHole(buffer.getString(at: 0, length: 1024))
        }
    }
}
