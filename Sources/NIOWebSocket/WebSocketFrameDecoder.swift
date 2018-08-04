//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

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

internal extension WebSocketErrorCode {
    internal init(_ error: NIOWebSocketError) {
        switch error {
        case .invalidFrameLength:
            self = .messageTooLarge
        case .fragmentedControlFrame,
             .multiByteControlFrameLength:
            self = .protocolError
        }
    }
}

public extension ByteBuffer {
    /// Applies the WebSocket unmasking operation.
    ///
    /// - parameters:
    ///     - maskingKey: The masking key.
    public mutating func webSocketUnmask(_ maskingKey: WebSocketMaskingKey, indexOffset: Int = 0) {
        /// Shhhh: secretly unmasking and masking are the same operation!
        webSocketMask(maskingKey, indexOffset: indexOffset)
    }

    /// Applies the websocket masking operation.
    ///
    /// - parameters:
    ///     - maskingKey: The masking key.
    ///     - indexOffset: An integer offset to apply to the index into the masking key.
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

    mutating func parseStep(_ buffer: inout ByteBuffer) -> ParseResult {
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

            if masked {
                self.state = .waitingForMask(firstByte: firstByte, length: Int(lengthQWord))
            } else {
                self.state = .waitingForData(firstByte: firstByte, length: Int(lengthQWord), maskingKey: nil)
            }
            return .continueParsing

        case .waitingForMask(let firstByte, let length):
            // We're waiting for the masking key.
            guard let maskingKey = buffer.readInteger(as: UInt32.self) else {
                return .insufficientData
            }

            self.state = .waitingForData(firstByte: firstByte, length: length, maskingKey: WebSocketMaskingKey(networkRepresentation: maskingKey))
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
    func validateState(maxFrameSize: Int) throws {
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
        case .idle, .firstByteReceived, .waitingForLengthWord, .waitingForLengthQWord:
            // No validation necessary in this state as we have no length to validate.
            break
        }
    }
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
    public var cumulationBuffer: ByteBuffer? = nil

    /// The maximum frame size the decoder is willing to tolerate from the remote peer.
    /* private but tests */ let maxFrameSize: Int

    /// Our parser state.
    private var parser = WSParser()

    /// Whether we should continue to parse.
    private var shouldKeepParsing = true

    /// Whether this `ChannelHandler` should be performing automatic error handling.
    private let automaticErrorHandling: Bool

    /// Construct a new `WebSocketFrameDecoder`
    ///
    /// - parameters:
    ///     - maxFrameSize: The maximum frame size the decoder is willing to tolerate from the
    ///         remote peer. WebSockets in principle allows frame sizes up to `2**64` bytes, but
    ///         this is an objectively unreasonable maximum value (on AMD64 systems it is not
    ///         possible to even allocate a buffer large enough to handle this size), so we
    ///         set a lower one. The default value is the same as the default HTTP/2 max frame
    ///         size, `2**14` bytes. Users may override this to any value up to `UInt32.max`.
    ///         Users are strongly encouraged not to increase this value unless they absolutely
    ///         must, as the decoder will not produce partial frames, meaning that it will hold
    ///         on to data until the *entire* body is received.
    ///     - automaticErrorHandling: Whether this `ChannelHandler` should automatically handle
    ///         protocol errors in frame serialization, or whether it should allow the pipeline
    ///         to handle them.
    public init(maxFrameSize: Int = 1 << 14, automaticErrorHandling: Bool = true) {
        precondition(maxFrameSize <= UInt32.max, "invalid overlarge max frame size")
        self.maxFrameSize = maxFrameSize
        self.automaticErrorHandling = automaticErrorHandling
    }

    public func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState  {
        // Even though the calling code will loop around calling us in `decode`, we can't quite
        // rely on that: sometimes we have zero-length elements to parse, and the caller doesn't
        // guarantee to call us with zero-length bytes.
        parseLoop: while self.shouldKeepParsing {
            switch parser.parseStep(&buffer) {
            case .result(let frame):
                ctx.fireChannelRead(self.wrapInboundOut(frame))
            case .continueParsing:
                do {
                    try self.parser.validateState(maxFrameSize: self.maxFrameSize)
                } catch {
                    self.handleError(error, ctx: ctx)
                }
            case .insufficientData:
                break parseLoop
            }
        }

        // We parse eagerly, so once we get here we definitionally need more data.
        return .needMoreData
    }

    public func decodeLast(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // EOF is not semantic in WebSocket, so ignore this.
        return .needMoreData
    }



    /// We hit a decoding error, we're going to tear things down now. To do this we're
    /// basically going to send an error frame and then close the connection. Once we're
    /// in this state we do no further parsing.
    ///
    /// A clean websocket shutdown is not really supposed to have an immediate close,
    /// but we're doing that because the remote peer has prevented us from doing
    /// further frame parsing, so we can't really wait for the next frame.
    private func handleError(_ error: Error, ctx: ChannelHandlerContext) {
        guard let error = error as? NIOWebSocketError else {
            fatalError("Can only handle NIOWebSocketErrors")
        }
        self.shouldKeepParsing = false

        // If we've been asked to handle the errors here, we should.
        // TODO(cory): Remove this in 2.0, in favour of `WebSocketProtocolErrorHandler`.
        if self.automaticErrorHandling {
            var data = ctx.channel.allocator.buffer(capacity: 2)
            data.write(webSocketErrorCode: WebSocketErrorCode(error))
            let frame = WebSocketFrame(fin: true,
                                       opcode: .connectionClose,
                                       data: data)
            ctx.writeAndFlush(self.wrapOutboundOut(frame)).whenComplete {
                ctx.close(promise: nil)
            }
        }

        ctx.fireErrorCaught(error)
    }
}
