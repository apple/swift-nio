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
        var cumulationBuffer: ByteBuffer?
        
        
        func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) -> Bool {
            guard buffer.readableBytes >= MemoryLayout<Int32>.size else {
                return false
            }
            ctx.fireChannelRead(data: .other(buffer.readInteger()! as Int32))
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
        
        channel.pipeline.fireChannelRead(data: .byteBuffer(buffer))
        XCTAssertNil(channel.readInbound())
        
        channel.pipeline.fireChannelRead(data: .byteBuffer(buffer.slice(at: writerIndex - 1, length: 1)!))
        
        var buffer2 = channel.allocator.buffer(capacity: 32)
        buffer2.write(integer: Int32(2))
        buffer2.write(integer: Int32(3))
        channel.pipeline.fireChannelRead(data: .byteBuffer(buffer2))
        
        try channel.close().wait()
        
        XCTAssertEqual(Int32(1), channel.readInbound())
        XCTAssertEqual(Int32(2), channel.readInbound())
        XCTAssertEqual(Int32(3), channel.readInbound())
        XCTAssertNil(channel.readInbound())
    }
}

public class MessageToByteEncoderTest: XCTestCase {
    
    private final class Int32ToByteEncoder : MessageToByteEncoder {
        public func encode(ctx: ChannelHandlerContext, data: IOData, out: inout ByteBuffer) throws {
            XCTAssertEqual(MemoryLayout<Int32>.size, out.writableBytes)
            let value: Int32 = data.forceAsOther()
            out.write(integer: value);
        }
        
        public func allocateOutBuffer(ctx: ChannelHandlerContext, data: IOData) throws -> ByteBuffer {
            return ctx.channel!.allocator.buffer(capacity: MemoryLayout<Int32>.size)
        }
    }
    
    func testEncoder() throws {
        let channel = EmbeddedChannel()
        
        _ = try channel.pipeline.add(handler: Int32ToByteEncoder()).wait()
        
        _ = try channel.writeAndFlush(data: .other(Int32(5))).wait()
        
        
        var buffer = channel.readOutbound() as ByteBuffer?
        XCTAssertEqual(Int32(5), buffer?.readInteger())
        XCTAssertEqual(0, buffer?.readableBytes)
        
        try channel.close().wait()
    }
}
