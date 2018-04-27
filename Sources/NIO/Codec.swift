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


/// State of the current decoding process.
public enum DecodingState {
    /// Continue decoding.
    case `continue`

    /// Stop decoding until more data is ready to be processed.
    case needMoreData
}

/// `ChannelInboundHandler` which decodes bytes in a stream-like fashion from one `ByteBuffer` to
/// another message type.
///
/// If a custom frame decoder is required, then one needs to be careful when implementing
/// one with `ByteToMessageDecoder`. Ensure there are enough bytes in the buffer for a
/// complete frame by checking `buffer.readableBytes`. If there are not enough bytes
/// for a complete frame, return without modifying the reader index to allow more bytes to arrive.
///
/// To check for complete frames without modifying the reader index, use methods like `buffer.getInteger`.
/// One _MUST_ use the reader index when using methods like `buffer.getInteger`.
/// For example calling `buffer.getInteger(at: 0)` is assuming the frame starts at the beginning of the buffer, which
/// is not always the case. Use `buffer.getInteger(at: buffer.readerIndex)` instead.
///
/// If you move the reader index forward, either manually or by using one of `buffer.read*` methods, you must ensure
/// that you no longer need to see those bytes again as they will not be returned to you the next time `decode` is called.
/// If you still need those bytes to come back, consider taking a local copy of buffer inside the function to perform your read operations on.
///
/// The `ByteBuffer` passed in as `buffer` is a slice of a larger buffer owned by the `ByteToMessageDecoder` implementation. Some aspects of this buffer are preserved across calls to `decode`, meaning that any changes to those properties you make in your `decode` method will be reflected in the next call to decode. In particular, the following operations are have the described effects:

/// 1. Moving the reader index forward persists across calls. When your method returns, if the reader index has advanced, those bytes are considered "consumed" and will not be available in future calls to `decode`.
///    Please note, however, that the numerical value of the `readerIndex` itself is not preserved, and may not be the same from one call to the next. Please do not rely on this numerical value: if you need
///    to recall where a byte is relative to the `readerIndex`, use an offset rather than an absolute value.
/// 2. Mutating the bytes in the buffer will cause undefined behaviour and likely crash your program
public protocol ByteToMessageDecoder: ChannelInboundHandler where InboundIn == ByteBuffer {
    /// The cumulationBuffer which will be used to buffer any data.
    var cumulationBuffer: ByteBuffer? { get set }

    /// Decode from a `ByteBuffer`. This method will be called till either the input
    /// `ByteBuffer` has nothing to read left or `DecodingState.needMoreData` is returned.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    ///     - buffer: The `ByteBuffer` from which we decode.
    /// - returns: `DecodingState.continue` if we should continue calling this method or `DecodingState.needMoreData` if it should be called
    //             again once more data is present in the `ByteBuffer`.
    func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState

    /// This method is called once, when the `ChannelHandlerContext` goes inactive (i.e. when `channelInactive` is fired)
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    ///     - buffer: The `ByteBuffer` from which we decode.
    /// - returns: `DecodingState.continue` if we should continue calling this method or `DecodingState.needMoreData` if it should be called
    //             again when more data is present in the `ByteBuffer`.
    func decodeLast(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws  -> DecodingState

    /// Called once this `ByteToMessageDecoder` is removed from the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    func decoderRemoved(ctx: ChannelHandlerContext)

    /// Called when this `ByteToMessageDecoder` is added to the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    func decoderAdded(ctx: ChannelHandlerContext)

    /// Determine if the read bytes in the given `ByteBuffer` should be reclaimed and their associated memory freed.
    /// Be aware that reclaiming memory may involve memory copies and so is not free.
    ///
    /// - parameters:
    ///     - buffer: The `ByteBuffer` to check
    /// - return: `true` if memory should be reclaimed, `false` otherwise.
    func shouldReclaimBytes(buffer: ByteBuffer) -> Bool
}

private extension ChannelHandlerContext {
    func withThrowingToFireErrorAndClose<T>(_ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            self.fireErrorCaught(error)
            self.close(promise: nil)
            return nil
        }
    }
}

extension ByteToMessageDecoder {

    /// Decode in a loop until there is nothing more to decode.
    private func decodeLoop(ctx: ChannelHandlerContext, decodeFunc: (ChannelHandlerContext, inout ByteBuffer) throws -> DecodingState) throws {
        while var slice = self.cumulationBuffer?.slice(), slice.readableBytes > 0 {
            // Needed to later calculate how much we need to advance the readerIndex of the cumulationBuffer.
            let sliceReadable = slice.readableBytes
            let sliceWriterIndex = slice.writerIndex

            // We fetch the writerIndex of the cumulationBuffer to make a good guess about if the cumulationBuffer changed in between due re-entrant call to
            // channelRead after we called decodeFunc(...).
            let writerIndex = self.cumulationBuffer!.writerIndex
            let result = try decodeFunc(ctx, &slice)

            guard self.cumulationBuffer != nil else {
                // The cumulationBuffer was set to nil by either removing the decoder or closing the channel, just break the loop.
                break
            }

            precondition(slice.writerIndex == sliceWriterIndex, "Writing to the buffer is not allowed")

            self.cumulationBuffer!.moveReaderIndex(forwardBy: sliceReadable - slice.readableBytes)

            // If the user told us more data is needed we also need to ensure the writerIndex did not change in between.
            // If the writerIndex changed we need to retry as there is more data delivered via re-entrance maybe.
            if result == .needMoreData && self.cumulationBuffer!.writerIndex == writerIndex {
                break
            }
        }
    }

    /// Calls `decode` until there is nothing left to decode.
    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        // Either merge the received data into the existing cumulationBuffer or use it as the cumulationBuffer if none exists yet.
        if self.cumulationBuffer != nil {
            var buffer = self.unwrapInboundIn(data)
            self.cumulationBuffer!.write(buffer: &buffer)
        } else {
            self.cumulationBuffer = self.unwrapInboundIn(data)
        }

        ctx.withThrowingToFireErrorAndClose {
            try self.decodeLoop(ctx: ctx, decodeFunc: self.decode)
        }

        // Discard the cumulationBuffer or discard read bytes if needed.
        guard let buffer = self.cumulationBuffer, buffer.readableBytes > 0 else {
            self.cumulationBuffer = nil
            return
        }

        // Check if we should reclaim some bytes and if so do it.
        if self.shouldReclaimBytes(buffer: self.cumulationBuffer!) {
            self.cumulationBuffer!.discardReadBytes()
        }
    }

    /// Call `decodeLast` before forward the event through the pipeline.
    public func channelInactive(ctx: ChannelHandlerContext) {
        if self.cumulationBuffer != nil {
            ctx.withThrowingToFireErrorAndClose {
                try self.decodeLoop(ctx: ctx, decodeFunc: self.decodeLast)
            }
            // Once the Channel goes inactive we can just drop all previous buffered data.
            self.cumulationBuffer = nil
        }

        ctx.fireChannelInactive()
    }

    public func handlerAdded(ctx: ChannelHandlerContext) {
        self.decoderAdded(ctx: ctx)
    }

    public func handlerRemoved(ctx: ChannelHandlerContext) {
        if let buffer = self.cumulationBuffer as? InboundOut {
            ctx.fireChannelRead(self.wrapInboundOut(buffer))
        } else {
            /* please note that we're dropping the partially received bytes (if any) on the floor here as we can't
               send a full message to the next handler. */
        }
        self.cumulationBuffer = nil
        self.decoderRemoved(ctx: ctx)
    }

    /// Just call `decode`. Users may implement their own logic.
    public func decodeLast(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        return try self.decode(ctx: ctx, buffer: &buffer)
    }

    /// Do nothing by default.
    public func decoderRemoved(ctx: ChannelHandlerContext) {
    }

    /// Do nothing by default.
    public func decoderAdded(ctx: ChannelHandlerContext) {
    }

    /// Default implementation to detect once bytes should be reclaimed.
    public func shouldReclaimBytes(buffer: ByteBuffer) -> Bool {
        // We want to reclaim in the following cases:
        //
        // 1. If there is more than 2kB of memory to reclaim
        // 2. If the buffer is more than 50% reclaimable memory and is at least
        //    1kB in size.
        if buffer.readerIndex > 2048 {
            return true
        }
        return buffer.capacity > 1024 && (buffer.capacity - buffer.readerIndex) >= buffer.readerIndex
    }
}

/// `ChannelOutboundHandler` which allows users to encode custom messages to a `ByteBuffer` easily.
public protocol MessageToByteEncoder: ChannelOutboundHandler where OutboundOut == ByteBuffer {

    /// Called once there is data to encode. The used `ByteBuffer` is allocated by `allocateOutBuffer`.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    ///     - data: The data to encode into a `ByteBuffer`.
    ///     - out: The `ByteBuffer` into which we want to encode.
    func encode(ctx: ChannelHandlerContext, data: OutboundIn, out: inout ByteBuffer) throws

    /// Returns a `ByteBuffer` to be used by `encode`.
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ByteToMessageDecoder` belongs to.
    ///     - data: The data to encode into a `ByteBuffer` by `encode`.
    /// - return: A `ByteBuffer` to use.
    func allocateOutBuffer(ctx: ChannelHandlerContext, data: OutboundIn) throws -> ByteBuffer
}

extension MessageToByteEncoder {

    /// Encodes the data into a `ByteBuffer` and writes it.
    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        do {
            let data = self.unwrapOutboundIn(data)
            var buffer: ByteBuffer = try allocateOutBuffer(ctx: ctx, data: data)
            try encode(ctx: ctx, data: data, out: &buffer)
            ctx.write(self.wrapOutboundOut(buffer), promise: promise)
        } catch let err {
            promise?.fail(error: err)
        }
    }

    /// Default implementation which just allocates a `ByteBuffer` with capacity of `256`.
    public func allocateOutBuffer(ctx: ChannelHandlerContext, data: OutboundIn) throws -> ByteBuffer {
        return ctx.channel.allocator.buffer(capacity: 256)
    }
}
