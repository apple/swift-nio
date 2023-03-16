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
    Benchmark.defaultConfiguration = .init(metrics:[.wallClock, .mallocCountTotal, .throughput],
                                           warmupIterations: 0,
                                           maxDuration: .seconds(1),
                                           maxIterations: Int.max)

    let mediumConfiguration = Benchmark.Configuration(metrics:[.wallClock, .mallocCountTotal],
                                                      warmupIterations: 0,
                                                      scalingFactor: .kilo,
                                                      maxDuration: .seconds(1),
                                                      maxIterations: Int.max)

    let largeConfiguration = Benchmark.Configuration(metrics:[.wallClock, .mallocCountTotal],
                                                      warmupIterations: 0,
                                                      scalingFactor: .mega,
                                                      maxDuration: .seconds(1),
                                                      maxIterations: Int.max)

    Benchmark("bytebuffer_write_12MB_short_string_literals") { benchmark in
        let bufferSize = 12 * 1024 * 1024
        var buffer = ByteBufferAllocator().buffer(capacity: bufferSize)

        for _ in 0 ..< 3 {
            buffer.clear()
            for _ in 0 ..< (bufferSize / 4) {
                buffer.writeString("abcd")
            }
        }

        let readableBytes = buffer.readableBytes
        precondition(readableBytes == bufferSize)
        blackHole(readableBytes)
    }

    Benchmark("bytebuffer_write_12MB_short_calculated_strings") { benchmark in
        let bufferSize = 12 * 1024 * 1024
        var buffer = ByteBufferAllocator().buffer(capacity: bufferSize)
        let s = someString(size: 4)

        for _ in 0 ..< 1 {
            buffer.clear()
            for _ in  0 ..< (bufferSize / 4) {
                buffer.writeString(s)
            }
        }

        let readableBytes = buffer.readableBytes
        precondition(readableBytes == bufferSize)
        blackHole(readableBytes)
    }

    // MARK: Extra check iteration count
    Benchmark("bytebuffer_write_12MB_medium_string_literals") { benchmark in
        let bufferSize = 12 * 1024 * 1024
        var buffer = ByteBufferAllocator().buffer(capacity: bufferSize)

        buffer.clear()
        for _ in  0 ..< (bufferSize / 24) {
            buffer.writeString("012345678901234567890123")
        }

        let readableBytes = buffer.readableBytes
        precondition(readableBytes == bufferSize)
        blackHole(readableBytes)
    }

    Benchmark("bytebuffer_write_12MB_medium_calculated_strings") { benchmark in
        let bufferSize = 12 * 1024 * 1024
        var buffer = ByteBufferAllocator().buffer(capacity: bufferSize)
        let s = someString(size: 24)

        for _ in 0 ..< 5 {
            buffer.clear()
            for _ in 0 ..< (bufferSize / 24) {
                buffer.writeString(s)
            }
        }

        let readableBytes = buffer.readableBytes
        precondition(readableBytes == bufferSize)
        blackHole(readableBytes)
    }

    Benchmark("bytebuffer_write_12MB_large_calculated_strings") { benchmark in
        let bufferSize = 12 * 1024 * 1024
        var buffer = ByteBufferAllocator().buffer(capacity: bufferSize)
        let s = someString(size: 1024 * 1024)

        for _ in 0 ..< 5 {
            buffer.clear()
            for _ in 0 ..< 12 {
                buffer.writeString(s)
            }
        }

        let readableBytes = buffer.readableBytes
        precondition(readableBytes == bufferSize)
        blackHole(readableBytes)
    }

    Benchmark("bytebuffer_lots_of_rw",
              configuration: largeConfiguration) { benchmark in
        let dispatchData = ("A" as StaticString).withUTF8Buffer { ptr in
            DispatchData(bytes: UnsafeRawBufferPointer(start: UnsafeRawPointer(ptr.baseAddress), count: ptr.count))
        }
        var buffer = ByteBufferAllocator().buffer(capacity: 7 * 1024 * 1024)
        let substring = Substring("A")
        @inline(never)
        func doWrites(buffer: inout ByteBuffer, dispatchData: DispatchData, substring: Substring) {
            /* all of those should be 0 allocations */

            // buffer.writeBytes(foundationData) // see SR-7542
            buffer.writeBytes([0x41])
            buffer.writeBytes(dispatchData)
            buffer.writeBytes("A".utf8)
            buffer.writeString("A")
            buffer.writeStaticString("A")
            buffer.writeInteger(0x41, as: UInt8.self)
            buffer.writeSubstring(substring)
        }
        @inline(never)
        func doReads(buffer: inout ByteBuffer) {
            /* these ones are zero allocations */
            let val = buffer.readInteger(as: UInt8.self)
            precondition(0x41 == val, "\(val!)")
            var slice = buffer.readSlice(length: 1)
            let sliceVal = slice!.readInteger(as: UInt8.self)
            precondition(0x41 == sliceVal, "\(sliceVal!)")
            buffer.withUnsafeReadableBytes { ptr in
                precondition(ptr[0] == 0x41)
            }

            /* those down here should be one allocation each */
            let arr = buffer.readBytes(length: 1)
            precondition([0x41] == arr!, "\(arr!)")
            let str = buffer.readString(length: 1)
            precondition("A" == str, "\(str!)")
        }
        for _ in benchmark.scaledIterations {
            doWrites(buffer: &buffer, dispatchData: dispatchData, substring: substring)
            doReads(buffer: &buffer)
        }
        blackHole(buffer.readableBytes)

    }

    Benchmark("bytebuffer_write_http_response_ascii_only_as_string",
              configuration: mediumConfiguration) { benchmark in
        var buffer = ByteBufferAllocator().buffer(capacity: 16 * 1024)
        for _ in benchmark.scaledIterations {
            writeExampleHTTPResponseAsString(buffer: &buffer)
            buffer.writeString(htmlASCIIOnly)
            buffer.clear()
        }
        blackHole(buffer.readableBytes)
    }

    Benchmark("bytebuffer_write_http_response_ascii_only_as_staticstring",
              configuration: largeConfiguration) { benchmark in
        var buffer = ByteBufferAllocator().buffer(capacity: 16 * 1024)
        for _ in benchmark.scaledIterations {
            writeExampleHTTPResponseAsStaticString(buffer: &buffer)
            buffer.writeStaticString(htmlASCIIOnlyStaticString)
            buffer.clear()
        }
        blackHole(buffer.readableBytes)
    }

    Benchmark("bytebuffer_write_http_response_some_nonascii_as_string",
              configuration: largeConfiguration) { benchmark in
        var buffer = ByteBufferAllocator().buffer(capacity: 16 * 1024)
        for _ in benchmark.scaledIterations {
            writeExampleHTTPResponseAsString(buffer: &buffer)
            buffer.writeString(htmlMostlyASCII)
            buffer.clear()
        }
        blackHole(buffer.readableBytes)
    }

    Benchmark("bytebuffer_write_http_response_some_nonascii_as_staticstring",
              configuration: largeConfiguration) { benchmark in
        var buffer = ByteBufferAllocator().buffer(capacity: 16 * 1024)
        for _ in benchmark.scaledIterations {
            writeExampleHTTPResponseAsStaticString(buffer: &buffer)
            buffer.writeStaticString(htmlMostlyASCIIStaticString)
            buffer.clear()
        }
        blackHole(buffer.readableBytes)
    }

    Benchmark("byte_buffer_view_iterator_1mb") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: ByteBufferViewIteratorBenchmark(
                iterations: 20,
                bufferSize: 1024*1024
            )
        )
    }

    Benchmark("byte_buffer_view_contains_12mb") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: ByteBufferViewContainsBenchmark(
                iterations: 5,
                bufferSize: 12*1024*1024
            )
        )
    }


    Benchmark("bytebuffer_rw_10_uint32s") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: ByteBufferReadWriteMultipleIntegersBenchmark<UInt32>(
                iterations: 100_000,
                numberOfInts: 10
            )
        )
    }

    Benchmark("bytebuffer_multi_rw_10_uint32s") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: ByteBufferMultiReadWriteTenIntegersBenchmark<UInt32>(
                iterations: 1_000_000
            )
        )
    }

    Benchmark("bytebufferview_copy_to_array_100k_times_1kb") { benchmark in
        try runNIOBenchmark(
            benchmark: benchmark,
            running: ByteBufferViewCopyToArrayBenchmark(
                iterations: 100_000,
                size: 1024
            )
        )
    }
}
