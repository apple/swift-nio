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
import ConcurrencyHelpers
@testable import NIO

class EchoServerClientTest : XCTestCase {

    func buildTempDir() -> String {
        let template = "/tmp/.NIOTests-UDS-container-dir_XXXXXX"
        var templateBytes = Array(template.utf8)
        templateBytes.append(0)
        templateBytes.withUnsafeMutableBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: Int8.self, capacity: templateBytes.count) { (ptr: UnsafeMutablePointer<Int8>) in
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
            try! group.syncShutdownGracefully()
        }

        let numBytes = 16 * 1024
        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: group.next().newPromise())
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            
            // Set the handlers that are appled to the accepted Channels
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                // Ensure we not read faster then we can write by adding the BackPressureHandler into the pipeline.
                return channel.pipeline.add(handler: countingHandler)
            })).bind(to: "127.0.0.1", on: 0).wait()
        
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
        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                return channel.pipeline.add(handler: WriteALotHandler())
            })).bind(to: "127.0.0.1", on: 0).wait()

        defer {
            _ = try! serverChannel.close().wait()
        }

        let promise: Promise<ByteBuffer> = group.next().newPromise()
        let clientChannel = try ClientBootstrap(group: group)
            .handler(handler: ChannelInitializer(initChannel: { channel in
                return channel.pipeline.add(handler: WriteOnConnectHandler(toWrite: "X")).then { v2 in
                    return channel.pipeline.add(handler: ByteCountingHandler(numBytes: 10000, promise: promise))
                }
            }))
            .connect(to: serverChannel.localAddress!).wait()
        defer {
            _ = clientChannel.close()
        }

        let bytes = try promise.futureResult.wait()
        let expected = String(decoding: Array(repeating: "X".utf8.first!, count: 10000), as: UTF8.self)
        XCTAssertEqual(expected, bytes.string(at: bytes.readerIndex, length: bytes.readableBytes))
    }

    func testEchoUnixDomainSocket() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let udsTempDir = buildTempDir()
        defer {
            try! FileManager.default.removeItem(atPath: udsTempDir)
        }

        let numBytes = 16 * 1024
        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: group.next().newPromise())
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are appled to the accepted Channels
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                // Ensure we not read faster then we can write by adding the BackPressureHandler into the pipeline.
                return channel.pipeline.add(handler: countingHandler)
            })).bind(unixDomainSocket: udsTempDir + "/server.sock").wait()

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
            try! group.syncShutdownGracefully()
        }

        let udsTempDir = buildTempDir()
        defer {
            try! FileManager.default.removeItem(atPath: udsTempDir)
        }

        let numBytes = 16 * 1024
        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: group.next().newPromise())
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are appled to the accepted Channels
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                // Ensure we not read faster then we can write by adding the BackPressureHandler into the pipeline.
                return channel.pipeline.add(handler: countingHandler)
            })).bind(unixDomainSocket: udsTempDir + "/server.sock").wait()

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
            try! group.syncShutdownGracefully()
        }

        let handler = ChannelActiveHandler()
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(to: "127.0.0.1", on: 0).wait()
        
        defer {
            _ = serverChannel.close()
        }
        
        let clientChannel = try ClientBootstrap(group: group)
            .handler(handler: handler)
            .connect(to: serverChannel.localAddress!).wait()
        
        defer {
            _ = clientChannel.close()
        }
        
        handler.assertChannelActiveFired()
    }

    func testWriteThenRead() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                return channel.pipeline.add(handler: EchoServer())
            })).bind(to: "127.0.0.1", on: 0).wait()

        defer {
            _ = serverChannel.close()
        }

        let numBytes = 16 * 1024
        let countingHandler = ByteCountingHandler(numBytes: numBytes, promise: group.next().newPromise())
        let clientChannel = try ClientBootstrap(group: group)
            .handler(handler: countingHandler)
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
    
    private final class ByteCountingHandler : ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        
        private let numBytes: Int
        private let promise: Promise<ByteBuffer>
        private var buffer: ByteBuffer!
        
        init(numBytes: Int, promise: Promise<ByteBuffer>) {
            self.numBytes = numBytes
            self.promise = promise
        }
        
        func handlerAdded(ctx: ChannelHandlerContext) {
            buffer = ctx.channel!.allocator.buffer(capacity: numBytes)
        }
        
        func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
            var currentBuffer = self.unwrapInboundIn(data)
            buffer.write(buffer: &currentBuffer)
            
            if buffer.readableBytes == numBytes {
                // Do something
                promise.succeed(result: buffer)
            }
        }
        
        func assertReceived(buffer: ByteBuffer) throws {
            let received = try promise.futureResult.wait()
            XCTAssertEqual(buffer, received)
        }
    }

    private final class ChannelActiveHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        
        private var promise: Promise<Void>! = nil
        
        func handlerAdded(ctx: ChannelHandlerContext) {
            promise = ctx.channel!.eventLoop.newPromise()
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
        let channelUnregisteredPromise: Promise<()>
        let channelInactivePromise: Promise<()>

        public init(channelUnregisteredPromise: Promise<()>,
                    channelInactivePromise: Promise<()>) {
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
            var dataToWrite = ctx.channel!.allocator.buffer(capacity: toWrite.utf8.count)
            dataToWrite.write(string: toWrite)
            ctx.writeAndFlush(data: NIOAny(dataToWrite), promise: nil)
            ctx.fireChannelActive()
        }
    }

    func testCloseInInactive() throws {

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
            defer {
                try! group.syncShutdownGracefully()
            }

        let inactivePromise = group.next().newPromise() as Promise<()>
        let unregistredPromise = group.next().newPromise() as Promise<()>
        let handler = CloseInInActiveAndUnregisteredChannelHandler(channelUnregisteredPromise: unregistredPromise,
                                                                   channelInactivePromise: inactivePromise)

        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are appled to the accepted Channels
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                // Ensure we not read faster then we can write by adding the BackPressureHandler into the pipeline.
                return channel.pipeline.add(handler: handler)
            })).bind(to: "127.0.0.1", on: 0).wait()

        defer {
            _ = try! serverChannel.close().wait()
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
            try! group.syncShutdownGracefully()
        }

        let writingBytes = "hello"
        let bytesReceivedPromise: Promise<ByteBuffer> = group.next().newPromise()
        let byteCountingHandler = ByteCountingHandler(numBytes: writingBytes.utf8.count, promise: bytesReceivedPromise)
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                // Ensure we not read faster then we can write by adding the BackPressureHandler into the pipeline.
                return channel.pipeline.add(handler: byteCountingHandler)
            })).bind(to: "127.0.0.1", on: 0).wait()

        defer {
            _ = try! serverChannel.close().wait()
        }

        let clientChannel = try ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait()
        defer {
            _ = clientChannel.close()
        }

        // First we confirm that the channel really is up by sending in the appropriate number of bytes.
        var bytesToWrite = clientChannel.allocator.buffer(capacity: writingBytes.utf8.count)
        bytesToWrite.write(string: writingBytes)
        clientChannel.writeAndFlush(data: NIOAny(bytesToWrite), promise: nil)

        // When we've received all the bytes we know the connection is up. Remove the handler.
        _ = try bytesReceivedPromise.futureResult.then { _ in
            clientChannel.pipeline.remove(handler: byteCountingHandler)
        }.wait()

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
            try! group.syncShutdownGracefully()
        }

        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                return channel.pipeline.add(handler: EchoServer())
            })).bind(to: "127.0.0.1", on: 0).wait()

        defer {
            _ = try! serverChannel.close().wait()
        }

        let stringToWrite = "hello"
        let promise: Promise<ByteBuffer> = group.next().newPromise()
        let clientChannel = try ClientBootstrap(group: group)
            .handler(handler: ChannelInitializer(initChannel: { channel in
                return channel.pipeline.add(handler: WriteOnConnectHandler(toWrite: stringToWrite)).then { v2 in
                    return channel.pipeline.add(handler: ByteCountingHandler(numBytes: stringToWrite.utf8.count, promise: promise))
                }
            }))
            .connect(to: serverChannel.localAddress!).wait()
        defer {
            _ = clientChannel.close()
        }

        let bytes = try promise.futureResult.wait()
        XCTAssertEqual(bytes.string(at: bytes.readerIndex, length: bytes.readableBytes), stringToWrite)
    }

    func testWriteOnAccept() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let stringToWrite = "hello"
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                return channel.pipeline.add(handler: WriteOnConnectHandler(toWrite: stringToWrite))
            })).bind(to: "127.0.0.1", on: 0).wait()

        defer {
            _ = try! serverChannel.close().wait()
        }

        let promise: Promise<ByteBuffer> = group.next().newPromise()
        let clientChannel = try ClientBootstrap(group: group)
            .handler(handler: ChannelInitializer(initChannel: { channel in
                return channel.pipeline.add(handler: ByteCountingHandler(numBytes: stringToWrite.utf8.count, promise: promise))
            }))
            .connect(to: serverChannel.localAddress!).wait()

        defer {
            _ = clientChannel.close()
        }

        let bytes = try promise.futureResult.wait()
        XCTAssertEqual(bytes.string(at: bytes.readerIndex, length: bytes.readableBytes), stringToWrite)
    }
}
