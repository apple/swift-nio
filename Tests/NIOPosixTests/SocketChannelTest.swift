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

import Atomics
import NIOConcurrencyHelpers
import NIOCore
import NIOTestUtils
import XCTest

@testable import NIOPosix

extension Array {
    /// A helper function that asserts that a predicate is true for all elements.
    fileprivate func assertAll(_ predicate: (Element) -> Bool) {
        for (index, element) in self.enumerated() {
            if !predicate(element) {
                XCTFail("Entry \(index) failed predicate, contents: \(element)")
            }
        }
    }
}

final class SocketChannelTest: XCTestCase {
    /// Validate that channel options are applied asynchronously.
    public func testAsyncSetOption() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        // Create two channels with different event loops.
        let channelA = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        let channelB: Channel = try {
            while true {
                let channel = try assertNoThrowWithValue(
                    ServerBootstrap(group: group)
                        .bind(host: "127.0.0.1", port: 0)
                        .wait()
                )
                if channel.eventLoop !== channelA.eventLoop {
                    return channel
                }
            }
        }()
        XCTAssert(channelA.eventLoop !== channelB.eventLoop)

        // Ensure we can dispatch two concurrent set option's on each others
        // event loops.
        let condition = ManagedAtomic(0)
        let futureA = channelA.eventLoop.submit {
            condition.wrappingIncrement(ordering: .relaxed)
            while condition.load(ordering: .relaxed) < 2 {}
            _ = channelB.setOption(.backlog, value: 1)
        }
        let futureB = channelB.eventLoop.submit {
            condition.wrappingIncrement(ordering: .relaxed)
            while condition.load(ordering: .relaxed) < 2 {}
            _ = channelA.setOption(.backlog, value: 1)
        }
        try futureA.wait()
        try futureB.wait()
    }

    public func testDelayedConnectSetsUpRemotePeerAddress() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .serverChannelOption(.backlog, value: 256)
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        // The goal of this test is to try to trigger at least one channel to have connection setup that is not
        // instantaneous. Due to the design of NIO this is not really observable to us, and due to the complex
        // overlapping interactions between SYN queues and loopback interfaces in modern kernels it's not
        // trivial to trigger this behaviour. The easiest thing we can do here is to try to slow the kernel down
        // enough that a connection eventually is delayed. To do this we're going to submit 50 connections more
        // or less at once.
        var clientConnectionFutures: [EventLoopFuture<Channel>] = []
        clientConnectionFutures.reserveCapacity(50)
        let clientBootstrap = ClientBootstrap(group: group)

        for _ in 0..<50 {
            let conn = clientBootstrap.connect(to: serverChannel.localAddress!)
            clientConnectionFutures.append(conn)
        }

        let remoteAddresses = try clientConnectionFutures.map { try $0.wait() }.map { $0.remoteAddress }

        // Now we want to check that they're all the same. The bug we're catching here is one where delayed connection
        // setup causes us to get nil as the remote address, even though we connected (and we did, as these are all
        // up right now).
        remoteAddresses.assertAll { $0 != nil }
    }

    public func testAcceptFailsWithECONNABORTED() throws {
        try assertAcceptFails(error: ECONNABORTED, active: true)
    }

    public func testAcceptFailsWithEMFILE() throws {
        try assertAcceptFails(error: EMFILE, active: true)
    }

    public func testAcceptFailsWithENFILE() throws {
        try assertAcceptFails(error: ENFILE, active: true)
    }

    public func testAcceptFailsWithENOBUFS() throws {
        try assertAcceptFails(error: ENOBUFS, active: true)
    }

    public func testAcceptFailsWithENOMEM() throws {
        try assertAcceptFails(error: ENOMEM, active: true)
    }

    public func testAcceptFailsWithEFAULT() throws {
        try assertAcceptFails(error: EFAULT, active: false)
    }

    private func assertAcceptFails(error: Int32, active: Bool) throws {
        final class AcceptHandler: ChannelInboundHandler {
            typealias InboundIn = Channel
            typealias InboundOut = Channel

            private let promise: EventLoopPromise<IOError>

            init(_ promise: EventLoopPromise<IOError>) {
                self.promise = promise
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                XCTFail("Should not accept a Channel but got \(Self.unwrapInboundIn(data))")
            }

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                if let ioError = error as? IOError {
                    self.promise.succeed(ioError)
                }
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let socket = try NonAcceptingServerSocket(errors: [error])
        let serverChannel = try assertNoThrowWithValue(
            ServerSocketChannel(
                serverSocket: socket,
                eventLoop: group.next() as! SelectableEventLoop,
                group: group
            )
        )
        let promise = serverChannel.eventLoop.makePromise(of: IOError.self)

        XCTAssertNoThrow(
            try serverChannel.eventLoop.flatSubmit {
                serverChannel.eventLoop.makeCompletedFuture {
                    try serverChannel.pipeline.syncOperations.addHandler(AcceptHandler(promise))
                }.flatMap {
                    serverChannel.register()
                }.flatMap {
                    serverChannel.bind(to: try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
                }
            }.wait() as Void
        )

        XCTAssertEqual(
            active,
            try serverChannel.eventLoop.submit {
                serverChannel.readable()
                return serverChannel.isActive
            }.wait()
        )

        if active {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let ioError = try promise.futureResult.wait()
        XCTAssertEqual(error, ioError.errnoCode)
    }

    public func testSetGetOptionClosedServerSocketChannel() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        // Create two channels with different event loops.
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!)
                .wait()
        )

        XCTAssertNoThrow(
            try assertSetGetOptionOnOpenAndClosed(
                channel: clientChannel,
                option: .allowRemoteHalfClosure,
                value: true
            )
        )
        XCTAssertNoThrow(
            try assertSetGetOptionOnOpenAndClosed(
                channel: serverChannel,
                option: .backlog,
                value: 100
            )
        )
    }

    public func testConnect() throws {
        final class ActiveVerificationHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            private let promise: EventLoopPromise<Void>

            init(_ promise: EventLoopPromise<Void>) {
                self.promise = promise
            }

            func channelActive(context: ChannelHandlerContext) {
                promise.succeed(())
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        class ConnectSocket: Socket {
            private let promise: EventLoopPromise<Void>
            init(promise: EventLoopPromise<Void>) throws {
                self.promise = promise
                try super.init(protocolFamily: .inet, type: .stream)
            }

            override func connect(to address: SocketAddress) throws -> Bool {
                self.promise.succeed(())
                return true
            }
        }

        let eventLoop = group.next()
        let connectPromise = eventLoop.makePromise(of: Void.self)

        let channel = try assertNoThrowWithValue(
            SocketChannel(
                socket: ConnectSocket(promise: connectPromise),
                parent: nil,
                eventLoop: eventLoop as! SelectableEventLoop
            )
        )
        let promise = channel.eventLoop.makePromise(of: Void.self)

        XCTAssertNoThrow(
            try channel.eventLoop.flatSubmit {
                // We need to hop to the EventLoop here to make sure that we don't get an ECONNRESET before we manage
                // to close.
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ActiveVerificationHandler(promise))
                }.flatMap {
                    channel.register()
                }.flatMap {
                    channel.connect(to: try! SocketAddress(ipAddress: "127.0.0.1", port: 9999))
                }.flatMap {
                    channel.close()
                }
            }.wait()
        )

        XCTAssertNoThrow(try channel.closeFuture.wait())
        XCTAssertNoThrow(try promise.futureResult.wait())
        XCTAssertNoThrow(try connectPromise.futureResult.wait())
    }

    public func testWriteServerSocketChannel() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        XCTAssertThrowsError(try serverChannel.writeAndFlush("test").wait()) { error in
            XCTAssertEqual(.operationUnsupported, error as? ChannelError)
        }
        try serverChannel.close().wait()
    }

    public func testWriteAndFlushServerSocketChannel() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        XCTAssertThrowsError(try serverChannel.writeAndFlush("test").wait()) { error in
            XCTAssertEqual(.operationUnsupported, error as? ChannelError)
        }
        try serverChannel.close().wait()
    }

    public func testConnectServerSocketChannel() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        XCTAssertThrowsError(try serverChannel.writeAndFlush("test").wait()) { error in
            XCTAssertEqual(.operationUnsupported, error as? ChannelError)
        }
    }

    public func testCloseDuringWriteFailure() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!)
                .wait()
        )

        // Put a write in the channel but don't flush it. We're then going to
        // close the channel. This should trigger an error callback that will
        // re-close the channel, which should fail with `alreadyClosed`.
        var buffer = clientChannel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("hello")
        let writeFut = clientChannel.write(buffer).map {
            XCTFail("Must not succeed")
        }.flatMapError { error in
            XCTAssertEqual(error as? ChannelError, ChannelError.ioOnClosedChannel)
            return clientChannel.close()
        }
        XCTAssertNoThrow(try clientChannel.close().wait())

        XCTAssertThrowsError(try writeFut.wait()) { error in
            XCTAssertEqual(.alreadyClosed, error as? ChannelError)
        }
    }

    public func testWithConfiguredStreamSocket() throws {
        let didAccept = ConditionLock<Int>(value: 0)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverSock = try Socket(protocolFamily: .inet, type: .stream)
        try serverSock.bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0))
        let serverChannelFuture = try serverSock.withUnsafeHandle {
            ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let acquiredLock = didAccept.lock(whenValue: 0, timeoutSeconds: 1)
                        XCTAssertTrue(acquiredLock)
                        didAccept.unlock(withValue: 1)
                    }
                }
                .withBoundSocket(dup($0))
        }
        try serverSock.close()
        let serverChannel = try serverChannelFuture.wait()

        let clientSock = try Socket(protocolFamily: .inet, type: .stream)
        let connected = try clientSock.connect(to: serverChannel.localAddress!)
        XCTAssertEqual(connected, true)
        let clientChannelFuture = try clientSock.withUnsafeHandle {
            ClientBootstrap(group: group).withConnectedSocket(dup($0))
        }
        try clientSock.close()

        // At this point we need to wait not just for the client connection to be created
        // but also for the server connection to come in. Otherwise we risk a race where the
        // client connection has come up but the server connection hasn't yet, leading to the
        // server channel close below causing the server to never accept the inbound channel
        // and leading to an unexpected error on close.
        let clientChannel = try clientChannelFuture.wait()
        XCTAssertEqual(true, clientChannel.isActive)

        let acquiredLock = didAccept.lock(whenValue: 1, timeoutSeconds: 1)
        XCTAssertTrue(acquiredLock)
        didAccept.unlock()

        try serverChannel.close().wait()
        try clientChannel.close().wait()
    }

    public func testWithConfiguredDatagramSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverSock = try Socket(protocolFamily: .inet, type: .datagram)
        try serverSock.bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0))
        let serverChannelFuture = try serverSock.withUnsafeHandle {
            DatagramBootstrap(group: group).withBoundSocket(dup($0))
        }
        try serverSock.close()
        let serverChannel = try serverChannelFuture.wait()

        XCTAssertEqual(true, serverChannel.isActive)

        try serverChannel.close().wait()
    }

    public func testPendingConnectNotificationOrder() throws {

        class NotificationOrderHandler: ChannelDuplexHandler {
            typealias InboundIn = Never
            typealias OutboundIn = Never

            private var connectPromise: EventLoopPromise<Void>?

            public func channelInactive(context: ChannelHandlerContext) {
                if let connectPromise = self.connectPromise {
                    XCTAssertTrue(connectPromise.futureResult.isFulfilled)
                } else {
                    XCTFail("connect(...) not called before")
                }
            }

            public func connect(
                context: ChannelHandlerContext,
                to address: SocketAddress,
                promise: EventLoopPromise<Void>?
            ) {
                XCTAssertNil(self.connectPromise)
                self.connectPromise = promise
                context.connect(to: address, promise: promise)
            }

            func handlerAdded(context: ChannelHandlerContext) {
                XCTAssertNil(self.connectPromise)
            }

            func handlerRemoved(context: ChannelHandlerContext) {
                if let connectPromise = self.connectPromise {
                    XCTAssertTrue(connectPromise.futureResult.isFulfilled)
                } else {
                    XCTFail("connect(...) not called before")
                }
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        defer { XCTAssertNoThrow(try serverChannel.close().wait()) }

        let eventLoop = group.next()
        let promise = eventLoop.makePromise(of: Void.self)

        class ConnectPendingSocket: Socket {
            let promise: EventLoopPromise<Void>
            init(promise: EventLoopPromise<Void>) throws {
                self.promise = promise
                try super.init(protocolFamily: .inet, type: .stream)
            }

            override func connect(to address: SocketAddress) throws -> Bool {
                // We want to return false here to have a pending connect.
                _ = try super.connect(to: address)
                self.promise.succeed(())
                return false
            }
        }

        let channel = try SocketChannel(
            socket: ConnectPendingSocket(promise: promise),
            parent: nil,
            eventLoop: eventLoop as! SelectableEventLoop
        )
        let connectPromise = channel.eventLoop.makePromise(of: Void.self)
        let closePromise = channel.eventLoop.makePromise(of: Void.self)

        closePromise.futureResult.whenComplete { (_: Result<Void, Error>) in
            XCTAssertTrue(connectPromise.futureResult.isFulfilled)
        }
        connectPromise.futureResult.whenComplete { (_: Result<Void, Error>) in
            XCTAssertFalse(closePromise.futureResult.isFulfilled)
        }

        let added = channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(NotificationOrderHandler())
        }

        XCTAssertNoThrow(try added.wait())

        // We need to call submit {...} here to ensure then {...} is called while on the EventLoop already to not have
        // a ECONNRESET sneak in.
        XCTAssertNoThrow(
            try channel.eventLoop.flatSubmit {
                channel.register().map { () -> Void in
                    channel.connect(to: serverChannel.localAddress!, promise: connectPromise)
                }.map { () -> Void in
                    XCTAssertFalse(connectPromise.futureResult.isFulfilled)
                    // The close needs to happen in the then { ... } block to ensure we close the channel
                    // before we have the chance to register it for .write.
                    channel.close(promise: closePromise)
                }
            }.wait() as Void
        )

        XCTAssertThrowsError(try connectPromise.futureResult.wait()) { error in
            XCTAssertEqual(.ioOnClosedChannel, error as? ChannelError)
        }
        XCTAssertNoThrow(try closePromise.futureResult.wait())
        XCTAssertNoThrow(try channel.closeFuture.wait())
        XCTAssertNoThrow(try promise.futureResult.wait())
    }

    public func testLocalAndRemoteAddressNotNilInChannelInactiveAndHandlerRemoved() throws {

        class AddressVerificationHandler: ChannelInboundHandler {
            typealias InboundIn = Never
            typealias OutboundIn = Never

            enum HandlerState {
                case created
                case inactive
                case removed
            }

            let promise: EventLoopPromise<Void>
            var state = HandlerState.created

            init(promise: EventLoopPromise<Void>) {
                self.promise = promise
            }

            func channelInactive(context: ChannelHandlerContext) {
                XCTAssertNotNil(context.localAddress)
                XCTAssertNotNil(context.remoteAddress)
                XCTAssertEqual(.created, state)
                state = .inactive
            }

            func handlerRemoved(context: ChannelHandlerContext) {
                XCTAssertNotNil(context.localAddress)
                XCTAssertNotNil(context.remoteAddress)
                XCTAssertEqual(.inactive, state)
                state = .removed

                let loopBoundContext = context.loopBound
                context.channel.closeFuture.assumeIsolated().whenComplete { (_: Result<Void, Error>) in
                    let context = loopBoundContext.value
                    XCTAssertNil(context.localAddress)
                    XCTAssertNil(context.remoteAddress)

                    self.promise.succeed(())
                }
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let promise = group.next().makePromise(of: Void.self)
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let handler = AddressVerificationHandler(promise: promise)
                        return try channel.pipeline.syncOperations.addHandler(handler)
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        defer { XCTAssertNoThrow(try serverChannel.close().wait()) }

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!)
                .wait()
        )

        XCTAssertNoThrow(try clientChannel.close().wait())
        XCTAssertNoThrow(try promise.futureResult.wait())
    }

    func testSocketFlagNONBLOCKWorks() throws {
        var socket = try assertNoThrowWithValue(try ServerSocket(protocolFamily: .inet, setNonBlocking: true))
        XCTAssertNoThrow(
            try socket.withUnsafeHandle { fd in
                let flags = try assertNoThrowWithValue(Posix.fcntl(descriptor: fd, command: F_GETFL, value: 0))
                XCTAssertEqual(O_NONBLOCK, flags & O_NONBLOCK)
            }
        )
        XCTAssertNoThrow(try socket.close())

        socket = try assertNoThrowWithValue(ServerSocket(protocolFamily: .inet, setNonBlocking: false))
        XCTAssertNoThrow(
            try socket.withUnsafeHandle { fd in
                var flags = try assertNoThrowWithValue(Posix.fcntl(descriptor: fd, command: F_GETFL, value: 0))
                XCTAssertEqual(0, flags & O_NONBLOCK)
                let ret = try assertNoThrowWithValue(
                    Posix.fcntl(descriptor: fd, command: F_SETFL, value: flags | O_NONBLOCK)
                )
                XCTAssertEqual(0, ret)
                flags = try assertNoThrowWithValue(Posix.fcntl(descriptor: fd, command: F_GETFL, value: 0))
                XCTAssertEqual(O_NONBLOCK, flags & O_NONBLOCK)
            }
        )
        XCTAssertNoThrow(try socket.close())
    }

    func testInstantTCPConnectionResetThrowsError() throws {
        #if !os(Linux) && !os(Android)
        // This test checks that we correctly fail with an error rather than
        // asserting or silently ignoring if a client aborts the connection
        // early with a RST before accept(). The behaviour is the same as closing the socket
        // during the accept. But it is easier to test closing the socket before the accept, than during it.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        // Handler that checks for the expected error.
        final class ErrorHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = Channel
            typealias InboundOut = Channel

            private let promise: EventLoopPromise<IOError>

            init(_ promise: EventLoopPromise<IOError>) {
                self.promise = promise
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                XCTFail("Should not accept a Channel but got \(self.unwrapInboundIn(data))")
                self.promise.fail(ChannelError.inappropriateOperationForState)  // any old error will do
            }

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                if let ioError = error as? IOError, ioError.errnoCode == EINVAL {
                    self.promise.succeed(ioError)
                } else {
                    self.promise.fail(error)
                }
            }
        }

        // Build server channel; after this point the server called listen()
        let serverPromise = group.next().makePromise(of: IOError.self)
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .serverChannelOption(.backlog, value: 256)
                .serverChannelOption(.autoRead, value: false)
                .serverChannelInitializer {
                    channel in channel.pipeline.addHandler(ErrorHandler(serverPromise))
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )

        // Make a client socket to mess with the server. Setting SO_LINGER forces RST instead of FIN.
        let clientSocket = try assertNoThrowWithValue(Socket(protocolFamily: .inet, type: .stream))
        XCTAssertNoThrow(
            try clientSocket.setOption(level: .socket, name: .so_linger, value: linger(l_onoff: 1, l_linger: 0))
        )
        XCTAssertNoThrow(try clientSocket.connect(to: serverChannel.localAddress!))
        XCTAssertNoThrow(try clientSocket.close())

        // We wait here to allow slow machines to close the socket
        // We want to ensure the socket is closed before we trigger accept
        // That will trigger the error that we want to test for
        group.any().scheduleTask(in: .seconds(1)) {
            // Trigger accept() in the server
            serverChannel.read()
        }

        // Wait for the server to have something
        XCTAssertThrowsError(try serverPromise.futureResult.wait()) { error in
            XCTAssert(error is NIOFcntlFailedError)
        }
        #endif
    }

    func testUnprocessedOutboundUserEventFailsOnServerSocketChannel() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let channel = try ServerSocketChannel(
            eventLoop: group.next() as! SelectableEventLoop,
            group: group,
            protocolFamily: .inet
        )
        XCTAssertThrowsError(try channel.triggerUserOutboundEvent("event").wait()) { (error: Error) in
            if let error = error as? ChannelError {
                XCTAssertEqual(ChannelError.operationUnsupported, error)
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testUnprocessedOutboundUserEventFailsOnSocketChannel() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let channel = try SocketChannel(
            eventLoop: group.next() as! SelectableEventLoop,
            protocolFamily: .inet
        )
        XCTAssertThrowsError(try channel.triggerUserOutboundEvent("event").wait()) { (error: Error) in
            if let error = error as? ChannelError {
                XCTAssertEqual(ChannelError.operationUnsupported, error)
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testSetSockOptDoesNotOverrideExistingFlags() throws {
        let s = try assertNoThrowWithValue(
            Socket(
                protocolFamily: .inet,
                type: .stream,
                setNonBlocking: false
            )
        )
        // check initial flags
        XCTAssertNoThrow(
            try s.withUnsafeHandle { fd in
                let flags = try Posix.fcntl(descriptor: fd, command: F_GETFL, value: 0)
                XCTAssertEqual(0, flags & O_NONBLOCK)
            }
        )

        // set other random flag
        XCTAssertNoThrow(
            try s.withUnsafeHandle { fd in
                let oldFlags = try Posix.fcntl(descriptor: fd, command: F_GETFL, value: 0)
                let ret = try Posix.fcntl(descriptor: fd, command: F_SETFL, value: oldFlags | O_ASYNC)
                XCTAssertEqual(0, ret)
                let newFlags = try Posix.fcntl(descriptor: fd, command: F_GETFL, value: 0)
                XCTAssertEqual(O_ASYNC, newFlags & O_ASYNC)
            }
        )

        // enable non-blocking
        XCTAssertNoThrow(try s.setNonBlocking())

        // check both are enabled
        XCTAssertNoThrow(
            try s.withUnsafeHandle { fd in
                let flags = try Posix.fcntl(descriptor: fd, command: F_GETFL, value: 0)
                XCTAssertEqual(O_ASYNC, flags & O_ASYNC)
                XCTAssertEqual(O_NONBLOCK, flags & O_NONBLOCK)
            }
        )

        XCTAssertNoThrow(try s.close())
    }

    func testServerChannelDoesNotBreakIfAcceptingFailsWithEINVAL() throws {
        // regression test for:
        // - https://github.com/apple/swift-nio/issues/1030
        // - https://github.com/apple/swift-nio/issues/1598
        class HandsOutMoodySocketsServerSocket: ServerSocket {
            let shouldAcceptsFail = ManagedAtomic(true)
            override func accept(setNonBlocking: Bool = false) throws -> Socket? {
                XCTAssertTrue(setNonBlocking)
                if self.shouldAcceptsFail.load(ordering: .relaxed) {
                    throw NIOFcntlFailedError()
                } else {
                    return try Socket(
                        protocolFamily: .inet,
                        type: .stream,
                        setNonBlocking: false
                    )
                }
            }
        }

        final class CloseAcceptedSocketsHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = Channel

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                Self.unwrapInboundIn(data).close(promise: nil)
            }

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                XCTAssert(error is NIOFcntlFailedError, "unexpected error: \(error)")
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let serverSock = try assertNoThrowWithValue(
            HandsOutMoodySocketsServerSocket(
                protocolFamily: .inet,
                setNonBlocking: true
            )
        )
        let serverChan = try assertNoThrowWithValue(
            ServerSocketChannel(
                serverSocket: serverSock,
                eventLoop: group.next() as! SelectableEventLoop,
                group: group
            )
        )
        XCTAssertNoThrow(try serverChan.setOption(.maxMessagesPerRead, value: 1).wait())
        XCTAssertNoThrow(try serverChan.setOption(.autoRead, value: false).wait())
        XCTAssertNoThrow(try serverChan.register().wait())
        XCTAssertNoThrow(try serverChan.bind(to: .init(ipAddress: "127.0.0.1", port: 0)).wait())

        let eventCounter = EventCounterHandler()
        XCTAssertNoThrow(try serverChan.pipeline.addHandler(eventCounter).wait())
        XCTAssertNoThrow(try serverChan.pipeline.addHandler(CloseAcceptedSocketsHandler()).wait())

        XCTAssertEqual([], eventCounter.allTriggeredEvents())
        XCTAssertNoThrow(
            try serverChan.eventLoop.submit {
                serverChan.readable()
            }.wait()
        )
        XCTAssertEqual(["channelReadComplete", "errorCaught"], eventCounter.allTriggeredEvents())
        XCTAssertEqual(1, eventCounter.channelReadCompleteCalls)
        XCTAssertEqual(1, eventCounter.errorCaughtCalls)

        serverSock.shouldAcceptsFail.store(false, ordering: .relaxed)

        XCTAssertNoThrow(
            try serverChan.eventLoop.submit {
                serverChan.readable()
            }.wait()
        )
        XCTAssertEqual(
            ["errorCaught", "channelRead", "channelReadComplete"],
            eventCounter.allTriggeredEvents()
        )
        XCTAssertEqual(1, eventCounter.errorCaughtCalls)
        XCTAssertEqual(1, eventCounter.channelReadCalls)
        XCTAssertEqual(2, eventCounter.channelReadCompleteCalls)
    }

    func testWeAreInterestedInReadEOFWhenChannelIsConnectedOnTheServerSide() throws {
        guard isEarlyEOFDeliveryWorkingOnThisOS else {
            #if os(Linux) || os(Android)
            preconditionFailure("this should only ever be entered on Darwin.")
            #else
            return
            #endif
        }
        // This test makes sure that we notice EOFs early, even if we never register for read (by dropping all the reads
        // on the floor. This is the same test as below but this one is for TCP servers.
        for mode in [DropAllReadsOnTheFloorHandler.Mode.halfClosureEnabled, .halfClosureDisabled] {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer {
                XCTAssertNoThrow(try group.syncShutdownGracefully())
            }

            let channelInactivePromise = group.next().makePromise(of: Void.self)
            let channelHalfClosedPromise = group.next().makePromise(of: Void.self)
            let waitUntilWriteFailedPromise = group.next().makePromise(of: Void.self)
            let channelActivePromise = group.next().makePromise(of: Void.self)
            if mode == .halfClosureDisabled {
                // if we don't support half-closure these two promises would otherwise never be fulfilled
                channelInactivePromise.futureResult.cascade(to: waitUntilWriteFailedPromise)
                channelInactivePromise.futureResult.cascade(to: channelHalfClosedPromise)
            }
            let eventCounter = EventCounterHandler()
            let numberOfAcceptedChannels = NIOLockedValueBox(0)
            let server = try assertNoThrowWithValue(
                ServerBootstrap(group: group)
                    .childChannelOption(.allowRemoteHalfClosure, value: mode == .halfClosureEnabled)
                    .childChannelInitializer { channel in
                        numberOfAcceptedChannels.withLockedValue { $0 += 1 }
                        XCTAssertEqual(1, numberOfAcceptedChannels.withLockedValue { $0 })
                        let drop = DropAllReadsOnTheFloorHandler(
                            mode: mode,
                            channelInactivePromise: channelInactivePromise,
                            channelHalfClosedPromise: channelHalfClosedPromise,
                            waitUntilWriteFailedPromise: waitUntilWriteFailedPromise,
                            channelActivePromise: channelActivePromise
                        )
                        return channel.pipeline.addHandlers([eventCounter, drop])
                    }
                    .bind(to: .init(ipAddress: "127.0.0.1", port: 0)).wait()
            )
            let client = try assertNoThrowWithValue(
                ClientBootstrap(group: group)
                    .connect(to: server.localAddress!).wait()
            )
            XCTAssertNoThrow(
                try channelActivePromise.futureResult.flatMap { () -> EventLoopFuture<Void> in
                    XCTAssertTrue(client.isActive)
                    XCTAssertEqual(
                        ["register", "channelActive", "channelRegistered"],
                        eventCounter.allTriggeredEvents()
                    )
                    XCTAssertEqual(1, eventCounter.channelActiveCalls)
                    XCTAssertEqual(1, eventCounter.channelRegisteredCalls)
                    return client.close()
                }.wait()
            )

            XCTAssertNoThrow(try channelHalfClosedPromise.futureResult.wait())
            XCTAssertNoThrow(try channelInactivePromise.futureResult.wait())
            XCTAssertNoThrow(try waitUntilWriteFailedPromise.futureResult.wait())
        }
    }

    func testWeAreInterestedInReadEOFWhenChannelIsConnectedOnTheClientSide() throws {
        guard isEarlyEOFDeliveryWorkingOnThisOS else {
            #if os(Linux) || os(Android)
            preconditionFailure("this should only ever be entered on Darwin.")
            #else
            return
            #endif
        }
        // This test makes sure that we notice EOFs early, even if we never register for read (by dropping all the reads
        // on the floor. This is the same test as above but this one is for TCP clients.
        enum Mode {
            case halfClosureEnabled
            case halfClosureDisabled
        }
        for mode in [DropAllReadsOnTheFloorHandler.Mode.halfClosureEnabled, .halfClosureDisabled] {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer {
                XCTAssertNoThrow(try group.syncShutdownGracefully())
            }

            let acceptedServerChannel: EventLoopPromise<Channel> = group.next().makePromise()
            let channelInactivePromise = group.next().makePromise(of: Void.self)
            let channelHalfClosedPromise = group.next().makePromise(of: Void.self)
            let waitUntilWriteFailedPromise = group.next().makePromise(of: Void.self)
            if mode == .halfClosureDisabled {
                // if we don't support half-closure these two promises would otherwise never be fulfilled
                channelInactivePromise.futureResult.cascade(to: waitUntilWriteFailedPromise)
                channelInactivePromise.futureResult.cascade(to: channelHalfClosedPromise)
            }
            let eventCounter = EventCounterHandler()
            let server = try assertNoThrowWithValue(
                ServerBootstrap(group: group)
                    .childChannelInitializer { channel in
                        acceptedServerChannel.succeed(channel)
                        return channel.eventLoop.makeSucceededFuture(())
                    }
                    .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
                    .wait()
            )
            let client = try assertNoThrowWithValue(
                ClientBootstrap(group: group)
                    .channelOption(.allowRemoteHalfClosure, value: mode == .halfClosureEnabled)
                    .channelInitializer { channel in
                        channel.pipeline.addHandlers([
                            eventCounter,
                            DropAllReadsOnTheFloorHandler(
                                mode: mode,
                                channelInactivePromise: channelInactivePromise,
                                channelHalfClosedPromise: channelHalfClosedPromise,
                                waitUntilWriteFailedPromise: waitUntilWriteFailedPromise
                            ),
                        ])
                    }
                    .connect(to: server.localAddress!).wait()
            )
            XCTAssertNoThrow(
                try acceptedServerChannel.futureResult.flatMap { channel -> EventLoopFuture<Void> in
                    XCTAssertEqual(
                        ["register", "channelActive", "channelRegistered", "connect"],
                        eventCounter.allTriggeredEvents()
                    )
                    XCTAssertEqual(1, eventCounter.channelActiveCalls)
                    XCTAssertEqual(1, eventCounter.channelRegisteredCalls)
                    return channel.close()
                }.wait()
            )

            XCTAssertNoThrow(try channelHalfClosedPromise.futureResult.wait())
            XCTAssertNoThrow(try channelInactivePromise.futureResult.wait())
            XCTAssertNoThrow(try client.closeFuture.wait())
            XCTAssertNoThrow(try waitUntilWriteFailedPromise.futureResult.wait())
        }
    }

    func testServerClosesTheConnectionImmediately() throws {
        // This is a regression test for a problem that the grpc-swift compatibility tests hit where everything would
        // get stuck on a server that just insta-closes every accepted connection.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        class WaitForChannelInactiveHandler: ChannelInboundHandler {
            typealias InboundIn = Never
            typealias OutboundOut = ByteBuffer

            let channelInactivePromise: EventLoopPromise<Void>

            init(channelInactivePromise: EventLoopPromise<Void>) {
                self.channelInactivePromise = channelInactivePromise
            }

            func channelActive(context: ChannelHandlerContext) {
                var buffer = context.channel.allocator.buffer(capacity: 128)
                buffer.writeString(String(repeating: "x", count: 517))
                context.writeAndFlush(Self.wrapOutboundOut(buffer), promise: nil)
            }

            func channelInactive(context: ChannelHandlerContext) {
                self.channelInactivePromise.succeed(())
                context.fireChannelInactive()
            }
        }

        let serverSocket = try assertNoThrowWithValue(ServerSocket(protocolFamily: .inet))
        XCTAssertNoThrow(try serverSocket.bind(to: .init(ipAddress: "127.0.0.1", port: 0)))
        XCTAssertNoThrow(try serverSocket.listen())
        let serverAddress = try serverSocket.localAddress()
        let g = DispatchGroup()
        // Transfer the socket to the dispatch queue. It's not used on this thread after this point.
        let unsafeServerSocket = UnsafeTransfer(serverSocket)
        DispatchQueue(label: "accept one client").async(group: g) {
            if let socket = try! unsafeServerSocket.wrappedValue.accept() {
                try! socket.close()
            }
        }
        let channelInactivePromise = group.next().makePromise(of: Void.self)
        let eventCounter = EventCounterHandler()
        let client = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers([
                            eventCounter,
                            WaitForChannelInactiveHandler(channelInactivePromise: channelInactivePromise),
                        ])
                    }
                }
                .connect(to: serverAddress)
                .wait()
        )
        XCTAssertNoThrow(
            try channelInactivePromise.futureResult.map { _ in
                XCTAssertEqual(1, eventCounter.channelInactiveCalls)
            }.wait()
        )
        XCTAssertNoThrow(try client.closeFuture.wait())
        g.wait()
        XCTAssertNoThrow(try serverSocket.close())
    }

    func testSimpleMPTCP() throws {
        #if os(Linux)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverChannel: Channel

        do {
            serverChannel = try ServerBootstrap(group: group)
                .enableMPTCP(true)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        } catch let error as IOError {
            // Older Linux kernel versions don't support MPTCP, which is fine.
            if error.errnoCode != EINVAL && error.errnoCode != EPROTONOSUPPORT && error.errnoCode != ENOPROTOOPT {
                XCTFail("Unexpected error: \(error)")
            }
            return
        }

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .enableMPTCP(true)
                .connect(to: serverChannel.localAddress!)
                .wait()
        )

        do {
            let serverInfo = try (serverChannel as? SocketOptionProvider)?.getMPTCPInfo().wait()
            let clientInfo = try (clientChannel as? SocketOptionProvider)?.getMPTCPInfo().wait()

            XCTAssertNotNil(serverInfo)
            XCTAssertNotNil(clientInfo)
        } catch let error as IOError {
            // Some Linux kernel versions do support MPTCP but don't support the MPTCP_INFO
            // option.
            XCTAssertEqual(error.errnoCode, EOPNOTSUPP, "Unexpected error: \(error)")
            return
        }

        #endif
    }

}

final class DropAllReadsOnTheFloorHandler: ChannelDuplexHandler, Sendable {
    typealias InboundIn = Never
    typealias OutboundIn = Never
    typealias OutboundOut = ByteBuffer

    enum Mode {
        case halfClosureEnabled
        case halfClosureDisabled
    }

    let channelInactivePromise: EventLoopPromise<Void>
    let channelHalfClosedPromise: EventLoopPromise<Void>
    let waitUntilWriteFailedPromise: EventLoopPromise<Void>
    let channelActivePromise: EventLoopPromise<Void>?
    let mode: Mode

    init(
        mode: Mode,
        channelInactivePromise: EventLoopPromise<Void>,
        channelHalfClosedPromise: EventLoopPromise<Void>,
        waitUntilWriteFailedPromise: EventLoopPromise<Void>,
        channelActivePromise: EventLoopPromise<Void>? = nil
    ) {
        self.mode = mode
        self.channelInactivePromise = channelInactivePromise
        self.channelHalfClosedPromise = channelHalfClosedPromise
        self.waitUntilWriteFailedPromise = waitUntilWriteFailedPromise
        self.channelActivePromise = channelActivePromise
    }

    func channelActive(context: ChannelHandlerContext) {
        self.channelActivePromise?.succeed(())
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            XCTAssertEqual(.halfClosureEnabled, self.mode)
            self.channelHalfClosedPromise.succeed(())
            var buffer = context.channel.allocator.buffer(capacity: 1_000_000)
            buffer.writeBytes(
                Array(
                    repeating: UInt8(ascii: "x"),
                    count: 1_000_000
                )
            )

            // What we're trying to do here is forcing a close without calling `close`. We know that the other side of
            // the connection is fully closed but because we support half-closure, we need to write to 'learn' that the
            // other side has actually fully closed the socket.
            let promise = self.waitUntilWriteFailedPromise
            func writeUntilError() {
                context.writeAndFlush(Self.wrapOutboundOut(buffer)).assumeIsolated().map {
                    writeUntilError()
                }.whenFailure { (_: Error) in
                    promise.succeed(())
                }
            }
            writeUntilError()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.channelInactivePromise.succeed(())
        context.fireChannelInactive()
    }

    func read(context: ChannelHandlerContext) {}
}
