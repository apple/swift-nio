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

import Foundation
import XCTest
import ConcurrencyHelpers
@testable import NIO

class EchoServerClientTest : XCTestCase {
    
    func testEcho() throws {
        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            _ = try? group.close()
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
        
        try clientChannel.writeAndFlush(data: IOData(buffer)).wait()
        
        try countingHandler.assertReceived(buffer: buffer)
    }
    
    func testChannelActiveOnConnect() throws {
        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            _ = try? group.close()
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
        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            _ = try? group.close()
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
        try clientChannel.writeAndFlush(data: IOData(buffer)).wait()

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
        
        func channelRead(ctx: ChannelHandlerContext, data: IOData) {
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
        
        func channelRead(ctx: ChannelHandlerContext, data: IOData) {
            ctx.write(data: data, promise: nil)
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

    func testCloseInInactive() throws {

        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            _ = try? group.close()
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
            _ = serverChannel.close()
        }

        let clientChannel = try ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait()

        defer {
            _ = clientChannel.close()
        }

        _ = try inactivePromise.futureResult.and(unregistredPromise.futureResult).wait()

        XCTAssertTrue(handler.alreadyClosedInChannelInactive.load())
        XCTAssertTrue(handler.alreadyClosedInChannelUnregistered.load())
    }
}
