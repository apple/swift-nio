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

import XCTest
@testable import NIO

class EmbeddedChannelTest: XCTestCase {
    func testWriteOutboundByteBuffer() throws {
        let channel = EmbeddedChannel()
        var buf = channel.allocator.buffer(capacity: 1024)
        buf.write(string: "hello")
        
        try channel.writeOutbound(data: buf)
        XCTAssertTrue(try channel.finish())
        XCTAssertEqual(buf, channel.readOutbound())
        XCTAssertNil(channel.readOutbound())
        XCTAssertNil(channel.readInbound())
    }
    
    func testWriteInboundByteBuffer() throws {
        let channel = EmbeddedChannel()
        var buf = channel.allocator.buffer(capacity: 1024)
        buf.write(string: "hello")
        
        try channel.writeInbound(data: buf)
        XCTAssertTrue(try channel.finish())
        XCTAssertEqual(buf, channel.readInbound())
        XCTAssertNil(channel.readInbound())
        XCTAssertNil(channel.readOutbound())
    }
    
    func testWriteInboundByteBufferReThrow() throws {
        let channel = EmbeddedChannel()
        _ = try channel.pipeline.add(handler: ExceptionThrowingInboundHandler()).wait()
        do {
        try channel.writeInbound(data: "msg")
            XCTFail()
        } catch let err {
            XCTAssertEqual(ChannelError.messageUnsupported, err as! ChannelError)
        }
        XCTAssertFalse(try channel.finish())
            
    }
    
    func testWriteOutboundByteBufferReThrow() throws {
        let channel = EmbeddedChannel()
        _ = try channel.pipeline.add(handler: ExceptionThrowingOutboundHandler()).wait()
        do {
            try channel.writeOutbound(data: "msg")
            XCTFail()
        } catch let err {
            XCTAssertEqual(ChannelError.messageUnsupported, err as! ChannelError)
        }
        XCTAssertFalse(try channel.finish())
        
    }
    
    private final class ExceptionThrowingInboundHandler : ChannelInboundHandler {
        typealias InboundIn = String
        
        public func channelRead(ctx: ChannelHandlerContext, data: IOData) throws {
            throw ChannelError.messageUnsupported
        }
        
    }
    
    private final class ExceptionThrowingOutboundHandler : ChannelOutboundHandler {
        typealias OutboundIn = String
        typealias OutboundOut = Never
        
        public func write(ctx: ChannelHandlerContext, data: IOData, promise: Promise<Void>?) {
            promise!.fail(error: ChannelError.messageUnsupported)
        }
    }
}
