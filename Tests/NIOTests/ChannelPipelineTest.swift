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
        } catch let err as ChannelError {
            XCTAssertEqual(err, .ioOnClosedChannel)
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

        _ = try channel.pipeline.add(handler: TestChannelOutboundHandler<Int, ByteBuffer> { data in
            XCTAssertEqual(1, data)
            return buf
        }).wait()

        _ = try channel.pipeline.add(handler: TestChannelOutboundHandler<String, Int> { data in
            XCTAssertEqual("msg", data)
            return 1
        }).wait()

        try channel.writeAndFlush(NIOAny("msg")).wait()
        if let data = channel.readOutbound() {
            XCTAssertEqual(IOData.byteBuffer(buf), data)
        } else {
            XCTFail("couldn't read from channel")
        }
        XCTAssertNil(channel.readOutbound())

        XCTAssertFalse(try channel.finish())
    }

    func testConnectingDoesntCallBind() throws {
        let channel = EmbeddedChannel()
        var ipv4SocketAddress = sockaddr_in()
        ipv4SocketAddress.sin_port = (12345 as UInt16).bigEndian
        let sa = SocketAddress(ipv4SocketAddress, host: "foobar.com")

        _ = try channel.pipeline.add(handler: NoBindAllowed()).wait()
        _ = try channel.pipeline.add(handler: TestChannelOutboundHandler<ByteBuffer, ByteBuffer> { data in
            return data
        }).wait()

        _ = try channel.connect(to: sa).wait()
        defer {
            XCTAssertFalse(try channel.finish())
        }
    }

    private final class TestChannelOutboundHandler<In, Out>: ChannelOutboundHandler {
        typealias OutboundIn = In
        typealias OutboundOut = Out

        private let body: (OutboundIn) throws -> OutboundOut

        init(_ body: @escaping (OutboundIn) throws -> OutboundOut) {
            self.body = body
        }

        public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            do {
                ctx.write(self.wrapOutboundOut(try body(self.unwrapOutboundIn(data))), promise: promise)
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

    private final class FireChannelReadOnRemoveHandler: ChannelInboundHandler {
        typealias InboundIn = Never
        typealias InboundOut = Int

        public func handlerRemoved(ctx: ChannelHandlerContext) {
            ctx.fireChannelRead(self.wrapInboundOut(1))
        }
    }

    func testFiringChannelReadsInHandlerRemovedWorks() throws {
        let channel = EmbeddedChannel()

        let h = FireChannelReadOnRemoveHandler()
        _ = try channel.pipeline.add(handler: h).then {
            channel.pipeline.remove(handler: h)
        }.wait()

        XCTAssertEqual(Optional<Int>.some(1), channel.readInbound())
        XCTAssertFalse(try channel.finish())
    }

    func testEmptyPipelineWorks() throws {
        let channel = EmbeddedChannel()
        try channel.writeInbound(2)
        XCTAssertEqual(Optional<Int>.some(2), channel.readInbound())
        XCTAssertFalse(try channel.finish())
    }

    func testWriteAfterClose() throws {

        let channel = EmbeddedChannel()
        _ = try channel.close().wait()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        loop.run()

        XCTAssertTrue(loop.inEventLoop)
        do {
            let handle = FileHandle(descriptor: -1)
            let fr = FileRegion(fileHandle: handle, readerIndex: 0, endIndex: 0)
            defer {
                // fake descriptor, so shouldn't be closed.
                XCTAssertNoThrow(try handle.takeDescriptorOwnership())
            }
            try channel.writeOutbound(fr)
            loop.run()
            XCTFail("we ran but an error should have been thrown")
        } catch let err as ChannelError {
            XCTAssertEqual(err, .ioOnClosedChannel)
        }
    }

    func testOutboundNextForInboundOnlyIsCorrect() throws {
        /// This handler always add its number to the inbound `[Int]` array
        final class MarkingInboundHandler: ChannelInboundHandler {
            typealias InboundIn = [Int]
            typealias InboundOut = [Int]

            private let no: Int

            init(number: Int) {
                self.no = number
            }

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                let data = self.unwrapInboundIn(data)
                ctx.fireChannelRead(self.wrapInboundOut(data + [self.no]))
            }
        }

        /// This handler always add its number to the outbound `[Int]` array
        final class MarkingOutboundHandler: ChannelOutboundHandler {
            typealias OutboundIn = [Int]
            typealias OutboundOut = [Int]

            private let no: Int

            init(number: Int) {
                self.no = number
            }

            func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                let data = self.unwrapOutboundIn(data)
                ctx.write(self.wrapOutboundOut(data + [self.no]), promise: promise)
            }
        }

        /// This handler multiplies the inbound `[Int]` it receives by `-1` and writes it to the next outbound handler.
        final class WriteOnReadHandler: ChannelInboundHandler {
            typealias InboundIn = [Int]
            typealias InboundOut = [Int]
            typealias OutboundOut = [Int]

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                let data = self.unwrapInboundIn(data)
                ctx.write(self.wrapOutboundOut(data.map { $0 * -1 }), promise: nil)
                ctx.fireChannelRead(self.wrapInboundOut(data))
            }
        }

        /// This handler just prints out the outbound received `[Int]` as a `ByteBuffer`.
        final class PrintOutboundAsByteBufferHandler: ChannelOutboundHandler {
            typealias OutboundIn = [Int]
            typealias OutboundOut = ByteBuffer

            func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                let data = self.unwrapOutboundIn(data)
                var buf = ctx.channel.allocator.buffer(capacity: 123)
                buf.write(string: String(describing: data))
                ctx.write(self.wrapOutboundOut(buf), promise: promise)
            }
        }

        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        loop.run()

        try channel.pipeline.add(handler: PrintOutboundAsByteBufferHandler()).wait()
        try channel.pipeline.add(handler: MarkingInboundHandler(number: 2)).wait()
        try channel.pipeline.add(handler: WriteOnReadHandler()).wait()
        try channel.pipeline.add(handler: MarkingOutboundHandler(number: 4)).wait()
        try channel.pipeline.add(handler: WriteOnReadHandler()).wait()
        try channel.pipeline.add(handler: MarkingInboundHandler(number: 6)).wait()
        try channel.pipeline.add(handler: WriteOnReadHandler()).wait()

        try channel.writeInbound([])
        loop.run()
        XCTAssertEqual([2, 6], channel.readInbound()!)

        /* the first thing, we should receive is `[-2]` as it shouldn't hit any `MarkingOutboundHandler`s (`4`) */
        var outbound = channel.readOutbound()
        switch outbound {
        case .some(.byteBuffer(var buf)):
            XCTAssertEqual("[-2]", buf.readString(length: buf.readableBytes))
        default:
            XCTFail("wrong contents: \(outbound.debugDescription)")
        }

        /* the next thing we should receive is `[-2, 4]` as the first `WriteOnReadHandler` (receiving `[2]`) is behind the `MarkingOutboundHandler` (`4`) */
        outbound = channel.readOutbound()
        switch outbound {
        case .some(.byteBuffer(var buf)):
            XCTAssertEqual("[-2, 4]", buf.readString(length: buf.readableBytes))
        default:
            XCTFail("wrong contents: \(outbound.debugDescription)")
        }

        /* and finally, we're waiting for `[-2, -6, 4]` as the second `WriteOnReadHandler`s (receiving `[2, 4]`) is behind the `MarkingOutboundHandler` (`4`) */
        outbound = channel.readOutbound()
        switch outbound {
        case .some(.byteBuffer(var buf)):
            XCTAssertEqual("[-2, -6, 4]", buf.readString(length: buf.readableBytes))
        default:
            XCTFail("wrong contents: \(outbound.debugDescription)")
        }

        XCTAssertNil(channel.readInbound())
        XCTAssertNil(channel.readOutbound())

        XCTAssertFalse(try channel.finish())
    }

    func testChannelInfrastructureIsNotLeaked() throws {
        class SomeHandler: ChannelInboundHandler {
            typealias InboundIn = Never

            let body: (ChannelHandlerContext) -> Void

            init(_ body: @escaping (ChannelHandlerContext) -> Void) {
                self.body = body
            }

            func handlerAdded(ctx: ChannelHandlerContext) {
                self.body(ctx)
            }
        }
        try {
            let channel = EmbeddedChannel()
            let loop = channel.eventLoop as! EmbeddedEventLoop

            weak var weakHandler1: ChannelHandler?
            weak var weakHandler2: ChannelHandler?
            weak var weakHandlerContext1: ChannelHandlerContext?
            weak var weakHandlerContext2: ChannelHandlerContext?

            () /* needed because Swift's grammar is so ambiguous that you can't remove this :\ */

            try {
                let handler1 = SomeHandler { ctx in
                    weakHandlerContext1 = ctx
                }
                weakHandler1 = handler1
                let handler2 = SomeHandler { ctx in
                    weakHandlerContext2 = ctx
                }
                weakHandler2 = handler2
                XCTAssertNoThrow(try channel.pipeline.add(handler: handler1).then {
                    channel.pipeline.add(handler: handler2)
                    }.wait())
            }()

            XCTAssertNotNil(weakHandler1)
            XCTAssertNotNil(weakHandler2)
            XCTAssertNotNil(weakHandlerContext1)
            XCTAssertNotNil(weakHandlerContext2)

            XCTAssertNoThrow(try channel.pipeline.remove(handler: weakHandler1!).wait())

            XCTAssertNil(weakHandler1)
            XCTAssertNotNil(weakHandler2)
            XCTAssertNil(weakHandlerContext1)
            XCTAssertNotNil(weakHandlerContext2)

            XCTAssertFalse(try channel.finish())

            XCTAssertNil(weakHandler1)
            XCTAssertNil(weakHandler2)
            XCTAssertNil(weakHandlerContext1)
            XCTAssertNil(weakHandlerContext2)

            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }()
    }
}
