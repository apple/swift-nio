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

//
import XCTest
@testable import NIO

public class ByteToMessageDecoderTest: XCTestCase {
    private final class ByteToInt32Decoder : ByteToMessageDecoder {
        var cumulationBuffer: ByteBuffer?
        
        
        func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) -> Bool {
            guard buffer.readableBytes >= MemoryLayout<Int32>.size else {
                return false
            }
            ctx.fireChannelRead(data: .other(buffer.readInteger()! as Int32))
            return true
        }
    }
    
    private final class InboundDataCollector: ChannelInboundHandler {
        
        private let fn: (IOData) -> Void
        
        init(_ fn: @escaping (IOData) -> Void) {
            self.fn = fn
        }
        
        public func channelRead(ctx: ChannelHandlerContext, data: IOData) {
            self.fn(data)
        }
    }
    
    func testDecoder() throws {
        let channel = EmbeddedChannel()
        
        var dataArray = [Int32]()
        _ = try channel.pipeline.add(handler: ByteToInt32Decoder()).wait()
        _ = try channel.pipeline.add(handler: InboundDataCollector { data in
            dataArray.append(data.forceAsOther())
        }).wait()
        
        var buffer = channel.allocator.buffer(capacity: 32)
        buffer.write(integer: Int32(1))
        let writerIndex = buffer.writerIndex
        buffer.moveWriterIndex(to: writerIndex - 1)
        
        channel.pipeline.fireChannelRead(data: .byteBuffer(buffer))
        XCTAssertTrue(dataArray.isEmpty)
        
        channel.pipeline.fireChannelRead(data: .byteBuffer(buffer.slice(at: writerIndex - 1, length: 1)!))
        XCTAssertEqual(1, dataArray.count)
        
        var buffer2 = channel.allocator.buffer(capacity: 32)
        buffer2.write(integer: Int32(2))
        buffer2.write(integer: Int32(3))
        channel.pipeline.fireChannelRead(data: .byteBuffer(buffer2))
        XCTAssertEqual(3, dataArray.count)

        try channel.close().wait()
        XCTAssertEqual(3, dataArray.count)

        XCTAssertEqual(Int32(1), dataArray[0])
        XCTAssertEqual(Int32(2), dataArray[1])
        XCTAssertEqual(Int32(3), dataArray[2])
    }
}
