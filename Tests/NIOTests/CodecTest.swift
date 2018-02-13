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

private final class ChannelInactivePromiser: ChannelInboundHandler {
    typealias InboundIn = Any

    let channelInactivePromise: EventLoopPromise<Void>

    init(channel: Channel) {
        channelInactivePromise = channel.eventLoop.newPromise()
    }

    func channelInactive(ctx: ChannelHandlerContext) {
        channelInactivePromise.succeed(result: ())
    }
}

public class ByteToMessageDecoderTest: XCTestCase {
    private final class ByteToInt32Decoder : ByteToMessageDecoder {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = Int32

        var cumulationBuffer: ByteBuffer?
        
        
        func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) -> Bool {
            guard buffer.readableBytes >= MemoryLayout<Int32>.size else {
                return false
            }
            ctx.fireChannelRead(self.wrapInboundOut(buffer.readInteger()!))
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
        
        channel.pipeline.fireChannelRead(NIOAny(buffer))
        XCTAssertNil(channel.readInbound())
        
        channel.pipeline.fireChannelRead(NIOAny(buffer.getSlice(at: writerIndex - 1, length: 1)!))
        
        var buffer2 = channel.allocator.buffer(capacity: 32)
        buffer2.write(integer: Int32(2))
        buffer2.write(integer: Int32(3))
        channel.pipeline.fireChannelRead(NIOAny(buffer2))
        
        XCTAssertNoThrow(try channel.finish())
        
        XCTAssertEqual(Int32(1), channel.readInbound())
        XCTAssertEqual(Int32(2), channel.readInbound())
        XCTAssertEqual(Int32(3), channel.readInbound())
        XCTAssertNil(channel.readInbound())
    }

    func testDecoderPropagatesChannelInactive() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }
        let inactivePromiser = ChannelInactivePromiser(channel: channel)
        _ = try channel.pipeline.add(handler: ByteToInt32Decoder()).wait()
        _ = try channel.pipeline.add(handler: inactivePromiser).wait()

        var buffer = channel.allocator.buffer(capacity: 32)
        buffer.write(integer: Int32(1))
        channel.pipeline.fireChannelRead(NIOAny(buffer))
        XCTAssertEqual(Int32(1), channel.readInbound())

        XCTAssertFalse(inactivePromiser.channelInactivePromise.futureResult.fulfilled)

        channel.pipeline.fireChannelInactive()
        XCTAssertTrue(inactivePromiser.channelInactivePromise.futureResult.fulfilled)
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
            return ctx.channel.allocator.buffer(capacity: MemoryLayout<Int32>.size)
        }
    }
    
    private final class Int32ToByteEncoderWithDefaultImpl : MessageToByteEncoder {
        typealias OutboundIn = Int32
        typealias OutboundOut = ByteBuffer
        
        public func encode(ctx: ChannelHandlerContext, data value: Int32, out: inout ByteBuffer) throws {
            XCTAssertEqual(MemoryLayout<Int32>.size, 256)
            out.write(integer: value);
        }
    }
    
    func testEncoderOverrideAllocateOutBuffer() throws {
        try testEncoder(Int32ToByteEncoder())
    }

    func testEncoder() throws {
        try testEncoder(Int32ToByteEncoderWithDefaultImpl())
    }
    
    private func testEncoder(_ handler: ChannelHandler) throws {
        let channel = EmbeddedChannel()
        
        _ = try channel.pipeline.add(handler: Int32ToByteEncoder()).wait()
        
        _ = try channel.writeAndFlush(NIOAny(Int32(5))).wait()
        
        if case .some(.byteBuffer(var buffer)) = channel.readOutbound() {
            XCTAssertEqual(Int32(5), buffer.readInteger())
            XCTAssertEqual(0, buffer.readableBytes)
        } else {
            XCTFail("couldn't read ByteBuffer from channel")
        }
        
        XCTAssertFalse(try channel.finish())

    }
}
