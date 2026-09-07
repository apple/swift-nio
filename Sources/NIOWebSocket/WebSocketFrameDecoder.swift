//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// Errors thrown by the NIO websocket module.
public enum NIOWebSocketError: Error {
    /// The frame being sent is larger than the configured maximum
    /// acceptable frame size
    case invalidFrameLength

    /// A control frame may not be fragmented.
    case fragmentedControlFrame

    /// A control frame may not have a length more than 125 bytes.
    case multiByteControlFrameLength
}

/// An error thrown when an inbound WebSocket frame violates RFC 6455 (§5.1) masking rules.
///
/// A ``WebSocketFrameDecoder`` only produces this error when it has been configured with a
/// ``WebSocketMaskingVerification`` other than ``WebSocketMaskingVerification/disabled``.
public struct NIOWebSocketMaskingError: Error, Hashable {
    private enum Base {
        case maskedFrame
        case unmaskedFrame
    }

    private var base: Base

    private init(_ base: Base) {
        self.base = base
    }

    /// A masked frame was received when an unmasked frame was expected. RFC 6455 (§5.1)
    /// requires that a server not mask any frames that it sends to the client.
    public static let maskedFrame = NIOWebSocketMaskingError(.maskedFrame)

    /// An unmasked frame was received when a masked frame was expected. RFC 6455 (§5.1)
    /// requires that a client mask all frames that it sends to the server.
    public static let unmaskedFrame = NIOWebSocketMaskingError(.unmaskedFrame)
}

extension WebSocketErrorCode {
    init(_ error: NIOWebSocketError) {
        switch error {
        case .invalidFrameLength:
            self = .messageTooLarge
        case .fragmentedControlFrame,
            .multiByteControlFrameLength:
            self = .protocolError
        }
    }
}

extension ByteBuffer {
    /// Applies the WebSocket unmasking operation.
    ///
    /// - Parameters:
    ///   - maskingKey: The masking key.
    ///   - indexOffset: An integer offset to apply to the index into the masking key.
    ///         This is used when masking multiple "contiguous" byte buffers, to ensure that
    ///         the masking key is applied uniformly to the collection rather than from the
    ///         start each time.
    public mutating func webSocketUnmask(_ maskingKey: WebSocketMaskingKey, indexOffset: Int = 0) {
        /// Shhhh: secretly unmasking and masking are the same operation!
        webSocketMask(maskingKey, indexOffset: indexOffset)
    }

    /// Applies the websocket masking operation.
    ///
    /// - Parameters:
    ///   - maskingKey: The masking key.
    ///   - indexOffset: An integer offset to apply to the index into the masking key.
    ///         This is used when masking multiple "contiguous" byte buffers, to ensure that
    ///         the masking key is applied uniformly to the collection rather than from the
    ///         start each time.
    public mutating func webSocketMask(_ maskingKey: WebSocketMaskingKey, indexOffset: Int = 0) {
        self.withUnsafeMutableReadableBytes {
            for (index, byte) in $0.enumerated() {
                $0[index] = byte ^ maskingKey[(index + indexOffset) % 4]
            }
        }
    }
}

/// The current state of the frame decoder.
enum DecoderState {
    /// Waiting for a frame.
    case idle

    /// The initial frame byte has been received, but the length byte
    /// has not.
    case firstByteReceived(firstByte: UInt8)

    /// The length byte indicates that we need to wait for the length word, and we're
    /// currently waiting for it.
    case waitingForLengthWord(firstByte: UInt8, masked: Bool)

    /// The length byte indicates that we need to wait for the length qword, and
    /// we're currently waiting for it.
    case waitingForLengthQWord(firstByte: UInt8, masked: Bool)

    /// The mask bit indicates we are expecting a mask key.
    case waitingForMask(firstByte: UInt8, length: Int)

    /// All the header data is complete, we are waiting for the application data.
    case waitingForData(firstByte: UInt8, length: Int, maskingKey: WebSocketMaskingKey?)
}

enum ParseResult {
    case insufficientData
    case continueParsing
    case result(WebSocketFrame)
}

/// An incremental websocket frame parser.
///
/// This parser attempts to parse a websocket frame incrementally, keeping as much parsing state around as possible to ensure that
/// we don't repeatedly partially parse the data.
struct WSParser {
    /// The current state of the decoder during incremental parse.
    var state: DecoderState = .idle

    mutating func parseStep(_ buffer: inout ByteBuffer) throws -> ParseResult {
        switch self.state {
        case .idle:
            // This is a new buffer. We want to find the first octet and save it off.
            guard let firstByte = buffer.readInteger(as: UInt8.self) else {
                return .insufficientData
            }
            self.state = .firstByteReceived(firstByte: firstByte)
            return .continueParsing

        case .firstByteReceived(let firstByte):
            // Now we're looking for the length. We begin by finding the length byte to see if we
            // need any more data.
            guard let lengthByte = buffer.readInteger(as: UInt8.self) else {
                return .insufficientData
            }

            let masked = (lengthByte & 0x80) != 0

            switch (lengthByte & 0x7F, masked) {
            case (126, _):
                self.state = .waitingForLengthWord(firstByte: firstByte, masked: masked)
            case (127, _):
                self.state = .waitingForLengthQWord(firstByte: firstByte, masked: masked)
            case (let len, true):
                assert(len <= 125)
                self.state = .waitingForMask(firstByte: firstByte, length: Int(len))
            case (let len, false):
                assert(len <= 125)
                self.state = .waitingForData(firstByte: firstByte, length: Int(len), maskingKey: nil)
            }
            return .continueParsing

        case .waitingForLengthWord(let firstByte, let masked):
            // We've got a one-word length here.
            guard let lengthWord = buffer.readInteger(as: UInt16.self) else {
                return .insufficientData
            }

            if masked {
                self.state = .waitingForMask(firstByte: firstByte, length: Int(lengthWord))
            } else {
                self.state = .waitingForData(firstByte: firstByte, length: Int(lengthWord), maskingKey: nil)
            }
            return .continueParsing

        case .waitingForLengthQWord(let firstByte, let masked):
            // We've got a qword of length here.
            guard let lengthQWord = buffer.readInteger(as: UInt64.self) else {
                return .insufficientData
            }

            guard lengthQWord <= UInt64(Int.max) else {
                throw NIOWebSocketError.invalidFrameLength
            }
            let length = Int(lengthQWord)
            if masked {
                self.state = .waitingForMask(firstByte: firstByte, length: length)
            } else {
                self.state = .waitingForData(firstByte: firstByte, length: length, maskingKey: nil)
            }
            return .continueParsing

        case .waitingForMask(let firstByte, let length):
            // We're waiting for the masking key.
            guard let maskingKey = buffer.readInteger(as: UInt32.self) else {
                return .insufficientData
            }

            self.state = .waitingForData(
                firstByte: firstByte,
                length: length,
                maskingKey: WebSocketMaskingKey(networkRepresentation: maskingKey)
            )
            return .continueParsing

        case .waitingForData(let firstByte, let length, let maskingKey):
            guard let data = buffer.readSlice(length: length) else {
                return .insufficientData
            }

            let frame = WebSocketFrame(firstByte: firstByte, maskKey: maskingKey, applicationData: data)
            self.state = .idle
            return .result(frame)
        }
    }

    /// Apply a number of validations to the incremental state, ensuring that the frame we're
    /// receiving is valid.
    func validateState(maxFrameSize: Int, maskingVerification: WebSocketMaskingVerification) throws {
        switch self.state {
        case .waitingForMask(let firstByte, let length), .waitingForData(let firstByte, let length, _):
            if length > maxFrameSize {
                throw NIOWebSocketError.invalidFrameLength
            }

            let isControlFrame = (firstByte & 0x08) != 0
            let isFragment = (firstByte & 0x80) == 0

            if isControlFrame && isFragment {
                throw NIOWebSocketError.fragmentedControlFrame
            }
            if isControlFrame && length > 125 {
                throw NIOWebSocketError.multiByteControlFrameLength
            }

            try self.validateMasking(maskingVerification)
        case .idle, .firstByteReceived, .waitingForLengthWord, .waitingForLengthQWord:
            // No validation necessary in this state as we have no length to validate.
            break
        }
    }

    /// Enforce RFC 6455 (§5.1) masking rules on the frame currently being parsed, if requested.
    private func validateMasking(_ maskingVerification: WebSocketMaskingVerification) throws {
        switch maskingVerification {
        case .disabled:
            break
        case .serverExpectsMaskedFrames:
            // A client must mask every frame it sends to a server. An unmasked frame reaches the
            // `.waitingForData` state with no masking key.
            if case .waitingForData(_, _, .none) = self.state {
                throw NIOWebSocketMaskingError.unmaskedFrame
            }
        case .clientExpectsUnmaskedFrames:
            // A server must not mask frames it sends to a client. A masked frame passes through
            // the `.waitingForMask` state.
            if case .waitingForMask = self.state {
                throw NIOWebSocketMaskingError.maskedFrame
            }
        }
    }
}

/// The masking validation that a ``WebSocketFrameDecoder`` applies to inbound frames.
///
/// RFC 6455 (§5.1) requires that a client mask every frame it sends to a server, and that a
/// server never mask frames it sends to a client. By default the decoder does not enforce these
/// rules, preserving its historic behaviour. A server or client that wishes to reject a
/// non-compliant peer can opt in to the relevant verification.
public enum WebSocketMaskingVerification: Sendable {
    /// Do not verify the masking of inbound frames.
    case disabled

    /// Verify that inbound frames are masked, as a server requires of its clients.
    ///
    /// Unmasked frames are rejected with ``NIOWebSocketMaskingError/unmaskedFrame``.
    case serverExpectsMaskedFrames

    /// Verify that inbound frames are not masked, as a client requires of its server.
    ///
    /// Masked frames are rejected with ``NIOWebSocketMaskingError/maskedFrame``.
    case clientExpectsUnmaskedFrames
}

/// An inbound `ChannelHandler` that deserializes websocket frames into a structured
/// format for further processing.
///
/// This decoder has limited enforcement of compliance to RFC 6455. In particular, to guarantee
/// that the decoder can handle arbitrary extensions, only normative MUST/MUST NOTs that do not
/// relate to extensions (e.g. the requirement that control frames not have lengths larger than
/// 125 bytes) are enforced by this decoder.
///
/// This decoder does not have any support for decoding extensions. If you wish to support
/// extensions, you should implement a message-to-message decoder that performs the appropriate
/// frame transformation as needed. All the frame data is assumed to be application data by this
/// parser.
public final class WebSocketFrameDecoder: ByteToMessageDecoder {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = WebSocketFrame
    public typealias OutboundOut = WebSocketFrame

    /// The maximum frame size the decoder is willing to tolerate from the remote peer.
    let maxFrameSize: Int

    /// The masking rules the decoder enforces on inbound frames.
    let maskingVerification: WebSocketMaskingVerification

    /// Our parser state.
    private var parser = WSParser()

    /// Construct a new `WebSocketFrameDecoder`
    ///
    /// - Parameters:
    ///   - maxFrameSize: The maximum frame size the decoder is willing to tolerate from the
    ///         remote peer. WebSockets in principle allows frame sizes up to `2**64` bytes, but
    ///         this is an objectively unreasonable maximum value (on AMD64 systems it is not
    ///         possible to even allocate a buffer large enough to handle this size), so we
    ///         set a lower one. The default value is the same as the default HTTP/2 max frame
    ///         size, `2**14` bytes. Users may override this to any value up to `UInt32.max`.
    ///         Users are strongly encouraged not to increase this value unless they absolutely
    ///         must, as the decoder will not produce partial frames, meaning that it will hold
    ///         on to data until the *entire* body is received.
    public init(maxFrameSize: Int = 1 << 14) {
        precondition(maxFrameSize <= UInt32.max, "invalid overlarge max frame size")
        self.maxFrameSize = maxFrameSize
        self.maskingVerification = .disabled
    }

    /// Construct a new `WebSocketFrameDecoder`
    ///
    /// - Parameters:
    ///   - maxFrameSize: The maximum frame size the decoder is willing to tolerate from the
    ///         remote peer. WebSockets in principle allows frame sizes up to `2**64` bytes, but
    ///         this is an objectively unreasonable maximum value (on AMD64 systems it is not
    ///         possible to even allocate a buffer large enough to handle this size), so we
    ///         set a lower one. The default value is the same as the default HTTP/2 max frame
    ///         size, `2**14` bytes. Users may override this to any value up to `UInt32.max`.
    ///         Users are strongly encouraged not to increase this value unless they absolutely
    ///         must, as the decoder will not produce partial frames, meaning that it will hold
    ///         on to data until the *entire* body is received.
    ///   - maskingVerification: The masking rules to enforce on inbound frames, per RFC 6455
    ///         (§5.1). Use ``WebSocketMaskingVerification/disabled`` to preserve the decoder's
    ///         historic behaviour of accepting both masked and unmasked frames.
    public init(
        maxFrameSize: Int = 1 << 14,
        maskingVerification: WebSocketMaskingVerification
    ) {
        precondition(maxFrameSize <= UInt32.max, "invalid overlarge max frame size")
        self.maxFrameSize = maxFrameSize
        self.maskingVerification = maskingVerification
    }

    public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // Even though the calling code will loop around calling us in `decode`, we can't quite
        // rely on that: sometimes we have zero-length elements to parse, and the caller doesn't
        // guarantee to call us with zero-length bytes.
        while true {
            switch try parser.parseStep(&buffer) {
            case .result(let frame):
                context.fireChannelRead(WebSocketFrameDecoder.wrapInboundOut(frame))
                return .continue
            case .continueParsing:
                try self.parser.validateState(
                    maxFrameSize: self.maxFrameSize,
                    maskingVerification: self.maskingVerification
                )
            // loop again, might be 'waiting' for 0 bytes
            case .insufficientData:
                return .needMoreData
            }
        }
    }
}

@available(*, unavailable)
extension WebSocketFrameDecoder: Sendable {}
