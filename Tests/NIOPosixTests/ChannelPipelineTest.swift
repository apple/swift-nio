//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import CNIOLinux
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOPosix
import NIOTestUtils
import XCTest

@testable import NIOCore

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
        var buf = Self.unwrapInboundIn(data)
        buf.writeInteger(UInt8(self.index))
        context.fireChannelRead(Self.wrapInboundOut(buf))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buf = Self.unwrapOutboundIn(data)
        buf.writeInteger(UInt8(self.index))
        context.write(Self.wrapOutboundOut(buf), promise: promise)
    }
}

extension EmbeddedChannel {
    fileprivate func assertReadIndexOrder(_ order: [UInt8]) {
        XCTAssertTrue(try self.writeInbound(self.allocator.buffer(capacity: 32)).isFull)
        XCTAssertNoThrow(
            XCTAssertEqual(
                order,
                try self.readInbound(as: ByteBuffer.self).flatMap { buffer in
                    var buffer = buffer
                    return buffer.readBytes(length: buffer.readableBytes)
                }
            )
        )
    }

    fileprivate func assertWriteIndexOrder(_ order: [UInt8]) {
        XCTAssertTrue(try self.writeOutbound(self.allocator.buffer(capacity: 32)).isFull)
        XCTAssertNoThrow(
            XCTAssertEqual(
                order,
                try self.readOutbound(as: ByteBuffer.self).flatMap { buffer in
                    var buffer = buffer
                    return buffer.readBytes(length: buffer.readableBytes)
                }
            )
        )
    }
}

class ChannelPipelineTest: XCTestCase {

    final class SimpleTypedHandler1: ChannelInboundHandler, Sendable {
        typealias InboundIn = NIOAny
    }
    final class SimpleTypedHandler2: ChannelInboundHandler, Sendable {
        typealias InboundIn = NIOAny
    }
    final class SimpleTypedHandler3: ChannelInboundHandler, Sendable {
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
            handler3,
        ]).wait()

        let result1 = try channel.pipeline.handler(type: SimpleTypedHandler1.self).wait()
        XCTAssertTrue(result1 === handler1)

        let result2 = try channel.pipeline.handler(type: SimpleTypedHandler2.self).wait()
        XCTAssertTrue(result2 === handler2)

        let result3 = try channel.pipeline.handler(type: SimpleTypedHandler3.self).wait()
        XCTAssertTrue(result3 === handler3)
    }

    func testContainsHandler() throws {
        let handler1 = SimpleTypedHandler1()
        let handler2 = SimpleTypedHandler2()

        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }
        try channel.pipeline.syncOperations.addHandler(handler1)
        try channel.pipeline.syncOperations.addHandler(handler2, name: "Handler2")

        try channel.pipeline.containsHandler(type: SimpleTypedHandler1.self).wait()
        try channel.pipeline.containsHandler(name: "Handler2").wait()
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
            otherHandler,
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

        XCTAssertThrowsError(try channel.pipeline.handler(type: SimpleTypedHandler3.self).wait()) {
            XCTAssertTrue($0 is ChannelPipelineError)
        }
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
        XCTAssertThrowsError(try channel.pipeline.syncOperations.addHandler(handler)) { error in
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

        try channel.pipeline.syncOperations.addHandler(
            TestChannelOutboundHandler<Int, ByteBuffer> { data in
                XCTAssertEqual(1, data)
                return buf
            }
        )

        try channel.pipeline.syncOperations.addHandler(
            TestChannelOutboundHandler<String, Int> { data in
                XCTAssertEqual("msg", data)
                return 1
            }
        )

        XCTAssertNoThrow(try channel.writeAndFlush("msg").wait() as Void)
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

        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(NoBindAllowed()))
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(
                TestChannelOutboundHandler<ByteBuffer, ByteBuffer> { data in
                    data
                }
            )
        )

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
                context.write(Self.wrapOutboundOut(try body(Self.unwrapOutboundIn(data))), promise: promise)
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
            context.fireChannelRead(Self.wrapInboundOut(1))
        }
    }

    func testFiringChannelReadsInHandlerRemovedWorks() throws {
        let channel = EmbeddedChannel()

        let h = FireChannelReadOnRemoveHandler()
        try channel.pipeline.syncOperations.addHandler(h)
        try channel.pipeline.syncOperations.removeHandler(h).wait()

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
            let handle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: -1)
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
                let data = Self.unwrapInboundIn(data)
                context.fireChannelRead(Self.wrapInboundOut(data + [self.no]))
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
                let data = Self.unwrapOutboundIn(data)
                context.write(Self.wrapOutboundOut(data + [self.no]), promise: promise)
            }
        }

        /// This handler multiplies the inbound `[Int]` it receives by `-1` and writes it to the next outbound handler.
        final class WriteOnReadHandler: ChannelInboundHandler {
            typealias InboundIn = [Int]
            typealias InboundOut = [Int]
            typealias OutboundOut = [Int]

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let data = Self.unwrapInboundIn(data)
                context.writeAndFlush(Self.wrapOutboundOut(data.map { $0 * -1 }), promise: nil)
                context.fireChannelRead(Self.wrapInboundOut(data))
            }
        }

        /// This handler just prints out the outbound received `[Int]` as a `ByteBuffer`.
        final class PrintOutboundAsByteBufferHandler: ChannelOutboundHandler {
            typealias OutboundIn = [Int]
            typealias OutboundOut = ByteBuffer

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                let data = Self.unwrapOutboundIn(data)
                var buf = context.channel.allocator.buffer(capacity: 123)
                buf.writeString(String(describing: data))
                context.write(Self.wrapOutboundOut(buf), promise: promise)
            }
        }

        let channel = EmbeddedChannel()
        let loop = channel.embeddedEventLoop
        loop.run()

        try channel.pipeline.syncOperations.addHandler(PrintOutboundAsByteBufferHandler())
        try channel.pipeline.syncOperations.addHandler(MarkingInboundHandler(number: 2))
        try channel.pipeline.syncOperations.addHandler(WriteOnReadHandler())
        try channel.pipeline.syncOperations.addHandler(MarkingOutboundHandler(number: 4))
        try channel.pipeline.syncOperations.addHandler(WriteOnReadHandler())
        try channel.pipeline.syncOperations.addHandler(MarkingInboundHandler(number: 6))
        try channel.pipeline.syncOperations.addHandler(WriteOnReadHandler())

        try channel.writeInbound([Int]())
        loop.run()
        XCTAssertNoThrow(XCTAssertEqual([2, 6], try channel.readInbound()!))

        // the first thing, we should receive is `[-2]` as it shouldn't hit any `MarkingOutboundHandler`s (`4`)
        var outbound = try channel.readOutbound(as: ByteBuffer.self)
        if var buf = outbound {
            XCTAssertEqual("[-2]", buf.readString(length: buf.readableBytes))
        } else {
            XCTFail("wrong contents: \(outbound.debugDescription)")
        }

        // the next thing we should receive is `[-2, 4]` as the first `WriteOnReadHandler` (receiving `[2]`) is behind the `MarkingOutboundHandler` (`4`)
        outbound = try channel.readOutbound()
        if var buf = outbound {
            XCTAssertEqual("[-2, 4]", buf.readString(length: buf.readableBytes))
        } else {
            XCTFail("wrong contents: \(outbound.debugDescription)")
        }

        // and finally, we're waiting for `[-2, -6, 4]` as the second `WriteOnReadHandler`s (receiving `[2, 4]`) is behind the `MarkingOutboundHandler` (`4`)
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

            ()  // needed because Swift's grammar is so ambiguous that you can't remove this :\

            try {
                let handler1 = SomeHandler { context in
                    weakHandlerContext1 = context
                }
                weakHandler1 = handler1
                let handler2 = SomeHandler { context in
                    weakHandlerContext2 = context
                }
                weakHandler2 = handler2
                XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler1))
                XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler2))
            }()

            XCTAssertNotNil(weakHandler1)
            XCTAssertNotNil(weakHandler2)
            XCTAssertNotNil(weakHandlerContext1)
            XCTAssertNotNil(weakHandlerContext2)

            XCTAssertNoThrow(try channel.pipeline.syncOperations.removeHandler(weakHandler1!).wait())

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
                    context.fireChannelRead(Self.wrapInboundOut(dataString.count))
                }
            }
        }

        final class TransformByteBufferToStringHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = String

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                if var buffer = data.tryAs(type: ByteBuffer.self) {
                    context.fireChannelRead(Self.wrapInboundOut(buffer.readString(length: buffer.readableBytes)!))
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

        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(countHandler))
        XCTAssertTrue(try channel.writeInbound(buffer).isEmpty)
        XCTAssertEqual(countHandler.intReadCount, 0)

        try channel.pipeline.syncOperations.addHandlers(
            TransformByteBufferToStringHandler(),
            TransformStringToIntHandler(),
            position: .first
        )
        XCTAssertTrue(try channel.writeInbound(buffer).isEmpty)
        XCTAssertEqual(countHandler.intReadCount, 1)
    }

    func testAddAfter() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let firstHandler = IndexWritingHandler(1)
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(firstHandler))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(IndexWritingHandler(2)))
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(
                IndexWritingHandler(3),
                position: .after(firstHandler)
            )
        )

        channel.assertReadIndexOrder([1, 3, 2])
        channel.assertWriteIndexOrder([2, 3, 1])
    }

    func testAddBefore() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let secondHandler = IndexWritingHandler(2)
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(IndexWritingHandler(1)))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(secondHandler))
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(
                IndexWritingHandler(3),
                position: .before(secondHandler)
            )
        )

        channel.assertReadIndexOrder([1, 3, 2])
        channel.assertWriteIndexOrder([2, 3, 1])
    }

    func testAddAfterLast() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let secondHandler = IndexWritingHandler(2)
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(IndexWritingHandler(1)))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(secondHandler))
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(
                IndexWritingHandler(3),
                position: .after(secondHandler)
            )
        )

        channel.assertReadIndexOrder([1, 2, 3])
        channel.assertWriteIndexOrder([3, 2, 1])
    }

    func testAddBeforeFirst() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let firstHandler = IndexWritingHandler(1)
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(firstHandler))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(IndexWritingHandler(2)))
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(
                IndexWritingHandler(3),
                position: .before(firstHandler)
            )
        )

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
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler))
        XCTAssertNoThrow(try channel.close().wait())
        channel.embeddedEventLoop.run()

        XCTAssertThrowsError(
            try channel.pipeline.syncOperations.addHandler(
                IndexWritingHandler(2),
                position: .after(handler)
            )
        ) { error in
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
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler))
        XCTAssertNoThrow(try channel.close().wait())
        channel.embeddedEventLoop.run()

        XCTAssertThrowsError(
            try channel.pipeline.syncOperations.addHandler(
                IndexWritingHandler(2),
                position: .before(handler)
            )
        ) { error in
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
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(h1))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(h2))

        XCTAssertTrue(try h1 === channel.pipeline.syncOperations.context(handlerType: TypeAHandler.self).handler)
        XCTAssertTrue(try h2 === channel.pipeline.syncOperations.context(handlerType: TypeBHandler.self).handler)

        XCTAssertThrowsError(try channel.pipeline.syncOperations.context(handlerType: TypeCHandler.self)) { error in
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
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(h1))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(h2))

        XCTAssertTrue(try h1 === channel.pipeline.syncOperations.context(handlerType: TestHandler.self).handler)
        XCTAssertFalse(try h2 === channel.pipeline.syncOperations.context(handlerType: TestHandler.self).handler)
    }

    func testContextForHeadOrTail() throws {
        let channel = EmbeddedChannel()

        defer {
            XCTAssertTrue(try channel.finish().isClean)
        }

        XCTAssertThrowsError(try channel.pipeline.syncOperations.context(name: HeadChannelHandler.name)) { error in
            XCTAssertEqual(.notFound, error as? ChannelPipelineError)
        }

        XCTAssertThrowsError(try channel.pipeline.syncOperations.context(handlerType: HeadChannelHandler.self)) {
            error in
            XCTAssertEqual(.notFound, error as? ChannelPipelineError)
        }

        XCTAssertThrowsError(try channel.pipeline.syncOperations.context(name: TailChannelHandler.name)) { error in
            XCTAssertEqual(.notFound, error as? ChannelPipelineError)
        }

        XCTAssertThrowsError(try channel.pipeline.syncOperations.context(handlerType: TailChannelHandler.self)) {
            error in
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
        struct DummyError: Error {}

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            _ = try? channel.finish()
        }

        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(NoOpHandler()))

        let context = try assertNoThrowWithValue(channel.pipeline.syncOperations.context(handlerType: NoOpHandler.self))

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        let removalPromise = channel.eventLoop.makePromise(of: Void.self)
        let loopBoundContext = context.loopBound
        removalPromise.futureResult.assumeIsolated().whenSuccess {
            let context = loopBoundContext.value
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }

        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.syncOperations.removeHandler(context: context, promise: removalPromise)

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
        final class NoOpHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = Never
        }
        struct DummyError: Error {}

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            XCTAssertTrue(try channel.finish().isClean)
        }

        XCTAssertNoThrow(try channel.pipeline.addHandler(NoOpHandler()).wait())

        let context = try assertNoThrowWithValue(channel.pipeline.syncOperations.context(handlerType: NoOpHandler.self))

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        let loopBoundContext = context.loopBound
        channel.pipeline.syncOperations.removeHandler(context: context).assumeIsolated().whenSuccess {
            let context = loopBoundContext.value
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
        struct DummyError: Error {}

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            _ = try? channel.finish()
        }

        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(NoOpHandler(), name: "TestHandler"))

        let context = try assertNoThrowWithValue(channel.pipeline.syncOperations.context(handlerType: NoOpHandler.self))

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        let removalPromise = channel.eventLoop.makePromise(of: Void.self)
        let loopBoundContext = context.loopBound
        removalPromise.futureResult.assumeIsolated().map {
            let context = loopBoundContext._value
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
        struct DummyError: Error {}

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            XCTAssertTrue(try channel.finish().isClean)
        }

        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(NoOpHandler(), name: "TestHandler"))

        let context = try assertNoThrowWithValue(channel.pipeline.syncOperations.context(handlerType: NoOpHandler.self))

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        let loopBoundContext = context.loopBound
        channel.pipeline.removeHandler(name: "TestHandler").assumeIsolated().whenSuccess {
            let context = loopBoundContext.value
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
        struct DummyError: Error {}

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            _ = try? channel.finish()
        }

        let handler = NoOpHandler()
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler))

        let context = try assertNoThrowWithValue(channel.pipeline.syncOperations.context(handlerType: NoOpHandler.self))

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        let removalPromise = channel.eventLoop.makePromise(of: Void.self)
        let loopBoundContext = context.loopBound
        removalPromise.futureResult.assumeIsolated().whenSuccess {
            let context = loopBoundContext.value
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }

        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.syncOperations.removeHandler(handler, promise: removalPromise)

        XCTAssertNoThrow(XCTAssertEqual(try channel.readOutbound(), buffer))

        XCTAssertThrowsError(try channel.throwIfErrorCaught()) { error in
            XCTAssertNotNil(error as? DummyError)
        }
    }

    func testRemovingByReferenceWithFutureNotInChannel() throws {
        class NoOpHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never
        }
        struct DummyError: Error {}

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            XCTAssertTrue(try channel.finish().isClean)
        }

        let handler = NoOpHandler()
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler))

        let context = try assertNoThrowWithValue(channel.pipeline.syncOperations.context(handlerType: NoOpHandler.self))

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        let loopBoundContext = context.loopBound
        channel.pipeline.syncOperations.removeHandler(handler).assumeIsolated().whenSuccess {
            let context = loopBoundContext.value
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
    }

    func testFireChannelReadInInactiveChannelDoesNotCrash() throws {
        final class FireWhenInactiveHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = ()
            typealias InboundOut = ()

            func channelInactive(context: ChannelHandlerContext) {
                context.fireChannelRead(Self.wrapInboundOut(()))
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
        let client = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(handler)
                }
                .connect(to: server.localAddress!)
                .wait()
        )
        XCTAssertNoThrow(try client.close().wait())
    }

    func testTeardownDuringFormalRemovalProcess() {
        class NeverCompleteRemovalHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never

            private let removalTokenPromise: EventLoopPromise<ChannelHandlerContext.RemovalToken>
            private let handlerRemovedPromise: EventLoopPromise<Void>

            init(
                removalTokenPromise: EventLoopPromise<ChannelHandlerContext.RemovalToken>,
                handlerRemovedPromise: EventLoopPromise<Void>
            ) {
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

        let channel = EmbeddedChannel(
            handler: NeverCompleteRemovalHandler(
                removalTokenPromise: removalTokenPromise,
                handlerRemovedPromise: handlerRemovedPromise
            ),
            loop: eventLoop
        )

        // pretend we're real and connect
        XCTAssertNoThrow(try channel.connect(to: .init(ipAddress: "1.2.3.4", port: 5)).wait())

        // let's trigger the removal process
        XCTAssertNoThrow(
            try channel.pipeline.context(handlerType: NeverCompleteRemovalHandler.self).map { handler in
                channel.pipeline.syncOperations.removeHandler(context: handler, promise: nil)
            }.wait()
        )

        XCTAssertNoThrow(
            try removalTokenPromise.futureResult.map { removalToken in
                // we know that the removal process has been started, so let's tear down the pipeline
                func workaroundSR9815withAUselessFunction() {
                    XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
                }
                workaroundSR9815withAUselessFunction()
            }.wait()
        )

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
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(allHandlers[0], name: "the first one to remove")
        )
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(allHandlers[1]))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(allHandlers[2], name: "the last one to remove"))

        let lastContext = try! channel.pipeline.syncOperations.context(name: "the last one to remove")

        XCTAssertNoThrow(try channel.pipeline.removeHandler(name: "the first one to remove").wait())
        XCTAssertNoThrow(try channel.pipeline.syncOperations.removeHandler(allHandlers[1]).wait())
        XCTAssertNoThrow(try channel.pipeline.syncOperations.removeHandler(context: lastContext).wait())

        for handler in allHandlers {
            XCTAssertTrue(handler.removeHandlerCalled)
            XCTAssertFalse(handler.withinRemoveHandler)
        }
    }

    func testRemovingByContexSync() throws {
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
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(allHandlers[0], name: "the first one to remove")
        )
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(allHandlers[1], name: "the second one to remove")
        )
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(allHandlers[2], name: "the last one to remove"))

        let firstContext = try! channel.pipeline.syncOperations.context(name: "the first one to remove")
        let secondContext = try! channel.pipeline.syncOperations.context(name: "the second one to remove")
        let lastContext = try! channel.pipeline.syncOperations.context(name: "the last one to remove")

        XCTAssertNoThrow(try channel.pipeline.syncOperations.removeHandler(context: firstContext).wait())
        XCTAssertNoThrow(try channel.pipeline.syncOperations.removeHandler(context: secondContext).wait())
        XCTAssertNoThrow(try channel.pipeline.syncOperations.removeHandler(context: lastContext).wait())

        for handler in allHandlers {
            XCTAssertTrue(handler.removeHandlerCalled)
            XCTAssertFalse(handler.withinRemoveHandler)
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
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(allHandlers[0], name: "1"))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(allHandlers[1], name: "2"))

        let lastContext = try! channel.pipeline.syncOperations.context(name: "1")

        XCTAssertThrowsError(try channel.pipeline.removeHandler(name: "2").wait()) { error in
            if let error = error as? ChannelError {
                XCTAssertEqual(ChannelError.unremovableHandler, error)
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try channel.pipeline.syncOperations.removeHandler(context: lastContext).wait()) { error in
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

        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(c))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(h))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandlers([d, e], position: .after(c)))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandlers([f, g], position: .before(h)))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandlers([a, b], position: .first))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandlers([i, j], position: .last))

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
        XCTAssertEqual(
            channel.pipeline.debugDescription,
            """
            ChannelPipeline[\(ObjectIdentifier(channel.pipeline))]:
             <no handlers>
            """
        )
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandlers([parser, serializer, handler]))
        XCTAssertEqual(
            channel.pipeline.debugDescription,
            """
            ChannelPipeline[\(ObjectIdentifier(channel.pipeline))]:
                           [I] ↓↑ [O]
             HTTPRequestParser ↓↑                        [handler0]
                               ↓↑ HTTPResponseSerializer [handler1]
                   HTTPHandler ↓↑ HTTPHandler            [handler2]
            """
        )
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
                let step = Self.unwrapInboundIn(data)
                self.state.next()
                XCTAssertEqual(self.state, step)

                // just to communicate to the outside where we are in our state machine
                context.fireChannelRead(Self.wrapInboundOut(self.state))

                switch step {
                case .triggerEventRead:
                    // Step 1: Okay, let's kick off the manual removal (it won't complete)
                    context.pipeline.syncOperations.removeHandler(self).assumeIsolated().map {
                        // When the manual removal completes, we advance the state.
                        self.state.next()
                    }.nonisolated().cascade(to: self.allDonePromise)
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
                context.fireChannelRead(Self.wrapInboundOut(self.state))

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

        XCTAssertNoThrow(
            try {
                // we'll get a left-over event on close which triggers the pipeline teardown and therefore continues the
                // process.
                switch try channel.finish() {
                case .clean:
                    XCTFail("expected output")
                case .leftOvers(let inbound, let outbound, let pendingOutbound):
                    XCTAssertEqual(0, outbound.count)
                    XCTAssertEqual(0, pendingOutbound.count)
                    XCTAssertEqual(1, inbound.count)
                    XCTAssertEqual(.handlerRemovedCalled, inbound.first?.tryAs(type: State.self))
                }
            }()
        )

        XCTAssertEqual(.manualRemovalCompleted, handler.state)

        XCTAssertNoThrow(try allDonePromise.futureResult.wait())
    }

    func testWeFailTheSecondRemoval() {
        final class Handler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never

            private let removalTriggeredPromise: EventLoopPromise<Void>
            private let continueRemovalFuture: EventLoopFuture<Void>
            private var removeHandlerCalls = 0

            init(
                removalTriggeredPromise: EventLoopPromise<Void>,
                continueRemovalFuture: EventLoopFuture<Void>
            ) {
                self.removalTriggeredPromise = removalTriggeredPromise
                self.continueRemovalFuture = continueRemovalFuture
            }

            func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
                self.removeHandlerCalls += 1
                XCTAssertEqual(1, self.removeHandlerCalls)
                self.removalTriggeredPromise.succeed(())
                let loopBoundContext = context.loopBound
                self.continueRemovalFuture.whenSuccess {
                    let context = loopBoundContext.value
                    context.leavePipeline(removalToken: removalToken)
                }
            }
        }

        let channel = EmbeddedChannel()
        let removalTriggeredPromise: EventLoopPromise<Void> = channel.eventLoop.makePromise()
        let continueRemovalPromise: EventLoopPromise<Void> = channel.eventLoop.makePromise()

        let handler = Handler(
            removalTriggeredPromise: removalTriggeredPromise,
            continueRemovalFuture: continueRemovalPromise.futureResult
        )
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler))
        let removal1Future = channel.pipeline.syncOperations.removeHandler(handler)
        XCTAssertThrowsError(try channel.pipeline.syncOperations.removeHandler(handler).wait()) { error in
            XCTAssert(
                error is NIOAttemptedToRemoveHandlerMultipleTimesError,
                "unexpected error: \(error)"
            )
        }
        continueRemovalPromise.succeed(())
        XCTAssertThrowsError(try channel.pipeline.syncOperations.removeHandler(handler).wait()) { error in
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
        XCTAssertNoThrow(
            try operations.addHandlers(
                [IndexWritingHandler(4), IndexWritingHandler(5)],
                position: .before(firstHandler)
            )
        )

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
        let simpleTypedHandler3Context = try assertNoThrowWithValue(
            operations.context(handlerType: SimpleTypedHandler3.self)
        )
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
        struct MyError: Error {}

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
        XCTAssertEqual(eventCounter.channelRegisteredCalls, 2)  // EmbeddedChannel itself does one, we did the other.
        XCTAssertEqual(eventCounter.channelUnregisteredCalls, 0)
        XCTAssertEqual(eventCounter.channelWritabilityChangedCalls, 0)
        XCTAssertEqual(eventCounter.closeCalls, 0)
        XCTAssertEqual(eventCounter.connectCalls, 1)
        XCTAssertEqual(eventCounter.errorCaughtCalls, 0)
        XCTAssertEqual(eventCounter.flushCalls, 2)  // flush, and writeAndFlush
        XCTAssertEqual(eventCounter.readCalls, 1)
        XCTAssertEqual(eventCounter.registerCalls, 2)  // EmbeddedChannel itself does one, we did the other.
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

        // EmbeddedChannel itself does one, we did the other.
        XCTAssertEqual(eventCounter.bindCalls, 1)
        XCTAssertEqual(eventCounter.channelActiveCalls, 2)
        XCTAssertEqual(eventCounter.channelInactiveCalls, 2)
        XCTAssertEqual(eventCounter.channelReadCalls, 1)
        XCTAssertEqual(eventCounter.channelReadCompleteCalls, 1)
        // EmbeddedChannel itself does one, we did the other two.
        XCTAssertEqual(eventCounter.channelRegisteredCalls, 3)
        // EmbeddedChannel itself does one, we did the other.
        XCTAssertEqual(eventCounter.channelUnregisteredCalls, 2)
        XCTAssertEqual(eventCounter.channelWritabilityChangedCalls, 1)
        XCTAssertEqual(eventCounter.closeCalls, 1)
        XCTAssertEqual(eventCounter.connectCalls, 1)
        XCTAssertEqual(eventCounter.errorCaughtCalls, 1)
        XCTAssertEqual(eventCounter.flushCalls, 2)  // flush, and writeAndFlush
        XCTAssertEqual(eventCounter.readCalls, 1)
        // EmbeddedChannel itself does one, we did the other.
        XCTAssertEqual(eventCounter.registerCalls, 2)
        XCTAssertEqual(eventCounter.triggerUserOutboundEventCalls, 1)
        XCTAssertEqual(eventCounter.userInboundEventTriggeredCalls, 1)
        XCTAssertEqual(eventCounter.writeCalls, 2)  // write, and writeAndFlush
    }

    func testRetrieveInboundBufferedBytesFromChannelWithZeroHandler() throws {
        let channel = EmbeddedChannel()

        let data = ByteBuffer(string: "1234")
        for _ in 1...5 {
            try channel.writeInbound(data)
            let bufferedBytes = try channel.pipeline.inboundBufferedBytes().wait()
            XCTAssertEqual(bufferedBytes, 0)
        }

        for _ in 1...5 {
            _ = try channel.readInbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testRetrieveOutboundBufferedBytesFromChannelWithZeroHandler() throws {
        let channel = EmbeddedChannel()

        let data = ByteBuffer(string: "1234")
        for _ in 1...5 {
            try channel.writeOutbound(data)
            let bufferedBytes = try channel.pipeline.outboundBufferedBytes().wait()
            XCTAssertEqual(bufferedBytes, 0)
        }

        for _ in 1...5 {
            _ = try channel.readOutbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testRetrieveInboundBufferedBytesFromChannelWithOneHandler() throws {
        class InboundBufferHandler: ChannelInboundHandler, NIOInboundByteBufferingChannelHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            private var buffer = ByteBuffer()

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                buffer.writeImmutableBuffer(self.unwrapInboundIn(data))
            }

            var inboundBufferedBytes: Int {
                self.buffer.readableBytes
            }
        }

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandlers([InboundBufferHandler()])

        let data = ByteBuffer(string: "1234")
        for cnt in 1...5 {
            try channel.writeInbound(data)
            let bufferedBytes = try channel.pipeline.inboundBufferedBytes().wait()
            XCTAssertEqual(bufferedBytes, cnt * data.readableBytes)
        }

        for _ in 1...5 {
            _ = try channel.readInbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testRetrieveOutboundBufferedBytesFromChannelWithOneHandler() throws {
        class OutboundBufferHandler: ChannelOutboundHandler, NIOOutboundByteBufferingChannelHandler {
            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            private var buffer = ByteBuffer()

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                buffer.writeImmutableBuffer(self.unwrapOutboundIn(data))
                promise?.succeed()
            }

            var outboundBufferedBytes: Int {
                self.buffer.readableBytes
            }
        }

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandlers([OutboundBufferHandler()])

        let data = ByteBuffer(string: "1234")
        for cnt in 1...5 {
            try channel.writeOutbound(data)
            let bufferedBytes = try channel.pipeline.outboundBufferedBytes().wait()
            XCTAssertEqual(bufferedBytes, cnt * data.readableBytes)
        }

        for _ in 1...5 {
            _ = try channel.readOutbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testRetrieveInboundBufferedBytesFromChannelWithEmptyBuffer() throws {
        class InboundBufferHandler: ChannelInboundHandler, NIOInboundByteBufferingChannelHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                context.fireChannelRead(data)
            }

            var inboundBufferedBytes: Int { 0 }
        }

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandlers([InboundBufferHandler(), InboundBufferHandler()])

        let data = ByteBuffer(string: "1234")
        for _ in 1...5 {
            try channel.writeInbound(data)
            let bufferedBytes = try channel.pipeline.inboundBufferedBytes().wait()
            XCTAssertEqual(bufferedBytes, 0)
        }

        for _ in 1...5 {
            _ = try channel.readInbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testRetrieveOutboundBufferedBytesFromChannelWithEmptyBuffer() throws {
        class OutboundBufferHandler: ChannelOutboundHandler, NIOOutboundByteBufferingChannelHandler {
            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                context.write(data, promise: promise)
            }

            var outboundBufferedBytes: Int { 0 }
        }

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandlers([OutboundBufferHandler(), OutboundBufferHandler()])

        let data = ByteBuffer(string: "1234")
        for _ in 1...5 {
            try channel.writeOutbound(data)
            let bufferedBytes = try channel.pipeline.outboundBufferedBytes().wait()
            XCTAssertEqual(bufferedBytes, 0)
        }

        for _ in 1...5 {
            _ = try channel.readOutbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testRetrieveInboundBufferedBytesFromChannelWithMultipleHandlers() throws {
        class InboundBufferHandler: ChannelInboundHandler, NIOInboundByteBufferingChannelHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            private var buffer = ByteBuffer()
            private let expectedBufferCount: Int

            init(expectedBufferCount: Int) {
                self.expectedBufferCount = expectedBufferCount
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buf = self.unwrapInboundIn(data)
                let readSize = min(expectedBufferCount, buf.readableBytes)
                if let b = buf.readSlice(length: readSize) {
                    buffer.writeImmutableBuffer(b)
                }
                context.fireChannelRead(self.wrapInboundOut(buf))
            }

            var inboundBufferedBytes: Int {
                self.buffer.readableBytes
            }
        }

        let handlers = (0..<5).map { InboundBufferHandler(expectedBufferCount: $0) }
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandlers(handlers)

        let data = ByteBuffer(string: "1234")
        try channel.writeInbound(data)
        let bufferedBytes = try channel.pipeline.inboundBufferedBytes().wait()
        XCTAssertEqual(bufferedBytes, data.readableBytes)

        _ = try channel.readInbound(as: ByteBuffer.self)
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testRetrieveOutboundBufferedBytesFromChannelWithMultipleHandlers() throws {
        class OutboundBufferHandler: ChannelOutboundHandler, NIOOutboundByteBufferingChannelHandler {

            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            private var buffer = ByteBuffer()
            private let expectedBufferCount: Int

            init(expectedBufferCount: Int) {
                self.expectedBufferCount = expectedBufferCount
            }

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                var buf = self.unwrapOutboundIn(data)
                let readSize = min(expectedBufferCount, buf.readableBytes)
                if let b = buf.readSlice(length: readSize) {
                    buffer.writeImmutableBuffer(b)
                }

                context.write(self.wrapOutboundOut(buf), promise: promise)
            }

            var outboundBufferedBytes: Int {
                self.buffer.readableBytes
            }
        }

        let handlers = (0..<5).map { OutboundBufferHandler(expectedBufferCount: $0) }
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandlers(handlers)

        let data = ByteBuffer(string: "1234")
        try channel.writeOutbound(data)
        let bufferedBytes = try channel.pipeline.outboundBufferedBytes().wait()
        XCTAssertEqual(bufferedBytes, data.readableBytes)

        _ = try channel.readOutbound(as: ByteBuffer.self)
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testRetrieveInboundBufferedBytesFromChannelWithHandlersRemoved() throws {
        class InboundBufferHandler: ChannelInboundHandler, NIOInboundByteBufferingChannelHandler,
            RemovableChannelHandler
        {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            private var buffer = ByteBuffer()
            let expectedBufferCount: Int

            init(expectedBufferCount: Int) {
                self.expectedBufferCount = expectedBufferCount
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buf = self.unwrapInboundIn(data)
                let readSize = min(expectedBufferCount, buf.readableBytes)
                if let b = buf.readBytes(length: readSize) {
                    buffer.writeBytes(b)
                    context.fireChannelRead(self.wrapInboundOut(buf))
                }
            }

            var inboundBufferedBytes: Int {
                self.buffer.readableBytes
            }
        }

        let handlers = (0..<5).map { InboundBufferHandler(expectedBufferCount: $0) }

        let channel = EmbeddedChannel()
        for handler in handlers {
            try channel.pipeline.syncOperations.addHandler(handler, position: .last)
        }

        let data = ByteBuffer(string: "1234")
        try channel.writeInbound(data)
        var total = try channel.pipeline.inboundBufferedBytes().wait()
        XCTAssertEqual(total, data.readableBytes)
        let expectedBufferedBytes = handlers.map { $0.inboundBufferedBytes }
        print(expectedBufferedBytes)

        for (expectedBufferedByte, handler) in zip(expectedBufferedBytes, handlers) {
            let expectedRemaining = total - expectedBufferedByte
            channel.pipeline.syncOperations.removeHandler(handler).flatMap { _ in
                channel.pipeline.inboundBufferedBytes()
            }.and(value: expectedRemaining).whenSuccess { (remaining, expectedRemaining) in
                XCTAssertEqual(remaining, expectedRemaining)
            }
            total -= expectedBufferedByte
        }

        _ = try channel.readInbound(as: ByteBuffer.self)
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testRetrieveOutboundBufferedBytesFromChannelWithHandlersRemoved() throws {
        class OutboundBufferHandler: ChannelOutboundHandler, NIOOutboundByteBufferingChannelHandler,
            RemovableChannelHandler
        {

            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            private var buffer = ByteBuffer()
            let expectedBufferCount: Int

            init(expectedBufferCount: Int) {
                self.expectedBufferCount = expectedBufferCount
            }

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                var buf = self.unwrapOutboundIn(data)
                let readSize = min(expectedBufferCount, buf.readableBytes)
                if let b = buf.readBytes(length: readSize) {
                    buffer.writeBytes(b)
                    context.write(self.wrapOutboundOut(buf), promise: promise)
                }
            }

            var outboundBufferedBytes: Int {
                self.buffer.readableBytes
            }
        }

        let handlers = (0..<5).map { OutboundBufferHandler(expectedBufferCount: $0) }

        let channel = EmbeddedChannel()
        for handler in handlers {
            try channel.pipeline.syncOperations.addHandler(handler, position: .first)
        }

        let data = ByteBuffer(string: "1234")
        try channel.writeOutbound(data)
        var total = try channel.pipeline.outboundBufferedBytes().wait()
        XCTAssertEqual(total, data.readableBytes)
        let expectedBufferedBytes = handlers.map { $0.outboundBufferedBytes }

        for (expectedBufferedByte, handler) in zip(expectedBufferedBytes, handlers) {
            let expectedRemaining = total - expectedBufferedByte
            channel.pipeline.syncOperations.removeHandler(handler).flatMap { _ in
                channel.pipeline.outboundBufferedBytes()
            }.and(value: expectedRemaining).whenSuccess { (remaining, expectedRemaining) in
                XCTAssertEqual(remaining, expectedRemaining)
            }
            total -= expectedBufferedByte
        }

        _ = try channel.readOutbound(as: ByteBuffer.self)
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testRetrieveBufferedBytesFromChannelWithMixedHandlers() throws {
        // A inbound channel handler that buffers incoming byte buffer when the total number of
        // calls to the channelRead() is even.
        class InboundBufferHandler: ChannelInboundHandler, NIOInboundByteBufferingChannelHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer
            var count: Int
            var bb: ByteBuffer

            init() {
                self.count = 0
                self.bb = ByteBuffer()
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var d = unwrapInboundIn(data)
                self.bb.writeBuffer(&d)

                if count % 2 == 1 {
                    context.fireChannelRead(self.wrapInboundOut(self.bb))
                    self.bb.moveReaderIndex(forwardBy: self.bb.readableBytes)
                }

                count += 1
            }

            var inboundBufferedBytes: Int {
                bb.readableBytes
            }
        }

        // A outbound channel handler that buffers incoming byte buffer when the total number of
        // calls to the write() is odd.
        class OutboundBufferedHandler: ChannelOutboundHandler, NIOOutboundByteBufferingChannelHandler {
            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer
            var count: Int
            var bb: ByteBuffer

            init() {
                self.count = 0
                self.bb = ByteBuffer()
            }

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                var d = unwrapOutboundIn(data)
                self.bb.writeBuffer(&d)
                if count % 2 == 0 {
                    promise?.succeed()
                } else {
                    context.write(self.wrapOutboundOut(self.bb), promise: promise)
                    self.bb.moveWriterIndex(forwardBy: self.bb.writableBytes)
                }
                count += 1
            }

            var outboundBufferedBytes: Int {
                bb.writableBytes
            }
        }

        let channel = EmbeddedChannel(handlers: [InboundBufferHandler(), OutboundBufferedHandler()])

        let data = ByteBuffer(string: "123")
        try channel.writeAndFlush(data).wait()

        channel.pipeline.outboundBufferedBytes().whenSuccess { result in
            XCTAssertEqual(result, data.writableBytes)
        }
        _ = try channel.readOutbound(as: ByteBuffer.self)

        try channel.writeAndFlush(data).wait()

        channel.pipeline.outboundBufferedBytes().whenSuccess { result in
            XCTAssertEqual(result, 0)
        }

        _ = try channel.readOutbound(as: ByteBuffer.self)

        try channel.writeInbound(data)

        channel.pipeline.inboundBufferedBytes().whenSuccess { result in
            XCTAssertEqual(result, data.readableBytes)
        }

        _ = try channel.readInbound(as: ByteBuffer.self)

        try channel.writeInbound(data)

        channel.pipeline.inboundBufferedBytes().whenSuccess { result in
            XCTAssertEqual(result, 0)
        }

        _ = try channel.readInbound(as: ByteBuffer.self)

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveInboundBufferedBytesWhenChannelHandlerNotConformToProtocol() throws {
        class InboundBufferHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                context.fireChannelRead(data)
            }
        }

        let channel = EmbeddedChannel()
        let inboundChannelHandlerName = "InboundBufferHandler"
        try channel.pipeline.syncOperations.addHandler(InboundBufferHandler(), name: inboundChannelHandlerName)
        let context = try channel.pipeline.syncOperations.context(name: inboundChannelHandlerName)
        let bufferedBytes = channel.pipeline.syncOperations.inboundBufferedBytes(in: context)

        XCTAssertNil(bufferedBytes)
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveOutboundBufferedBytesWhenChannelHandlerNotConformToProtocol() throws {
        class OutboundBufferHandler: ChannelOutboundHandler {
            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                context.write(data, promise: promise)
            }
        }

        let channel = EmbeddedChannel()
        let outboundChannelHandlerName = "outboundBufferHandler"
        try channel.pipeline.syncOperations.addHandler(OutboundBufferHandler(), name: outboundChannelHandlerName)
        let context = try channel.pipeline.syncOperations.context(name: outboundChannelHandlerName)
        let bufferedBytes = channel.pipeline.syncOperations.outboundBufferedBytes(in: context)

        XCTAssertNil(bufferedBytes)
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveInboundBufferedBytesFromOneHandler() throws {
        class InboundBufferHandler: ChannelInboundHandler, NIOInboundByteBufferingChannelHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            private var buffer = ByteBuffer()

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                buffer.writeImmutableBuffer(self.unwrapInboundIn(data))
            }

            var inboundBufferedBytes: Int {
                self.buffer.readableBytes
            }
        }

        let channel = EmbeddedChannel()
        let inboundChannelHandlerName = "InboundBufferHandler"
        try channel.pipeline.syncOperations.addHandler(InboundBufferHandler(), name: inboundChannelHandlerName)

        let data = ByteBuffer(string: "1234")
        for cnt in 1...5 {
            try channel.writeInbound(data)
            let context = try channel.pipeline.syncOperations.context(name: inboundChannelHandlerName)
            let bufferedBytes = channel.pipeline.syncOperations.inboundBufferedBytes(in: context)
            XCTAssertNotNil(bufferedBytes)
            XCTAssertEqual(bufferedBytes, data.readableBytes * cnt)
        }

        for _ in 1...5 {
            _ = try channel.readInbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveOutboundBufferedBytesFromOneHandler() throws {
        class OutboundBufferHandler: ChannelOutboundHandler, NIOOutboundByteBufferingChannelHandler {
            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            private var buffer = ByteBuffer()

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                buffer.writeImmutableBuffer(self.unwrapOutboundIn(data))
                promise?.succeed()
            }

            var outboundBufferedBytes: Int {
                self.buffer.readableBytes
            }
        }

        let channel = EmbeddedChannel()
        let outboundChannelHandlerName = "outboundBufferHandler"
        try channel.pipeline.syncOperations.addHandler(OutboundBufferHandler(), name: outboundChannelHandlerName)

        let data = ByteBuffer(string: "1234")
        for cnt in 1...5 {
            try channel.writeOutbound(data)
            let context = try channel.pipeline.syncOperations.context(name: outboundChannelHandlerName)
            let bufferedBytes = channel.pipeline.syncOperations.outboundBufferedBytes(in: context)

            XCTAssertNotNil(bufferedBytes)
            XCTAssertEqual(bufferedBytes, data.readableBytes * cnt)
        }

        for _ in 1...5 {
            _ = try channel.readOutbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveEmptyInboundBufferedBytes() throws {
        class InboundBufferHandler: ChannelInboundHandler, NIOInboundByteBufferingChannelHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                context.fireChannelRead(data)
            }

            var inboundBufferedBytes: Int { 0 }
        }

        let channel = EmbeddedChannel()
        let inboundChannelHandlerName = "InboundBufferHandler"
        try channel.pipeline.syncOperations.addHandler(InboundBufferHandler(), name: inboundChannelHandlerName)

        let data = ByteBuffer(string: "1234")
        for _ in 1...5 {
            try channel.writeInbound(data)
            let context = try channel.pipeline.syncOperations.context(name: inboundChannelHandlerName)
            let bufferedBytes = channel.pipeline.syncOperations.inboundBufferedBytes(in: context)

            XCTAssertNotNil(bufferedBytes)
            XCTAssertEqual(bufferedBytes, 0)
        }

        for _ in 1...5 {
            _ = try channel.readInbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveEmptyOutboundBufferedBytes() throws {
        class OutboundBufferHandler: ChannelOutboundHandler, NIOOutboundByteBufferingChannelHandler {
            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                context.write(data, promise: promise)
            }

            var outboundBufferedBytes: Int { 0 }
        }

        let channel = EmbeddedChannel()
        let outboundChannelHandlerName = "outboundBufferHandler"
        try channel.pipeline.syncOperations.addHandler(OutboundBufferHandler(), name: outboundChannelHandlerName)

        let data = ByteBuffer(string: "1234")
        for _ in 1...5 {
            try channel.writeOutbound(data)
            let context = try channel.pipeline.syncOperations.context(name: outboundChannelHandlerName)
            let bufferedBytes = channel.pipeline.syncOperations.outboundBufferedBytes(in: context)

            XCTAssertNotNil(bufferedBytes)
            XCTAssertEqual(bufferedBytes, 0)
        }

        for _ in 1...5 {
            _ = try channel.readOutbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveInboundBufferedBytesFromChannelWithZeroHandler() throws {
        let channel = EmbeddedChannel()

        let data = ByteBuffer(string: "1234")
        for _ in 1...5 {
            try channel.writeInbound(data)
            let bufferedBytes = channel.pipeline.syncOperations.inboundBufferedBytes()
            XCTAssertEqual(bufferedBytes, 0)
        }

        for _ in 1...5 {
            _ = try channel.readInbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveOutboundBufferedBytesFromChannelWithZeroHandler() throws {
        let channel = EmbeddedChannel()

        let data = ByteBuffer(string: "1234")
        for _ in 1...5 {
            try channel.writeOutbound(data)
            let bufferedBytes = channel.pipeline.syncOperations.outboundBufferedBytes()
            XCTAssertEqual(bufferedBytes, 0)
        }

        for _ in 1...5 {
            _ = try channel.readOutbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveInboundBufferedBytesFromChannelWithOneHandler() throws {
        class InboundBufferHandler: ChannelInboundHandler, NIOInboundByteBufferingChannelHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            private var buffer = ByteBuffer()

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                buffer.writeImmutableBuffer(self.unwrapInboundIn(data))
            }

            var inboundBufferedBytes: Int {
                self.buffer.readableBytes
            }
        }

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandlers([InboundBufferHandler()])

        let data = ByteBuffer(string: "1234")
        for cnt in 1...5 {
            try channel.writeInbound(data)
            let bufferedBytes = channel.pipeline.syncOperations.inboundBufferedBytes()
            XCTAssertEqual(bufferedBytes, cnt * data.readableBytes)
        }

        for _ in 1...5 {
            _ = try channel.readInbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveOutboundBufferedBytesFromChannelWithOneHandler() throws {
        class OutboundBufferHandler: ChannelOutboundHandler, NIOOutboundByteBufferingChannelHandler {
            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            private var buffer = ByteBuffer()

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                buffer.writeImmutableBuffer(self.unwrapOutboundIn(data))
                promise?.succeed()
            }

            var outboundBufferedBytes: Int {
                self.buffer.readableBytes
            }
        }

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandlers([OutboundBufferHandler()])

        let data = ByteBuffer(string: "1234")
        for cnt in 1...5 {
            try channel.writeOutbound(data)
            let bufferedBytes = channel.pipeline.syncOperations.outboundBufferedBytes()
            XCTAssertEqual(bufferedBytes, cnt * data.readableBytes)
        }

        for _ in 1...5 {
            _ = try channel.readOutbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveInboundBufferedBytesFromChannelWithEmptyBuffer() throws {
        class InboundBufferHandler: ChannelInboundHandler, NIOInboundByteBufferingChannelHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                context.fireChannelRead(data)
            }

            var inboundBufferedBytes: Int { 0 }
        }

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandlers([InboundBufferHandler(), InboundBufferHandler()])

        let data = ByteBuffer(string: "1234")
        for _ in 1...5 {
            try channel.writeInbound(data)
            let bufferedBytes = channel.pipeline.syncOperations.inboundBufferedBytes()
            XCTAssertEqual(bufferedBytes, 0)
        }

        for _ in 1...5 {
            _ = try channel.readInbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveOutboundBufferedBytesFromChannelWithEmptyBuffer() throws {
        class OutboundBufferHandler: ChannelOutboundHandler, NIOOutboundByteBufferingChannelHandler {
            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                context.write(data, promise: promise)
            }

            var outboundBufferedBytes: Int { 0 }
        }

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandlers([OutboundBufferHandler(), OutboundBufferHandler()])

        let data = ByteBuffer(string: "1234")
        for _ in 1...5 {
            try channel.writeOutbound(data)
            let bufferedBytes = channel.pipeline.syncOperations.outboundBufferedBytes()
            XCTAssertEqual(bufferedBytes, 0)
        }

        for _ in 1...5 {
            _ = try channel.readOutbound(as: ByteBuffer.self)
        }

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveInboundBufferedBytesFromChannelWithMultipleHandlers() throws {
        class InboundBufferHandler: ChannelInboundHandler, NIOInboundByteBufferingChannelHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            private var buffer = ByteBuffer()
            private let expectedBufferCount: Int

            init(expectedBufferCount: Int) {
                self.expectedBufferCount = expectedBufferCount
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buf = self.unwrapInboundIn(data)
                let readSize = min(expectedBufferCount, buf.readableBytes)
                if let b = buf.readSlice(length: readSize) {
                    buffer.writeImmutableBuffer(b)
                }
                context.fireChannelRead(self.wrapInboundOut(buf))
            }

            var inboundBufferedBytes: Int {
                self.buffer.readableBytes
            }
        }

        let handlers = (0..<5).map { InboundBufferHandler(expectedBufferCount: $0) }
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandlers(handlers)

        let data = ByteBuffer(string: "1234")
        try channel.writeInbound(data)
        let bufferedBytes = channel.pipeline.syncOperations.inboundBufferedBytes()
        XCTAssertEqual(bufferedBytes, data.readableBytes)

        _ = try channel.readInbound(as: ByteBuffer.self)
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveOutboundBufferedBytesFromChannelWithMultipleHandlers() throws {
        class OutboundBufferHandler: ChannelOutboundHandler, NIOOutboundByteBufferingChannelHandler {

            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            private var buffer = ByteBuffer()
            private let expectedBufferCount: Int

            init(expectedBufferCount: Int) {
                self.expectedBufferCount = expectedBufferCount
            }

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                var buf = self.unwrapOutboundIn(data)
                let readSize = min(expectedBufferCount, buf.readableBytes)
                if let b = buf.readSlice(length: readSize) {
                    buffer.writeImmutableBuffer(b)
                }

                context.write(self.wrapOutboundOut(buf), promise: promise)
            }

            var outboundBufferedBytes: Int {
                self.buffer.readableBytes
            }
        }

        let handlers = (0..<5).map { OutboundBufferHandler(expectedBufferCount: $0) }
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandlers(handlers)

        let data = ByteBuffer(string: "1234")
        try channel.writeOutbound(data)
        let bufferedBytes = channel.pipeline.syncOperations.outboundBufferedBytes()
        XCTAssertEqual(bufferedBytes, data.readableBytes)

        _ = try channel.readOutbound(as: ByteBuffer.self)
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveInboundBufferedBytesFromChannelWithHandlersRemoved() throws {
        class InboundBufferHandler: ChannelInboundHandler, NIOInboundByteBufferingChannelHandler,
            RemovableChannelHandler
        {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer

            private var buffer = ByteBuffer()
            let expectedBufferCount: Int

            init(expectedBufferCount: Int) {
                self.expectedBufferCount = expectedBufferCount
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buf = self.unwrapInboundIn(data)
                let readSize = min(expectedBufferCount, buf.readableBytes)
                if let b = buf.readBytes(length: readSize) {
                    buffer.writeBytes(b)
                    context.fireChannelRead(self.wrapInboundOut(buf))
                }
            }

            var inboundBufferedBytes: Int {
                self.buffer.readableBytes
            }
        }

        let handlers = (0..<5).map { InboundBufferHandler(expectedBufferCount: $0) }

        let channel = EmbeddedChannel()
        for handler in handlers {
            try channel.pipeline.syncOperations.addHandler(handler, position: .last)
        }

        let data = ByteBuffer(string: "1234")
        try channel.writeInbound(data)
        var total = channel.pipeline.syncOperations.inboundBufferedBytes()
        XCTAssertEqual(total, data.readableBytes)
        let expectedBufferedBytes = handlers.map { $0.inboundBufferedBytes }
        print(expectedBufferedBytes)

        for (expectedBufferedByte, handler) in zip(expectedBufferedBytes, handlers) {
            let expectedRemaining = total - expectedBufferedByte
            channel.pipeline.syncOperations
                .removeHandler(handler)
                .and(value: expectedRemaining)
                .whenSuccess { (_, expectedRemaining) in
                    let remaining = channel.pipeline.syncOperations.inboundBufferedBytes()
                    XCTAssertEqual(remaining, expectedRemaining)
                }
            total -= expectedBufferedByte
        }

        _ = try channel.readInbound(as: ByteBuffer.self)
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveOutboundBufferedBytesFromChannelWithHandlersRemoved() throws {
        class OutboundBufferHandler: ChannelOutboundHandler, NIOOutboundByteBufferingChannelHandler,
            RemovableChannelHandler
        {

            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            private var buffer = ByteBuffer()
            let expectedBufferCount: Int

            init(expectedBufferCount: Int) {
                self.expectedBufferCount = expectedBufferCount
            }

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                var buf = self.unwrapOutboundIn(data)
                let readSize = min(expectedBufferCount, buf.readableBytes)
                if let b = buf.readBytes(length: readSize) {
                    buffer.writeBytes(b)
                    context.write(self.wrapOutboundOut(buf), promise: promise)
                }
            }

            var outboundBufferedBytes: Int {
                self.buffer.readableBytes
            }
        }

        let handlers = (0..<5).map { OutboundBufferHandler(expectedBufferCount: $0) }

        let channel = EmbeddedChannel()
        for handler in handlers {
            try channel.pipeline.syncOperations.addHandler(handler, position: .first)
        }

        let data = ByteBuffer(string: "1234")
        try channel.writeOutbound(data)
        var total = channel.pipeline.syncOperations.outboundBufferedBytes()
        XCTAssertEqual(total, data.readableBytes)
        let expectedBufferedBytes = handlers.map { $0.outboundBufferedBytes }

        for (expectedBufferedByte, handler) in zip(expectedBufferedBytes, handlers) {
            let expectedRemaining = total - expectedBufferedByte
            channel.pipeline.syncOperations
                .removeHandler(handler)
                .and(value: expectedRemaining)
                .whenSuccess { (_, expectedRemaining) in
                    let remaining = channel.pipeline.syncOperations.outboundBufferedBytes()
                    XCTAssertEqual(remaining, expectedRemaining)
                }
            total -= expectedBufferedByte
        }

        _ = try channel.readOutbound(as: ByteBuffer.self)
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSynchronouslyRetrieveBufferedBytesFromChannelWithMixedHandlers() throws {
        // A inbound channel handler that buffers incoming byte buffer when the total number of
        // calls to the channelRead() is even.
        class InboundBufferHandler: ChannelInboundHandler, NIOInboundByteBufferingChannelHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = ByteBuffer
            var count: Int
            var bb: ByteBuffer

            init() {
                self.count = 0
                self.bb = ByteBuffer()
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var d = unwrapInboundIn(data)
                self.bb.writeBuffer(&d)

                if count % 2 == 1 {
                    context.fireChannelRead(self.wrapInboundOut(self.bb))
                    self.bb.moveReaderIndex(forwardBy: self.bb.readableBytes)
                }

                count += 1
            }

            var inboundBufferedBytes: Int {
                bb.readableBytes
            }
        }

        // A outbound channel handler that buffers incoming byte buffer when the total number of
        // calls to the write() is odd.
        class OutboundBufferedHandler: ChannelOutboundHandler, NIOOutboundByteBufferingChannelHandler {
            typealias OutboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer
            var count: Int
            var bb: ByteBuffer

            init() {
                self.count = 0
                self.bb = ByteBuffer()
            }

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                var d = unwrapOutboundIn(data)
                self.bb.writeBuffer(&d)
                if count % 2 == 0 {
                    promise?.succeed()
                } else {
                    context.write(self.wrapOutboundOut(self.bb), promise: promise)
                    self.bb.moveWriterIndex(forwardBy: self.bb.writableBytes)
                }
                count += 1
            }

            var outboundBufferedBytes: Int {
                bb.writableBytes
            }
        }

        let channel = EmbeddedChannel(handlers: [InboundBufferHandler(), OutboundBufferedHandler()])

        let data = ByteBuffer(string: "123")
        try channel.writeAndFlush(data).wait()

        var result = channel.pipeline.syncOperations.outboundBufferedBytes()
        XCTAssertEqual(result, data.writableBytes)

        _ = try channel.readOutbound(as: ByteBuffer.self)

        try channel.writeAndFlush(data).wait()

        result = channel.pipeline.syncOperations.outboundBufferedBytes()
        XCTAssertEqual(result, 0)

        _ = try channel.readOutbound(as: ByteBuffer.self)

        try channel.writeInbound(data)

        result = channel.pipeline.syncOperations.inboundBufferedBytes()
        XCTAssertEqual(result, data.readableBytes)

        _ = try channel.readInbound(as: ByteBuffer.self)

        try channel.writeInbound(data)

        result = channel.pipeline.syncOperations.inboundBufferedBytes()
        XCTAssertEqual(result, 0)

        _ = try channel.readInbound(as: ByteBuffer.self)

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testAddAfterForSynchronousPosition() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let firstHandler = IndexWritingHandler(1)
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(firstHandler))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(IndexWritingHandler(2)))
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(
                IndexWritingHandler(3),
                position: .after(firstHandler)
            )
        )

        channel.assertReadIndexOrder([1, 3, 2])
        channel.assertWriteIndexOrder([2, 3, 1])
    }

    func testAddBeforeForSynchronousPosition() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let secondHandler = IndexWritingHandler(2)
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(IndexWritingHandler(1)))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(secondHandler))
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(
                IndexWritingHandler(3),
                position: .before(secondHandler)
            )
        )

        channel.assertReadIndexOrder([1, 3, 2])
        channel.assertWriteIndexOrder([2, 3, 1])
    }

    func testAddAfterLastForSynchronousPosition() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let secondHandler = IndexWritingHandler(2)
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(IndexWritingHandler(1)))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(secondHandler))
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(
                IndexWritingHandler(3),
                position: .after(secondHandler)
            )
        )

        channel.assertReadIndexOrder([1, 2, 3])
        channel.assertWriteIndexOrder([3, 2, 1])
    }

    func testAddBeforeFirstForSynchronousPosition() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let firstHandler = IndexWritingHandler(1)
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(firstHandler))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(IndexWritingHandler(2)))
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(
                IndexWritingHandler(3),
                position: .before(firstHandler)
            )
        )

        channel.assertReadIndexOrder([3, 1, 2])
        channel.assertWriteIndexOrder([2, 1, 3])
    }

    func testAddAfterWhileClosedForSynchronousPosition() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertThrowsError(try channel.finish()) { error in
                XCTAssertEqual(.alreadyClosed, error as? ChannelError)
            }
        }

        let handler = IndexWritingHandler(1)
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler))
        XCTAssertNoThrow(try channel.close().wait())
        channel.embeddedEventLoop.run()

        XCTAssertThrowsError(
            try channel.pipeline.syncOperations.addHandler(
                IndexWritingHandler(2),
                position: .after(handler)
            )
        ) { error in
            XCTAssertEqual(.ioOnClosedChannel, error as? ChannelError)
        }
    }

    func testAddBeforeWhileClosedForSynchronousPosition() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertThrowsError(try channel.finish()) { error in
                XCTAssertEqual(.alreadyClosed, error as? ChannelError)
            }
        }

        let handler = IndexWritingHandler(1)
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler))
        XCTAssertNoThrow(try channel.close().wait())
        channel.embeddedEventLoop.run()

        XCTAssertThrowsError(
            try channel.pipeline.syncOperations.addHandler(
                IndexWritingHandler(2),
                position: .before(handler)
            )
        ) { error in
            XCTAssertEqual(.ioOnClosedChannel, error as? ChannelError)
        }
    }
}

// this should be within `testAddMultipleHandlers` but https://bugs.swift.org/browse/SR-9956
final class TestAddMultipleHandlersHandlerWorkingAroundSR9956: ChannelDuplexHandler, Equatable, Sendable {
    typealias InboundIn = Never
    typealias OutboundIn = Never

    static let _allHandlers = NIOLockedValueBox<[TestAddMultipleHandlersHandlerWorkingAroundSR9956]>([])

    static var allHandlers: [TestAddMultipleHandlersHandlerWorkingAroundSR9956] {
        get {
            Self._allHandlers.withLockedValue { $0 }
        }
        set {
            Self._allHandlers.withLockedValue { $0 = newValue }
        }
    }

    init() {}

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        Self.allHandlers.append(self)
        context.fireUserInboundEventTriggered(event)
    }

    public static func == (
        lhs: TestAddMultipleHandlersHandlerWorkingAroundSR9956,
        rhs: TestAddMultipleHandlersHandlerWorkingAroundSR9956
    ) -> Bool {
        lhs === rhs
    }
}
