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


public protocol ByteToMessageDecoder : ChannelInboundHandler {
    var cumulationBuffer: ByteBuffer? { get set }
    func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> Bool
    func decodeLast(ctx: ChannelHandlerContext, buffer: inout ByteBuffer)throws  -> Bool
    func decoderRemoved(ctx: ChannelHandlerContext) throws
    func decoderAdded(ctx: ChannelHandlerContext) throws
}

public extension ByteToMessageDecoder {

    public func channelRead(ctx: ChannelHandlerContext, data: IOData) throws {
        var buffer = data.forceAsByteBuffer()
        
        if var cum = cumulationBuffer {
            var buf = ctx.channel!.allocator.buffer(capacity: cum.readableBytes + buffer.readableBytes)
            buf.write(buffer: &cum)
            buf.write(buffer: &buffer)
            buffer = buf
        }
        
        // Running decode method until either the buffer is not readable anymore or the user returned false.
        while try decode(ctx: ctx, buffer: &buffer) && buffer.readableBytes > 0 { }
        
        handleLeftOver(buffer: &buffer)
    }
    
    public func channelInactive(ctx: ChannelHandlerContext) throws {
        if var buffer = cumulationBuffer {
            // Running decode method until either the buffer is not readable anymore or the user returned false.
            while try decodeLast(ctx: ctx, buffer: &buffer) && buffer.readableBytes > 0 { }
            
            handleLeftOver(buffer: &buffer)
        }
    }
    
    private func handleLeftOver(buffer: inout ByteBuffer) {
        if buffer.readableBytes > 0 {
            buffer.discardReadBytes()
            cumulationBuffer = buffer
        } else {
            cumulationBuffer = nil
        }
    }
    
    public func handlerAdded(ctx: ChannelHandlerContext) throws {
        try decoderAdded(ctx: ctx)
    }
    
    public func handlerRemoved(ctx: ChannelHandlerContext) throws {
        if let buffer = cumulationBuffer {
            ctx.fireChannelRead(data: .byteBuffer(buffer))
            cumulationBuffer = nil
        }
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
