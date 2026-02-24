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
import Dispatch
import NIOCore
import XCTest

@testable import NIOPosix

class EchoServerClientTest: XCTestCase {
    func testEcho() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let numBytes = 16 * 1024
        let promise = group.next().makePromise(of: ByteBuffer.self)
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            ByteCountingHandler(numBytes: numBytes, promise: promise)
                        )
                    }
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!)
                .wait()
        )

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)

        for i in 0..<numBytes {
            buffer.writeInteger(UInt8(i % 256))
        }

        try clientChannel.writeAndFlush(buffer).wait()

        XCTAssertEqual(try promise.futureResult.wait(), buffer)
    }

    func testLotsOfUnflushedWrites() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(WriteALotHandler())
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let promise = group.next().makePromise(of: ByteBuffer.self)
        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sync = channel.pipeline.syncOperations
                        try sync.addHandler(WriteOnConnectHandler(toWrite: "X"))
                        try sync.addHandler(ByteCountingHandler(numBytes: 10000, promise: promise))
                    }
                }
                .connect(to: serverChannel.localAddress!).wait()
        )
        defer {
            _ = clientChannel.close()
        }

        let bytes = try promise.futureResult.wait()
        let expected = String(decoding: Array(repeating: "X".utf8.first!, count: 10000), as: Unicode.UTF8.self)
        XCTAssertEqual(expected, bytes.getString(at: bytes.readerIndex, length: bytes.readableBytes))
    }

    func testEchoUnixDomainSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        try withTemporaryUnixDomainSocketPathName { udsPath in
            let numBytes = 16 * 1024
            let promise = group.next().makePromise(of: ByteBuffer.self)
            let serverChannel = try assertNoThrowWithValue(
                ServerBootstrap(group: group)
                    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                    // Set the handlers that are appled to the accepted Channels
                    .childChannelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: promise)
                            try channel.pipeline.syncOperations.addHandler(countingHandler)
                        }
                    }.bind(unixDomainSocketPath: udsPath).wait()
            )

            defer {
                XCTAssertNoThrow(try serverChannel.close().wait())
            }

            let clientChannel = try assertNoThrowWithValue(
                ClientBootstrap(group: group)
                    .connect(to: serverChannel.localAddress!)
                    .wait()
            )

            defer {
                XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
            }

            var buffer = clientChannel.allocator.buffer(capacity: numBytes)

            for i in 0..<numBytes {
                buffer.writeInteger(UInt8(i % 256))
            }

            XCTAssertNoThrow(try clientChannel.writeAndFlush(buffer).wait())

            XCTAssertEqual(try promise.futureResult.wait(), buffer)
        }
    }

    func testConnectUnixDomainSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        try withTemporaryUnixDomainSocketPathName { udsPath in
            let numBytes = 16 * 1024
            let promise = group.next().makePromise(of: ByteBuffer.self)
            let serverChannel = try assertNoThrowWithValue(
                ServerBootstrap(group: group)
                    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)

                    // Set the handlers that are appled to the accepted Channels
                    .childChannelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: promise)
                            try channel.pipeline.syncOperations.addHandler(countingHandler)
                        }
                    }.bind(unixDomainSocketPath: udsPath).wait()
            )

            defer {
                XCTAssertNoThrow(try serverChannel.close().wait())
            }

            let clientChannel = try assertNoThrowWithValue(
                ClientBootstrap(group: group)
                    .connect(unixDomainSocketPath: udsPath)
                    .wait()
            )

            defer {
                XCTAssertNoThrow(try clientChannel.close().wait())
            }

            var buffer = clientChannel.allocator.buffer(capacity: numBytes)

            for i in 0..<numBytes {
                buffer.writeInteger(UInt8(i % 256))
            }

            try clientChannel.writeAndFlush(buffer).wait()

            XCTAssertEqual(try promise.futureResult.wait(), buffer)
        }
    }

    func testCleanupUnixDomainSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        try withTemporaryUnixDomainSocketPathName { udsPath in
            let bootstrap = ServerBootstrap(group: group)

            let serverChannel = try assertNoThrowWithValue(
                bootstrap.bind(unixDomainSocketPath: udsPath).wait()
            )

            XCTAssertNoThrow(try serverChannel.close().wait())

            let reusedPathServerChannel = try assertNoThrowWithValue(
                bootstrap.bind(
                    unixDomainSocketPath: udsPath,
                    cleanupExistingSocketFile: true
                ).wait()
            )

            XCTAssertNoThrow(try reusedPathServerChannel.close().wait())
        }
    }

    func testBootstrapUnixDomainSocketNameClash() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        try withTemporaryUnixDomainSocketPathName { udsPath in
            // Bootstrap should not overwrite an existing file unless it is a socket
            _ = FileManager.default.createFile(atPath: udsPath, contents: nil, attributes: nil)
            let bootstrap = ServerBootstrap(group: group)

            XCTAssertThrowsError(
                try bootstrap.bind(unixDomainSocketPath: udsPath).wait()
            )
        }
    }

    func testEchoVsock() throws {
        try XCTSkipUnless(System.supportsVsockLoopback, "No vsock loopback transport available")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let numBytes = 16 * 1024
        let port = VsockAddress.Port(1234)
        let promise = group.next().makePromise(of: ByteBuffer.self)
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: promise)
                        try channel.pipeline.syncOperations.addHandler(countingHandler)
                    }
                }
                .bind(to: VsockAddress(cid: .any, port: port))
        )
        .wait()

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        #if canImport(Darwin)
        let connectAddress = VsockAddress(cid: .any, port: port)
        #elseif os(Linux) || os(Android)
        let connectAddress = VsockAddress(cid: .local, port: port)
        #endif
        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group).connect(to: connectAddress).wait())

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)

        for i in 0..<numBytes {
            buffer.writeInteger(UInt8(i % 256))
        }

        try clientChannel.writeAndFlush(buffer).wait()

        XCTAssertEqual(try promise.futureResult.wait(), buffer)
    }

    func testChannelActiveOnConnect() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let promise = group.next().makePromise(of: Void.self)
        let handler = ChannelActiveHandler(promise: promise)
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { $0.pipeline.addHandler(handler) }
                .connect(to: serverChannel.localAddress!).wait()
        )

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        XCTAssertNoThrow(try handler.assertChannelActiveFired())
    }

    func testWriteThenRead() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(EchoServer())
                    }
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let numBytes = 16 * 1024
        let promise = group.next().makePromise(of: ByteBuffer.self)
        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: promise)
                        try channel.pipeline.syncOperations.addHandler(countingHandler)
                    }
                }
                .connect(to: serverChannel.localAddress!).wait()
        )

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)
        for i in 0..<numBytes {
            buffer.writeInteger(UInt8(i % 256))
        }
        XCTAssertNoThrow(try clientChannel.writeAndFlush(buffer).wait())

        XCTAssertEqual(try promise.futureResult.wait(), buffer)
    }

    private final class ChannelActiveHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer

        private let promise: EventLoopPromise<Void>

        init(promise: EventLoopPromise<Void>) {
            self.promise = promise
        }

        func channelActive(context: ChannelHandlerContext) {
            promise.succeed(())
            context.fireChannelActive()
        }

        func assertChannelActiveFired() throws {
            try promise.futureResult.wait()
        }
    }

    private final class EchoServer: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.write(data, promise: nil)
        }

        func channelReadComplete(context: ChannelHandlerContext) {
            context.flush()
        }
    }

    private final class EchoAndEchoAgainAfterSomeTimeServer: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let timeAmount: TimeAmount
        private let group = DispatchGroup()
        private var numberOfReads: Int = 0
        private let calloutQ = DispatchQueue(label: "EchoAndEchoAgainAfterSomeTimeServer callback queue")

        public init(time: TimeAmount, secondWriteDoneHandler: @escaping () -> Void) {
            self.timeAmount = time
            self.group.enter()
            self.group.notify(queue: self.calloutQ) {
                secondWriteDoneHandler()
            }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let bytes = Self.unwrapInboundIn(data)
            self.numberOfReads += 1
            precondition(self.numberOfReads == 1, "\(self) is only ever allowed to read once")
            let loopBoundContext = context.loopBound
            _ = context.eventLoop.scheduleTask(in: self.timeAmount) { [group] in
                let context = loopBoundContext.value
                context.writeAndFlush(Self.wrapInboundOut(bytes), promise: nil)
                group.leave()
            }.futureResult.recover { [group] e in
                XCTFail("we failed to schedule the task: \(e)")
                group.leave()
            }
            context.writeAndFlush(data, promise: nil)
        }
    }

    private final class WriteALotHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            for _ in 0..<10000 {
                context.write(data, promise: nil)
            }
        }

        func channelReadComplete(context: ChannelHandlerContext) {
            context.flush()
        }
    }

    private final class CloseInInActiveAndUnregisteredChannelHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = Never
        let alreadyClosedInChannelInactive = ManagedAtomic(false)
        let alreadyClosedInChannelUnregistered = ManagedAtomic(false)
        let channelUnregisteredPromise: EventLoopPromise<Void>
        let channelInactivePromise: EventLoopPromise<Void>

        public init(
            channelUnregisteredPromise: EventLoopPromise<Void>,
            channelInactivePromise: EventLoopPromise<Void>
        ) {
            self.channelUnregisteredPromise = channelUnregisteredPromise
            self.channelInactivePromise = channelInactivePromise
        }

        public func channelActive(context: ChannelHandlerContext) {
            context.close().whenFailure { error in
                XCTFail("bad, initial close failed (\(error))")
            }
        }

        public func channelInactive(context: ChannelHandlerContext) {
            if alreadyClosedInChannelInactive.compareExchange(expected: false, desired: true, ordering: .relaxed)
                .exchanged
            {
                XCTAssertFalse(
                    self.channelUnregisteredPromise.futureResult.isFulfilled,
                    "channelInactive should fire before channelUnregistered"
                )
                context.close().map {
                    XCTFail("unexpected success")
                }.recover { err in
                    switch err {
                    case ChannelError.alreadyClosed:
                        // OK
                        ()
                    default:
                        XCTFail("unexpected error: \(err)")
                    }
                }.whenComplete { [channelInactivePromise] (_: Result<Void, Error>) in
                    channelInactivePromise.succeed(())
                }
            }
        }

        public func channelUnregistered(context: ChannelHandlerContext) {
            if alreadyClosedInChannelUnregistered.compareExchange(expected: false, desired: true, ordering: .relaxed)
                .exchanged
            {
                XCTAssertTrue(
                    self.channelInactivePromise.futureResult.isFulfilled,
                    "when channelUnregister fires, channelInactive should already have fired"
                )
                context.close().map {
                    XCTFail("unexpected success")
                }.recover { err in
                    switch err {
                    case ChannelError.alreadyClosed:
                        // OK
                        ()
                    default:
                        XCTFail("unexpected error: \(err)")
                    }
                }.whenComplete { [channelUnregisteredPromise] (_: Result<Void, Error>) in
                    channelUnregisteredPromise.succeed(())
                }
            }
        }
    }

    /// A channel handler that calls write on connect.
    private final class WriteOnConnectHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer

        private let toWrite: String

        init(toWrite: String) {
            self.toWrite = toWrite
        }

        func channelActive(context: ChannelHandlerContext) {
            let dataToWrite = context.channel.allocator.buffer(string: toWrite)
            context.writeAndFlush(NIOAny(dataToWrite), promise: nil)
            context.fireChannelActive()
        }
    }

    func testCloseInInactive() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let inactivePromise = group.next().makePromise() as EventLoopPromise<Void>
        let unregistredPromise = group.next().makePromise() as EventLoopPromise<Void>
        let handler = CloseInInActiveAndUnregisteredChannelHandler(
            channelUnregisteredPromise: unregistredPromise,
            channelInactivePromise: inactivePromise
        )

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)

                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(handler)
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!)
                .wait()
        )

        defer {
            _ = clientChannel.close()
        }

        _ = try inactivePromise.futureResult.and(unregistredPromise.futureResult).wait()

        XCTAssertTrue(handler.alreadyClosedInChannelInactive.load(ordering: .relaxed))
        XCTAssertTrue(handler.alreadyClosedInChannelUnregistered.load(ordering: .relaxed))
    }

    func testFlushOnEmpty() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let writingBytes = "hello"
        let bytesReceivedPromise = group.next().makePromise(of: ByteBuffer.self)
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    // When we've received all the bytes we know the connection is up. Remove the handler.
                    channel.eventLoop.makeCompletedFuture {
                        let byteCountingHandler = ByteCountingHandler(
                            numBytes: writingBytes.utf8.count,
                            promise: bytesReceivedPromise
                        )

                        _ = bytesReceivedPromise.futureResult.hop(
                            to: channel.eventLoop
                        ).assumeIsolated().flatMapThrowing { (_: ByteBuffer) in
                            channel.pipeline.syncOperations.removeHandler(byteCountingHandler)
                        }

                        try channel.pipeline.syncOperations.addHandler(byteCountingHandler)
                    }

                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!)
                .wait()
        )
        defer {
            _ = clientChannel.close()
        }

        // First we confirm that the channel really is up by sending in the appropriate number of bytes.
        let bytesToWrite = clientChannel.allocator.buffer(string: writingBytes)
        let lastWriteFuture = clientChannel.writeAndFlush(bytesToWrite)

        // When we've received all the bytes we know the connection is up.
        _ = try bytesReceivedPromise.futureResult.wait()

        // Now, with an empty write pipeline, we want to flush. This should complete immediately and without error.
        clientChannel.flush()
        lastWriteFuture.whenFailure { err in
            XCTFail("\(err)")
        }
        try lastWriteFuture.wait()
    }

    func testWriteOnConnect() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(EchoServer())
                    }
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let stringToWrite = "hello"
        let promise = group.next().makePromise(of: ByteBuffer.self)
        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sync = channel.pipeline.syncOperations
                        try sync.addHandler(WriteOnConnectHandler(toWrite: stringToWrite))
                        try sync.addHandler(ByteCountingHandler(numBytes: stringToWrite.utf8.count, promise: promise))
                    }
                }
                .connect(to: serverChannel.localAddress!).wait()
        )
        defer {
            _ = clientChannel.close()
        }

        let bytes = try promise.futureResult.wait()
        XCTAssertEqual(bytes.getString(at: bytes.readerIndex, length: bytes.readableBytes), stringToWrite)
    }

    func testWriteOnAccept() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let stringToWrite = "hello"
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(WriteOnConnectHandler(toWrite: stringToWrite))
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let promise = group.next().makePromise(of: ByteBuffer.self)
        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            ByteCountingHandler(numBytes: stringToWrite.utf8.count, promise: promise)
                        )
                    }
                }
                .connect(to: serverChannel.localAddress!).wait()
        )

        defer {
            XCTAssertNoThrow(try clientChannel.close().wait())
        }

        let bytes = try assertNoThrowWithValue(promise.futureResult.wait())
        XCTAssertEqual(bytes.getString(at: bytes.readerIndex, length: bytes.readableBytes), stringToWrite)
    }

    func testWriteAfterChannelIsDead() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let dpGroup = DispatchGroup()

        dpGroup.enter()
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            EchoAndEchoAgainAfterSomeTimeServer(
                                time: .seconds(1),
                                secondWriteDoneHandler: {
                                    dpGroup.leave()
                                }
                            )
                        )
                    }
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let str = "hi there"
        let promise = group.next().makePromise(of: ByteBuffer.self)
        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            ByteCountingHandler(numBytes: str.utf8.count, promise: promise)
                        )
                    }
                }
                .connect(to: serverChannel.localAddress!).wait()
        )

        let buffer = clientChannel.allocator.buffer(string: str)
        try clientChannel.writeAndFlush(buffer).wait()

        XCTAssertEqual(try promise.futureResult.wait(), buffer)

        // close the client channel so that the second write should fail
        try clientChannel.close().wait()

        dpGroup.wait()  // make sure we stick around until the second write has happened
    }

    func testPendingReadProcessedAfterWriteError() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let loop1 = group.next()
        let loop2 = group.next()
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let dpGroup = DispatchGroup()
        dpGroup.enter()

        let str = "hi there"

        class WriteHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private var writeFailed = false

            func channelActive(context: ChannelHandlerContext) {
                var buffer = context.channel.allocator.buffer(capacity: 4)
                buffer.writeString("test")
                Self.writeUntilFailed(context, buffer)
            }

            private static func writeUntilFailed(_ context: ChannelHandlerContext, _ buffer: ByteBuffer) {
                let loopBoundContext = context.loopBound
                context.writeAndFlush(NIOAny(buffer)).whenSuccess { [eventLoop = context.eventLoop] in
                    eventLoop.assumeIsolated().execute {
                        let context = loopBoundContext.value
                        Self.writeUntilFailed(context, buffer)
                    }
                }
            }
        }

        class WriteWhenActiveHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            let str: String
            let dpGroup: DispatchGroup

            init(_ str: String, _ dpGroup: DispatchGroup) {
                self.str = str
                self.dpGroup = dpGroup
            }

            func channelActive(context: ChannelHandlerContext) {
                context.fireChannelActive()
                let buffer = context.channel.allocator.buffer(string: str)

                // write it four times and then close the connect.
                let loopBoundContext = context.loopBound
                context.writeAndFlush(NIOAny(buffer)).flatMap {
                    let context = loopBoundContext.value
                    return context.writeAndFlush(NIOAny(buffer))
                }.flatMap {
                    let context = loopBoundContext.value
                    return context.writeAndFlush(NIOAny(buffer))
                }.flatMap {
                    let context = loopBoundContext.value
                    return context.writeAndFlush(NIOAny(buffer))
                }.flatMap {
                    let context = loopBoundContext.value
                    return context.close()
                }.assumeIsolated().whenComplete { (_: Result<Void, Error>) in
                    self.dpGroup.leave()
                }
            }
        }
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: loop1)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(WriteWhenActiveHandler(str, dpGroup))
                    }
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let promise = group.next().makePromise(of: ByteBuffer.self)
        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: loop2)
                // We will only start reading once we wrote all data on the accepted channel.
                //.channelOption(.autoRead, value: false)
                .channelOption(.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 2))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(WriteHandler())
                    }.flatMapThrowing {
                        try channel.pipeline.syncOperations.addHandler(
                            ByteCountingHandler(numBytes: str.utf8.count * 4, promise: promise)
                        )
                    }
                }.connect(to: serverChannel.localAddress!).wait()
        )
        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }
        dpGroup.wait()

        var completeBuffer = clientChannel.allocator.buffer(capacity: str.utf8.count * 4)
        completeBuffer.writeString(str)
        completeBuffer.writeString(str)
        completeBuffer.writeString(str)
        completeBuffer.writeString(str)

        XCTAssertEqual(try promise.futureResult.wait(), completeBuffer)
    }

    func testChannelErrorEOFNotFiredThroughPipeline() throws {

        class ErrorHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private let promise: EventLoopPromise<Void>

            init(_ promise: EventLoopPromise<Void>) {
                self.promise = promise
            }

            public func errorCaught(context: ChannelHandlerContext, error: Error) {
                if let err = error as? ChannelError {
                    XCTAssertNotEqual(ChannelError.eof, err)
                }
            }

            public func channelInactive(context: ChannelHandlerContext) {
                self.promise.succeed(())
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let promise = group.next().makePromise(of: Void.self)

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ErrorHandler(promise))
                    }
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!).wait()
        )
        XCTAssertNoThrow(try clientChannel.close().wait())

        XCTAssertNoThrow(try promise.futureResult.wait())
    }

    func testPortNumbers() throws {
        var atLeastOneSucceeded = false
        for host in ["127.0.0.1", "::1"] {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer {
                XCTAssertNoThrow(try group.syncShutdownGracefully())
            }
            let acceptedRemotePort = ManagedAtomic<Int>(-1)
            let acceptedLocalPort = ManagedAtomic<Int>(-2)
            let sem = DispatchSemaphore(value: 0)

            let serverChannel: Channel
            do {
                serverChannel = try ServerBootstrap(group: group)
                    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { channel in
                        acceptedRemotePort.store(channel.remoteAddress?.port ?? -3, ordering: .relaxed)
                        acceptedLocalPort.store(channel.localAddress?.port ?? -4, ordering: .relaxed)
                        sem.signal()
                        return channel.eventLoop.makeSucceededFuture(())
                    }.bind(host: host, port: 0).wait()
            } catch let e as SocketAddressError {
                if case .unknown(host, port: 0) = e {
                    // this can happen if the system isn't configured for both IPv4 and IPv6
                    continue
                } else {
                    // nope, that's a different socket error
                    XCTFail("unexpected SocketAddressError: \(e)")
                    break
                }
            } catch {
                // other unknown error
                XCTFail("unexpected error: \(error)")
                break
            }
            atLeastOneSucceeded = true
            defer {
                XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
            }

            let clientChannel = try assertNoThrowWithValue(
                ClientBootstrap(group: group).connect(
                    host: host,
                    port: Int(serverChannel.localAddress!.port!)
                ).wait()
            )
            defer {
                XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
            }
            sem.wait()
            XCTAssertEqual(serverChannel.localAddress?.port, clientChannel.remoteAddress?.port)
            XCTAssertEqual(acceptedLocalPort.load(ordering: .relaxed), clientChannel.remoteAddress?.port ?? -5)
            XCTAssertEqual(acceptedRemotePort.load(ordering: .relaxed), clientChannel.localAddress?.port ?? -6)
        }
        XCTAssertTrue(atLeastOneSucceeded)
    }

    func testConnectingToIPv4And6ButServerOnlyWaitsOnIPv4() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let numBytes = 16 * 1024
        let promise = group.next().makePromise(of: ByteBuffer.self)

        // we're binding to IPv4 only
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: promise)
                        try channel.pipeline.syncOperations.addHandler(countingHandler)
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        // but we're trying to connect to (depending on the system configuration and resolver) IPv4 and IPv6
        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(host: "localhost", port: Int(serverChannel.localAddress!.port!))
                .flatMapError {
                    promise.fail($0)
                    return group.next().makeFailedFuture($0)
                }
                .wait()
        )

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)

        for i in 0..<numBytes {
            buffer.writeInteger(UInt8(i % 256))
        }

        try clientChannel.writeAndFlush(buffer).wait()

        XCTAssertEqual(try promise.futureResult.wait(), buffer)
    }
}
