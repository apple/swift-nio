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

import NIO
import XCTest

final class ByteCountingHandler : ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    
    private let numBytes: Int
    private let promise: EventLoopPromise<ByteBuffer>
    private var buffer: ByteBuffer!
    
    init(numBytes: Int, promise: EventLoopPromise<ByteBuffer>) {
        self.numBytes = numBytes
        self.promise = promise
    }
    
    func handlerAdded(ctx: ChannelHandlerContext) {
        buffer = ctx.channel.allocator.buffer(capacity: numBytes)
        if self.numBytes == 0 {
            self.promise.succeed(result: buffer)
        }
    }
    
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var currentBuffer = self.unwrapInboundIn(data)
        buffer.write(buffer: &currentBuffer)
        
        if buffer.readableBytes == numBytes {
            promise.succeed(result: buffer)
        }
    }
    
    func assertReceived(buffer: ByteBuffer) throws {
        let received = try promise.futureResult.wait()
        XCTAssertEqual(buffer, received)
    }
}
