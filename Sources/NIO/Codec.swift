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


public protocol ByteToMessageDecoder : ChannelInboundHandler where InboundIn == ByteBuffer {

    var cumulationBuffer: ByteBuffer? { get set }
    func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> Bool
    func decodeLast(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws  -> Bool
    func decoderRemoved(ctx: ChannelHandlerContext) throws
    func decoderAdded(ctx: ChannelHandlerContext) throws
}

extension ByteToMessageDecoder {

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) throws {
        var buffer = self.unwrapInboundIn(data)
        
        if var cum = cumulationBuffer {
            var buf = ctx.channel!.allocator.buffer(capacity: cum.readableBytes + buffer.readableBytes)
            buf.write(buffer: &cum)
            buf.write(buffer: &buffer)
            cumulationBuffer = buf
            buffer = buf
        } else {
            cumulationBuffer = buffer
        }
        
        // Running decode method until either the buffer is not readable anymore or the user returned false.
        while try decode(ctx: ctx, buffer: &buffer) && buffer.readableBytes > 0 { }
        
        if buffer.readableBytes > 0 {
            cumulationBuffer = buffer
        } else {
            cumulationBuffer = nil
        }
    }
    
    public func channelInactive(ctx: ChannelHandlerContext) throws {
        if var buffer = cumulationBuffer {
            // Running decode method until either the buffer is not readable anymore or the user returned false.
            while try decodeLast(ctx: ctx, buffer: &buffer) && buffer.readableBytes > 0 { }
            
            if buffer.readableBytes > 0 {
                cumulationBuffer = buffer
            } else {
                cumulationBuffer = nil
            }
        }
        
        ctx.fireChannelInactive()
    }
    
    public func handlerAdded(ctx: ChannelHandlerContext) throws {
        try decoderAdded(ctx: ctx)
    }
    
    public func handlerRemoved(ctx: ChannelHandlerContext) throws {
        if let buffer = cumulationBuffer as? InboundOut {
            ctx.fireChannelRead(data: self.wrapInboundOut(buffer))
        } else {
            /* please note that we're dropping the partially received bytes (if any) on the floor here as we can't
               send a full message to the next handler. */
        }
        cumulationBuffer = nil
        try decoderRemoved(ctx: ctx)
    }

    public func decodeLast(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> Bool {
        return try decode(ctx: ctx, buffer: &buffer)
    }
    
    public func decoderRemoved(ctx: ChannelHandlerContext) throws {
    }

    public func decoderAdded(ctx: ChannelHandlerContext) throws {
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
            ctx.write(data: self.wrapOutboundOut(buffer), promise: promise)
        } catch let err {
            promise?.fail(error: err)
        }
    }
    
    public func allocateOutBuffer(ctx: ChannelHandlerContext, data: OutboundIn) throws -> ByteBuffer {
        return ctx.channel!.allocator.buffer(capacity: 256)
    }
}
