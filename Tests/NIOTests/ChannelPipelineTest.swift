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

class ChannelPipelineTest: XCTestCase {
    
    
    func testOutboundOrdering() throws {
        
        let channel = EmbeddedChannel()

        var buf = try channel.allocator.buffer(capacity: 1024)
        buf.write(string: "hello")
        
        _ = try channel.pipeline.add(handler: TestChannelOutboundHandler({ data in
            XCTAssertEqual(1, data.forceAsOther())
            return .byteBuffer(buf)
        })).wait()
        
        _ = try channel.pipeline.add(handler: TestChannelOutboundHandler({ data in
            XCTAssertEqual("msg", data.forceAsOther())
            return .other(1)
        })).wait()
        
        
        _ = try channel.writeAndFlush(data: .other("msg")).wait()
        XCTAssertEqual(buf, channel.outboundBuffer[0] as! ByteBuffer)
    }
    
    private final class TestChannelOutboundHandler: ChannelOutboundHandler {
        
        private let fn: (IOData) throws -> IOData
        
        init(_ fn: @escaping (IOData) throws -> IOData) {
            self.fn = fn
        }
        
        public func write(ctx: ChannelHandlerContext, data: IOData, promise: Promise<Void>) {
            
            do {
                ctx.write(data: try fn(data), promise: promise)
            } catch let err {
                promise.fail(error: err)
            }
        }
    }
}
