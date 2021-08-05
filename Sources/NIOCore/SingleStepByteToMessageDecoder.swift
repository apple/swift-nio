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
/// `ByteToMessageDecoder`'s decode` and `decodeLast` methods.
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
    /// - parameters:
    ///     - buffer: The `ByteBuffer` from which we decode.
    /// - returns: A message if one can be decoded or `nil` if it should be called again once more data is present in the `ByteBuffer`.
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
    /// - parameters:
    ///     - buffer: The `ByteBuffer` from which we decode.
    ///     - seenEOF: `true` if EOF has been seen.
    /// - returns: A message if one can be decoded or `nil` if no more messages can be produced.
    mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut?
}


// MARK: NIOSingleStepByteToMessageDecoder: ByteToMessageDecoder
extension NIOSingleStepByteToMessageDecoder {
    public mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let message = try self.decode(buffer: &buffer) {
            context.fireChannelRead(self.wrapInboundOut(message))
            return .continue
        } else {
            return .needMoreData
        }
    }

    public mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        if let message = try self.decodeLast(buffer: &buffer, seenEOF: seenEOF) {
            context.fireChannelRead(self.wrapInboundOut(message))
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
///             let req = self.unwrapInboundIn(data)
///             do {
///                 switch req {
///                 case .head(let head):
///                     // simply forward on the head
///                     context.fireChannelRead(self.wrapInboundOut(.head(head)))
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
///                     context.fireChannelRead(self.wrapInboundOut(.end(trailers)))
///                 }
///             } catch {
///                 context.fireErrorCaught(error)
///             }
///         }
///
///         // Forward on the body messages as whole messages
///         func channelReadMessage(context: ChannelHandlerContext, message: String) {
///             context.fireChannelRead(self.wrapInboundOut(.body(message)))
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
///             let message = self.unwrapInboundIn(data)
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
///                 context.write(self.wrapOutboundOut(HTTPServerResponsePart.head(
///                     HTTPResponseHead(version: .http1_1,
///                                      status: .ok, headers: headers))), promise: nil)
///
///                 context.write(self.wrapOutboundOut(HTTPServerResponsePart.body(
///                     .byteBuffer(responseBuffer))), promise: nil)
///                 context.writeAndFlush(self.wrapOutboundOut(HTTPServerResponsePart.end(nil)), promise: nil)
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
    private enum DecodeMode {
        /// This is a usual decode, ie. not the last chunk
        case normal
        /// Last chunk
        case last
    }

    private var decoder: Decoder
    private let maximumBufferSize: Int?
    internal private(set) var _buffer: ByteBuffer?

    /// Initialize a `NIOSingleStepByteToMessageProcessor`.
    ///
    /// - parameters:
    ///     - decoder: The `NIOSingleStepByteToMessageDecoder` to decode the bytes into message.
    ///     - maximumBufferSize: The maximum number of bytes to aggregate in-memory.
    public init(_ decoder: Decoder, maximumBufferSize: Int? = nil) {
        self.decoder = decoder
        self.maximumBufferSize = maximumBufferSize
    }

    private func append(_ buffer: ByteBuffer) {
        if self._buffer == nil || self._buffer!.readableBytes == 0 {
            self._buffer = buffer
        } else {
            var buffer = buffer
            self._buffer!.writeBuffer(&buffer)
        }
    }

    private func withNonCoWBuffer(_ body: (inout ByteBuffer) throws -> Decoder.InboundOut?) throws -> Decoder.InboundOut? {
        guard var buffer = self._buffer else {
            return nil
        }

        if buffer.readableBytes == 0 {
            return nil
        }

        self._buffer = nil  // To avoid CoW
        let result = try body(&buffer)
        self._buffer = buffer
        return result
    }

    private func decodeLoop(decodeMode: DecodeMode, seenEOF: Bool = false, _ messageReceiver: (Decoder.InboundOut) throws -> Void) throws {
        // we want to call decodeLast once with an empty buffer if we have nothing
        if decodeMode == .last && (self._buffer == nil || self._buffer!.readableBytes == 0) {
            var emptyBuffer = self._buffer == nil ? ByteBuffer() : self._buffer!
            if let message = try self.decoder.decodeLast(buffer: &emptyBuffer, seenEOF: seenEOF) {
                try messageReceiver(message)
            }
            return
        }

        // buffer can only be nil if we're called from finishProcessing which is handled above
        assert(self._buffer != nil)

        func decodeOnce(buffer: inout ByteBuffer) throws -> Decoder.InboundOut? {
            defer {
                if buffer.readableBytes > 0 {
                    if self.decoder.shouldReclaimBytes(buffer: buffer) {
                        buffer.discardReadBytes()
                    }
                }
            }
            if decodeMode == .normal {
                return try self.decoder.decode(buffer: &buffer)
            } else {
                return try self.decoder.decodeLast(buffer: &buffer, seenEOF: seenEOF)
            }
        }

        while let message = try self.withNonCoWBuffer(decodeOnce) {
            try messageReceiver(message)
        }

        if let maximumBufferSize = self.maximumBufferSize, self._buffer!.readableBytes > maximumBufferSize {
            throw ByteToMessageDecoderError.PayloadTooLargeError()
        }

        // force unwrapping is safe because nil case is handled already and asserted above
        if self._buffer!.readableBytes == 0 {
            self._buffer!.discardReadBytes()
        }
    }
}


// MARK: NIOSingleStepByteToMessageProcessor Public API
extension NIOSingleStepByteToMessageProcessor {
    /// Feed data into the `NIOSingleStepByteToMessageProcessor`
    ///
    /// - parameters:
    ///     - buffer: The `ByteBuffer` containing the next data in the stream
    ///     - messageReceiver: A closure called for each message produced by the `Decoder`
    public func process(buffer: ByteBuffer, _ messageReceiver: (Decoder.InboundOut) throws -> Void) throws {
        self.append(buffer)
        try self.decodeLoop(decodeMode: .normal, messageReceiver)
    }

    /// Call when there is no data left in the stream. Calls `Decoder`.`decodeLast` one or more times. If there is no data left
    /// `decodeLast` will be called one time with an empty `ByteBuffer`.
    ///
    /// - parameters:
    ///     - seenEOF: Whether an EOF was seen on the stream.
    ///     - messageReceiver: A closure called for each message produced by the `Decoder`.
    public func finishProcessing(seenEOF: Bool, _ messageReceiver: (Decoder.InboundOut) throws -> Void) throws {
        try self.decodeLoop(decodeMode: .last, seenEOF: seenEOF, messageReceiver)
    }
}
