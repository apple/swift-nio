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
            })).bind(to: "127.0.0.1", on: 1234).wait()
        
        defer {
            _ = serverChannel.close()
        }
        
        let clientChannel = try ClientBootstrap(group: group).connect(to: "127.0.0.1", on: 1234).wait()
        
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
}
