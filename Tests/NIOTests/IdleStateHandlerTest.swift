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
        try testIdle(IdleStateHandler(readTimeout: .seconds(1)), false, { v in
            if case IdleStateHandler.IdleStateEvent.read = v {
                return true
            } else {
                return false
            }
        })
    }
    
    func testIdleWrite() throws {
        try testIdle(IdleStateHandler(writeTimeout: .seconds(1)), true, { v in
            if case IdleStateHandler.IdleStateEvent.write = v {
                return true
            } else {
                return false
            }
        })
    }
    
    func testIdleAllWrite() throws {
        try testIdle(IdleStateHandler(allTimeout: .seconds(1)), true, { v in
            if case IdleStateHandler.IdleStateEvent.all = v {
                return true
            } else {
                return false
            }
        })
    }
    
    func testIdleAllRead() throws {
        try testIdle(IdleStateHandler(allTimeout: .seconds(1)), false, { v in
            if case IdleStateHandler.IdleStateEvent.all = v {
                return true
            } else {
                return false
            }
        })
    }
    
    private func testIdle(_ handler: IdleStateHandler, _ writeToChannel: Bool, _ assertEventFn: @escaping (Any) -> Bool) throws {
        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }
        
        class TestWriteHandler: _ChannelInboundHandler {
            private var read = false
            private let writeToChannel: Bool
            private let assertEventFn: (Any) -> Bool
            
            init(_ writeToChannel: Bool, _ assertEventFn: @escaping (Any) -> Bool) {
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

                XCTAssertTrue(assertEventFn(event))
                ctx.close(promise: nil)
            }
            
            public func channelActive(ctx: ChannelHandlerContext) {
                if writeToChannel {
                    var buffer = ctx.channel!.allocator.buffer(capacity: 4)
                    buffer.write(staticString: "test")
                    ctx.writeAndFlush(data: NIOAny(buffer), promise: nil)
                }
            }
        }
        
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                channel.pipeline.add(handler: handler).then(callback: { f in
                    channel.pipeline.add(handler: TestWriteHandler(writeToChannel, assertEventFn))
                })
            })).bind(to: "127.0.0.1", on: 0).wait()
        
        defer {
            _ = serverChannel.close()
        }
        
        let clientChannel = try ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait()
        if !writeToChannel {
            var buffer = clientChannel.allocator.buffer(capacity: 4)
            buffer.write(staticString: "test")
            try clientChannel.writeAndFlush(data: NIOAny(buffer)).wait()
        }
        try clientChannel.closeFuture.wait()
    }
}
