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
import Dispatch
import NIOConcurrencyHelpers

private extension Array {
    /// A helper function that asserts that a predicate is true for all elements.
    func assertAll(_ predicate: (Element) -> Bool) {
        self.enumerated().forEach { (index: Int, element: Element) in
            if !predicate(element) {
                XCTFail("Entry \(index) failed predicate, contents: \(element)")
            }
        }
    }
}

public class SocketChannelTest : XCTestCase {
    /// Validate that channel options are applied asynchronously.
    public func testAsyncSetOption() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        // Create two channels with different event loops.
        let channelA = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        let channelB: Channel = try {
            while true {
                let channel = try assertNoThrowWithValue(ServerBootstrap(group: group)
                    .bind(host: "127.0.0.1", port: 0)
                    .wait())
                if channel.eventLoop !== channelA.eventLoop {
                    return channel
                }
            }
        }()
        XCTAssert(channelA.eventLoop !== channelB.eventLoop)

        // Ensure we can dispatch two concurrent set option's on each others
        // event loops.
        let condition = Atomic<Int>(value: 0)
        let futureA = channelA.eventLoop.submit {
            _ = condition.add(1)
            while condition.load() < 2 { }
            _ = channelB.setOption(option: ChannelOptions.backlog, value: 1)
        }
        let futureB = channelB.eventLoop.submit {
            _ = condition.add(1)
            while condition.load() < 2 { }
            _ = channelA.setOption(option: ChannelOptions.backlog, value: 1)
        }
        try futureA.wait()
        try futureB.wait()
    }

    public func testDelayedConnectSetsUpRemotePeerAddress() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .bind(host: "127.0.0.1", port: 0).wait())

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

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                XCTFail("Should not accept a Channel but got \(self.unwrapInboundIn(data))")
            }

            func errorCaught(ctx: ChannelHandlerContext, error: Error) {
                if let ioError = error as? IOError {
                    self.promise.succeed(result: ioError)
                }
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let socket = try NonAcceptingServerSocket(errors: [error])
        let serverChannel = try assertNoThrowWithValue(ServerSocketChannel(serverSocket: socket,
                                                                           eventLoop: group.next() as! SelectableEventLoop,
                                                                           group: group))
        let promise: EventLoopPromise<IOError> = serverChannel.eventLoop.newPromise()

        XCTAssertNoThrow(try serverChannel.eventLoop.submit {
            serverChannel.pipeline.add(handler: AcceptHandler(promise)).then {
                serverChannel.register()
            }.then {
                serverChannel.bind(to: try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
            }
        }.wait().wait() as Void)

        XCTAssertEqual(active, try serverChannel.eventLoop.submit {
            serverChannel.readable()
            return serverChannel.isActive
        }.wait())

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
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!)
            .wait())

        XCTAssertNoThrow(try assertSetGetOptionOnOpenAndClosed(channel: clientChannel,
                                                               option: ChannelOptions.allowRemoteHalfClosure,
                                                               value: true))
        XCTAssertNoThrow(try assertSetGetOptionOnOpenAndClosed(channel: serverChannel,
                                                               option: ChannelOptions.backlog,
                                                               value: 100))
    }

    public func testConnect() throws {
        final class ActiveVerificationHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            private let promise: EventLoopPromise<Void>

            init(_ promise: EventLoopPromise<Void>) {
                self.promise = promise
            }

            func channelActive(ctx: ChannelHandlerContext) {
                promise.succeed(result: ())
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
                try super.init(protocolFamily: PF_INET, type: Posix.SOCK_STREAM)
            }

            override func connect(to address: SocketAddress) throws -> Bool {
                self.promise.succeed(result: ())
                return true
            }
        }

        let eventLoop = group.next()
        let connectPromise: EventLoopPromise<Void> = eventLoop.newPromise()

        let channel = try assertNoThrowWithValue(SocketChannel(socket: ConnectSocket(promise: connectPromise),
                                                               parent: nil,
                                                               eventLoop: eventLoop as! SelectableEventLoop))
        let promise: EventLoopPromise<Void> = channel.eventLoop.newPromise()

        XCTAssertNoThrow(try channel.pipeline.add(handler: ActiveVerificationHandler(promise)).then {
            channel.register()
        }.then {
            channel.connect(to: try! SocketAddress(ipAddress: "127.0.0.1", port: 9999))
        }.then {
            channel.close()
        }.wait())

        XCTAssertNoThrow(try channel.closeFuture.wait())
        XCTAssertNoThrow(try promise.futureResult.wait())
        XCTAssertNoThrow(try connectPromise.futureResult.wait())
    }

    public func testWriteServerSocketChannel() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        do {
            try serverChannel.writeAndFlush("test").wait()
            XCTFail("did not throw")
        } catch let err as ChannelError where err == .operationUnsupported {
            // expected
        }
        try serverChannel.close().wait()
    }


    public func testWriteAndFlushServerSocketChannel() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        do {
            try serverChannel.writeAndFlush("test").wait()
        } catch let err as ChannelError where err == .operationUnsupported {
            // expected
        }
        try serverChannel.close().wait()
    }


    public func testConnectServerSocketChannel() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        do {
            try serverChannel.connect(to: serverChannel.localAddress!).wait()
            XCTFail("Did not throw")
            XCTAssertNoThrow(try serverChannel.close().wait())
        } catch let err as ChannelError where err == .operationUnsupported {
            // expected, no close here as the channel is already closed.
        } catch {
            XCTFail("Unexpected error \(error)")
            XCTAssertNoThrow(try serverChannel.close().wait())
        }
    }

    public func testCloseDuringWriteFailure() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!)
            .wait())

        // Put a write in the channel but don't flush it. We're then going to
        // close the channel. This should trigger an error callback that will
        // re-close the channel, which should fail with `alreadyClosed`.
        var buffer = clientChannel.allocator.buffer(capacity: 12)
        buffer.write(staticString: "hello")
        let writeFut = clientChannel.write(buffer).map {
            XCTFail("Must not succeed")
        }.thenIfError { error in
            XCTAssertEqual(error as? ChannelError, ChannelError.alreadyClosed)
            return clientChannel.close()
        }
        XCTAssertNoThrow(try clientChannel.close().wait())

        do {
            try writeFut.wait()
            XCTFail("Did not throw")
        } catch ChannelError.alreadyClosed {
            // ok
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    public func testWithConfiguredStreamSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverSock = try Socket(protocolFamily: AF_INET, type: Posix.SOCK_STREAM)
        try serverSock.bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0))
        let serverChannelFuture = try serverSock.withUnsafeFileDescriptor {
            ServerBootstrap(group: group).withBoundSocket(descriptor: dup($0))
        }
        try serverSock.close()
        let serverChannel = try serverChannelFuture.wait()

        let clientSock = try Socket(protocolFamily: AF_INET, type: Posix.SOCK_STREAM)
        let connected = try clientSock.connect(to: serverChannel.localAddress!)
        XCTAssertEqual(connected, true)
        let clientChannelFuture = try clientSock.withUnsafeFileDescriptor {
            ClientBootstrap(group: group).withConnectedSocket(descriptor: dup($0))
        }
        try clientSock.close()
        let clientChannel = try clientChannelFuture.wait()

        XCTAssertEqual(true, clientChannel.isActive)

        try serverChannel.close().wait()
        try clientChannel.close().wait()
    }

    public func testWithConfiguredDatagramSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverSock = try Socket(protocolFamily: AF_INET, type: Posix.SOCK_DGRAM)
        try serverSock.bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0))
        let serverChannelFuture = try serverSock.withUnsafeFileDescriptor {
            DatagramBootstrap(group: group).withBoundSocket(descriptor: dup($0))
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

            public func channelInactive(ctx: ChannelHandlerContext) {
                if let connectPromise = self.connectPromise {
                    XCTAssertTrue(connectPromise.futureResult.isFulfilled)
                } else {
                    XCTFail("connect(...) not called before")
                }
            }

            public func connect(ctx: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
                XCTAssertNil(self.connectPromise)
                self.connectPromise = promise
                ctx.connect(to: address, promise: promise)
            }

            func handlerAdded(ctx: ChannelHandlerContext) {
                XCTAssertNil(self.connectPromise)
            }

            func handlerRemoved(ctx: ChannelHandlerContext) {
                if let connectPromise = self.connectPromise {
                    XCTAssertTrue(connectPromise.futureResult.isFulfilled)
                } else {
                    XCTFail("connect(...) not called before")
                }
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        defer { XCTAssertNoThrow(try serverChannel.close().wait()) }

        let eventLoop = group.next()
        let promise: EventLoopPromise<Void> = eventLoop.newPromise()

        class ConnectPendingSocket: Socket {
            let promise: EventLoopPromise<Void>
            init(promise: EventLoopPromise<Void>) throws {
                self.promise = promise
                try super.init(protocolFamily: PF_INET, type: Posix.SOCK_STREAM)
            }

            override func connect(to address: SocketAddress) throws -> Bool {
                // We want to return false here to have a pending connect.
                _ = try super.connect(to: address)
                self.promise.succeed(result: ())
                return false
            }
        }

        let channel = try SocketChannel(socket: ConnectPendingSocket(promise: promise), parent: nil, eventLoop: eventLoop as! SelectableEventLoop)
        let connectPromise: EventLoopPromise<Void> = channel.eventLoop.newPromise()
        let closePromise: EventLoopPromise<Void> = channel.eventLoop.newPromise()

        closePromise.futureResult.whenComplete {
            XCTAssertTrue(connectPromise.futureResult.isFulfilled)
        }
        connectPromise.futureResult.whenComplete {
            XCTAssertFalse(closePromise.futureResult.isFulfilled)
        }

        XCTAssertNoThrow(try channel.pipeline.add(handler: NotificationOrderHandler()).wait())

        // We need to call submit {...} here to ensure then {...} is called while on the EventLoop already to not have
        // a ECONNRESET sneak in.
        XCTAssertNoThrow(try channel.eventLoop.submit {
            channel.register().map { () -> Void in
                channel.connect(to: serverChannel.localAddress!, promise: connectPromise)
            }.map { () -> Void in
                XCTAssertFalse(connectPromise.futureResult.isFulfilled)
                // The close needs to happen in the then { ... } block to ensure we close the channel
                // before we have the chance to register it for .write.
                channel.close(promise: closePromise)
            }
        }.wait().wait() as Void)

        do {
            try connectPromise.futureResult.wait()
            XCTFail("Did not throw")
        } catch let err as ChannelError where err == .alreadyClosed {
            // expected
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

            func channelInactive(ctx: ChannelHandlerContext) {
                XCTAssertNotNil(ctx.localAddress)
                XCTAssertNotNil(ctx.remoteAddress)
                XCTAssertEqual(.created, state)
                state = .inactive
            }

            func handlerRemoved(ctx: ChannelHandlerContext) {
                XCTAssertNotNil(ctx.localAddress)
                XCTAssertNotNil(ctx.remoteAddress)
                XCTAssertEqual(.inactive, state)
                state = .removed

                ctx.channel.closeFuture.whenComplete {
                    XCTAssertNil(ctx.localAddress)
                    XCTAssertNil(ctx.remoteAddress)

                    self.promise.succeed(result: ())
                }
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let handler = AddressVerificationHandler(promise: group.next().newPromise())
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.add(handler: handler) }
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        defer { XCTAssertNoThrow(try serverChannel.close().wait()) }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!)
            .wait())

        XCTAssertNoThrow(try clientChannel.close().wait())
        XCTAssertNoThrow(try handler.promise.futureResult.wait())
    }

    func testSocketFlagNONBLOCKWorks() throws {
        var socket = try assertNoThrowWithValue(try ServerSocket(protocolFamily: PF_INET, setNonBlocking: true))
        XCTAssertNoThrow(try socket.withUnsafeFileDescriptor { fd in
            let flags = try assertNoThrowWithValue(Posix.fcntl(descriptor: fd, command: F_GETFL, value: 0))
            XCTAssertEqual(O_NONBLOCK, flags & O_NONBLOCK)
        })
        XCTAssertNoThrow(try socket.close())

        socket = try assertNoThrowWithValue(ServerSocket(protocolFamily: PF_INET, setNonBlocking: false))
        XCTAssertNoThrow(try socket.withUnsafeFileDescriptor { fd in
            var flags = try assertNoThrowWithValue(Posix.fcntl(descriptor: fd, command: F_GETFL, value: 0))
            XCTAssertEqual(0, flags & O_NONBLOCK)
            let ret = try assertNoThrowWithValue(Posix.fcntl(descriptor: fd, command: F_SETFL, value: O_NONBLOCK))
            XCTAssertEqual(0, ret)
            flags = try assertNoThrowWithValue(Posix.fcntl(descriptor: fd, command: F_GETFL, value: 0))
            XCTAssertEqual(O_NONBLOCK, flags & O_NONBLOCK)
            })
        XCTAssertNoThrow(try socket.close())
    }
}
