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
        
        XCTAssertTrue(try channel.writeOutbound(data: buf))
        XCTAssertTrue(try channel.finish())
        XCTAssertEqual(.byteBuffer(buf), channel.readOutbound())
        XCTAssertNil(channel.readOutbound())
        XCTAssertNil(channel.readInbound())
    }
    
    func testWriteInboundByteBuffer() throws {
        let channel = EmbeddedChannel()
        var buf = channel.allocator.buffer(capacity: 1024)
        buf.write(string: "hello")
        
        XCTAssertTrue(try channel.writeInbound(data: buf))
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
            XCTAssertEqual(ChannelError.operationUnsupported, err as! ChannelError)
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
            XCTAssertEqual(ChannelError.operationUnsupported, err as! ChannelError)
        }
        XCTAssertFalse(try channel.finish())
    }

    func testCloseMultipleTimesThrows() throws {
        let channel = EmbeddedChannel()
        _ = try channel.close().wait()

        // Close a second time. This must fail.
        do {
            try _ = channel.close().wait()
            XCTFail("Second close succeeded")
        } catch ChannelError.alreadyClosed {
            // Nothing to do here.
        }
    }

    func testCloseOnInactiveIsOk() throws {
        let channel = EmbeddedChannel()
        let inactiveHandler = CloseInChannelInactiveHandler()
        _ = try channel.pipeline.add(handler: inactiveHandler).wait()
        _ = try channel.close().wait()

        // channelInactive should fire only once.
        XCTAssertEqual(inactiveHandler.inactiveNotifications, 1)
    }

    func testEmbeddedLifecycle() throws {
        let channel = EmbeddedChannel()
        let handler = ChannelLifecycleHandler()
        XCTAssertEqual(handler.currentState, .unregistered)

        _ = try channel.pipeline.add(handler: handler).wait()
        XCTAssertEqual(handler.currentState, .unregistered)
        XCTAssertFalse(channel.isActive)

        _ = try channel.connect(to: try SocketAddress.unixDomainSocketAddress(path: "/fake")).wait()
        XCTAssertEqual(handler.currentState, .active)
        XCTAssertTrue(channel.isActive)

        _ = try channel.close().wait()
        XCTAssertEqual(handler.currentState, .unregistered)
        XCTAssertFalse(channel.isActive)
    }
    
    private final class ExceptionThrowingInboundHandler : ChannelInboundHandler {
        typealias InboundIn = String
        
        public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) throws {
            throw ChannelError.operationUnsupported
        }
        
    }
    
    private final class ExceptionThrowingOutboundHandler : ChannelOutboundHandler {
        typealias OutboundIn = String
        typealias OutboundOut = Never
        
        public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            promise!.fail(error: ChannelError.operationUnsupported)
        }
    }

    private final class CloseInChannelInactiveHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        public var inactiveNotifications = 0

        public func channelInactive(ctx: ChannelHandlerContext) {
            inactiveNotifications += 1
            ctx.close(promise: nil)
        }
    }

    func testEmbeddedChannelAndPipelineAndChannelCoreShareTheEventLoop() {
        let channel = EmbeddedChannel()
        let pipelineEventLoop = channel.pipeline.eventLoop
        XCTAssert(pipelineEventLoop === channel.eventLoop)
        XCTAssert(pipelineEventLoop === (channel._unsafe as! EmbeddedChannelCore).eventLoop)
    }
}
