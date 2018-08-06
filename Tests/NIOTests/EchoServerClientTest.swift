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
import NIOConcurrencyHelpers
import Dispatch
@testable import NIO

class EchoServerClientTest : XCTestCase {
    func testEcho() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let numBytes = 16 * 1024
        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: group.next().newPromise())
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            .childChannelInitializer { channel in
                channel.pipeline.add(handler: countingHandler)
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!)
            .wait())

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)

        for i in 0..<numBytes {
            buffer.write(integer: UInt8(i % 256))
        }

        try clientChannel.writeAndFlush(NIOAny(buffer)).wait()

        try countingHandler.assertReceived(buffer: buffer)
    }

    func testLotsOfUnflushedWrites() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: WriteALotHandler())
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let promise: EventLoopPromise<ByteBuffer> = group.next().newPromise()
        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.add(handler: WriteOnConnectHandler(toWrite: "X")).then { v2 in
                    channel.pipeline.add(handler: ByteCountingHandler(numBytes: 10000, promise: promise))
                }
            }
            .connect(to: serverChannel.localAddress!).wait())
        defer {
            _ = clientChannel.close()
        }

        let bytes = try promise.futureResult.wait()
        let expected = String(decoding: Array(repeating: "X".utf8.first!, count: 10000), as: UTF8.self)
        XCTAssertEqual(expected, bytes.getString(at: bytes.readerIndex, length: bytes.readableBytes))
    }

    func testEchoUnixDomainSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let udsTempDir = createTemporaryDirectory()
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(atPath: udsTempDir))
        }

        let numBytes = 16 * 1024
        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: group.next().newPromise())
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are appled to the accepted Channels
            .childChannelInitializer { channel in
                // Ensure we don't read faster then we can write by adding the BackPressureHandler into the pipeline.
                channel.pipeline.add(handler: countingHandler)
            }.bind(unixDomainSocketPath: udsTempDir + "/server.sock").wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!)
            .wait())

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)

        for i in 0..<numBytes {
            buffer.write(integer: UInt8(i % 256))
        }

        XCTAssertNoThrow(try clientChannel.writeAndFlush(NIOAny(buffer)).wait())

        XCTAssertNoThrow(try countingHandler.assertReceived(buffer: buffer))
    }

    func testConnectUnixDomainSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let udsTempDir = createTemporaryDirectory()
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(atPath: udsTempDir))
        }

        let numBytes = 16 * 1024
        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: group.next().newPromise())
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are appled to the accepted Channels
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: countingHandler)
            }.bind(unixDomainSocketPath: udsTempDir + "/server.sock").wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(unixDomainSocketPath: udsTempDir + "/server.sock")
            .wait())

        defer {
            XCTAssertNoThrow(try clientChannel.close().wait())
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)

        for i in 0..<numBytes {
            buffer.write(integer: UInt8(i % 256))
        }

        try clientChannel.writeAndFlush(NIOAny(buffer)).wait()

        try countingHandler.assertReceived(buffer: buffer)
    }

    func testChannelActiveOnConnect() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let handler = ChannelActiveHandler()
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.add(handler: handler) }
            .connect(to: serverChannel.localAddress!).wait())

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

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: EchoServer())
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let numBytes = 16 * 1024
        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: group.next().newPromise())
        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.add(handler: countingHandler) }
            .connect(to: serverChannel.localAddress!).wait())

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)
        for i in 0..<numBytes {
            buffer.write(integer: UInt8(i % 256))
        }
        XCTAssertNoThrow(try clientChannel.writeAndFlush(NIOAny(buffer)).wait())

        XCTAssertNoThrow(try countingHandler.assertReceived(buffer: buffer))
    }

    private final class ChannelActiveHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer

        private var promise: EventLoopPromise<Void>! = nil

        func handlerAdded(ctx: ChannelHandlerContext) {
            promise = ctx.channel.eventLoop.newPromise()
        }

        func channelActive(ctx: ChannelHandlerContext) {
            promise.succeed(result: ())
            ctx.fireChannelActive()
        }

        func assertChannelActiveFired() throws {
            try promise.futureResult.wait()
        }
    }

    private final class EchoServer: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
            ctx.write(data, promise: nil)
        }

        func channelReadComplete(ctx: ChannelHandlerContext) {
            ctx.flush()
        }
    }

    private final class EchoAndEchoAgainAfterSomeTimeServer: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
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

        func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
            self.numberOfReads += 1
            precondition(self.numberOfReads == 1, "\(self) is only ever allowed to read once")
            _ = ctx.eventLoop.scheduleTask(in: self.timeAmount) {
                ctx.writeAndFlush(data, promise: nil)
                self.group.leave()
            }.futureResult.mapIfError { e in
                XCTFail("we failed to schedule the task: \(e)")
                self.group.leave()
            }
            ctx.writeAndFlush(data, promise: nil)
        }
    }

    private final class WriteALotHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
            for _ in 0..<10000 {
                ctx.write(data, promise: nil)
            }
        }

        func channelReadComplete(ctx: ChannelHandlerContext) {
            ctx.flush()
        }
    }

    private final class CloseInInActiveAndUnregisteredChannelHandler: ChannelInboundHandler {
        typealias InboundIn = Never
        let alreadyClosedInChannelInactive = Atomic<Bool>(value: false)
        let alreadyClosedInChannelUnregistered = Atomic<Bool>(value: false)
        let channelUnregisteredPromise: EventLoopPromise<Void>
        let channelInactivePromise: EventLoopPromise<Void>

        public init(channelUnregisteredPromise: EventLoopPromise<Void>,
                    channelInactivePromise: EventLoopPromise<Void>) {
            self.channelUnregisteredPromise = channelUnregisteredPromise
            self.channelInactivePromise = channelInactivePromise
        }

        public func channelActive(ctx: ChannelHandlerContext) {
            ctx.close().whenFailure { error in
                XCTFail("bad, initial close failed (\(error))")
            }
        }

        public func channelInactive(ctx: ChannelHandlerContext) {
            if alreadyClosedInChannelInactive.compareAndExchange(expected: false, desired: true) {
                XCTAssertFalse(self.channelUnregisteredPromise.futureResult.isFulfilled,
                               "channelInactive should fire before channelUnregistered")
                ctx.close().map {
                    XCTFail("unexpected success")
                }.mapIfError { err in
                    switch err {
                    case ChannelError.alreadyClosed:
                        // OK
                        ()
                    default:
                        XCTFail("unexpected error: \(err)")
                    }
                }.whenComplete {
                    self.channelInactivePromise.succeed(result: ())
                }
            }
        }

        public func channelUnregistered(ctx: ChannelHandlerContext) {
            if alreadyClosedInChannelUnregistered.compareAndExchange(expected: false, desired: true) {
                XCTAssertTrue(self.channelInactivePromise.futureResult.isFulfilled,
                              "when channelUnregister fires, channelInactive should already have fired")
                ctx.close().map {
                    XCTFail("unexpected success")
                }.mapIfError { err in
                    switch err {
                    case ChannelError.alreadyClosed:
                        // OK
                        ()
                    default:
                        XCTFail("unexpected error: \(err)")
                    }
                }.whenComplete {
                    self.channelUnregisteredPromise.succeed(result: ())
                }
            }
        }
    }

    /// A channel handler that calls write on connect.
    private class WriteOnConnectHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer

        private let toWrite: String

        init(toWrite: String) {
            self.toWrite = toWrite
        }

        func channelActive(ctx: ChannelHandlerContext) {
            var dataToWrite = ctx.channel.allocator.buffer(capacity: toWrite.utf8.count)
            dataToWrite.write(string: toWrite)
            ctx.writeAndFlush(NIOAny(dataToWrite), promise: nil)
            ctx.fireChannelActive()
        }
    }

    func testCloseInInactive() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer {
                XCTAssertNoThrow(try group.syncShutdownGracefully())
            }

        let inactivePromise = group.next().newPromise() as EventLoopPromise<Void>
        let unregistredPromise = group.next().newPromise() as EventLoopPromise<Void>
        let handler = CloseInInActiveAndUnregisteredChannelHandler(channelUnregisteredPromise: unregistredPromise,
                                                                   channelInactivePromise: inactivePromise)

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            .childChannelInitializer { channel in
                channel.pipeline.add(handler: handler)
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!)
            .wait())

        defer {
            _ = clientChannel.close()
        }

        _ = try inactivePromise.futureResult.and(unregistredPromise.futureResult).wait()

        XCTAssertTrue(handler.alreadyClosedInChannelInactive.load())
        XCTAssertTrue(handler.alreadyClosedInChannelUnregistered.load())
    }

    func testFlushOnEmpty() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let writingBytes = "hello"
        let bytesReceivedPromise: EventLoopPromise<ByteBuffer> = group.next().newPromise()
        let byteCountingHandler = ByteCountingHandler(numBytes: writingBytes.utf8.count, promise: bytesReceivedPromise)
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                // When we've received all the bytes we know the connection is up. Remove the handler.
                _ = bytesReceivedPromise.futureResult.then { (_: ByteBuffer) in
                    channel.pipeline.remove(handler: byteCountingHandler)
                }

                return channel.pipeline.add(handler: byteCountingHandler)
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!)
            .wait())
        defer {
            _ = clientChannel.close()
        }

        // First we confirm that the channel really is up by sending in the appropriate number of bytes.
        var bytesToWrite = clientChannel.allocator.buffer(capacity: writingBytes.utf8.count)
        bytesToWrite.write(string: writingBytes)
        let lastWriteFuture = clientChannel.writeAndFlush(NIOAny(bytesToWrite))

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

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: EchoServer())
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let stringToWrite = "hello"
        let promise: EventLoopPromise<ByteBuffer> = group.next().newPromise()
        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.add(handler: WriteOnConnectHandler(toWrite: stringToWrite)).then {
                    channel.pipeline.add(handler: ByteCountingHandler(numBytes: stringToWrite.utf8.count, promise: promise))
                }
            }
            .connect(to: serverChannel.localAddress!).wait())
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
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: WriteOnConnectHandler(toWrite: stringToWrite))
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let promise: EventLoopPromise<ByteBuffer> = group.next().newPromise()
        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.add(handler: ByteCountingHandler(numBytes: stringToWrite.utf8.count, promise: promise))
            }
            .connect(to: serverChannel.localAddress!).wait())

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
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: EchoAndEchoAgainAfterSomeTimeServer(time: .seconds(1), secondWriteDoneHandler: {
                    dpGroup.leave()
                }))
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let str = "hi there"
        let countingHandler = ByteCountingHandler(numBytes: str.utf8.count, promise: group.next().newPromise())
        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.add(handler: countingHandler) }
            .connect(to: serverChannel.localAddress!).wait())

        var buffer = clientChannel.allocator.buffer(capacity: str.utf8.count)
        buffer.write(string: str)
        try clientChannel.writeAndFlush(NIOAny(buffer)).wait()

        try countingHandler.assertReceived(buffer: buffer)

        /* close the client channel so that the second write should fail */
        try clientChannel.close().wait()

        dpGroup.wait() /* make sure we stick around until the second write has happened */
    }

    func testPendingReadProcessedAfterWriteError() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let dpGroup = DispatchGroup()

        dpGroup.enter()

        let str = "hi there"

        let countingHandler = ByteCountingHandler(numBytes: str.utf8.count * 4, promise: group.next().newPromise())

        class WriteHandler : ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private var writeFailed = false

            func channelActive(ctx: ChannelHandlerContext) {
                var buffer = ctx.channel.allocator.buffer(capacity: 4)
                buffer.write(string: "test")
                writeUntilFailed(ctx, buffer)
            }

            private func writeUntilFailed(_ ctx: ChannelHandlerContext, _ buffer: ByteBuffer) {
                ctx.writeAndFlush(NIOAny(buffer)).whenComplete {
                    ctx.eventLoop.execute {
                        self.writeUntilFailed(ctx, buffer)
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

            func channelActive(ctx: ChannelHandlerContext) {
                ctx.fireChannelActive()
                var buffer = ctx.channel.allocator.buffer(capacity: str.utf8.count)
                buffer.write(string: str)

                // write it four times and then close the connect.
                ctx.writeAndFlush(NIOAny(buffer)).then {
                    ctx.writeAndFlush(NIOAny(buffer))
                }.then {
                    ctx.writeAndFlush(NIOAny(buffer))
                }.then {
                    ctx.writeAndFlush(NIOAny(buffer))
                }.then {
                    ctx.close()
                }.whenComplete {
                    self.dpGroup.leave()
                }
            }
        }
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: WriteWhenActiveHandler(str, dpGroup))
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            // We will only start reading once we wrote all data on the accepted channel.
            //.channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 2))
            .channelInitializer { channel in
                channel.pipeline.add(handler: WriteHandler()).then {
                    channel.pipeline.add(handler: countingHandler)
                }
            }.connect(to: serverChannel.localAddress!).wait())
        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }
        dpGroup.wait()

        var completeBuffer = clientChannel.allocator.buffer(capacity: str.utf8.count * 4)
        completeBuffer.write(string: str)
        completeBuffer.write(string: str)
        completeBuffer.write(string: str)
        completeBuffer.write(string: str)

        try countingHandler.assertReceived(buffer: completeBuffer)

        XCTAssertNoThrow(try group.syncShutdownGracefully())
    }

    func testChannelErrorEOFNotFiredThroughPipeline() throws {

        class ErrorHandler : ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private let promise: EventLoopPromise<Void>

            init(_ promise: EventLoopPromise<Void>) {
                self.promise = promise
            }

            public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
                if let err = error as? ChannelError {
                    XCTAssertNotEqual(ChannelError.eof, err)
                }
            }

            public func channelInactive(ctx: ChannelHandlerContext) {
                self.promise.succeed(result: ())
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let promise: EventLoopPromise<Void> = group.next().newPromise()

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: ErrorHandler(promise))
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait())
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
            let acceptedRemotePort: Atomic<Int> = Atomic(value: -1)
            let acceptedLocalPort: Atomic<Int> = Atomic(value: -2)
            let sem = DispatchSemaphore(value: 0)

            let serverChannel: Channel
            do {
                serverChannel = try ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                    .childChannelInitializer { channel in
                        acceptedRemotePort.store(channel.remoteAddress?.port.map(Int.init) ?? -3)
                        acceptedLocalPort.store(channel.localAddress?.port.map(Int.init) ?? -4)
                        sem.signal()
                        return channel.eventLoop.newSucceededFuture(result: ())
                    }.bind(host: host, port: 0).wait()
            } catch let e as SocketAddressError {
                if case .unknown(host, port: 0) = e {
                    /* this can happen if the system isn't configured for both IPv4 and IPv6 */
                    continue
                } else {
                    /* nope, that's a different socket error */
                    XCTFail("unexpected SocketAddressError: \(e)")
                    break
                }
            } catch {
                /* other unknown error */
                XCTFail("unexpected error: \(error)")
                break
            }
            atLeastOneSucceeded = true
            defer {
                XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
            }

            let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group).connect(host: host,
                                                                                                 port: Int(serverChannel.localAddress!.port!)).wait())
            defer {
                XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
            }
            sem.wait()
            XCTAssertEqual(serverChannel.localAddress?.port, clientChannel.remoteAddress?.port)
            XCTAssertEqual(acceptedLocalPort.load(), clientChannel.remoteAddress?.port.map(Int.init) ?? -5)
            XCTAssertEqual(acceptedRemotePort.load(), clientChannel.localAddress?.port.map(Int.init) ?? -6)
        }
        XCTAssertTrue(atLeastOneSucceeded)
    }

    func testConnectingToIPv4And6ButServerOnlyWaitsOnIPv4() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let numBytes = 16 * 1024
        let promise: EventLoopPromise<ByteBuffer> = group.next().newPromise()
        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: promise)

        // we're binding to IPv4 only
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: countingHandler)
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait())

        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        // but we're trying to connect to (depending on the system configuration and resolver) IPv4 and IPv6
        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(host: "localhost", port: Int(serverChannel.localAddress!.port!))
            .thenIfError {
                promise.fail(error: $0)
                return group.next().newFailedFuture(error: $0)
            }
            .wait())

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)

        for i in 0..<numBytes {
            buffer.write(integer: UInt8(i % 256))
        }

        try clientChannel.writeAndFlush(NIOAny(buffer)).wait()

        try countingHandler.assertReceived(buffer: buffer)
    }
}
