//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import Atomics
@testable import NIOCore
import NIOEmbedded
import NIOPosix
import NIOTestUtils

private final class IndexWritingHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let index: Int

    init(_ index: Int) {
        self.index = index
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        buf.writeInteger(UInt8(self.index))
        context.fireChannelRead(self.wrapInboundOut(buf))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buf = self.unwrapOutboundIn(data)
        buf.writeInteger(UInt8(self.index))
        context.write(self.wrapOutboundOut(buf), promise: promise)
    }
}

private extension EmbeddedChannel {
    func assertReadIndexOrder(_ order: [UInt8]) {
        XCTAssertTrue(try self.writeInbound(self.allocator.buffer(capacity: 32)).isFull)
        XCTAssertNoThrow(XCTAssertEqual(order,
                                        try self.readInbound(as: ByteBuffer.self).flatMap { buffer in
                                            var buffer = buffer
                                            return buffer.readBytes(length: buffer.readableBytes)
            }))
    }

    func assertWriteIndexOrder(_ order: [UInt8]) {
        XCTAssertTrue(try self.writeOutbound(self.allocator.buffer(capacity: 32)).isFull)
        XCTAssertNoThrow(XCTAssertEqual(order,
                                        try self.readOutbound(as: ByteBuffer.self).flatMap { buffer in
                                            var buffer = buffer
                                            return buffer.readBytes(length: buffer.readableBytes)
            }))
    }
}

class ChannelPipelineTest: XCTestCase {

    class SimpleTypedHandler1: ChannelInboundHandler {
        typealias InboundIn = NIOAny
    }
    class SimpleTypedHandler2: ChannelInboundHandler {
        typealias InboundIn = NIOAny
    }
    class SimpleTypedHandler3: ChannelInboundHandler {
        typealias InboundIn = NIOAny
    }

    func testGetHandler() throws {
        let handler1 = SimpleTypedHandler1()
        let handler2 = SimpleTypedHandler2()
        let handler3 = SimpleTypedHandler3()
        
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }
        try channel.pipeline.addHandlers([
            handler1,
            handler2,
            handler3
        ]).wait()
        
        let result1 = try channel.pipeline.handler(type: SimpleTypedHandler1.self).wait()
        XCTAssertTrue(result1 === handler1)
        
        let result2 = try channel.pipeline.handler(type: SimpleTypedHandler2.self).wait()
        XCTAssertTrue(result2 === handler2)

        let result3 = try channel.pipeline.handler(type: SimpleTypedHandler3.self).wait()
        XCTAssertTrue(result3 === handler3)
    }
    
    func testGetFirstHandler() throws {
        let sameTypeHandler1 = SimpleTypedHandler1()
        let sameTypeHandler2 = SimpleTypedHandler1()
        let otherHandler = SimpleTypedHandler2()

        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }
        try channel.pipeline.addHandlers([
            sameTypeHandler1,
            sameTypeHandler2,
            otherHandler
        ]).wait()
        
        let result = try channel.pipeline.handler(type: SimpleTypedHandler1.self).wait()
        XCTAssertTrue(result === sameTypeHandler1)
    }
    
    func testGetNotAddedHandler() throws {
        let handler1 = SimpleTypedHandler1()
        let handler2 = SimpleTypedHandler2()
        
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }
        try channel.pipeline.addHandlers([
            handler1,
            handler2,
        ]).wait()
        
        XCTAssertThrowsError(try channel.pipeline.handler(type: SimpleTypedHandler3.self).wait()) { XCTAssertTrue($0 is ChannelPipelineError )}
    }
    
    func testAddAfterClose() throws {

        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true))
        }
        XCTAssertNoThrow(try channel.close().wait())

        channel.pipeline.removeHandlers()

        let handler = DummyHandler()
        defer {
            XCTAssertFalse(handler.handlerAddedCalled.load(ordering: .relaxed))
            XCTAssertFalse(handler.handlerRemovedCalled.load(ordering: .relaxed))
        }
        XCTAssertThrowsError(try channel.pipeline.addHandler(handler).wait()) { error in
            XCTAssertEqual(.ioOnClosedChannel, error as? ChannelError)
        }
    }

    private final class DummyHandler: ChannelHandler {
        let handlerAddedCalled = ManagedAtomic(false)
        let handlerRemovedCalled = ManagedAtomic(false)

        public func handlerAdded(context: ChannelHandlerContext) {
            handlerAddedCalled.store(true, ordering: .relaxed)
        }

        public func handlerRemoved(context: ChannelHandlerContext) {
            handlerRemovedCalled.store(true, ordering: .relaxed)
        }
    }

    func testOutboundOrdering() throws {

        let channel = EmbeddedChannel()

        var buf = channel.allocator.buffer(capacity: 1024)
        buf.writeString("hello")

        _ = try channel.pipeline.addHandler(TestChannelOutboundHandler<Int, ByteBuffer> { data in
            XCTAssertEqual(1, data)
            return buf
        }).wait()

        _ = try channel.pipeline.addHandler(TestChannelOutboundHandler<String, Int> { data in
            XCTAssertEqual("msg", data)
            return 1
        }).wait()

        XCTAssertNoThrow(try channel.writeAndFlush(NIOAny("msg")).wait() as Void)
        if let data = try channel.readOutbound(as: ByteBuffer.self) {
            XCTAssertEqual(buf, data)
        } else {
            XCTFail("couldn't read from channel")
        }
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testConnectingDoesntCallBind() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertTrue(try channel.finish().isClean)
        }
        var ipv4SocketAddress = sockaddr_in()
        ipv4SocketAddress.sin_port = (12345 as in_port_t).bigEndian
        let sa = SocketAddress(ipv4SocketAddress, host: "foobar.com")

        XCTAssertNoThrow(try channel.pipeline.addHandler(NoBindAllowed()).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(TestChannelOutboundHandler<ByteBuffer, ByteBuffer> { data in
            data
        }).wait())

        XCTAssertNoThrow(try channel.connect(to: sa).wait())
    }

    private final class TestChannelOutboundHandler<In, Out>: ChannelOutboundHandler {
        typealias OutboundIn = In
        typealias OutboundOut = Out

        private let body: (OutboundIn) throws -> OutboundOut

        init(_ body: @escaping (OutboundIn) throws -> OutboundOut) {
            self.body = body
        }

        public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            do {
                context.write(self.wrapOutboundOut(try body(self.unwrapOutboundIn(data))), promise: promise)
            } catch let err {
                promise!.fail(err)
            }
        }
    }

    private final class NoBindAllowed: ChannelOutboundHandler {
        typealias OutboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        enum TestFailureError: Error {
            case CalledBind
        }

        public func bind(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
            promise!.fail(TestFailureError.CalledBind)
        }
    }

    private final class FireChannelReadOnRemoveHandler: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = Never
        typealias InboundOut = Int

        public func handlerRemoved(context: ChannelHandlerContext) {
            context.fireChannelRead(self.wrapInboundOut(1))
        }
    }

    func testFiringChannelReadsInHandlerRemovedWorks() throws {
        let channel = EmbeddedChannel()

        let h = FireChannelReadOnRemoveHandler()
        _ = try channel.pipeline.addHandler(h).flatMap {
            channel.pipeline.removeHandler(h)
        }.wait()

        XCTAssertNoThrow(XCTAssertEqual(Optional<Int>.some(1), try channel.readInbound()))
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testEmptyPipelineWorks() throws {
        let channel = EmbeddedChannel()
        XCTAssertTrue(try assertNoThrowWithValue(channel.writeInbound(2)).isFull)
        XCTAssertNoThrow(XCTAssertEqual(Optional<Int>.some(2), try channel.readInbound()))
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testWriteAfterClose() throws {

        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(XCTAssertTrue(try channel.finish(acceptAlreadyClosed: true).isClean))
        }
        XCTAssertNoThrow(try channel.close().wait())
        let loop = channel.eventLoop as! EmbeddedEventLoop
        loop.run()

        XCTAssertTrue(loop.inEventLoop)
        do {
            let handle = NIOFileHandle(descriptor: -1)
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

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let data = self.unwrapInboundIn(data)
                context.fireChannelRead(self.wrapInboundOut(data + [self.no]))
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

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                let data = self.unwrapOutboundIn(data)
                context.write(self.wrapOutboundOut(data + [self.no]), promise: promise)
            }
        }

        /// This handler multiplies the inbound `[Int]` it receives by `-1` and writes it to the next outbound handler.
        final class WriteOnReadHandler: ChannelInboundHandler {
            typealias InboundIn = [Int]
            typealias InboundOut = [Int]
            typealias OutboundOut = [Int]

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let data = self.unwrapInboundIn(data)
                context.writeAndFlush(self.wrapOutboundOut(data.map { $0 * -1 }), promise: nil)
                context.fireChannelRead(self.wrapInboundOut(data))
            }
        }

        /// This handler just prints out the outbound received `[Int]` as a `ByteBuffer`.
        final class PrintOutboundAsByteBufferHandler: ChannelOutboundHandler {
            typealias OutboundIn = [Int]
            typealias OutboundOut = ByteBuffer

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                let data = self.unwrapOutboundIn(data)
                var buf = context.channel.allocator.buffer(capacity: 123)
                buf.writeString(String(describing: data))
                context.write(self.wrapOutboundOut(buf), promise: promise)
            }
        }

        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        loop.run()

        try channel.pipeline.addHandler(PrintOutboundAsByteBufferHandler()).wait()
        try channel.pipeline.addHandler(MarkingInboundHandler(number: 2)).wait()
        try channel.pipeline.addHandler(WriteOnReadHandler()).wait()
        try channel.pipeline.addHandler(MarkingOutboundHandler(number: 4)).wait()
        try channel.pipeline.addHandler(WriteOnReadHandler()).wait()
        try channel.pipeline.addHandler(MarkingInboundHandler(number: 6)).wait()
        try channel.pipeline.addHandler(WriteOnReadHandler()).wait()

        try channel.writeInbound([Int]())
        loop.run()
        XCTAssertNoThrow(XCTAssertEqual([2, 6], try channel.readInbound()!))

        /* the first thing, we should receive is `[-2]` as it shouldn't hit any `MarkingOutboundHandler`s (`4`) */
        var outbound = try channel.readOutbound(as: ByteBuffer.self)
        if var buf = outbound {
            XCTAssertEqual("[-2]", buf.readString(length: buf.readableBytes))
        } else {
            XCTFail("wrong contents: \(outbound.debugDescription)")
        }

        /* the next thing we should receive is `[-2, 4]` as the first `WriteOnReadHandler` (receiving `[2]`) is behind the `MarkingOutboundHandler` (`4`) */
        outbound = try channel.readOutbound()
        if var buf = outbound {
            XCTAssertEqual("[-2, 4]", buf.readString(length: buf.readableBytes))
        } else {
            XCTFail("wrong contents: \(outbound.debugDescription)")
        }

        /* and finally, we're waiting for `[-2, -6, 4]` as the second `WriteOnReadHandler`s (receiving `[2, 4]`) is behind the `MarkingOutboundHandler` (`4`) */
        outbound = try channel.readOutbound()
        if var buf = outbound {
            XCTAssertEqual("[-2, -6, 4]", buf.readString(length: buf.readableBytes))
        } else {
            XCTFail("wrong contents: \(outbound.debugDescription)")
        }

        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testChannelInfrastructureIsNotLeaked() throws {
        class SomeHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never

            let body: (ChannelHandlerContext) -> Void

            init(_ body: @escaping (ChannelHandlerContext) -> Void) {
                self.body = body
            }

            func handlerAdded(context: ChannelHandlerContext) {
                self.body(context)
            }
        }
        try {
            let channel = EmbeddedChannel()
            let loop = channel.eventLoop as! EmbeddedEventLoop

            weak var weakHandler1: RemovableChannelHandler?
            weak var weakHandler2: ChannelHandler?
            weak var weakHandlerContext1: ChannelHandlerContext?
            weak var weakHandlerContext2: ChannelHandlerContext?

            () /* needed because Swift's grammar is so ambiguous that you can't remove this :\ */

            try {
                let handler1 = SomeHandler { context in
                    weakHandlerContext1 = context
                }
                weakHandler1 = handler1
                let handler2 = SomeHandler { context in
                    weakHandlerContext2 = context
                }
                weakHandler2 = handler2
                XCTAssertNoThrow(try channel.pipeline.addHandler(handler1).flatMap {
                    channel.pipeline.addHandler(handler2)
                    }.wait())
            }()

            XCTAssertNotNil(weakHandler1)
            XCTAssertNotNil(weakHandler2)
            XCTAssertNotNil(weakHandlerContext1)
            XCTAssertNotNil(weakHandlerContext2)

            XCTAssertNoThrow(try channel.pipeline.removeHandler(weakHandler1!).wait())

            XCTAssertNil(weakHandler1)
            XCTAssertNotNil(weakHandler2)
            XCTAssertNil(weakHandlerContext1)
            XCTAssertNotNil(weakHandlerContext2)

            XCTAssertTrue(try channel.finish().isClean)

            XCTAssertNil(weakHandler1)
            XCTAssertNil(weakHandler2)
            XCTAssertNil(weakHandlerContext1)
            XCTAssertNil(weakHandlerContext2)

            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }()
    }

    func testAddingHandlersFirstWorks() throws {
        final class ReceiveIntHandler: ChannelInboundHandler {
            typealias InboundIn = Int

            var intReadCount = 0

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                if data.tryAs(type: Int.self) != nil {
                    self.intReadCount += 1
                }
            }
        }

        final class TransformStringToIntHandler: ChannelInboundHandler {
            typealias InboundIn = String
            typealias InboundOut = Int

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                if let dataString = data.tryAs(type: String.self) {
                    context.fireChannelRead(self.wrapInboundOut(dataString.count))
                }
            }
        }

        final class TransformByteBufferToStringHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = String

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                if var buffer = data.tryAs(type: ByteBuffer.self) {
                    context.fireChannelRead(self.wrapInboundOut(buffer.readString(length: buffer.readableBytes)!))
                }
            }
        }

        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let countHandler = ReceiveIntHandler()
        var buffer = channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("hello, world")

        XCTAssertNoThrow(try channel.pipeline.addHandler(countHandler).wait())
        XCTAssertTrue(try channel.writeInbound(buffer).isEmpty)
        XCTAssertEqual(countHandler.intReadCount, 0)

        try channel.pipeline.addHandlers(TransformByteBufferToStringHandler(),
                                         TransformStringToIntHandler(),
                                         position: .first).wait()
        XCTAssertTrue(try channel.writeInbound(buffer).isEmpty)
        XCTAssertEqual(countHandler.intReadCount, 1)
    }

    func testAddAfter() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let firstHandler = IndexWritingHandler(1)
        XCTAssertNoThrow(try channel.pipeline.addHandler(firstHandler).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(IndexWritingHandler(2)).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(IndexWritingHandler(3),
                                                         position: .after(firstHandler)).wait())

        channel.assertReadIndexOrder([1, 3, 2])
        channel.assertWriteIndexOrder([2, 3, 1])
    }

    func testAddBefore() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let secondHandler = IndexWritingHandler(2)
        XCTAssertNoThrow(try channel.pipeline.addHandler(IndexWritingHandler(1)).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(secondHandler).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(IndexWritingHandler(3),
                                                         position: .before(secondHandler)).wait())

        channel.assertReadIndexOrder([1, 3, 2])
        channel.assertWriteIndexOrder([2, 3, 1])
    }

    func testAddAfterLast() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let secondHandler = IndexWritingHandler(2)
        XCTAssertNoThrow(try channel.pipeline.addHandler(IndexWritingHandler(1)).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(secondHandler).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(IndexWritingHandler(3),
                                                         position: .after(secondHandler)).wait())

        channel.assertReadIndexOrder([1, 2, 3])
        channel.assertWriteIndexOrder([3, 2, 1])
    }

    func testAddBeforeFirst() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let firstHandler = IndexWritingHandler(1)
        XCTAssertNoThrow(try channel.pipeline.addHandler(firstHandler).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(IndexWritingHandler(2)).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(IndexWritingHandler(3),
                                                         position: .before(firstHandler)).wait())

        channel.assertReadIndexOrder([3, 1, 2])
        channel.assertWriteIndexOrder([2, 1, 3])
    }

    func testAddAfterWhileClosed() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertThrowsError(try channel.finish()) { error in
                XCTAssertEqual(.alreadyClosed, error as? ChannelError)
            }
        }

        let handler = IndexWritingHandler(1)
        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())
        XCTAssertNoThrow(try channel.close().wait())
        channel.embeddedEventLoop.run()

        XCTAssertThrowsError(try channel.pipeline.addHandler(IndexWritingHandler(2),
                                                             position: .after(handler)).wait()) { error in
            XCTAssertEqual(.ioOnClosedChannel, error as? ChannelError)
        }
    }

    func testAddBeforeWhileClosed() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertThrowsError(try channel.finish()) { error in
                XCTAssertEqual(.alreadyClosed, error as? ChannelError)
            }
        }

        let handler = IndexWritingHandler(1)
        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())
        XCTAssertNoThrow(try channel.close().wait())
        channel.embeddedEventLoop.run()

        XCTAssertThrowsError(try channel.pipeline.addHandler(IndexWritingHandler(2),
                                                             position: .before(handler)).wait()) { error in
            XCTAssertEqual(.ioOnClosedChannel, error as? ChannelError)
        }
    }

    func testFindHandlerByType() {
        class TypeAHandler: ChannelInboundHandler {
            typealias InboundIn = Any
            typealias InboundOut = Any
        }

        class TypeBHandler: ChannelInboundHandler {
            typealias InboundIn = Any
            typealias InboundOut = Any
        }

        class TypeCHandler: ChannelInboundHandler {
            typealias InboundIn = Any
            typealias InboundOut = Any
        }

        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let h1 = TypeAHandler()
        let h2 = TypeBHandler()
        XCTAssertNoThrow(try channel.pipeline.addHandler(h1).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(h2).wait())

        XCTAssertTrue(try h1 === channel.pipeline.context(handlerType: TypeAHandler.self).wait().handler)
        XCTAssertTrue(try h2 === channel.pipeline.context(handlerType: TypeBHandler.self).wait().handler)

        XCTAssertThrowsError(try channel.pipeline.context(handlerType: TypeCHandler.self).wait()) { error in
            XCTAssertEqual(.notFound, error as? ChannelPipelineError)
        }
    }

    func testFindHandlerByTypeReturnsTheFirstOfItsType() {
        class TestHandler: ChannelInboundHandler {
            typealias InboundIn = Any
            typealias InboundOut = Any
        }

        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let h1 = TestHandler()
        let h2 = TestHandler()
        XCTAssertNoThrow(try channel.pipeline.addHandler(h1).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(h2).wait())

        XCTAssertTrue(try h1 === channel.pipeline.context(handlerType: TestHandler.self).wait().handler)
        XCTAssertFalse(try h2 === channel.pipeline.context(handlerType: TestHandler.self).wait().handler)
    }

    func testContextForHeadOrTail() throws {
        let channel = EmbeddedChannel()

        defer {
            XCTAssertTrue(try channel.finish().isClean)
        }

        XCTAssertThrowsError(try channel.pipeline.context(name: HeadChannelHandler.name).wait()) { error in
            XCTAssertEqual(.notFound, error as? ChannelPipelineError)
        }

        XCTAssertThrowsError(try channel.pipeline.context(handlerType: HeadChannelHandler.self).wait()) { error in
            XCTAssertEqual(.notFound, error as? ChannelPipelineError)
        }

        XCTAssertThrowsError(try channel.pipeline.context(name: TailChannelHandler.name).wait()) { error in
            XCTAssertEqual(.notFound, error as? ChannelPipelineError)
        }

        XCTAssertThrowsError(try channel.pipeline.context(handlerType: TailChannelHandler.self).wait()) { error in
            XCTAssertEqual(.notFound, error as? ChannelPipelineError)
        }
    }

    func testRemoveHeadOrTail() throws {
        let channel = EmbeddedChannel()

        defer {
            XCTAssertTrue(try channel.finish().isClean)
        }

        XCTAssertThrowsError(try channel.pipeline.removeHandler(name: HeadChannelHandler.name).wait()) { error in
            XCTAssertEqual(.notFound, error as? ChannelPipelineError)
        }
        XCTAssertThrowsError(try channel.pipeline.removeHandler(name: TailChannelHandler.name).wait()) { error in
            XCTAssertEqual(.notFound, error as? ChannelPipelineError)
        }
    }

    func testRemovingByContextWithPromiseStillInChannel() throws {
        class NoOpHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never
        }
        class DummyError: Error { }

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            _ = try? channel.finish()
        }

        XCTAssertNoThrow(try channel.pipeline.addHandler(NoOpHandler()).wait())

        let context = try assertNoThrowWithValue(channel.pipeline.context(handlerType: NoOpHandler.self).wait())

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        let removalPromise = channel.eventLoop.makePromise(of: Void.self)
        removalPromise.futureResult.whenSuccess {
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }

        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.removeHandler(context: context, promise: removalPromise)

        XCTAssertNoThrow(try removalPromise.futureResult.wait())
        guard case .some(.byteBuffer(let receivedBuffer)) = try channel.readOutbound(as: IOData.self) else {
            XCTFail("No buffer")
            return
        }
        XCTAssertEqual(receivedBuffer, buffer)

        XCTAssertThrowsError(try channel.throwIfErrorCaught()) { error in
            XCTAssertNotNil(error as? DummyError)
        }
    }

    func testRemovingByContextWithFutureNotInChannel() throws {
        class NoOpHandler: ChannelInboundHandler {
            typealias InboundIn = Never
        }
        class DummyError: Error { }

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            XCTAssertTrue(try channel.finish().isClean)
        }

        XCTAssertNoThrow(try channel.pipeline.addHandler(NoOpHandler()).wait())

        let context = try assertNoThrowWithValue(channel.pipeline.context(handlerType: NoOpHandler.self).wait())

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.removeHandler(context: context).whenSuccess {
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
    }

    func testRemovingByNameWithPromiseStillInChannel() throws {
        class NoOpHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never
        }
        class DummyError: Error { }

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            _ = try? channel.finish()
        }

        XCTAssertNoThrow(try channel.pipeline.addHandler(NoOpHandler(), name: "TestHandler").wait())

        let context = try assertNoThrowWithValue(channel.pipeline.context(handlerType: NoOpHandler.self).wait())

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        let removalPromise = channel.eventLoop.makePromise(of: Void.self)
        removalPromise.futureResult.map {
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }.whenFailure {
            XCTFail("unexpected error: \($0)")
        }

        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.removeHandler(name: "TestHandler", promise: removalPromise)

        XCTAssertNoThrow(XCTAssertEqual(try channel.readOutbound(), buffer))

        XCTAssertThrowsError(try channel.throwIfErrorCaught()) { error in
            XCTAssertNotNil(error as? DummyError)
        }
    }

    func testRemovingByNameWithFutureNotInChannel() throws {
        class NoOpHandler: ChannelInboundHandler {
            typealias InboundIn = Never
        }
        class DummyError: Error { }

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            XCTAssertTrue(try channel.finish().isClean)
        }

        XCTAssertNoThrow(try channel.pipeline.addHandler(NoOpHandler(), name: "TestHandler").wait())

        let context = try assertNoThrowWithValue(channel.pipeline.context(handlerType: NoOpHandler.self).wait())

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.removeHandler(name: "TestHandler").whenSuccess {
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
    }

    func testRemovingByReferenceWithPromiseStillInChannel() throws {
        class NoOpHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never
        }
        class DummyError: Error { }

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            _ = try? channel.finish()
        }

        let handler = NoOpHandler()
        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())

        let context = try assertNoThrowWithValue(channel.pipeline.context(handlerType: NoOpHandler.self).wait())

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        let removalPromise = channel.eventLoop.makePromise(of: Void.self)
        removalPromise.futureResult.whenSuccess {
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }

        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.removeHandler(handler, promise: removalPromise)

        XCTAssertNoThrow(XCTAssertEqual(try channel.readOutbound(), buffer))

        XCTAssertThrowsError(try channel.throwIfErrorCaught()) { error in
            XCTAssertNotNil(error as? DummyError)
        }
    }

    func testRemovingByReferenceWithFutureNotInChannel() throws {
        class NoOpHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never
        }
        class DummyError: Error { }

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            XCTAssertTrue(try channel.finish().isClean)
        }

        let handler = NoOpHandler()
        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())

        let context = try assertNoThrowWithValue(channel.pipeline.context(handlerType: NoOpHandler.self).wait())

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.removeHandler(handler).whenSuccess {
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
    }

    func testFireChannelReadInInactiveChannelDoesNotCrash() throws {
        class FireWhenInactiveHandler: ChannelInboundHandler {
            typealias InboundIn = ()
            typealias InboundOut = ()

            func channelInactive(context: ChannelHandlerContext) {
                context.fireChannelRead(self.wrapInboundOut(()))
            }
        }
        let handler = FireWhenInactiveHandler()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let server = try assertNoThrowWithValue(ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait())
        defer {
            XCTAssertNoThrow(try server.close().wait())
        }
        let client = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }
            .connect(to: server.localAddress!)
            .wait())
        XCTAssertNoThrow(try client.close().wait())
    }

    func testTeardownDuringFormalRemovalProcess() {
        class NeverCompleteRemovalHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never

            private let removalTokenPromise: EventLoopPromise<ChannelHandlerContext.RemovalToken>
            private let handlerRemovedPromise: EventLoopPromise<Void>

            init(removalTokenPromise: EventLoopPromise<ChannelHandlerContext.RemovalToken>,
                 handlerRemovedPromise: EventLoopPromise<Void>) {
                self.removalTokenPromise = removalTokenPromise
                self.handlerRemovedPromise = handlerRemovedPromise
            }

            func handlerRemoved(context: ChannelHandlerContext) {
                self.handlerRemovedPromise.succeed(())
            }

            func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
                self.removalTokenPromise.succeed(removalToken)
            }
        }

        let eventLoop = EmbeddedEventLoop()
        let removalTokenPromise = eventLoop.makePromise(of: ChannelHandlerContext.RemovalToken.self)
        let handlerRemovedPromise = eventLoop.makePromise(of: Void.self)

        let channel = EmbeddedChannel(handler: NeverCompleteRemovalHandler(removalTokenPromise: removalTokenPromise,
                                                                           handlerRemovedPromise: handlerRemovedPromise),
                                      loop: eventLoop)

        // pretend we're real and connect
        XCTAssertNoThrow(try channel.connect(to: .init(ipAddress: "1.2.3.4", port: 5)).wait())

        // let's trigger the removal process
        XCTAssertNoThrow(try channel.pipeline.context(handlerType: NeverCompleteRemovalHandler.self).map { handler in
            channel.pipeline.removeHandler(context: handler, promise: nil)
        }.wait())

        XCTAssertNoThrow(try removalTokenPromise.futureResult.map { removalToken in
            // we know that the removal process has been started, so let's tear down the pipeline
            func workaroundSR9815withAUselessFunction() {
                XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
            }
            workaroundSR9815withAUselessFunction()
        }.wait())

        // verify that the handler has now been removed, despite the fact it should be mid-removal
        XCTAssertNoThrow(try handlerRemovedPromise.futureResult.wait())
    }

    func testVariousChannelRemovalAPIsGoThroughRemovableChannelHandler() {
        class Handler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never

            var removeHandlerCalled = false
            var withinRemoveHandler = false

            func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
                self.removeHandlerCalled = true
                self.withinRemoveHandler = true
                defer {
                    self.withinRemoveHandler = false
                }
                context.leavePipeline(removalToken: removalToken)
            }

            func handlerRemoved(context: ChannelHandlerContext) {
                XCTAssertTrue(self.removeHandlerCalled)
                XCTAssertTrue(self.withinRemoveHandler)
            }
        }

        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
        }
        let allHandlers = [Handler(), Handler(), Handler()]
        XCTAssertNoThrow(try channel.pipeline.addHandler(allHandlers[0], name: "the first one to remove").wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(allHandlers[1]).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(allHandlers[2], name: "the last one to remove").wait())

        let lastContext = try! channel.pipeline.context(name: "the last one to remove").wait()

        XCTAssertNoThrow(try channel.pipeline.removeHandler(name: "the first one to remove").wait())
        XCTAssertNoThrow(try channel.pipeline.removeHandler(allHandlers[1]).wait())
        XCTAssertNoThrow(try channel.pipeline.removeHandler(context: lastContext).wait())

        allHandlers.forEach {
            XCTAssertTrue($0.removeHandlerCalled)
            XCTAssertFalse($0.withinRemoveHandler)
        }
    }

    func testNonRemovableChannelHandlerIsNotRemovable() {
        class NonRemovableHandler: ChannelInboundHandler {
            typealias InboundIn = Never
        }

        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
        }

        let allHandlers = [NonRemovableHandler(), NonRemovableHandler(), NonRemovableHandler()]
        XCTAssertNoThrow(try channel.pipeline.addHandler(allHandlers[0], name: "1").wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(allHandlers[1], name: "2").wait())

        let lastContext = try! channel.pipeline.context(name: "1").wait()

        XCTAssertThrowsError(try channel.pipeline.removeHandler(name: "2").wait()) { error in
            if let error = error as? ChannelError {
                XCTAssertEqual(ChannelError.unremovableHandler, error)
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try channel.pipeline.removeHandler(context: lastContext).wait()) { error in
            if let error = error as? ChannelError {
                XCTAssertEqual(ChannelError.unremovableHandler, error)
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testAddMultipleHandlers() {
        typealias Handler = TestAddMultipleHandlersHandlerWorkingAroundSR9956
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
        }
        let a = Handler()
        let b = Handler()
        let c = Handler()
        let d = Handler()
        let e = Handler()
        let f = Handler()
        let g = Handler()
        let h = Handler()
        let i = Handler()
        let j = Handler()

        XCTAssertNoThrow(try channel.pipeline.addHandler(c).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(h).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandlers([d, e], position: .after(c)).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandlers([f, g], position: .before(h)).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandlers([a, b], position: .first).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandlers([i, j], position: .last).wait())

        Handler.allHandlers = []
        channel.pipeline.fireUserInboundEventTriggered(())

        XCTAssertEqual([a, b, c, d, e, f, g, h, i, j], Handler.allHandlers)
    }
    
    func testPipelineDebugDescription() {
        final class HTTPRequestParser: ChannelInboundHandler {
            typealias InboundIn = Never
        }
        final class HTTPResponseSerializer: ChannelOutboundHandler {
            typealias OutboundIn = Never
        }
        final class HTTPHandler: ChannelDuplexHandler {
            typealias InboundIn = Never
            typealias OutboundIn = Never
        }
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
        }
        let parser = HTTPRequestParser()
        let serializer = HTTPResponseSerializer()
        let handler = HTTPHandler()
        XCTAssertEqual(channel.pipeline.debugDescription, """
        ChannelPipeline[\(ObjectIdentifier(channel.pipeline))]:
         <no handlers>
        """)
        XCTAssertNoThrow(try channel.pipeline.addHandlers([parser, serializer, handler]).wait())
        XCTAssertEqual(channel.pipeline.debugDescription, """
        ChannelPipeline[\(ObjectIdentifier(channel.pipeline))]:
                       [I] ↓↑ [O]
         HTTPRequestParser ↓↑                        [handler0]
                           ↓↑ HTTPResponseSerializer [handler1]
               HTTPHandler ↓↑ HTTPHandler            [handler2]
        """)
    }

    func testWeDontCallHandlerRemovedTwiceIfAHandlerCompletesRemovalOnlyAfterChannelTeardown() {
        enum State: Int {
            // When we start the test,
            case testStarted = 0
            // we send a trigger event,
            case triggerEventRead = 1
            // when receiving the trigger event, we start the manual removal (which won't complete).
            case manualRemovalStarted = 2
            // Instead, we now close the channel to force a pipeline teardown,
            case pipelineTeardown = 3
            // which will make `handlerRemoved` called, from where
            case handlerRemovedCalled = 4
            // we also complete the manual removal.
            case manualRemovalCompleted = 5
            // And hopefully we never reach the error state.
            case error = 999

            mutating func next() {
                if let newState = State(rawValue: self.rawValue + 1) {
                    self = newState
                } else {
                    XCTFail("there's no next state starting from \(self)")
                    self = .error
                }
            }
        }
        class Handler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = State
            typealias InboundOut = State

            private(set) var state: State = .testStarted
            private var removalToken: ChannelHandlerContext.RemovalToken? = nil
            private let allDonePromise: EventLoopPromise<Void>

            init(allDonePromise: EventLoopPromise<Void>) {
                self.allDonePromise = allDonePromise
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let step = self.unwrapInboundIn(data)
                self.state.next()
                XCTAssertEqual(self.state, step)

                // just to communicate to the outside where we are in our state machine
                context.fireChannelRead(self.wrapInboundOut(self.state))

                switch step {
                case .triggerEventRead:
                    // Step 1: Okay, let's kick off the manual removal (it won't complete)
                    context.pipeline.removeHandler(self).map {
                        // When the manual removal completes, we advance the state.
                        self.state.next()
                    }.cascade(to: self.allDonePromise)
                default:
                    XCTFail("channelRead called in state \(self.state)")
                }
            }

            func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
                self.state.next()
                XCTAssertEqual(.manualRemovalStarted, self.state)

                // Step 2: Save the removal token that we got from kicking off the manual removal (in step 1)
                self.removalToken = removalToken
            }

            func handlerRemoved(context: ChannelHandlerContext) {
                self.state.next()
                XCTAssertEqual(.pipelineTeardown, self.state)

                // Step 3: We'll call our own channelRead which will advance the state.
                self.completeTheManualRemoval(context: context)
            }

            func completeTheManualRemoval(context: ChannelHandlerContext) {
                self.state.next()
                XCTAssertEqual(.handlerRemovedCalled, self.state)

                // just to communicate to the outside where we are in our state machine
                context.fireChannelRead(self.wrapInboundOut(self.state))

                // Step 4: This happens when the pipeline is being torn down, so let's now also finish the manual
                // removal process.
                self.removalToken.map(context.leavePipeline(removalToken:))
            }
        }

        let eventLoop = EmbeddedEventLoop()
        let allDonePromise = eventLoop.makePromise(of: Void.self)
        let handler = Handler(allDonePromise: allDonePromise)
        let channel = EmbeddedChannel(handler: handler, loop: eventLoop)
        XCTAssertNoThrow(try channel.connect(to: .init(ipAddress: "1.2.3.4", port: 5)).wait())

        XCTAssertEqual(.testStarted, handler.state)
        XCTAssertNoThrow(try channel.writeInbound(State.triggerEventRead))
        XCTAssertNoThrow(XCTAssertEqual(State.triggerEventRead, try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        XCTAssertNoThrow(try {
            // we'll get a left-over event on close which triggers the pipeline teardown and therefore continues the
            // process.
            switch try channel.finish() {
            case .clean:
                XCTFail("expected output")
            case .leftOvers(inbound: let inbound, outbound: let outbound, pendingOutbound: let pendingOutbound):
                XCTAssertEqual(0, outbound.count)
                XCTAssertEqual(0, pendingOutbound.count)
                XCTAssertEqual(1, inbound.count)
                XCTAssertEqual(.handlerRemovedCalled, inbound.first?.tryAs(type: State.self))
            }
        }())

        XCTAssertEqual(.manualRemovalCompleted, handler.state)

        XCTAssertNoThrow(try allDonePromise.futureResult.wait())
    }

    func testWeFailTheSecondRemoval() {
        final class Handler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never

            private let removalTriggeredPromise: EventLoopPromise<Void>
            private let continueRemovalFuture: EventLoopFuture<Void>
            private var removeHandlerCalls = 0

            init(removalTriggeredPromise: EventLoopPromise<Void>,
                 continueRemovalFuture: EventLoopFuture<Void>) {
                self.removalTriggeredPromise = removalTriggeredPromise
                self.continueRemovalFuture = continueRemovalFuture
            }

            func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
                self.removeHandlerCalls += 1
                XCTAssertEqual(1, self.removeHandlerCalls)
                self.removalTriggeredPromise.succeed(())
                self.continueRemovalFuture.whenSuccess {
                    context.leavePipeline(removalToken: removalToken)
                }
            }
        }

        let channel = EmbeddedChannel()
        let removalTriggeredPromise: EventLoopPromise<Void> = channel.eventLoop.makePromise()
        let continueRemovalPromise: EventLoopPromise<Void> = channel.eventLoop.makePromise()

        let handler = Handler(removalTriggeredPromise: removalTriggeredPromise,
                              continueRemovalFuture: continueRemovalPromise.futureResult)
        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())
        let removal1Future = channel.pipeline.removeHandler(handler)
        XCTAssertThrowsError(try channel.pipeline.removeHandler(handler).wait()) { error in
            XCTAssert(error is NIOAttemptedToRemoveHandlerMultipleTimesError,
                      "unexpected error: \(error)")
        }
        continueRemovalPromise.succeed(())
        XCTAssertThrowsError(try channel.pipeline.removeHandler(handler).wait()) { error in
            XCTAssertEqual(.notFound, error as? ChannelPipelineError, "unexpected error: \(error)")
        }
        XCTAssertNoThrow(try removal1Future.wait())
        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
    }

    func testSynchronousViewAddHandler() throws {
        let channel = EmbeddedChannel()
        let operations = channel.pipeline.syncOperations

        // Add some handlers.
        let handler = IndexWritingHandler(1)
        XCTAssertNoThrow(try operations.addHandler(IndexWritingHandler(2)))
        XCTAssertNoThrow(try operations.addHandler(handler, position: .first))
        XCTAssertNoThrow(try operations.addHandler(IndexWritingHandler(3), position: .after(handler)))
        XCTAssertNoThrow(try operations.addHandler(IndexWritingHandler(4), position: .before(handler)))

        channel.assertReadIndexOrder([4, 1, 3, 2])
        channel.assertWriteIndexOrder([2, 3, 1, 4])
    }

    func testSynchronousViewAddHandlerAfterDestroyed() throws {
        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.finish())

        let operations = channel.pipeline.syncOperations

        XCTAssertThrowsError(try operations.addHandler(SimpleTypedHandler1())) { error in
            XCTAssertEqual(error as? ChannelError, .ioOnClosedChannel)
        }

        // The same for 'addHandlers'.
        XCTAssertThrowsError(try operations.addHandlers([SimpleTypedHandler1()])) { error in
            XCTAssertEqual(error as? ChannelError, .ioOnClosedChannel)
        }
    }

    func testSynchronousViewAddHandlers() throws {
        let channel = EmbeddedChannel()
        let operations = channel.pipeline.syncOperations

        // Add some handlers.
        let firstHandler = IndexWritingHandler(1)
        XCTAssertNoThrow(try operations.addHandler(firstHandler))
        XCTAssertNoThrow(try operations.addHandlers(IndexWritingHandler(2), IndexWritingHandler(3)))
        XCTAssertNoThrow(try operations.addHandlers([IndexWritingHandler(4), IndexWritingHandler(5)], position: .before(firstHandler)))

        channel.assertReadIndexOrder([4, 5, 1, 2, 3])
        channel.assertWriteIndexOrder([3, 2, 1, 5, 4])
    }

    func testSynchronousViewContext() throws {
        let channel = EmbeddedChannel()
        let operations = channel.pipeline.syncOperations

        let simpleTypedHandler1 = SimpleTypedHandler1()
        // Add some handlers.
        XCTAssertNoThrow(try operations.addHandler(simpleTypedHandler1))
        XCTAssertNoThrow(try operations.addHandler(SimpleTypedHandler2(), name: "simple-2"))
        XCTAssertNoThrow(try operations.addHandler(SimpleTypedHandler3()))

        // Get contexts using different predicates.

        // By identity.
        let simpleTypedHandler1Context = try assertNoThrowWithValue(operations.context(handler: simpleTypedHandler1))
        XCTAssertTrue(simpleTypedHandler1Context.handler === simpleTypedHandler1)

        // By name.
        let simpleTypedHandler2Context = try assertNoThrowWithValue(operations.context(name: "simple-2"))
        XCTAssertTrue(simpleTypedHandler2Context.handler is SimpleTypedHandler2)

        // By type.
        let simpleTypedHandler3Context = try assertNoThrowWithValue(operations.context(handlerType: SimpleTypedHandler3.self))
        XCTAssertTrue(simpleTypedHandler3Context.handler is SimpleTypedHandler3)
    }

    func testSynchronousViewGetTypedHandler() throws {
        let channel = EmbeddedChannel()
        let operations = channel.pipeline.syncOperations

        let simpleTypedHandler1 = SimpleTypedHandler1()
        let simpleTypedHandler2 = SimpleTypedHandler2()
        // Add some handlers.
        XCTAssertNoThrow(try operations.addHandler(simpleTypedHandler1))
        XCTAssertNoThrow(try operations.addHandler(simpleTypedHandler2))

        let handler1 = try assertNoThrowWithValue(try operations.handler(type: SimpleTypedHandler1.self))
        XCTAssertTrue(handler1 === simpleTypedHandler1)

        let handler2 = try assertNoThrowWithValue(try operations.handler(type: SimpleTypedHandler2.self))
        XCTAssertTrue(handler2 === simpleTypedHandler2)
    }

    func testSynchronousViewPerformOperations() throws {
        struct MyError: Error { }

        let eventCounter = EventCounterHandler()
        let channel = EmbeddedChannel(handler: eventCounter)

        let operations = channel.pipeline.syncOperations
        XCTAssertEqual(eventCounter.allTriggeredEvents(), ["register", "channelRegistered"])

        // First do all the outbounds except close().
        operations.register(promise: nil)
        operations.bind(to: try! SocketAddress(ipAddress: "127.0.0.1", port: 80), promise: nil)
        operations.connect(to: try! SocketAddress(ipAddress: "127.0.0.1", port: 80), promise: nil)
        operations.triggerUserOutboundEvent("event", promise: nil)
        operations.write(NIOAny(ByteBuffer()), promise: nil)
        operations.flush()
        operations.writeAndFlush(NIOAny(ByteBuffer()), promise: nil)
        operations.read()

        XCTAssertEqual(eventCounter.bindCalls, 1)
        XCTAssertEqual(eventCounter.channelActiveCalls, 1)
        XCTAssertEqual(eventCounter.channelInactiveCalls, 0)
        XCTAssertEqual(eventCounter.channelReadCalls, 0)
        XCTAssertEqual(eventCounter.channelReadCompleteCalls, 0)
        XCTAssertEqual(eventCounter.channelRegisteredCalls, 2) // EmbeddedChannel itself does one, we did the other.
        XCTAssertEqual(eventCounter.channelUnregisteredCalls, 0)
        XCTAssertEqual(eventCounter.channelWritabilityChangedCalls, 0)
        XCTAssertEqual(eventCounter.closeCalls, 0)
        XCTAssertEqual(eventCounter.connectCalls, 1)
        XCTAssertEqual(eventCounter.errorCaughtCalls, 0)
        XCTAssertEqual(eventCounter.flushCalls, 2)  // flush, and writeAndFlush
        XCTAssertEqual(eventCounter.readCalls, 1)
        XCTAssertEqual(eventCounter.registerCalls, 2) // EmbeddedChannel itself does one, we did the other.
        XCTAssertEqual(eventCounter.triggerUserOutboundEventCalls, 1)
        XCTAssertEqual(eventCounter.userInboundEventTriggeredCalls, 0)
        XCTAssertEqual(eventCounter.writeCalls, 2)  // write, and writeAndFlush

        // Now the inbound methods.
        operations.fireChannelRegistered()
        operations.fireChannelUnregistered()
        operations.fireUserInboundEventTriggered("event")
        operations.fireChannelActive()
        operations.fireChannelInactive()
        operations.fireChannelRead(NIOAny(ByteBuffer()))
        operations.fireChannelReadComplete()
        operations.fireChannelWritabilityChanged()
        operations.fireErrorCaught(MyError())

        // And now close
        operations.close(promise: nil)

        XCTAssertEqual(eventCounter.bindCalls, 1)
        XCTAssertEqual(eventCounter.channelActiveCalls, 2)
        XCTAssertEqual(eventCounter.channelInactiveCalls, 2)  // EmbeddedChannel itself does one, we did the other.
        XCTAssertEqual(eventCounter.channelReadCalls, 1)
        XCTAssertEqual(eventCounter.channelReadCompleteCalls, 1)
        XCTAssertEqual(eventCounter.channelRegisteredCalls, 3)  // EmbeddedChannel itself does one, we did the other two.
        XCTAssertEqual(eventCounter.channelUnregisteredCalls, 2)  // EmbeddedChannel itself does one, we did the other.
        XCTAssertEqual(eventCounter.channelWritabilityChangedCalls, 1)
        XCTAssertEqual(eventCounter.closeCalls, 1)
        XCTAssertEqual(eventCounter.connectCalls, 1)
        XCTAssertEqual(eventCounter.errorCaughtCalls, 1)
        XCTAssertEqual(eventCounter.flushCalls, 2)   // flush, and writeAndFlush
        XCTAssertEqual(eventCounter.readCalls, 1)
        XCTAssertEqual(eventCounter.registerCalls, 2)  // EmbeddedChannel itself does one, we did the other.
        XCTAssertEqual(eventCounter.triggerUserOutboundEventCalls, 1)
        XCTAssertEqual(eventCounter.userInboundEventTriggeredCalls, 1)
        XCTAssertEqual(eventCounter.writeCalls, 2)  // write, and writeAndFlush
    }
}

// this should be within `testAddMultipleHandlers` but https://bugs.swift.org/browse/SR-9956
final class TestAddMultipleHandlersHandlerWorkingAroundSR9956: ChannelDuplexHandler, Equatable {
    typealias InboundIn = Never
    typealias OutboundIn = Never

    static var allHandlers: [TestAddMultipleHandlersHandlerWorkingAroundSR9956] = []

    init() {}

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        TestAddMultipleHandlersHandlerWorkingAroundSR9956.allHandlers.append(self)
        context.fireUserInboundEventTriggered(event)
    }

    public static func == (lhs: TestAddMultipleHandlersHandlerWorkingAroundSR9956,
                           rhs: TestAddMultipleHandlersHandlerWorkingAroundSR9956) -> Bool {
        return lhs === rhs
    }
}
