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

public protocol ByteToMessageDecoder : ChannelInboundHandler where InboundIn == ByteBuffer {
    var cumulationBuffer: ByteBuffer? { get set }
    func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState
    func decodeLast(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws  -> DecodingState
    func decoderRemoved(ctx: ChannelHandlerContext)
    func decoderAdded(ctx: ChannelHandlerContext)
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

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)

        if self.cumulationBuffer != nil {
            self.cumulationBuffer!.write(buffer: &buffer)
            buffer = self.cumulationBuffer!
        } else {
            self.cumulationBuffer = buffer
        }
        
        ctx.withThrowingToFireErrorAndClose {
            // Running decode method until either the user returned `.needMoreData` or an error occured.
            while try decode(ctx: ctx, buffer: &buffer) == .`continue` && buffer.readableBytes > 0 { }
        }
        
        if buffer.readableBytes > 0 {
            if self.shouldReclaimBytes(buffer: buffer) {
                buffer.discardReadBytes()
            }
            cumulationBuffer = buffer
        } else {
            cumulationBuffer = nil
        }
    }
    
    public func channelInactive(ctx: ChannelHandlerContext) {
        if var buffer = cumulationBuffer {
            ctx.withThrowingToFireErrorAndClose {
                // Running decodeLast method until either the user returned `.needMoreData` or an error occured.
                while try decodeLast(ctx: ctx, buffer: &buffer)  == .`continue` && buffer.readableBytes > 0 { }
            }
            
            if buffer.readableBytes > 0 {
                cumulationBuffer = buffer
            } else {
                cumulationBuffer = nil
            }
        }
        
        ctx.fireChannelInactive()
    }
    
    public func handlerAdded(ctx: ChannelHandlerContext) {
        decoderAdded(ctx: ctx)
    }
    
    public func handlerRemoved(ctx: ChannelHandlerContext) {
        if let buffer = cumulationBuffer as? InboundOut {
            ctx.fireChannelRead(self.wrapInboundOut(buffer))
        } else {
            /* please note that we're dropping the partially received bytes (if any) on the floor here as we can't
               send a full message to the next handler. */
        }
        cumulationBuffer = nil
        decoderRemoved(ctx: ctx)
    }

    public func decodeLast(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        return try decode(ctx: ctx, buffer: &buffer)
    }
    
    public func decoderRemoved(ctx: ChannelHandlerContext) {
    }

    public func decoderAdded(ctx: ChannelHandlerContext) {
    }

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

public protocol MessageToByteEncoder : ChannelOutboundHandler where OutboundOut == ByteBuffer {
    func encode(ctx: ChannelHandlerContext, data: OutboundIn, out: inout ByteBuffer) throws
    func allocateOutBuffer(ctx: ChannelHandlerContext, data: OutboundIn) throws -> ByteBuffer
}

extension MessageToByteEncoder {
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
    
    public func allocateOutBuffer(ctx: ChannelHandlerContext, data: OutboundIn) throws -> ByteBuffer {
        return ctx.channel.allocator.buffer(capacity: 256)
    }
}
