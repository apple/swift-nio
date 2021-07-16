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

@testable import NIO
import XCTest

class IdleStateHandlerTest: XCTestCase {
    func testIdleRead() throws {
        try testIdle(IdleStateHandler(readTimeout: .seconds(1)), false) { $0 == IdleStateHandler.IdleStateEvent.read }
    }

    func testIdleWrite() throws {
        try testIdle(IdleStateHandler(writeTimeout: .seconds(1)), true) { $0 == IdleStateHandler.IdleStateEvent.write }
    }

    func testIdleAllWrite() throws {
        try testIdle(IdleStateHandler(allTimeout: .seconds(1)), true) { $0 == IdleStateHandler.IdleStateEvent.all }
    }

    func testIdleAllRead() throws {
        try testIdle(IdleStateHandler(allTimeout: .seconds(1)), false) { $0 == IdleStateHandler.IdleStateEvent.all }
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

            public func channelRead(context _: ChannelHandlerContext, data _: NIOAny) {
                read = true
            }

            public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
                if !writeToChannel {
                    XCTAssertTrue(read)
                }

                XCTAssertTrue(assertEventFn(event as! IdleStateHandler.IdleStateEvent))
                context.close(promise: nil)
            }

            public func channelActive(context: ChannelHandlerContext) {
                if writeToChannel {
                    var buffer = context.channel.allocator.buffer(capacity: 4)
                    buffer.writeStaticString("test")
                    context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
                }
            }
        }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(handler).flatMap { _ in
                    channel.pipeline.addHandler(TestWriteHandler(writeToChannel, assertEventFn))
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

            func channelActive(context _: ChannelHandlerContext) {
                active = true
            }

            func channelInactive(context _: ChannelHandlerContext) {
                inactive = true
            }

            func channelRead(context _: ChannelHandlerContext, data _: NIOAny) {
                read = true
            }

            func channelReadComplete(context _: ChannelHandlerContext) {
                readComplete = true
            }

            func channelWritabilityChanged(context _: ChannelHandlerContext) {
                writabilityChanged = true
            }

            func userInboundEventTriggered(context _: ChannelHandlerContext, event _: Any) {
                eventTriggered = true
            }

            func errorCaught(context _: ChannelHandlerContext, error _: Error) {
                errorCaught = true
            }

            func channelRegistered(context _: ChannelHandlerContext) {
                registered = true
            }

            func channelUnregistered(context _: ChannelHandlerContext) {
                unregistered = true
            }

            func assertAllEventsReceived() {
                XCTAssertTrue(active)
                XCTAssertTrue(inactive)
                XCTAssertTrue(read)
                XCTAssertTrue(readComplete)
                XCTAssertTrue(writabilityChanged)
                XCTAssertTrue(eventTriggered)
                XCTAssertTrue(errorCaught)
                XCTAssertTrue(registered)
                XCTAssertTrue(unregistered)
            }
        }
        let eventHandler = EventHandler()
        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.pipeline.addHandler(IdleStateHandler()).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(eventHandler).wait())

        channel.pipeline.fireChannelRegistered()
        channel.pipeline.fireChannelActive()
        channel.pipeline.fireChannelRead(NIOAny(""))
        channel.pipeline.fireChannelReadComplete()
        channel.pipeline.fireErrorCaught(ChannelError.alreadyClosed)
        channel.pipeline.fireUserInboundEventTriggered("")

        channel.pipeline.fireChannelWritabilityChanged()
        channel.pipeline.fireChannelInactive()
        channel.pipeline.fireChannelUnregistered()

        XCTAssertTrue(try channel.finish().isClean)
        eventHandler.assertAllEventsReceived()
    }
}
