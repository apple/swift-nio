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

    func buildTempDir() -> String {
        let template = "/tmp/.NIOTests-UDS-container-dir_XXXXXX"
        var templateBytes = template.utf8 + [0]
        let templateBytesCount = templateBytes.count
        templateBytes.withUnsafeMutableBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: Int8.self, capacity: templateBytesCount) { (ptr: UnsafeMutablePointer<Int8>) in
                let ret = mkdtemp(ptr)
                XCTAssertNotNil(ret)
            }
        }
        templateBytes.removeLast()
        let udsTempDir = String(decoding: templateBytes, as: UTF8.self)
        return udsTempDir
    }
    
    func testEcho() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let numBytes = 16 * 1024
        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: group.next().newPromise())
        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            
            // Set the handlers that are appled to the accepted Channels
            .childChannelInitializer { channel in
                // Ensure we don't read faster then we can write by adding the BackPressureHandler into the pipeline.
                return channel.pipeline.add(handler: countingHandler)
            }.bind(to: "127.0.0.1", on: 0).wait()

        defer {
            _ = serverChannel.close()
        }

        let clientChannel = try ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait()

        defer {
            _ = clientChannel.close()
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)

        for i in 0..<numBytes {
            buffer.write(integer: UInt8(i % 256))
        }

        try clientChannel.writeAndFlush(data: NIOAny(buffer)).wait()

        try countingHandler.assertReceived(buffer: buffer)
    }
    
    func testLotsOfUnflushedWrites() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                return channel.pipeline.add(handler: WriteALotHandler())
            }.bind(to: "127.0.0.1", on: 0).wait()

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let promise: EventLoopPromise<ByteBuffer> = group.next().newPromise()
        let clientChannel = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                return channel.pipeline.add(handler: WriteOnConnectHandler(toWrite: "X")).then { v2 in
                    return channel.pipeline.add(handler: ByteCountingHandler(numBytes: 10000, promise: promise))
                }
            }
            .connect(to: serverChannel.localAddress!).wait()
        defer {
            _ = clientChannel.close()
        }

        let bytes = try promise.futureResult.wait()
        let expected = String(decoding: Array(repeating: "X".utf8.first!, count: 10000), as: UTF8.self)
        XCTAssertEqual(expected, bytes.getString(at: bytes.readerIndex, length: bytes.readableBytes))
    }

    func testEchoUnixDomainSocket() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let udsTempDir = buildTempDir()
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(atPath: udsTempDir))
        }

        let numBytes = 16 * 1024
        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: group.next().newPromise())
        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are appled to the accepted Channels
            .childChannelInitializer { channel in
                // Ensure we don't read faster then we can write by adding the BackPressureHandler into the pipeline.
                return channel.pipeline.add(handler: countingHandler)
            }.bind(to: udsTempDir + "/server.sock").wait()

        defer {
            _ = serverChannel.close()
        }

        let clientChannel = try ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait()

        defer {
            _ = clientChannel.close()
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)

        for i in 0..<numBytes {
            buffer.write(integer: UInt8(i % 256))
        }

        try clientChannel.writeAndFlush(data: NIOAny(buffer)).wait()

        try countingHandler.assertReceived(buffer: buffer)
    }

    func testConnectUnixDomainSocket() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let udsTempDir = buildTempDir()
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(atPath: udsTempDir))
        }

        let numBytes = 16 * 1024
        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: group.next().newPromise())
        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are appled to the accepted Channels
            .childChannelInitializer { channel in
                // Ensure we don't read faster then we can write by adding the BackPressureHandler into the pipeline.
                return channel.pipeline.add(handler: countingHandler)
            }.bind(to: udsTempDir + "/server.sock").wait()

        defer {
            _ = serverChannel.close()
        }

        let clientChannel = try ClientBootstrap(group: group).connect(to: udsTempDir + "/server.sock").wait()

        defer {
            _ = clientChannel.close()
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)

        for i in 0..<numBytes {
            buffer.write(integer: UInt8(i % 256))
        }

        try clientChannel.writeAndFlush(data: NIOAny(buffer)).wait()

        try countingHandler.assertReceived(buffer: buffer)
    }

    func testChannelActiveOnConnect() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let handler = ChannelActiveHandler()
        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(to: "127.0.0.1", on: 0).wait()
        
        defer {
            _ = serverChannel.close()
        }
        
        let clientChannel = try ClientBootstrap(group: group)
            .channelInitializer({ $0.pipeline.add(handler: handler) })
            .connect(to: serverChannel.localAddress!).wait()
        
        defer {
            _ = clientChannel.close()
        }
        
        handler.assertChannelActiveFired()
    }

    func testWriteThenRead() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                return channel.pipeline.add(handler: EchoServer())
            }.bind(to: "127.0.0.1", on: 0).wait()

        defer {
            _ = serverChannel.close()
        }

        let numBytes = 16 * 1024
        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: group.next().newPromise())
        let clientChannel = try ClientBootstrap(group: group)
            .channelInitializer({ $0.pipeline.add(handler: countingHandler) })
            .connect(to: serverChannel.localAddress!).wait()

        defer {
            _ = clientChannel.close()
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)
        for i in 0..<numBytes {
            buffer.write(integer: UInt8(i % 256))
        }
        try clientChannel.writeAndFlush(data: NIOAny(buffer)).wait()

        try countingHandler.assertReceived(buffer: buffer)
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
        
        func assertChannelActiveFired() {
            XCTAssert(promise.futureResult.fulfilled)
        }
    }

    private final class EchoServer: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        
        func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
            ctx.write(data: data, promise: nil)
        }
        
        func channelReadComplete(ctx: ChannelHandlerContext) {
            ctx.flush(promise: nil)
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
                ctx.writeAndFlush(data: data, promise: nil)
                self.group.leave()
            }.futureResult.whenComplete { res in
                switch res {
                case .failure(let e):
                    XCTFail("we failed to schedule the task: \(e)")
                    self.group.leave()
                default:
                    ()
                }
            }
            ctx.writeAndFlush(data: data, promise: nil)
        }
    }

    private final class WriteALotHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
            for _ in 0..<10000 {
                ctx.write(data: data, promise: nil)
            }
        }

        func channelReadComplete(ctx: ChannelHandlerContext) {
            ctx.flush(promise: nil)
        }
    }

    private final class CloseInInActiveAndUnregisteredChannelHandler: ChannelInboundHandler {
        typealias InboundIn = Never
        let alreadyClosedInChannelInactive = Atomic<Bool>(value: false)
        let alreadyClosedInChannelUnregistered = Atomic<Bool>(value: false)
        let channelUnregisteredPromise: EventLoopPromise<()>
        let channelInactivePromise: EventLoopPromise<()>

        public init(channelUnregisteredPromise: EventLoopPromise<()>,
                    channelInactivePromise: EventLoopPromise<()>) {
            self.channelUnregisteredPromise = channelUnregisteredPromise
            self.channelInactivePromise = channelInactivePromise
        }

        public func channelActive(ctx: ChannelHandlerContext) {
            ctx.close().whenComplete { val in
                switch val {
                case .success(()):
                    ()
                default:
                    XCTFail("bad, initial close failed")
                }
            }
        }

        public func channelInactive(ctx: ChannelHandlerContext) {
            if alreadyClosedInChannelInactive.compareAndExchange(expected: false, desired: true) {
                XCTAssertFalse(self.channelUnregisteredPromise.futureResult.fulfilled,
                               "channelInactive should fire before channelUnregistered")
                ctx.close().whenComplete { val in
                    switch val {
                    case .failure(ChannelError.alreadyClosed):
                        ()
                    case .success(()):
                        XCTFail("unexpected success")
                    case .failure(let e):
                        XCTFail("unexpected error: \(e)")
                    }
                    self.channelInactivePromise.succeed(result: ())
                }
            }
        }

        public func channelUnregistered(ctx: ChannelHandlerContext) {
            if alreadyClosedInChannelUnregistered.compareAndExchange(expected: false, desired: true) {
                XCTAssertTrue(self.channelInactivePromise.futureResult.fulfilled,
                              "when channelUnregister fires, channelInactive should already have fired")
                ctx.close().whenComplete { val in
                    switch val {
                    case .failure(ChannelError.alreadyClosed):
                        ()
                    case .success(()):
                        XCTFail("unexpected success")
                    case .failure(let e):
                        XCTFail("unexpected error: \(e)")
                    }
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
            ctx.writeAndFlush(data: NIOAny(dataToWrite), promise: nil)
            ctx.fireChannelActive()
        }
    }

    func testCloseInInactive() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
            defer {
                XCTAssertNoThrow(try group.syncShutdownGracefully())
            }

        let inactivePromise = group.next().newPromise() as EventLoopPromise<()>
        let unregistredPromise = group.next().newPromise() as EventLoopPromise<()>
        let handler = CloseInInActiveAndUnregisteredChannelHandler(channelUnregisteredPromise: unregistredPromise,
                                                                   channelInactivePromise: inactivePromise)

        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are appled to the accepted Channels
            .childChannelInitializer { channel in
                // Ensure we don't read faster then we can write by adding the BackPressureHandler into the pipeline.
                return channel.pipeline.add(handler: handler)
            }.bind(to: "127.0.0.1", on: 0).wait()

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait()

        defer {
            _ = clientChannel.close()
        }

        _ = try inactivePromise.futureResult.and(unregistredPromise.futureResult).wait()

        XCTAssertTrue(handler.alreadyClosedInChannelInactive.load())
        XCTAssertTrue(handler.alreadyClosedInChannelUnregistered.load())
    }

    func testFlushOnEmpty() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let writingBytes = "hello"
        let bytesReceivedPromise: EventLoopPromise<ByteBuffer> = group.next().newPromise()
        let byteCountingHandler = ByteCountingHandler(numBytes: writingBytes.utf8.count, promise: bytesReceivedPromise)
        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                // When we've received all the bytes we know the connection is up. Remove the handler.
                _ = bytesReceivedPromise.futureResult.then { _ in
                    channel.pipeline.remove(handler: byteCountingHandler)
                }

                // Ensure we don't read faster then we can write by adding the BackPressureHandler into the pipeline.
                return channel.pipeline.add(handler: byteCountingHandler)
            }.bind(to: "127.0.0.1", on: 0).wait()

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait()
        defer {
            _ = clientChannel.close()
        }

        // First we confirm that the channel really is up by sending in the appropriate number of bytes.
        var bytesToWrite = clientChannel.allocator.buffer(capacity: writingBytes.utf8.count)
        bytesToWrite.write(string: writingBytes)
        clientChannel.writeAndFlush(data: NIOAny(bytesToWrite), promise: nil)

        // When we've received all the bytes we know the connection is up.
        _ = try bytesReceivedPromise.futureResult.wait()

        // Now, with an empty write pipeline, we want to flush. This should complete immediately and without error.
        let flushFuture = clientChannel.flush()
        flushFuture.whenComplete { result in
            switch result {
            case .success:
                break
            case .failure(let err):
                XCTFail("\(err)")
            }
        }
        try flushFuture.wait()
    }

    func testWriteOnConnect() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                return channel.pipeline.add(handler: EchoServer())
            }.bind(to: "127.0.0.1", on: 0).wait()

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let stringToWrite = "hello"
        let promise: EventLoopPromise<ByteBuffer> = group.next().newPromise()
        let clientChannel = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                return channel.pipeline.add(handler: WriteOnConnectHandler(toWrite: stringToWrite)).then { v2 in
                    return channel.pipeline.add(handler: ByteCountingHandler(numBytes: stringToWrite.utf8.count, promise: promise))
                }
            }
            .connect(to: serverChannel.localAddress!).wait()
        defer {
            _ = clientChannel.close()
        }

        let bytes = try promise.futureResult.wait()
        XCTAssertEqual(bytes.getString(at: bytes.readerIndex, length: bytes.readableBytes), stringToWrite)
    }

    func testWriteOnAccept() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let stringToWrite = "hello"
        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                return channel.pipeline.add(handler: WriteOnConnectHandler(toWrite: stringToWrite))
            }.bind(to: "127.0.0.1", on: 0).wait()

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let promise: EventLoopPromise<ByteBuffer> = group.next().newPromise()
        let clientChannel = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                return channel.pipeline.add(handler: ByteCountingHandler(numBytes: stringToWrite.utf8.count, promise: promise))
            }
            .connect(to: serverChannel.localAddress!).wait()

        defer {
            _ = clientChannel.close()
        }

        let bytes = try promise.futureResult.wait()
        XCTAssertEqual(bytes.getString(at: bytes.readerIndex, length: bytes.readableBytes), stringToWrite)
    }

    func testWriteAfterChannelIsDead() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        let dpGroup = DispatchGroup()

        dpGroup.enter()
        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                return channel.pipeline.add(handler: EchoAndEchoAgainAfterSomeTimeServer(time: .seconds(1), secondWriteDoneHandler: {
                    dpGroup.leave()
                }))
            }.bind(to: "127.0.0.1", on: 0).wait()

        defer {
            _ = serverChannel.close()
        }

        let str = "hi there"
        let countingHandler = ByteCountingHandler(numBytes: str.utf8.count, promise: group.next().newPromise())
        let clientChannel = try ClientBootstrap(group: group)
            .channelInitializer({ $0.pipeline.add(handler: countingHandler) })
            .connect(to: serverChannel.localAddress!).wait()

        var buffer = clientChannel.allocator.buffer(capacity: str.utf8.count)
        buffer.write(string: str)
        try clientChannel.writeAndFlush(data: NIOAny(buffer)).wait()

        try countingHandler.assertReceived(buffer: buffer)

        /* close the client channel so that the second write should fail */
        try clientChannel.close().wait()

        dpGroup.wait() /* make sure we stick around until the second write has happened */

        XCTAssertNoThrow(try group.syncShutdownGracefully())
    }
    
    func testPendingReadProcessedAfterWriteError() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
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
                ctx.writeAndFlush(data: NIOAny(buffer)).whenSuccess { _ in
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
                ctx.writeAndFlush(data: NIOAny(buffer)).then{ _ in
                    ctx.writeAndFlush(data: NIOAny(buffer)).then{ _ in
                        ctx.writeAndFlush(data: NIOAny(buffer)).then{ _ in
                            ctx.writeAndFlush(data: NIOAny(buffer)).then{ _ in
                                ctx.close()
                            }
                        }
                    }
                }.whenComplete{ _ in
                    self.dpGroup.leave()
                }
            }
        }
        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .childChannelInitializer { channel in
                return channel.pipeline.add(handler: WriteWhenActiveHandler(str, dpGroup))
            }.bind(to: "127.0.0.1", on: 0).wait()
        
        defer {
            _ = serverChannel.close()
        }
        
        let clientChannel = try ClientBootstrap(group: group)
            // We will only start reading once we wrote all data on the accepted channel.
            //.channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 2))
            .channelInitializer{ channel in
                return channel.pipeline.add(handler: WriteHandler()).then{ _ in
                    return channel.pipeline.add(handler: countingHandler)
                }
            }.connect(to: serverChannel.localAddress!).wait()
        defer {
            _ = clientChannel.close()
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
}
