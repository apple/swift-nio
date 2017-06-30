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

class ChannelPipelineTest: XCTestCase {
    
    func testAddAfterClose() throws {
        
        let channel = EmbeddedChannel()
        _ = channel.close()
        
        channel.pipeline.removeHandlers()
        
        let handler = DummyHandler()
        defer {
            XCTAssertFalse(handler.handlerAddedCalled.load())
            XCTAssertFalse(handler.handlerRemovedCalled.load())
        }
        do {
            try channel.pipeline.add(handler: handler).wait()
            XCTFail()
        } catch let err as ChannelPipelineError {
            XCTAssertEqual(err, .alreadyClosed)
        }
    }
    
    private final class DummyHandler: ChannelHandler {
        let handlerAddedCalled = Atomic<Bool>(value: false)
        let handlerRemovedCalled = Atomic<Bool>(value: false)

        public func handlerAdded(ctx: ChannelHandlerContext) {
            handlerAddedCalled.store(true)
        }
        
        public func handlerRemoved(ctx: ChannelHandlerContext) {
            handlerRemovedCalled.store(true)
        }
    }
    
    func testOutboundOrdering() throws {
        
        let channel = EmbeddedChannel()

        var buf = channel.allocator.buffer(capacity: 1024)
        buf.write(string: "hello")
        
        _ = try channel.pipeline.add(handler: TestChannelOutboundHandler<Int, ByteBuffer>({ data in
            XCTAssertEqual(1, data)
            return buf
        })).wait()
        
        _ = try channel.pipeline.add(handler: TestChannelOutboundHandler<String, Int>({ data in
            XCTAssertEqual("msg", data)
            return 1
        })).wait()
        
        
        _ = channel.write(data: IOData("msg"))
        _ = try channel.flush().wait()
        XCTAssertEqual(buf, channel.readOutbound())
        XCTAssertNil(channel.readOutbound())
        
    }
    
    private final class TestChannelOutboundHandler<In, Out>: ChannelOutboundHandler {
        typealias OutboundIn = In
        typealias OutboundOut = Out
        
        private let fn: (OutboundIn) throws -> OutboundOut
        
        init(_ fn: @escaping (OutboundIn) throws -> OutboundOut) {
            self.fn = fn
        }
        
        public func write(ctx: ChannelHandlerContext, data: IOData, promise: Promise<Void>?) {
            do {
                ctx.write(data: self.wrapOutboundOut(try fn(self.unwrapOutboundIn(data))), promise: promise)
            } catch let err {
                promise!.fail(error: err)
            }
        }
    }
}
