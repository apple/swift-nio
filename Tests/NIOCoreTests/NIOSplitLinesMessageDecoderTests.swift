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

@testable import NIOCore
import Testing

struct NIOSplitLinesMessageDecoderTests {
    @Test(arguments: SplittingTextTestArgument.all)
    private func splittingTextWorksSimilarToStandardLibraryStringSplitFunction(
        argument: SplittingTextTestArgument
    ) async throws {
        let buffer = ByteBuffer(string: argument.text)
        let stream = try self.makeFinishedAsyncStream(using: buffer, chunkSize: argument.chunkSize)

        let decodedSequence = stream.decode(
            using: SplitMessageDecoder(
                omittingEmptySubsequences: argument.omittingEmptySubsequences,
                whereSeparator: { $0 == argument.separator }
            )
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

    @Test(arguments: SplittingLinesTestArgument.all)
    private func splittingLineSlicesWorksSimilarToStandardLibraryStringSplitFunction(
        argument: SplittingLinesTestArgument
    ) async throws {
        let buffer = ByteBuffer(string: argument.text)
        let stream = try self.makeFinishedAsyncStream(using: buffer, chunkSize: argument.chunkSize)

        let decodedSequence = stream.splitLines(
            omittingEmptySubsequences: argument.omittingEmptySubsequences
        )

        let expectedElements = argument.text.split(
            omittingEmptySubsequences: argument.omittingEmptySubsequences,
            whereSeparator: \.isNewline
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

    @Test(arguments: SplittingLinesTestArgument.all)
    private func splittingLinesWorksSimilarToStandardLibraryStringSplitFunction(
        argument: SplittingLinesTestArgument
    ) async throws {
        let buffer = ByteBuffer(string: argument.text)
        let stream = try self.makeFinishedAsyncStream(using: buffer, chunkSize: argument.chunkSize)

        let decodedSequence = stream.splitUTF8Lines(
            omittingEmptySubsequences: argument.omittingEmptySubsequences
        )

        let expectedElements = argument.text.split(
            omittingEmptySubsequences: argument.omittingEmptySubsequences,
            whereSeparator: \.isNewline
        ).map(String.init)

        var producedElements = [String]()
        producedElements.reserveCapacity(expectedElements.count)
        for try await element in decodedSequence {
            producedElements.append(element)
        }

        #expect(
            producedElements == expectedElements,
            """
            Produced elements: \(producedElements.debugDescription)
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

private struct SplittingLinesTestArgument {
    let text: String
    let omittingEmptySubsequences: Bool
    let chunkSize: Int

    /// A text with a lot of line breaks.
    /// U+0009, U+000E are not considered line breaks, they are included since they are right
    /// outside the line-break-byte boundaries (U+000A to U+000D).
    static let text = """
           Here's to the  \n\r\n\u{000B}\n\r\u{000C}\n\r\n\r\n\r\n\n\r\n\r crazy    ones, th    e misfits, t he rebels,
        the troublemakers, \u{0009} the  \u{000C} round \u{000E}. pegs in \u{000B}\u{000C}\r\n\r\n\r\n\r\n\rthe square holes, the ones
        who  \r\n  see   thi \n   ngs differently .\u{000B}
        """
    static let chunkSizes: [Int] = [1, 2, 5, 8, 10, 15, 16, 20, 50, 100, 500]

    static var all: [Self] {
        [true, false].flatMap { omittingEmptySubsequences -> [Self] in
            Self.chunkSizes.map { chunkSize -> Self in
                Self(
                    text: Self.text,
                    omittingEmptySubsequences: omittingEmptySubsequences,
                    chunkSize: chunkSize
                )
            }
        }
    }
}
