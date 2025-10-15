//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import Testing

struct NIODecodedAsyncSequenceTests {
    private final class ByteToInt32Decoder: NIOSingleStepByteToMessageDecoder {
        typealias InboundOut = Int32

        func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
            buffer.readInteger()
        }

        func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
            #expect(seenEOF)
            return try self.decode(buffer: &buffer)
        }
    }

    private final class ThrowingDecoder: NIOSingleStepByteToMessageDecoder {
        typealias InboundOut = Int32

        struct DecoderError: Error {}

        func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
            throw DecoderError()
        }

        func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
            #expect(seenEOF)
            return try self.decode(buffer: &buffer)
        }
    }

    static let testingArguments = [
        (elementCount: 100, chunkSize: 4),
        (elementCount: 89, chunkSize: 4),
        (elementCount: 77, chunkSize: 1),
        (elementCount: 65, chunkSize: 3),
        (elementCount: 61, chunkSize: 100),
        (elementCount: 55, chunkSize: 15),
    ]

    @Test(arguments: Self.testingArguments)
    func decodingWorks(elementCount: Int, chunkSize: Int) async throws {
        let baseSequence = AsyncStream<ByteBuffer>.makeStream()

        var randomElements: [UInt8] = (0..<elementCount).map {
            _ in UInt8.random(in: .min ... .max)
        }

        let buffers =
            randomElements
            .chunks(ofSize: chunkSize)
            .map(ByteBuffer.init(bytes:))

        for buffer in buffers {
            baseSequence.continuation.yield(buffer)
        }
        baseSequence.continuation.finish()

        let decodedSequence = baseSequence.stream.decode(using: ByteToInt32Decoder())

        for try await element in decodedSequence {
            // Create an Int32 from the first 4 UInt8s
            let int32 = randomElements[0..<4].enumerated().reduce(into: Int32(0)) { result, next in
                result |= Int32(next.element) << ((3 - next.offset) * 8)
            }
            randomElements = Array(randomElements[4...])
            #expect(element == int32)
        }
    }

    @Test(arguments: Self.testingArguments)
    func decodingThrowsWhenDecoderThrows(elementCount: Int, chunkSize: Int) async throws {
        let baseSequence = AsyncStream<ByteBuffer>.makeStream()

        let randomElements: [UInt8] = (0..<elementCount).map {
            _ in UInt8.random(in: .min ... .max)
        }

        let buffers =
            randomElements
            .chunks(ofSize: chunkSize)
            .map(ByteBuffer.init(bytes:))

        for buffer in buffers {
            baseSequence.continuation.yield(buffer)
        }
        baseSequence.continuation.finish()

        let decodedSequence = baseSequence.stream.decode(using: ThrowingDecoder())
        await #expect(throws: ThrowingDecoder.DecoderError.self) {
            for try await _ in decodedSequence {
                Issue.record("Should not have reached here")
            }
        }
    }

    @Test
    func decodingThrowsWhenStreamThrows() async throws {
        struct StreamError: Error {}

        let baseSequence = AsyncThrowingStream<ByteBuffer, any Error>.makeStream()

        /// Sleep for 50ms to simulate asynchronous work
        try await Task.sleep(nanoseconds: 50_000_000)
        baseSequence.continuation.finish(throwing: StreamError())

        let decodedSequence = baseSequence.stream.decode(using: ByteToInt32Decoder())

        await #expect(throws: StreamError.self) {
            for try await _ in decodedSequence {
                Issue.record("Should not have reached here")
            }
        }
    }
}

extension Array {
    fileprivate func chunks(ofSize size: Int) -> [[Element]] {
        stride(from: 0, to: self.count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, self.count)])
        }
    }
}
