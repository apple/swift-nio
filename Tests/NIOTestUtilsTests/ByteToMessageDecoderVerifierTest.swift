//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOPosix
import NIOTestUtils
import Testing

@testable import NIOCore

typealias VerificationError = ByteToMessageDecoderVerifier.VerificationError<String>

struct ByteToMessageDecoderVerifierTests {
    @Test func wrongResults() throws {
        struct AlwaysProduceY: ByteToMessageDecoder {
            typealias InboundOut = String

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                buffer.moveReaderIndex(to: buffer.writerIndex)
                context.fireChannelRead(Self.wrapInboundOut("Y"))
                return .needMoreData
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                while try self.decode(context: context, buffer: &buffer) == .continue {}
                return .needMoreData
            }
        }

        let error = try #require(throws: VerificationError.self) {
            try ByteToMessageDecoderVerifier.verifyDecoder(
                stringInputOutputPairs: [("x", ["x"])],
                decoderFactory: AlwaysProduceY.init
            )
        }

        #expect(1 == error.inputs.count)
        switch error.errorCode {
        case .wrongProduction(let actual, let expected):
            #expect("Y" == actual)
            #expect("x" == expected)
        default:
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func noOutputWhenWeShouldHaveOutput() throws {
        struct NeverProduce: ByteToMessageDecoder {
            typealias InboundOut = String

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                buffer.moveReaderIndex(to: buffer.writerIndex)
                return .needMoreData
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                while try self.decode(context: context, buffer: &buffer) == .continue {}
                return .needMoreData
            }
        }

        let error = try #require(throws: VerificationError.self) {
            try ByteToMessageDecoderVerifier.verifyDecoder(
                stringInputOutputPairs: [("x", ["x"])],
                decoderFactory: NeverProduce.init
            )
        }

        #expect(1 == error.inputs.count)
        switch error.errorCode {
        case .underProduction(let expected):
            #expect("x" == expected)
        default:
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func outputWhenWeShouldNotProduceOutput() throws {
        struct ProduceTooEarly: ByteToMessageDecoder {
            typealias InboundOut = String

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                context.fireChannelRead(Self.wrapInboundOut("Y"))
                return .needMoreData
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                while try self.decode(context: context, buffer: &buffer) == .continue {}
                return .needMoreData
            }
        }

        let error = try #require(throws: VerificationError.self) {
            try ByteToMessageDecoderVerifier.verifyDecoder(
                stringInputOutputPairs: [("xxxxxx", ["Y"])],
                decoderFactory: ProduceTooEarly.init
            )
        }

        switch error.errorCode {
        case .overProduction(let actual):
            #expect("Y" == actual)
        default:
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func leftovers() throws {
        struct NeverDoAnything: ByteToMessageDecoder {
            typealias InboundOut = String

            func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
                .needMoreData
            }

            func decodeLast(
                context: ChannelHandlerContext,
                buffer: inout ByteBuffer,
                seenEOF: Bool
            ) throws -> DecodingState {
                while try self.decode(context: context, buffer: &buffer) == .continue {}
                if buffer.readableBytes > 0 {
                    context.fireChannelRead(Self.wrapInboundOut("leftover"))
                }
                return .needMoreData
            }
        }

        let error = try #require(throws: VerificationError.self) {
            try ByteToMessageDecoderVerifier.verifyDecoder(
                stringInputOutputPairs: [("xxxxxx", [])],
                decoderFactory: NeverDoAnything.init
            )
        }

        switch error.errorCode {
        case .leftOversOnDeconstructingChannel(
            let inbound,
            let outbound,
            pendingOutbound: let pending
        ):
            #expect(0 == outbound.count)
            #expect(["leftover"] == inbound.map { $0.tryAs(type: String.self) })
            #expect(0 == pending.count)
        default:
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Non-copyable decoders

    /// Decodes one byte into a one character `String`.
    private struct NonCopyableOneByteDecoder: NIOSingleStepByteToMessageDecoder, ~Copyable {
        typealias InboundOut = String

        mutating func decode(buffer: inout ByteBuffer) throws -> String? {
            buffer.readString(length: 1)
        }

        mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> String? {
            try self.decode(buffer: &buffer)
        }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func nonCopyableDecoderIsVerified() throws {
        try ByteToMessageDecoderVerifier.verifyDecoder(
            stringInputOutputPairs: [("x", ["x"]), ("y", ["y"])],
            decoderFactory: NonCopyableOneByteDecoder.init
        )
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func nonCopyableDecoderWrongResults() throws {
        struct AlwaysProduceY: NIOSingleStepByteToMessageDecoder, ~Copyable {
            typealias InboundOut = String

            mutating func decode(buffer: inout ByteBuffer) throws -> String? {
                guard buffer.readableBytes > 0 else { return nil }
                buffer.moveReaderIndex(to: buffer.writerIndex)
                return "Y"
            }

            mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> String? {
                try self.decode(buffer: &buffer)
            }
        }

        let error = try #require(throws: VerificationError.self) {
            try ByteToMessageDecoderVerifier.verifyDecoder(
                stringInputOutputPairs: [("x", ["x"])],
                decoderFactory: AlwaysProduceY.init
            )
        }

        #expect(1 == error.inputs.count)
        switch error.errorCode {
        case .wrongProduction(let actual, let expected):
            #expect("Y" == actual)
            #expect("x" == expected)
        default:
            Issue.record("unexpected error: \(error)")
        }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func nonCopyableDecoderNoOutputWhenWeShouldHaveOutput() throws {
        struct NeverProduce: NIOSingleStepByteToMessageDecoder, ~Copyable {
            typealias InboundOut = String

            mutating func decode(buffer: inout ByteBuffer) throws -> String? {
                buffer.moveReaderIndex(to: buffer.writerIndex)
                return nil
            }

            mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> String? {
                try self.decode(buffer: &buffer)
            }
        }

        let error = try #require(throws: VerificationError.self) {
            try ByteToMessageDecoderVerifier.verifyDecoder(
                stringInputOutputPairs: [("x", ["x"])],
                decoderFactory: NeverProduce.init
            )
        }

        #expect(1 == error.inputs.count)
        switch error.errorCode {
        case .underProduction(let expected):
            #expect("x" == expected)
        default:
            Issue.record("unexpected error: \(error)")
        }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func nonCopyableDecoderOutputWhenWeShouldNotProduceOutput() throws {
        let error = try #require(throws: VerificationError.self) {
            try ByteToMessageDecoderVerifier.verifyDecoder(
                // The decoder produces one message per byte, so it over-produces on the second byte.
                stringInputOutputPairs: [("xy", ["x"])],
                decoderFactory: NonCopyableOneByteDecoder.init
            )
        }

        switch error.errorCode {
        case .overProduction(let actual):
            #expect("y" == actual)
        default:
            Issue.record("unexpected error: \(error)")
        }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func nonCopyableDecoderLeftovers() throws {
        struct NeverDoAnything: NIOSingleStepByteToMessageDecoder, ~Copyable {
            typealias InboundOut = String

            mutating func decode(buffer: inout ByteBuffer) throws -> String? {
                nil
            }

            mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> String? {
                nil
            }
        }

        let error = try #require(throws: VerificationError.self) {
            try ByteToMessageDecoderVerifier.verifyDecoder(
                stringInputOutputPairs: [("xxxxxx", [])],
                decoderFactory: NeverDoAnything.init
            )
        }

        switch error.errorCode {
        case .leftOversOnDeconstructingChannel(let inbound, let outbound, pendingOutbound: let pending):
            // The bytes the decoder never consumed sit in `ByteToMessageHandler`'s buffer rather than in the
            // `Channel`, so the left overs are reported as empty.
            #expect(0 == inbound.count)
            #expect(0 == outbound.count)
            #expect(0 == pending.count)
        default:
            Issue.record("unexpected error: \(error)")
        }
    }
}
