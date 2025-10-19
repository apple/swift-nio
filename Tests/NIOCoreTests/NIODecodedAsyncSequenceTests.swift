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
        var randomElements: [Int32] = (0..<elementCount).map {
            _ in Int32.random(in: .min ... .max)
        }

        var buffer = ByteBuffer()
        buffer.reserveCapacity(minimumWritableBytes: elementCount)
        for element in randomElements {
            buffer.writeInteger(element)
        }

        let stream = try self.makeFinishedAsyncStream(using: buffer, chunkSize: chunkSize)
        let decodedSequence = stream.decode(using: ByteToInt32Decoder())

        for try await element in decodedSequence {
            #expect(element == randomElements.removeFirst())
        }
    }

    @Test(arguments: Self.testingArguments)
    func decodingThrowsWhenDecoderThrows(elementCount: Int, chunkSize: Int) async throws {
        let randomElements: [Int32] = (0..<elementCount).map {
            _ in Int32.random(in: .min ... .max)
        }

        var buffer = ByteBuffer()
        buffer.reserveCapacity(minimumWritableBytes: elementCount)
        for element in randomElements {
            buffer.writeInteger(element)
        }

        let stream = try self.makeFinishedAsyncStream(using: buffer, chunkSize: chunkSize)
        let decodedSequence = stream.decode(using: ThrowingDecoder())

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
        baseSequence.continuation.finish(throwing: StreamError())

        let decodedSequence = baseSequence.stream.decode(using: ByteToInt32Decoder())

        await #expect(throws: StreamError.self) {
            for try await _ in decodedSequence {
                Issue.record("Should not have reached here")
            }
        }
    }

    private func makeFinishedAsyncStream(
        using buffer: ByteBuffer,
        chunkSize: Int
    ) throws -> AsyncStream<ByteBuffer> {
        var buffer = buffer
        let sequence = AsyncStream<ByteBuffer>.makeStream()
        while buffer.readableBytes > 0 {
            if Int.random(in: 0..<4) == 0 {
                // Insert an empty buffer to test the behavior of the decoder.
                sequence.continuation.yield(ByteBuffer())
                continue
            }
            let length = min(buffer.readableBytes, chunkSize)
            let _slice = buffer.readSlice(length: length)
            let slice = try #require(_slice)
            sequence.continuation.yield(slice)
        }
        sequence.continuation.finish()
        return sequence.stream
    }
}
