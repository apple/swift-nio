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

    @Test(arguments: SplittingTextTestArgument.all)
    private func splittingTextWorksSimilarToStandardLibraryStringSplitFunctions(
        argument: SplittingTextTestArgument
    ) async throws {
        let buffer = ByteBuffer(string: argument.text)
        let stream = try self.makeFinishedAsyncStream(using: buffer, chunkSize: argument.chunkSize)

        let decodedSequence = stream.split(
            separator: argument.separator,
            omittingEmptySubsequences: argument.omittingEmptySubsequences
        )

        let expectedElements = argument.text.split(
            separator: Character(Unicode.Scalar(argument.separator)),
            omittingEmptySubsequences: argument.omittingEmptySubsequences
        ).map(String.init)

        var producedElements = [ByteBuffer]()
        producedElements.reserveCapacity(expectedElements.count)
        for try await element in decodedSequence {
            producedElements.append(element)
        }

        #expect(
            producedElements == expectedElements.map(ByteBuffer.init),
            """
            Produced elements: \(producedElements.map(String.init(buffer:)).debugDescription)
            Expected elements: \(expectedElements.debugDescription)
            """,
        )
    }

    private func makeFinishedAsyncStream(
        using buffer: ByteBuffer,
        chunkSize: Int
    ) throws -> AsyncStream<ByteBuffer> {
        var buffer = buffer
        let sequence = AsyncStream<ByteBuffer>.makeStream()
        while buffer.readableBytes > 0 {
            let length = min(buffer.readableBytes, chunkSize)
            let _slice = buffer.readSlice(length: length)
            let slice = try #require(_slice)
            sequence.continuation.yield(slice)
        }
        sequence.continuation.finish()
        return sequence.stream
    }
}

private struct SplittingTextTestArgument {
    let text: String
    let separator: UInt8
    let omittingEmptySubsequences: Bool
    let chunkSize: Int

    static let text = """
           Here's to the   crazy    ones, th    e misfits, t he rebels, the troublemakers, \
        the   round . pegs in the square holes, the ones who    see   thi    ngs
        differently .
        """
    static let separators: [String] = ["a", ".", " ", "\n", ",", "r"]
    static let chunkSizes: [Int] = [1, 2, 5, 8, 10, 15, 16, 20, 50, 100, 500]

    static var all: [Self] {
        Self.separators.flatMap { separator -> [Self] in
            [true, false].flatMap { omittingEmptySubsequences -> [Self] in
                Self.chunkSizes.map { chunkSize -> Self in
                    Self(
                        text: Self.text,
                        separator: separator.utf8.first!,
                        omittingEmptySubsequences: omittingEmptySubsequences,
                        chunkSize: chunkSize
                    )
                }
            }
        }
    }
}
