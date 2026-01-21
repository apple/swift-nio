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

/// A simplified version of `ByteToMessageDecoder` that can generate zero or one messages for each invocation of `decode` or `decodeLast`.
/// Having `decode` and `decodeLast` return an optional message avoids re-entrancy problems, since the functions relinquish exclusive access
/// to the `ByteBuffer` when returning. This allows for greatly simplified processing.
///
/// Many `ByteToMessageDecoder`'s can trivially be translated to `NIOSingleStepByteToMessageDecoder`'s. You should not implement
/// `ByteToMessageDecoder`'s `decode` and `decodeLast` methods.
public protocol NIOSingleStepByteToMessageDecoder: ByteToMessageDecoder {
    /// The decoded type this `NIOSingleStepByteToMessageDecoder` decodes to. To conform to `ByteToMessageDecoder` it must be called
    /// `InboundOut` - see https://bugs.swift.org/browse/SR-11868.
    associatedtype InboundOut

    /// Decode from a `ByteBuffer`.
    ///
    /// This method will be called in a loop until either the input `ByteBuffer` has nothing to read left or `nil` is returned. If non-`nil` is
    /// returned and the `ByteBuffer` contains more readable bytes, this method will immediately be invoked again, unless `decodeLast` needs
    /// to be invoked instead.
    ///
    /// - Parameters:
    ///   - buffer: The `ByteBuffer` from which we decode.
    /// - Returns: A message if one can be decoded or `nil` if it should be called again once more data is present in the `ByteBuffer`.
    mutating func decode(buffer: inout ByteBuffer) throws -> InboundOut?

    /// Decode from a `ByteBuffer` when no more data is incoming.
    ///
    /// Like with `decode`, this method will be called in a loop until either `nil` is returned from the method or until the input `ByteBuffer`
    /// has no more readable bytes. If non-`nil` is returned and the `ByteBuffer` contains more readable bytes, this method will immediately
    /// be invoked again.
    ///
    /// Once `nil` is returned, neither `decode` nor `decodeLast` will be called again. If there are no bytes left, `decodeLast` will be called
    /// once with an empty buffer.
    ///
    /// - Parameters:
    ///   - buffer: The `ByteBuffer` from which we decode.
    ///   - seenEOF: `true` if EOF has been seen.
    /// - Returns: A message if one can be decoded or `nil` if no more messages can be produced.
    mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut?
}

// MARK: NIOSingleStepByteToMessageDecoder: ByteToMessageDecoder
extension NIOSingleStepByteToMessageDecoder {
    public mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let message = try self.decode(buffer: &buffer) {
            context.fireChannelRead(Self.wrapInboundOut(message))
            return .continue
        } else {
            return .needMoreData
        }
    }

    public mutating func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        if let message = try self.decodeLast(buffer: &buffer, seenEOF: seenEOF) {
            context.fireChannelRead(Self.wrapInboundOut(message))
            return .continue
        } else {
            return .needMoreData
        }
    }
}

/// `NIOSingleStepByteToMessageProcessor` uses a `NIOSingleStepByteToMessageDecoder` to produce messages
/// from a stream of incoming bytes. It works like `ByteToMessageHandler` but may be used outside of the channel pipeline. This allows
/// processing of wrapped protocols in a general way.
///
/// A `NIOSingleStepByteToMessageProcessor` is first initialized with a `NIOSingleStepByteToMessageDecoder`. Then
/// call `process` as each `ByteBuffer` is received from the stream. The closure is called repeatedly with each message produced by
/// the decoder.
///
/// When your stream ends, call `finishProcessing` to ensure all buffered data is passed to your decoder. This will call `decodeLast`
/// one or more times with any remaining data.
///
/// ### Example
///
/// Below is an example of a protocol decoded by `TwoByteStringCodec` that is sent over HTTP. `RawBodyMessageHandler` forwards the headers
/// and trailers directly and uses `NIOSingleStepByteToMessageProcessor` to send whole decoded messages.
///
///     class TwoByteStringCodec: NIOSingleStepByteToMessageDecoder {
///         typealias InboundOut = String
///
///         public func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
///             return buffer.readString(length: 2)
///         }
///
///         public func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
///             return try self.decode(buffer: &buffer)
///         }
///     }
///
///     class RawBodyMessageHandler: ChannelInboundHandler {
///         typealias InboundIn = HTTPServerRequestPart // alias for HTTPPart<HTTPRequestHead, ByteBuffer>
///         // This converts the body from ByteBuffer to String, our message type
///         typealias InboundOut = HTTPPart<HTTPRequestHead, String>
///
///         private var messageProcessor: NIOSingleStepByteToMessageProcessor<TwoByteStringCodec>? = nil
///
///         func channelRead(context: ChannelHandlerContext, data: NIOAny) {
///             let req = Self.unwrapInboundIn(data)
///             do {
///                 switch req {
///                 case .head(let head):
///                     // simply forward on the head
///                     context.fireChannelRead(Self.wrapInboundOut(.head(head)))
///                 case .body(let body):
///                     if self.messageProcessor == nil {
///                         self.messageProcessor = NIOSingleStepByteToMessageProcessor(TwoByteStringCodec())
///                     }
///                     try self.messageProcessor!.process(buffer: body) { message in
///                         self.channelReadMessage(context: context, message: message)
///                     }
///                 case .end(let trailers):
///                     // Forward on any remaining messages and the trailers
///                     try self.messageProcessor?.finishProcessing(seenEOF: false) { message in
///                         self.channelReadMessage(context: context, message: message)
///                     }
///                     context.fireChannelRead(Self.wrapInboundOut(.end(trailers)))
///                 }
///             } catch {
///                 context.fireErrorCaught(error)
///             }
///         }
///
///         // Forward on the body messages as whole messages
///         func channelReadMessage(context: ChannelHandlerContext, message: String) {
///             context.fireChannelRead(Self.wrapInboundOut(.body(message)))
///         }
///     }
///
///     private class DecodedBodyHTTPHandler: ChannelInboundHandler {
///         typealias InboundIn = HTTPPart<HTTPRequestHead, String>
///         typealias OutboundOut = HTTPServerResponsePart
///
///         var msgs: [String] = []
///
///         func channelRead(context: ChannelHandlerContext, data: NIOAny) {
///             let message = Self.unwrapInboundIn(data)
///
///             switch message {
///             case .head(let head):
///                 print("head: \(head)")
///             case .body(let msg):
///                 self.msgs.append(msg)
///             case .end(let trailers):
///                 print("trailers: \(trailers)")
///                 var responseBuffer = context.channel.allocator.buffer(capacity: 32)
///                 for msg in msgs {
///                     responseBuffer.writeString(msg)
///                     responseBuffer.writeStaticString("\n")
///                 }
///                 var headers = HTTPHeaders()
///                 headers.add(name: "content-length", value: String(responseBuffer.readableBytes))
///
///                 context.write(Self.wrapOutboundOut(HTTPServerResponsePart.head(
///                     HTTPResponseHead(version: .http1_1,
///                                      status: .ok, headers: headers))), promise: nil)
///
///                 context.write(Self.wrapOutboundOut(HTTPServerResponsePart.body(
///                     .byteBuffer(responseBuffer))), promise: nil)
///                 context.writeAndFlush(Self.wrapOutboundOut(HTTPServerResponsePart.end(nil)), promise: nil)
///             }
///         }
///     }
///
///     let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
///     let bootstrap = ServerBootstrap(group: group).childChannelInitializer({channel in
///         channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: true, withErrorHandling: true).flatMap { _ in
///             channel.pipeline.addHandlers([RawBodyMessageHandler(), DecodedBodyHTTPHandler()])
///         }
///     })
///     let channelFuture = bootstrap.bind(host: "127.0.0.1", port: 0)
///
public final class NIOSingleStepByteToMessageProcessor<Decoder: NIOSingleStepByteToMessageDecoder> {
    @usableFromInline
    enum DecodeMode: Sendable {
        /// This is a usual decode, ie. not the last chunk
        case normal
        /// Last chunk
        case last
    }

    @usableFromInline
    internal private(set) var decoder: Decoder
    @usableFromInline
    let maximumBufferSize: Int?
    @usableFromInline
    internal private(set) var _buffer: ByteBuffer?

    /// Initialize a `NIOSingleStepByteToMessageProcessor`.
    ///
    /// - Parameters:
    ///   - decoder: The `NIOSingleStepByteToMessageDecoder` to decode the bytes into message.
    ///   - maximumBufferSize: The maximum number of bytes to aggregate in-memory.
    ///     An error will be thrown if after decoding elements there is more aggregated data than this amount.
    @inlinable
    public init(_ decoder: Decoder, maximumBufferSize: Int? = nil) {
        self.decoder = decoder
        self.maximumBufferSize = maximumBufferSize
    }

    /// Append a new buffer to this processor.
    @inlinable
    func append(_ buffer: ByteBuffer) {
        if self._buffer == nil || self._buffer!.readableBytes == 0 {
            self._buffer = buffer
        } else {
            var buffer = buffer
            self._buffer!.writeBuffer(&buffer)
        }
    }

    @inlinable
    func _withNonCoWBuffer(_ body: (inout ByteBuffer) throws -> Decoder.InboundOut?) throws -> Decoder.InboundOut? {
        guard var buffer = self._buffer else {
            return nil
        }

        if buffer.readableBytes == 0 {
            return nil
        }

        self._buffer = nil  // To avoid CoW
        defer { self._buffer = buffer }

        let result = try body(&buffer)
        return result
    }

    @inlinable
    func _decodeLoop(
        decodeMode: DecodeMode,
        seenEOF: Bool = false,
        _ messageReceiver: (Decoder.InboundOut) throws -> Void
    ) throws {
        // we want to call decodeLast once with an empty buffer if we have nothing
        if decodeMode == .last && (self._buffer == nil || self._buffer!.readableBytes == 0) {
            var emptyBuffer = self._buffer ?? ByteBuffer()
            if let message = try self.decoder.decodeLast(buffer: &emptyBuffer, seenEOF: seenEOF) {
                try messageReceiver(message)
            }
            return
        }

        // buffer can only be nil if we're called from finishProcessing which is handled above
        assert(self._buffer != nil)

        func decodeOnce(buffer: inout ByteBuffer) throws -> Decoder.InboundOut? {
            if decodeMode == .normal {
                return try self.decoder.decode(buffer: &buffer)
            } else {
                return try self.decoder.decodeLast(buffer: &buffer, seenEOF: seenEOF)
            }
        }

        while let message = try self._withNonCoWBuffer(decodeOnce) {
            try messageReceiver(message)
        }

        try _postDecodeCheck()
    }

    /// Decode the next message from the `NIOSingleStepByteToMessageProcessor`
    ///
    /// This function is useful to manually decode the next message from the `NIOSingleStepByteToMessageProcessor`.
    /// It should be used in combination with the `append(_:)` function.
    /// Whenever you receive a new chunk of data, feed it into the `NIOSingleStepByteToMessageProcessor` using `append(_:)`,
    /// then call this function to decode the next message.
    ///
    /// When you've already received the last chunk of data, call this function with `receivedLastChunk` set to `true`.
    /// In this case, if the function returns `nil`, you are done decoding and there are no more messages to decode.
    /// Note that you might need to call `decodeNext` _multiple times_, even if `receivedLastChunk` is true, as there
    /// might be multiple messages left in the buffer.
    ///
    /// If `decodeMode` is `.normal`, this function will never return `ended == true`.
    ///
    /// If `decodeMode` is `.last`, this function will try to decode a message even if it means only with an empty buffer.
    /// It'll then return the decoded message with `ended == true`. When you've received `ended == true`, you should
    /// simply end the decoding process.
    ///
    /// `seenEOF` should only be true if `decodeMode == .last`. Otherwise it'll be ignored.
    ///
    /// After a `decoder.decode(buffer:)` or `decoder.decodeLast(buffer:seenEOF:)` returns without throwing,
    /// the aggregated buffer will have to contain less than or equal to `maximumBufferSize` amount of bytes.
    /// Otherwise an error will be thrown.
    ///
    /// - Parameters:
    ///   - decodeMode: Either 'normal', or 'last' if the last chunk has been received and appended to the processor.
    ///   - seenEOF: Whether an EOF was seen on the stream
    /// - Returns: A tuple containing the decoded message and a boolean indicating whether the decoding has ended.
    @inlinable
    func decodeNext(
        decodeMode: DecodeMode,
        seenEOF: Bool = false
    ) throws -> (decoded: Decoder.InboundOut?, ended: Bool) {
        // we want to call decodeLast once with an empty buffer if we have nothing
        if decodeMode == .last && (self._buffer == nil || self._buffer!.readableBytes == 0) {
            var emptyBuffer = self._buffer ?? ByteBuffer()
            let message = try self.decoder.decodeLast(buffer: &emptyBuffer, seenEOF: seenEOF)
            return (message, true)
        }

        if self._buffer == nil {
            return (nil, false)
        }

        func decodeOnce(buffer: inout ByteBuffer) throws -> Decoder.InboundOut? {
            if decodeMode == .normal {
                return try self.decoder.decode(buffer: &buffer)
            } else {
                return try self.decoder.decodeLast(buffer: &buffer, seenEOF: seenEOF)
            }
        }

        let message = try self._withNonCoWBuffer(decodeOnce)

        try _postDecodeCheck()

        return (message, false)
    }

    @inlinable
    func _postDecodeCheck() throws {
        if let maximumBufferSize = self.maximumBufferSize, self._buffer!.readableBytes > maximumBufferSize {
            throw ByteToMessageDecoderError.PayloadTooLargeError()
        }

        if let readerIndex = self._buffer?.readerIndex, readerIndex > 0,
            self.decoder.shouldReclaimBytes(buffer: self._buffer!)
        {
            self._buffer!.discardReadBytes()
        }
    }
}

@available(*, unavailable)
extension NIOSingleStepByteToMessageProcessor: Sendable {}

// MARK: NIOSingleStepByteToMessageProcessor Public API
extension NIOSingleStepByteToMessageProcessor {
    /// The number of bytes that are currently not processed by the ``process(buffer:_:)`` method. Having unprocessed
    /// bytes may result from receiving only partial messages or from receiving multiple messages at once.
    public var unprocessedBytes: Int {
        self._buffer?.readableBytes ?? 0
    }

    /// Feed data into the `NIOSingleStepByteToMessageProcessor` and process it
    ///
    /// This function will decode as many `Decoder.InboundOut` messages from the `NIOSingleStepByteToMessageProcessor` as possible,
    /// and call the `messageReceiver` closure for each message.
    ///
    /// - Parameters:
    ///   - buffer: The `ByteBuffer` containing the next data in the stream
    ///   - messageReceiver: A closure called for each message produced by the `Decoder`
    @inlinable
    public func process(buffer: ByteBuffer, _ messageReceiver: (Decoder.InboundOut) throws -> Void) throws {
        self.append(buffer)
        try self._decodeLoop(decodeMode: .normal, messageReceiver)
    }

    /// Call when there is no data left in the stream. Calls `Decoder`.`decodeLast` one or more times. If there is no data left
    /// `decodeLast` will be called one time with an empty `ByteBuffer`.
    ///
    /// This function will decode as many `Decoder.InboundOut` messages from the `NIOSingleStepByteToMessageProcessor` as possible,
    /// and call the `messageReceiver` closure for each message.
    ///
    /// - Parameters:
    ///   - seenEOF: Whether an EOF was seen on the stream.
    ///   - messageReceiver: A closure called for each message produced by the `Decoder`.
    @inlinable
    public func finishProcessing(seenEOF: Bool, _ messageReceiver: (Decoder.InboundOut) throws -> Void) throws {
        try self._decodeLoop(decodeMode: .last, seenEOF: seenEOF, messageReceiver)
    }
}
