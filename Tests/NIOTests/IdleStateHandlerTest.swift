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
                    buffer.write(staticString: "test")
                    ctx.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
                }
            }
        }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: handler).then { f in
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
            buffer.write(staticString: "test")
            XCTAssertNoThrow(try clientChannel.writeAndFlush(NIOAny(buffer)).wait())
        }
        XCTAssertNoThrow(try clientChannel.closeFuture.wait())
    }
}
