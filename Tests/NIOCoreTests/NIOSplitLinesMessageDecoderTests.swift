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

import NIOTestUtils
import Testing

@testable import NIOCore

struct NIOSplitLinesMessageDecoderTests {
    @Test
    private func splittingTextWorksSimilarToStandardLibraryStringSplitFunction() async throws {
        for (configuration, arguments) in SplittingTextTestArgument.all {
            #expect(throws: Never.self) {
                do {
                    try ByteToMessageDecoderVerifier.verifyDecoder(
                        inputOutputPairs: arguments[0...0].map { ($0.textBuffer, $0.expectedBuffers) },
                        decoderFactory: {
                            SplitMessageDecoder(
                                omittingEmptySubsequences: configuration.omittingEmptySubsequences,
                                whereSeparator: { $0 == configuration.separator }
                            )
                        }
                    )
                } catch let error as ByteToMessageDecoderVerifier.VerificationError<ByteBuffer> {
                    self.beautifyAndPrint(
                        error: error,
                        omittingEmptySubsequences: configuration.omittingEmptySubsequences,
                        separator: Character(Unicode.Scalar(configuration.separator)).debugDescription
                    )
                    throw error
                }
            }
        }
    }

    @Test
    private func splittingLineSlicesWorksSimilarToStandardLibraryStringSplitFunction() async throws {
        for (configuration, arguments) in SplittingLinesTestArgument.all {
            #expect(throws: Never.self) {
                do {
                    try ByteToMessageDecoderVerifier.verifyDecoder(
                        inputOutputPairs: arguments.map { ($0.textBuffer, $0.expectedBuffers) },
                        decoderFactory: {
                            NIOSplitLinesMessageDecoder(
                                omittingEmptySubsequences: configuration.omittingEmptySubsequences
                            )
                        }
                    )
                } catch let error as ByteToMessageDecoderVerifier.VerificationError<ByteBuffer> {
                    self.beautifyAndPrint(
                        error: error,
                        omittingEmptySubsequences: configuration.omittingEmptySubsequences,
                        separator: "newlines"
                    )
                    throw error
                }
            }
        }
    }

    private func beautifyAndPrint(
        error: ByteToMessageDecoderVerifier.VerificationError<ByteBuffer>,
        omittingEmptySubsequences: Bool,
        separator: String
    ) {
        print("Got ByteToMessageDecoderVerifier.VerificationError")
        print("Inputs:")
        for input in error.inputs {
            print("  \(String(buffer: input).debugDescription)")
        }
        print("Configuration:")
        print("  omittingEmptySubsequences: \(omittingEmptySubsequences)")
        print("  separator: \(separator)")
        print("Error code:")
        print("  \(self.beautifyAndPrint(error.errorCode))")
    }

    func beautifyAndPrint(
        _ errorCode: ByteToMessageDecoderVerifier.VerificationError<ByteBuffer>.ErrorCode
    ) -> String {
        switch errorCode {
        case .wrongProduction(let actual, let expected):
            return
                "wrongProduction: expected \(String(buffer: expected).debugDescription), got \(String(buffer: actual).debugDescription)"
        case .overProduction(let output):
            return "overProduction: \(String(buffer: output).debugDescription)"
        case .underProduction(let expected):
            return "underProduction: expected \(String(buffer: expected).debugDescription), got no output"
        case .leftOversOnDeconstructingChannel(let inbound, let outbound, let pendingOutbound):
            return
                "leftOversOnDeconstructingChannel: got \(inbound.count) inbound, \(outbound.count) outbound, \(pendingOutbound.count) pending outbound"
        }
    }
}

private struct SplittingTextTestArgument {
    struct Configuration: Hashable {
        let separator: UInt8
        let omittingEmptySubsequences: Bool
    }

    let textBuffer: ByteBuffer
    let expectedBuffers: [ByteBuffer]

    static let text = """
           Here's to the   crazy    ones, th    e misfits, t he rebels, the troublemakers, \
        the   round . pegs in the square holes, the ones who    see   thi    ngs
        differently .
        """
    static let separators: [String] = ["a", ".", " ", "\n", ",", "r"]

    static var all: [Configuration: [Self]] {
        var dict = [Configuration: [Self]]()
        let textBuffer = ByteBuffer(string: Self.text)
        for separator in Self.separators {
            for omittingEmptySubsequences in [true, false] {
                let config = Configuration(
                    separator: separator.utf8.first!,
                    omittingEmptySubsequences: omittingEmptySubsequences
                )
                dict[config, default: []].append(
                    Self(
                        textBuffer: textBuffer,
                        expectedBuffers: Self.text.split(
                            omittingEmptySubsequences: omittingEmptySubsequences,
                            whereSeparator: { $0 == separator.first }
                        ).map(ByteBuffer.init)
                    )
                )
            }
        }
        return dict
    }
}

private struct SplittingLinesTestArgument {
    struct Configuration: Hashable {
        let omittingEmptySubsequences: Bool
    }

    let textBuffer: ByteBuffer
    let expectedBuffers: [ByteBuffer]

    /// A text with a lot of line breaks.
    /// U+0009, U+000E are not considered line breaks, they are included since they are right
    /// outside the line-break-byte boundaries (U+000A to U+000D).
    static let text = """
           Here's to the  \n\r\n\u{000B}\n\r\u{000C}\n\r\n\r\n\r\n\n\r\n\r crazy    ones, th    e misfits, t he rebels,
        the troublemakers, \u{0009} the  \u{000C} round \u{000E}. pegs in \u{000B}\u{000C}\r\n\r\n\r\n\r\n\rthe square holes, the ones
        who  \r\n  see   thi \n   ngs differently .\u{000B}
        """

    static var all: [Configuration: [Self]] {
        var dict = [Configuration: [Self]]()
        let textBuffer = ByteBuffer(string: Self.text)
        for omittingEmptySubsequences in [true, false] {
            let config = Configuration(omittingEmptySubsequences: omittingEmptySubsequences)
            dict[config, default: []].append(
                Self(
                    textBuffer: textBuffer,
                    expectedBuffers: Self.text.split(
                        omittingEmptySubsequences: omittingEmptySubsequences,
                        whereSeparator: \.isNewline
                    ).map(ByteBuffer.init)
                )
            )
        }
        return dict
    }
}
