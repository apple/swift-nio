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

//
import XCTest
@testable import NIO

public class ByteToMessageDecoderTest: XCTestCase {
    private final class ByteToInt32Decoder : ByteToMessageDecoder {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = Int32

        var cumulationBuffer: ByteBuffer?
        
        
        func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) -> Bool {
            guard buffer.readableBytes >= MemoryLayout<Int32>.size else {
                return false
            }
            ctx.fireChannelRead(data: self.wrapInboundOut(buffer.readInteger()!))
            return true
        }
    }
    
    func testDecoder() throws {
        let channel = EmbeddedChannel()
        
        _ = try channel.pipeline.add(handler: ByteToInt32Decoder()).wait()
        
        var buffer = channel.allocator.buffer(capacity: 32)
        buffer.write(integer: Int32(1))
        let writerIndex = buffer.writerIndex
        buffer.moveWriterIndex(to: writerIndex - 1)
        
        channel.pipeline.fireChannelRead(data: NIOAny(buffer))
        XCTAssertNil(channel.readInbound())
        
        channel.pipeline.fireChannelRead(data: NIOAny(buffer.slice(at: writerIndex - 1, length: 1)!))
        
        var buffer2 = channel.allocator.buffer(capacity: 32)
        buffer2.write(integer: Int32(2))
        buffer2.write(integer: Int32(3))
        channel.pipeline.fireChannelRead(data: NIOAny(buffer2))
        
        try channel.close().wait()
        
        XCTAssertEqual(Int32(1), channel.readInbound())
        XCTAssertEqual(Int32(2), channel.readInbound())
        XCTAssertEqual(Int32(3), channel.readInbound())
        XCTAssertNil(channel.readInbound())
    }
}

public class MessageToByteEncoderTest: XCTestCase {
    
    private final class Int32ToByteEncoder : MessageToByteEncoder {
        typealias OutboundIn = Int32
        typealias OutboundOut = ByteBuffer

        public func encode(ctx: ChannelHandlerContext, data value: Int32, out: inout ByteBuffer) throws {
            XCTAssertEqual(MemoryLayout<Int32>.size, out.writableBytes)
            out.write(integer: value);
        }
        
        public func allocateOutBuffer(ctx: ChannelHandlerContext, data: Int32) throws -> ByteBuffer {
            return ctx.channel!.allocator.buffer(capacity: MemoryLayout<Int32>.size)
        }
    }
    
    func testEncoder() throws {
        let channel = EmbeddedChannel()
        
        _ = try channel.pipeline.add(handler: Int32ToByteEncoder()).wait()
        
        _ = try channel.writeAndFlush(data: NIOAny(Int32(5))).wait()
        
        if case .some(.byteBuffer(var buffer)) = channel.readOutbound() {
            XCTAssertEqual(Int32(5), buffer.readInteger())
            XCTAssertEqual(0, buffer.readableBytes)
        } else {
            XCTFail("couldn't read ByteBuffer from channel")
        }
        
        try channel.close().wait()
    }
}
