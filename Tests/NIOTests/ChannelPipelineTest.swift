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
        
        
        _ = channel.write(data: NIOAny("msg"))
        _ = try channel.flush().wait()
        if let data = channel.readOutbound() {
            XCTAssertEqual(IOData.byteBuffer(buf), data)
        } else {
            XCTFail("couldn't read from channel")
        }
        XCTAssertNil(channel.readOutbound())
        
    }
    
    func testConnectingDoesntCallBind() throws {
        let channel = EmbeddedChannel()
        var ipv4SocketAddress = sockaddr_in()
        ipv4SocketAddress.sin_port = (12345 as UInt16).bigEndian
        let sa = SocketAddress(IPv4Address: ipv4SocketAddress, host: "foobar.com")
        
        _ = try channel.pipeline.add(handler: NoBindAllowed()).wait()
        _ = try channel.pipeline.add(handler: TestChannelOutboundHandler<ByteBuffer, ByteBuffer>({ data in
            return data
        })).wait()
        
        _ = try channel.connect(to: sa).wait()
        _ = try channel.close().wait()
        
        return
    }
    
    private final class TestChannelOutboundHandler<In, Out>: ChannelOutboundHandler {
        typealias OutboundIn = In
        typealias OutboundOut = Out
        
        private let fn: (OutboundIn) throws -> OutboundOut
        
        init(_ fn: @escaping (OutboundIn) throws -> OutboundOut) {
            self.fn = fn
        }
        
        public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            do {
                ctx.write(data: self.wrapOutboundOut(try fn(self.unwrapOutboundIn(data))), promise: promise)
            } catch let err {
                promise!.fail(error: err)
            }
        }
    }
    
    private final class NoBindAllowed: ChannelOutboundHandler {
        typealias OutboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        
        enum TestFailureError: Error {
            case CalledBind
        }
        
        public func bind(ctx: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
            promise!.fail(error: TestFailureError.CalledBind)
        }
    }
}
