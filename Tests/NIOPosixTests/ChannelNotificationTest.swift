//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import XCTest

@testable import NIOPosix

class ChannelNotificationTest: XCTestCase {

    private static func assertFulfilled(
        promise: EventLoopPromise<Void>?,
        promiseName: String,
        trigger: String,
        setter: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let promise = promise {
            XCTAssertTrue(
                promise.futureResult.isFulfilled,
                "\(promiseName) not fulfilled before \(trigger) was called",
                file: (file),
                line: line
            )
        } else {
            XCTFail("\(setter) not called before \(trigger)", file: (file), line: line)
        }
    }

    // Handler that verifies the notification order of the different promises + the inbound events that are fired.
    class SocketChannelLifecycleVerificationHandler: ChannelDuplexHandler {
        typealias InboundIn = Any
        typealias OutboundIn = Any

        private var registerPromise: EventLoopPromise<Void>?
        private var connectPromise: EventLoopPromise<Void>?
        private var closePromise: EventLoopPromise<Void>?

        public func channelActive(context: ChannelHandlerContext) {
            XCTAssertTrue(context.channel.isActive)

            assertFulfilled(
                promise: self.registerPromise,
                promiseName: "registerPromise",
                trigger: "channelActive",
                setter: "register"
            )
            assertFulfilled(
                promise: self.connectPromise,
                promiseName: "connectPromise",
                trigger: "channelActive",
                setter: "connect"
            )

            XCTAssertNil(self.closePromise)
            XCTAssertFalse(context.channel.closeFuture.isFulfilled)
        }

        public func channelInactive(context: ChannelHandlerContext) {
            XCTAssertFalse(context.channel.isActive)

            assertFulfilled(
                promise: self.registerPromise,
                promiseName: "registerPromise",
                trigger: "channelInactive",
                setter: "register"
            )
            assertFulfilled(
                promise: self.connectPromise,
                promiseName: "connectPromise",
                trigger: "channelInactive",
                setter: "connect"
            )
            assertFulfilled(
                promise: self.closePromise,
                promiseName: "closePromise",
                trigger: "channelInactive",
                setter: "close"
            )

            XCTAssertFalse(context.channel.closeFuture.isFulfilled)
        }

        public func channelRegistered(context: ChannelHandlerContext) {
            XCTAssertFalse(context.channel.isActive)
            XCTAssertNil(self.connectPromise)
            XCTAssertNil(self.closePromise)

            assertFulfilled(
                promise: self.registerPromise,
                promiseName: "registerPromise",
                trigger: "channelRegistered",
                setter: "register"
            )

            XCTAssertFalse(context.channel.closeFuture.isFulfilled)
        }

        public func channelUnregistered(context: ChannelHandlerContext) {
            XCTAssertFalse(context.channel.isActive)

            assertFulfilled(
                promise: self.registerPromise,
                promiseName: "registerPromise",
                trigger: "channelInactive",
                setter: "register"
            )
            assertFulfilled(
                promise: self.connectPromise,
                promiseName: "connectPromise",
                trigger: "channelInactive",
                setter: "connect"
            )
            assertFulfilled(
                promise: self.closePromise,
                promiseName: "closePromise",
                trigger: "channelInactive",
                setter: "close"
            )

            XCTAssertFalse(context.channel.closeFuture.isFulfilled)
        }

        public func register(context: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
            XCTAssertNil(self.registerPromise)
            XCTAssertNil(self.connectPromise)
            XCTAssertNil(self.closePromise)

            promise!.futureResult.whenSuccess { [channel = context.channel] in
                XCTAssertFalse(channel.isActive)
            }

            self.registerPromise = promise
            context.register(promise: promise)
        }

        public func bind(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
            XCTFail("bind(...) should not be called")
            context.bind(to: address, promise: promise)
        }

        public func connect(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?)
        {
            XCTAssertNotNil(self.registerPromise)
            XCTAssertNil(self.connectPromise)
            XCTAssertNil(self.closePromise)

            promise!.futureResult.whenSuccess { [channel = context.channel] in
                XCTAssertTrue(channel.isActive)
            }

            self.connectPromise = promise
            context.connect(to: address, promise: promise)
        }

        public func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
            XCTAssertNotNil(self.registerPromise)
            XCTAssertNotNil(self.connectPromise)
            XCTAssertNil(self.closePromise)

            promise!.futureResult.whenSuccess { [channel = context.channel] in
                XCTAssertFalse(channel.isActive)
            }

            self.closePromise = promise
            context.close(mode: mode, promise: promise)
        }
    }

    class AcceptedSocketChannelLifecycleVerificationHandler: ChannelDuplexHandler {
        typealias InboundIn = Any
        typealias OutboundIn = Any

        private var registerPromise: EventLoopPromise<Void>?
        private let activeChannelPromise: EventLoopPromise<Channel>

        init(_ activeChannelPromise: EventLoopPromise<Channel>) {
            self.activeChannelPromise = activeChannelPromise
        }

        public func channelActive(context: ChannelHandlerContext) {
            XCTAssertTrue(context.channel.isActive)

            assertFulfilled(
                promise: self.registerPromise,
                promiseName: "registerPromise",
                trigger: "channelActive",
                setter: "register"
            )

            XCTAssertFalse(context.channel.closeFuture.isFulfilled)
            XCTAssertFalse(self.activeChannelPromise.futureResult.isFulfilled)
            self.activeChannelPromise.succeed(context.channel)
        }

        public func channelInactive(context: ChannelHandlerContext) {
            XCTAssertFalse(context.channel.isActive)

            assertFulfilled(
                promise: self.registerPromise,
                promiseName: "registerPromise",
                trigger: "channelInactive",
                setter: "register"
            )

            XCTAssertFalse(context.channel.closeFuture.isFulfilled)
        }

        public func channelRegistered(context: ChannelHandlerContext) {
            XCTAssertFalse(context.channel.isActive)

            assertFulfilled(
                promise: self.registerPromise,
                promiseName: "registerPromise",
                trigger: "channelRegistered",
                setter: "register"
            )

            XCTAssertFalse(context.channel.closeFuture.isFulfilled)
        }

        public func channelUnregistered(context: ChannelHandlerContext) {
            XCTAssertFalse(context.channel.isActive)

            assertFulfilled(
                promise: self.registerPromise,
                promiseName: "registerPromise",
                trigger: "channelUnregistered",
                setter: "register"
            )

            XCTAssertFalse(context.channel.closeFuture.isFulfilled)
        }

        public func register(context: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
            XCTAssertNil(self.registerPromise)

            let p = promise ?? context.eventLoop.makePromise()
            p.futureResult.whenSuccess { [channel = context.channel] in
                XCTAssertFalse(channel.isActive)
            }

            self.registerPromise = p
            context.register(promise: p)
        }

        public func connect(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?)
        {
            XCTFail("connect(...) should not be called")
            context.connect(to: address, promise: promise)
        }

        public func bind(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
            XCTFail("bind(...) should not be called")
            context.bind(to: address, promise: promise)
        }

        public func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
            XCTFail("close(...) should not be called")
            context.close(mode: mode, promise: promise)
        }
    }

    class ServerSocketChannelLifecycleVerificationHandler: ChannelDuplexHandler {
        typealias InboundIn = Any
        typealias OutboundIn = Any

        private var registerPromise: EventLoopPromise<Void>?
        private var bindPromise: EventLoopPromise<Void>?

        private var closePromise: EventLoopPromise<Void>?

        public func channelActive(context: ChannelHandlerContext) {
            XCTAssertTrue(context.channel.isActive)

            assertFulfilled(
                promise: self.registerPromise,
                promiseName: "registerPromise",
                trigger: "channelActive",
                setter: "register"
            )

            XCTAssertNil(self.closePromise)
            XCTAssertFalse(context.channel.closeFuture.isFulfilled)
        }

        public func channelInactive(context: ChannelHandlerContext) {
            XCTAssertFalse(context.channel.isActive)

            assertFulfilled(
                promise: self.registerPromise,
                promiseName: "registerPromise",
                trigger: "channelInactive",
                setter: "register"
            )
            assertFulfilled(
                promise: self.closePromise,
                promiseName: "closePromise",
                trigger: "channelInactive",
                setter: "close"
            )

            XCTAssertFalse(context.channel.closeFuture.isFulfilled)
        }

        public func channelRegistered(context: ChannelHandlerContext) {
            XCTAssertFalse(context.channel.isActive)
            XCTAssertNil(closePromise)

            assertFulfilled(
                promise: self.registerPromise,
                promiseName: "registerPromise",
                trigger: "channelRegistered",
                setter: "register"
            )

            XCTAssertFalse(context.channel.closeFuture.isFulfilled)
        }

        public func channelUnregistered(context: ChannelHandlerContext) {
            XCTAssertFalse(context.channel.isActive)

            assertFulfilled(
                promise: self.registerPromise,
                promiseName: "registerPromise",
                trigger: "channelUnregistered",
                setter: "register"
            )
            assertFulfilled(
                promise: self.closePromise,
                promiseName: "closePromise",
                trigger: "channelInactive",
                setter: "close"
            )

            XCTAssertFalse(context.channel.closeFuture.isFulfilled)
        }

        public func register(context: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
            XCTAssertNil(self.registerPromise)
            XCTAssertNil(self.bindPromise)
            XCTAssertNil(self.closePromise)

            let p = promise ?? context.eventLoop.makePromise()
            p.futureResult.whenSuccess { [channel = context.channel] in
                XCTAssertFalse(channel.isActive)
            }

            self.registerPromise = p
            context.register(promise: p)
        }

        public func connect(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?)
        {
            XCTFail("connect(...) should not be called")
            context.connect(to: address, promise: promise)
        }

        public func bind(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
            XCTAssertNotNil(self.registerPromise)
            XCTAssertNil(self.bindPromise)
            XCTAssertNil(self.closePromise)

            promise?.futureResult.whenSuccess { [channel = context.channel] in
                XCTAssertTrue(channel.isActive)
            }

            self.bindPromise = promise
            context.bind(to: address, promise: promise)
        }

        public func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
            XCTAssertNotNil(self.registerPromise)
            XCTAssertNotNil(self.bindPromise)
            XCTAssertNil(self.closePromise)

            let p = promise ?? context.eventLoop.makePromise()
            p.futureResult.whenSuccess { [channel = context.channel] in
                XCTAssertFalse(channel.isActive)
            }

            self.closePromise = p
            context.close(mode: mode, promise: p)
        }
    }

    func testNotificationOrder() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let acceptedChannelPromise = group.next().makePromise(of: Channel.self)

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .serverChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            ServerSocketChannelLifecycleVerificationHandler()
                        )
                    }
                }
                .childChannelOption(.autoRead, value: false)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            AcceptedSocketChannelLifecycleVerificationHandler(acceptedChannelPromise)
                        )
                    }
                }
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            SocketChannelLifecycleVerificationHandler()
                        )
                    }
                }
                .connect(to: serverChannel.localAddress!).wait()
        )
        XCTAssertNoThrow(try clientChannel.close().wait())
        XCTAssertNoThrow(try clientChannel.closeFuture.wait())

        let channel = try acceptedChannelPromise.futureResult.wait()
        var buffer = channel.allocator.buffer(capacity: 8)
        buffer.writeString("test")

        while (try? channel.writeAndFlush(buffer).wait()) != nil {
            // Just write in a loop until it fails to ensure we detect the closed connection in a timely manner.
        }
        XCTAssertNoThrow(try channel.closeFuture.wait())

        XCTAssertNoThrow(try serverChannel.close().wait())
        XCTAssertNoThrow(try serverChannel.closeFuture.wait())
    }

    func testActiveBeforeChannelRead() throws {
        // Use two EventLoops to ensure the ServerSocketChannel and the SocketChannel are on different threads.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        class OrderVerificationHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private enum State {
                case `init`
                case active
                case read
                case readComplete
                case inactive
            }

            private var state = State.`init`
            private let promise: EventLoopPromise<Void>

            init(_ promise: EventLoopPromise<Void>) {
                self.promise = promise
            }

            public func channelActive(context: ChannelHandlerContext) {
                XCTAssertEqual(.`init`, state)
                state = .active
            }

            public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                XCTAssertEqual(.active, state)
                state = .read
            }

            public func channelReadComplete(context: ChannelHandlerContext) {
                XCTAssertTrue(
                    .read == state || .readComplete == state,
                    "State should either be .read or .readComplete but was \(state)"
                )
                state = .readComplete
            }

            public func channelInactive(context: ChannelHandlerContext) {
                XCTAssertEqual(.readComplete, state)
                state = .inactive

                promise.succeed(())
            }
        }

        let promise = group.next().makePromise(of: Void.self)
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(.autoRead, value: true)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(OrderVerificationHandler(promise))
                    }
                }
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!).wait()
        )

        var buffer = clientChannel.allocator.buffer(capacity: 2)
        buffer.writeString("X")
        XCTAssertNoThrow(
            try clientChannel.writeAndFlush(buffer).flatMap {
                clientChannel.close()
            }.wait()
        )
        XCTAssertNoThrow(try promise.futureResult.wait())

        XCTAssertNoThrow(try clientChannel.closeFuture.wait())
        XCTAssertNoThrow(try serverChannel.close().wait())
        XCTAssertNoThrow(try serverChannel.closeFuture.wait())
    }
}
