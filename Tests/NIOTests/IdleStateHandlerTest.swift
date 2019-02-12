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

class IdleStateHandlerTest : XCTestCase {

    func testIdleRead() throws {
        try testIdle(IdleStateHandler(readTimeout: .seconds(1)), false, { $0 == IdleStateHandler.IdleStateEvent.read })
    }

    func testIdleWrite() throws {
        try testIdle(IdleStateHandler(writeTimeout: .seconds(1)), true, { $0 == IdleStateHandler.IdleStateEvent.write })
    }

    func testIdleAllWrite() throws {
        try testIdle(IdleStateHandler(allTimeout: .seconds(1)), true, { $0 == IdleStateHandler.IdleStateEvent.all })
    }

    func testIdleAllRead() throws {
        try testIdle(IdleStateHandler(allTimeout: .seconds(1)), false, { $0 == IdleStateHandler.IdleStateEvent.all })
    }

    private func testIdle(_ handler: IdleStateHandler, _ writeToChannel: Bool, _ assertEventFn: @escaping (IdleStateHandler.IdleStateEvent) -> Bool) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        class TestWriteHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            private var read = false
            private let writeToChannel: Bool
            private let assertEventFn: (IdleStateHandler.IdleStateEvent) -> Bool

            init(_ writeToChannel: Bool, _ assertEventFn: @escaping (IdleStateHandler.IdleStateEvent) -> Bool) {
                self.writeToChannel = writeToChannel
                self.assertEventFn = assertEventFn
            }

            public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                self.read = true
            }

            public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
                if !self.writeToChannel {
                    XCTAssertTrue(self.read)
                }

                XCTAssertTrue(assertEventFn(event as! IdleStateHandler.IdleStateEvent))
                ctx.close(promise: nil)
            }

            public func channelActive(ctx: ChannelHandlerContext) {
                if writeToChannel {
                    var buffer = ctx.channel.allocator.buffer(capacity: 4)
                    buffer.writeStaticString("test")
                    ctx.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
                }
            }
        }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: handler).flatMap { f in
                    channel.pipeline.add(handler: TestWriteHandler(writeToChannel, assertEventFn))
                }
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!)
            .wait())
        if !writeToChannel {
            var buffer = clientChannel.allocator.buffer(capacity: 4)
            buffer.writeStaticString("test")
            XCTAssertNoThrow(try clientChannel.writeAndFlush(NIOAny(buffer)).wait())
        }
        XCTAssertNoThrow(try clientChannel.closeFuture.wait())
    }
    
    func testPropagateInboundEvents() {
        class EventHandler: ChannelInboundHandler {
            typealias InboundIn = Any
            
            var active = false
            var inactive = false
            var read = false
            var readComplete = false
            var writabilityChanged = false
            var eventTriggered = false
            var errorCaught = false
            var registered = false
            var unregistered = false

            func channelActive(ctx: ChannelHandlerContext) {
                self.active = true
            }
            
            func channelInactive(ctx: ChannelHandlerContext) {
                self.inactive = true
            }
            
            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                self.read = true
            }
            
            func channelReadComplete(ctx: ChannelHandlerContext) {
                self.readComplete = true
            }
            
            func channelWritabilityChanged(ctx: ChannelHandlerContext) {
                self.writabilityChanged = true
            }
  
            func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
                self.eventTriggered = true
            }
            
            func errorCaught(ctx: ChannelHandlerContext, error: Error) {
                self.errorCaught = true
            }
            
            func channelRegistered(ctx: ChannelHandlerContext) {
                self.registered = true
            }
            
            func channelUnregistered(ctx: ChannelHandlerContext) {
                self.unregistered = true
            }
            
            func assertAllEventsReceived() {
                XCTAssertTrue(self.active)
                XCTAssertTrue(self.inactive)
                XCTAssertTrue(self.read)
                XCTAssertTrue(self.readComplete)
                XCTAssertTrue(self.writabilityChanged)
                XCTAssertTrue(self.eventTriggered)
                XCTAssertTrue(self.errorCaught)
                XCTAssertTrue(self.registered)
                XCTAssertTrue(self.unregistered)
            }
        }
        let eventHandler = EventHandler()
        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.pipeline.add(handler: IdleStateHandler()).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: eventHandler).wait())
        
        channel.pipeline.fireChannelRegistered()
        channel.pipeline.fireChannelActive()
        channel.pipeline.fireChannelRead(NIOAny(""))
        channel.pipeline.fireChannelReadComplete()
        channel.pipeline.fireErrorCaught(ChannelError.alreadyClosed)
        channel.pipeline.fireUserInboundEventTriggered("")

        channel.pipeline.fireChannelWritabilityChanged()
        channel.pipeline.fireChannelInactive()
        channel.pipeline.fireChannelUnregistered()
        
        XCTAssertFalse(try channel.finish())
        eventHandler.assertAllEventsReceived()
    }
}
