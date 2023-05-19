//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
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
import NIOCore
@testable import NIOEmbedded

class AsyncTestingChannelTests: XCTestCase {
    func testSingleHandlerInit() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            class Handler: ChannelInboundHandler {
                typealias InboundIn = Never
            }

            let channel = await NIOAsyncTestingChannel(handler: Handler())
            XCTAssertNoThrow(try channel.pipeline.handler(type: Handler.self).wait())
        }
    }

    func testEmptyInit() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }

        class Handler: ChannelInboundHandler {
            typealias InboundIn = Never
        }

        let channel = NIOAsyncTestingChannel()
        XCTAssertThrowsError(try channel.pipeline.handler(type: Handler.self).wait()) { e in
            XCTAssertEqual(e as? ChannelPipelineError, .notFound)
        }

    }

    func testMultipleHandlerInit() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            class Handler: ChannelInboundHandler, RemovableChannelHandler {
                typealias InboundIn = Never
                let identifier: String

                init(identifier: String) {
                    self.identifier = identifier
                }
            }

            let channel = await NIOAsyncTestingChannel(
                handlers: [Handler(identifier: "0"), Handler(identifier: "1"), Handler(identifier: "2")]
            )
            XCTAssertNoThrow(XCTAssertEqual(try channel.pipeline.handler(type: Handler.self).wait().identifier, "0"))
            XCTAssertNoThrow(try channel.pipeline.removeHandler(name: "handler0").wait())

            XCTAssertNoThrow(XCTAssertEqual(try channel.pipeline.handler(type: Handler.self).wait().identifier, "1"))
            XCTAssertNoThrow(try channel.pipeline.removeHandler(name: "handler1").wait())

            XCTAssertNoThrow(XCTAssertEqual(try channel.pipeline.handler(type: Handler.self).wait().identifier, "2"))
            XCTAssertNoThrow(try channel.pipeline.removeHandler(name: "handler2").wait())
        }
    }

    func testWaitForInboundWrite() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            let task = Task {
                try await XCTAsyncAssertEqual(try await channel.waitForInboundWrite(), 1)
                try await XCTAsyncAssertEqual(try await channel.waitForInboundWrite(), 2)
                try await XCTAsyncAssertEqual(try await channel.waitForInboundWrite(), 3)
            }

            try await channel.writeInbound(1)
            try await channel.writeInbound(2)
            try await channel.writeInbound(3)
            try await task.value
        }
    }

    func testWaitForMultipleInboundWritesInParallel() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            let task = Task {
                let task1 = Task { try await channel.waitForInboundWrite(as: Int.self) }
                let task2 = Task { try await channel.waitForInboundWrite(as: Int.self) }
                let task3 = Task { try await channel.waitForInboundWrite(as: Int.self) }
                try await XCTAsyncAssertEqual(Set([
                    try await task1.value,
                    try await task2.value,
                    try await task3.value,
                ]), [1, 2, 3])
            }

            try await channel.writeInbound(1)
            try await channel.writeInbound(2)
            try await channel.writeInbound(3)
            try await task.value
        }
    }

    func testWaitForOutboundWrite() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            let task = Task {
                try await XCTAsyncAssertEqual(try await channel.waitForOutboundWrite(), 1)
                try await XCTAsyncAssertEqual(try await channel.waitForOutboundWrite(), 2)
                try await XCTAsyncAssertEqual(try await channel.waitForOutboundWrite(), 3)
            }

            try await channel.writeOutbound(1)
            try await channel.writeOutbound(2)
            try await channel.writeOutbound(3)
            try await task.value
        }
    }

    func testWaitForMultipleOutboundWritesInParallel() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            let task = Task {
                let task1 = Task { try await channel.waitForOutboundWrite(as: Int.self) }
                let task2 = Task { try await channel.waitForOutboundWrite(as: Int.self) }
                let task3 = Task { try await channel.waitForOutboundWrite(as: Int.self) }
                try await XCTAsyncAssertEqual(Set([
                    try await task1.value,
                    try await task2.value,
                    try await task3.value,
                ]), [1, 2, 3])
            }

            try await channel.writeOutbound(1)
            try await channel.writeOutbound(2)
            try await channel.writeOutbound(3)
            try await task.value
        }
    }

    func testWriteOutboundByteBuffer() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            var buf = channel.allocator.buffer(capacity: 1024)
            buf.writeString("hello")

            let isFull = try await channel.writeOutbound(buf).isFull
            XCTAssertTrue(isFull)

            let hasLeftovers = try await channel.finish().hasLeftOvers
            XCTAssertTrue(hasLeftovers)

            let read = try await channel.readOutbound(as: ByteBuffer.self)
            XCTAssertNoThrow(XCTAssertEqual(buf, read))

            let nextOutboundRead = try await channel.readOutbound(as: ByteBuffer.self)
            let nextInboundRead = try await channel.readInbound(as: ByteBuffer.self)
            XCTAssertNoThrow(XCTAssertNil(nextOutboundRead))
            XCTAssertNoThrow(XCTAssertNil(nextInboundRead))
        }
    }

    func testWriteOutboundByteBufferMultipleTimes() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            var buf = channel.allocator.buffer(capacity: 1024)
            buf.writeString("hello")

            try await XCTAsyncAssertTrue(await channel.writeOutbound(buf).isFull)
            try await XCTAsyncAssertEqual(buf, await channel.readOutbound())
            try await XCTAsyncAssertNil(await channel.readOutbound(as: ByteBuffer.self))
            try await XCTAsyncAssertNil(await channel.readInbound(as: ByteBuffer.self))

            var bufB = channel.allocator.buffer(capacity: 1024)
            bufB.writeString("again")

            try await XCTAsyncAssertTrue(await channel.writeOutbound(bufB).isFull)
            try await XCTAsyncAssertTrue(await channel.finish().hasLeftOvers)
            try await XCTAsyncAssertEqual(bufB, await channel.readOutbound())
            try await XCTAsyncAssertNil(await channel.readOutbound(as: ByteBuffer.self))
            try await XCTAsyncAssertNil(await channel.readInbound(as: ByteBuffer.self))
        }
    }

    func testWriteInboundByteBuffer() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            var buf = channel.allocator.buffer(capacity: 1024)
            buf.writeString("hello")

            try await XCTAsyncAssertTrue(await channel.writeInbound(buf).isFull)
            try await XCTAsyncAssertTrue(await channel.finish().hasLeftOvers)
            try await XCTAsyncAssertEqual(buf, await channel.readInbound())
            try await XCTAsyncAssertNil(await channel.readInbound(as: ByteBuffer.self))
            try await XCTAsyncAssertNil(await channel.readOutbound(as: ByteBuffer.self))
        }
    }

    func testWriteInboundByteBufferMultipleTimes() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            var buf = channel.allocator.buffer(capacity: 1024)
            buf.writeString("hello")

            try await XCTAsyncAssertTrue(await channel.writeInbound(buf).isFull)
            try await XCTAsyncAssertEqual(buf, await channel.readInbound())
            try await XCTAsyncAssertNil(await channel.readInbound(as: ByteBuffer.self))
            try await XCTAsyncAssertNil(await channel.readOutbound(as: ByteBuffer.self))

            var bufB = channel.allocator.buffer(capacity: 1024)
            bufB.writeString("again")

            try await XCTAsyncAssertTrue(await channel.writeInbound(bufB).isFull)
            try await XCTAsyncAssertTrue(await channel.finish().hasLeftOvers)
            try await XCTAsyncAssertEqual(bufB, await channel.readInbound())
            try await XCTAsyncAssertNil(await channel.readInbound(as: ByteBuffer.self))
            try await XCTAsyncAssertNil(await channel.readOutbound(as: ByteBuffer.self))
        }
    }

    func testWriteInboundByteBufferReThrow() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            XCTAssertNoThrow(try channel.pipeline.addHandler(ExceptionThrowingInboundHandler()).wait())
            await XCTAsyncAssertThrowsError(try await channel.writeInbound("msg")) { error in
                XCTAssertEqual(ChannelError.operationUnsupported, error as? ChannelError)
            }
            try await XCTAsyncAssertTrue(await channel.finish().isClean)
        }
    }

    func testWriteOutboundByteBufferReThrow() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            XCTAssertNoThrow(try channel.pipeline.addHandler(ExceptionThrowingOutboundHandler()).wait())
            await XCTAsyncAssertThrowsError(try await channel.writeOutbound("msg")) { error in
                XCTAssertEqual(ChannelError.operationUnsupported, error as? ChannelError)
            }
            try await XCTAsyncAssertTrue(await channel.finish().isClean)
        }
    }

    func testReadOutboundWrongTypeThrows() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            try await XCTAsyncAssertTrue(await channel.writeOutbound("hello").isFull)
            do {
                _ = try await channel.readOutbound(as: Int.self)
                XCTFail()
            } catch let error as NIOAsyncTestingChannel.WrongTypeError {
                let expectedError = NIOAsyncTestingChannel.WrongTypeError(expected: Int.self, actual: String.self)
                XCTAssertEqual(error, expectedError)
            } catch {
                XCTFail()
            }
        }
    }

    func testReadInboundWrongTypeThrows() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            try await XCTAsyncAssertTrue(await channel.writeInbound("hello").isFull)
            do {
                _ = try await channel.readInbound(as: Int.self)
                XCTFail()
            } catch let error as NIOAsyncTestingChannel.WrongTypeError {
                let expectedError = NIOAsyncTestingChannel.WrongTypeError(expected: Int.self, actual: String.self)
                XCTAssertEqual(error, expectedError)
            } catch {
                XCTFail()
            }
        }
    }

    func testWrongTypesWithFastpathTypes() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()

            let buffer = channel.allocator.buffer(capacity: 0)

            try await XCTAsyncAssertTrue(await channel.writeOutbound(buffer).isFull)
            try await XCTAsyncAssertTrue(await channel.writeOutbound(
                AddressedEnvelope<ByteBuffer>(remoteAddress: SocketAddress(ipAddress: "1.2.3.4", port: 5678),
                                              data: buffer)).isFull)
            try await XCTAsyncAssertTrue(await channel.writeOutbound(buffer).isFull)


            try await XCTAsyncAssertTrue(await channel.writeInbound(buffer).isFull)
            try await XCTAsyncAssertTrue(await channel.writeInbound(
                AddressedEnvelope<ByteBuffer>(remoteAddress: SocketAddress(ipAddress: "1.2.3.4", port: 5678),
                                              data: buffer)).isFull)
            try await XCTAsyncAssertTrue(await channel.writeInbound(buffer).isFull)

            func check<Expected: Sendable, Actual>(expected: Expected.Type,
                                                   actual: Actual.Type,
                                                   file: StaticString = #filePath,
                                                   line: UInt = #line) async {
                do {
                    _ = try await channel.readOutbound(as: Expected.self)
                    XCTFail("this should have failed", file: (file), line: line)
                } catch let error as NIOAsyncTestingChannel.WrongTypeError {
                    let expectedError = NIOAsyncTestingChannel.WrongTypeError(expected: Expected.self, actual: Actual.self)
                    XCTAssertEqual(error, expectedError, file: (file), line: line)
                } catch {
                    XCTFail("unexpected error: \(error)", file: (file), line: line)
                }

                do {
                    _ = try await channel.readInbound(as: Expected.self)
                    XCTFail("this should have failed", file: (file), line: line)
                } catch let error as NIOAsyncTestingChannel.WrongTypeError {
                    let expectedError = NIOAsyncTestingChannel.WrongTypeError(expected: Expected.self, actual: Actual.self)
                    XCTAssertEqual(error, expectedError, file: (file), line: line)
                } catch {
                    XCTFail("unexpected error: \(error)", file: (file), line: line)
                }
            }

            await check(expected: Never.self, actual: IOData.self)
            await check(expected: ByteBuffer.self, actual: AddressedEnvelope<ByteBuffer>.self)
            await check(expected: AddressedEnvelope<ByteBuffer>.self, actual: IOData.self)
        }
    }

    func testCloseMultipleTimesThrows() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            try await XCTAsyncAssertTrue(await channel.finish().isClean)

            // Close a second time. This must fail.
            do {
                try await channel.close()
                XCTFail("Second close succeeded")
            } catch ChannelError.alreadyClosed {
                // Nothing to do here.
            }
        }
    }

    func testCloseOnInactiveIsOk() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            let inactiveHandler = CloseInChannelInactiveHandler()
            XCTAssertNoThrow(try channel.pipeline.addHandler(inactiveHandler).wait())
            try await XCTAsyncAssertTrue(await channel.finish().isClean)

            // channelInactive should fire only once.
            XCTAssertEqual(inactiveHandler.inactiveNotifications, 1)
        }
    }

    func testEmbeddedLifecycle() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let handler = ChannelLifecycleHandler()
            XCTAssertEqual(handler.currentState, .unregistered)

            let channel = await NIOAsyncTestingChannel(handler: handler)

            XCTAssertEqual(handler.currentState, .registered)
            XCTAssertFalse(channel.isActive)

            XCTAssertNoThrow(try channel.connect(to: try SocketAddress(unixDomainSocketPath: "/fake")).wait())
            XCTAssertEqual(handler.currentState, .active)
            XCTAssertTrue(channel.isActive)

            try await XCTAsyncAssertTrue(await channel.finish().isClean)
            XCTAssertEqual(handler.currentState, .unregistered)
            XCTAssertFalse(channel.isActive)
        }
    }

    private final class ExceptionThrowingInboundHandler : ChannelInboundHandler {
        typealias InboundIn = String

        public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.fireErrorCaught(ChannelError.operationUnsupported)
        }
    }

    private final class ExceptionThrowingOutboundHandler : ChannelOutboundHandler {
        typealias OutboundIn = String
        typealias OutboundOut = Never

        public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            promise!.fail(ChannelError.operationUnsupported)
        }
    }

    private final class CloseInChannelInactiveHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        public var inactiveNotifications = 0

        public func channelInactive(context: ChannelHandlerContext) {
            inactiveNotifications += 1
            context.close(promise: nil)
        }
    }

    func testEmbeddedChannelAndPipelineAndChannelCoreShareTheEventLoop() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            let pipelineEventLoop = channel.pipeline.eventLoop
            XCTAssert(pipelineEventLoop === channel.eventLoop)
            XCTAssert(pipelineEventLoop === (channel._channelCore as! EmbeddedChannelCore).eventLoop)
            try await XCTAsyncAssertTrue(await channel.finish().isClean)
        }
    }

    func testSendingAnythingOnEmbeddedChannel() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            let buffer = ByteBufferAllocator().buffer(capacity: 5)
            let socketAddress = try SocketAddress(unixDomainSocketPath: "path")
            let handle = NIOFileHandle(descriptor: 1)
            let fileRegion = FileRegion(fileHandle: handle, readerIndex: 1, endIndex: 2)
            defer {
                // fake descriptor, so shouldn't be closed.
                XCTAssertNoThrow(try handle.takeDescriptorOwnership())
            }
            try await channel.writeAndFlush(1)
            try await channel.writeAndFlush("1")
            try await channel.writeAndFlush(buffer)
            try await channel.writeAndFlush(IOData.byteBuffer(buffer))
            try await channel.writeAndFlush(IOData.fileRegion(fileRegion))
            try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: socketAddress, data: buffer))
        }
    }

    func testActiveWhenConnectPromiseFiresAndInactiveWhenClosePromiseFires() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            XCTAssertFalse(channel.isActive)
            let connectPromise = channel.eventLoop.makePromise(of: Void.self)
            connectPromise.futureResult.whenComplete { (_: Result<Void, Error>) in
                XCTAssertTrue(channel.isActive)
            }
            channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0), promise: connectPromise)
            try await connectPromise.futureResult.get()

            let closePromise = channel.eventLoop.makePromise(of: Void.self)
            closePromise.futureResult.whenComplete { (_: Result<Void, Error>) in
                XCTAssertFalse(channel.isActive)
            }

            channel.close(promise: closePromise)
            try await closePromise.futureResult.get()
        }
    }

    func testWriteWithoutFlushDoesNotWrite() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()

            let buf = ByteBuffer(bytes: [1])
            let writeFuture = channel.write(buf)
            try await XCTAsyncAssertNil(await channel.readOutbound(as: ByteBuffer.self))
            XCTAssertFalse(writeFuture.isFulfilled)
            channel.flush()
            try await XCTAsyncAssertNotNil(await channel.readOutbound(as: ByteBuffer.self))
            XCTAssertTrue(writeFuture.isFulfilled)
            try await XCTAsyncAssertTrue(await channel.finish().isClean)
        }
    }

    func testSetLocalAddressAfterSuccessfulBind() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }

        let channel = NIOAsyncTestingChannel()
        let bindPromise = channel.eventLoop.makePromise(of: Void.self)
        let socketAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        channel.bind(to: socketAddress, promise: bindPromise)
        bindPromise.futureResult.whenComplete { _ in
            XCTAssertEqual(channel.localAddress, socketAddress)
        }
        try bindPromise.futureResult.wait()

    }

    func testSetRemoteAddressAfterSuccessfulConnect() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }

        let channel = NIOAsyncTestingChannel()
        let connectPromise = channel.eventLoop.makePromise(of: Void.self)
        let socketAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        channel.connect(to: socketAddress, promise: connectPromise)
        connectPromise.futureResult.whenComplete { _ in
            XCTAssertEqual(channel.remoteAddress, socketAddress)
        }
        try connectPromise.futureResult.wait()

    }

    func testUnprocessedOutboundUserEventFailsOnEmbeddedChannel() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }

        let channel = NIOAsyncTestingChannel()
        XCTAssertThrowsError(try channel.triggerUserOutboundEvent("event").wait()) { (error: Error) in
            if let error = error as? ChannelError {
                XCTAssertEqual(ChannelError.operationUnsupported, error)
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }

    }

    func testEmbeddedChannelWritabilityIsWritable() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }

        let channel = NIOAsyncTestingChannel()
        let opaqueChannel: Channel = channel
        XCTAssertTrue(channel.isWritable)
        XCTAssertTrue(opaqueChannel.isWritable)
        channel.isWritable = false
        XCTAssertFalse(channel.isWritable)
        XCTAssertFalse(opaqueChannel.isWritable)

    }

    func testFinishWithRecursivelyScheduledTasks() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            let invocations = AtomicCounter()

            @Sendable func recursivelyScheduleAndIncrement() {
                channel.pipeline.eventLoop.scheduleTask(deadline: .distantFuture) {
                    invocations.increment()
                    recursivelyScheduleAndIncrement()
                }
            }

            recursivelyScheduleAndIncrement()

            _ = try await channel.finish()
            XCTAssertEqual(invocations.load(), 1)
        }
    }

    func testSyncOptionsAreSupported() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        let channel = NIOAsyncTestingChannel()
        try channel.testingEventLoop.submit {
            let options = channel.syncOptions
            XCTAssertNotNil(options)
            // Unconditionally returns true.
            XCTAssertEqual(try options?.getOption(ChannelOptions.autoRead), true)
            // (Setting options isn't supported.)
        }.wait()
    }

    func testGetChannelOptionAutoReadIsSupported() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        let channel = NIOAsyncTestingChannel()
        try channel.testingEventLoop.submit {
            let options = channel.syncOptions
            XCTAssertNotNil(options)
            // Unconditionally returns true.
            XCTAssertEqual(try options?.getOption(ChannelOptions.autoRead), true)
        }.wait()
    }

    func testSetGetChannelOptionAllowRemoteHalfClosureIsSupported() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        let channel = NIOAsyncTestingChannel()
        try channel.testingEventLoop.submit {
            let options = channel.syncOptions
            XCTAssertNotNil(options)

            // allowRemoteHalfClosure should be false by default
            XCTAssertEqual(try options?.getOption(ChannelOptions.allowRemoteHalfClosure), false)

            channel.allowRemoteHalfClosure = true
            XCTAssertEqual(try options?.getOption(ChannelOptions.allowRemoteHalfClosure), true)

            XCTAssertNoThrow(try options?.setOption(ChannelOptions.allowRemoteHalfClosure, value: false))
            XCTAssertEqual(try options?.getOption(ChannelOptions.allowRemoteHalfClosure), false)
        }.wait()
    }

    func testSecondFinishThrows() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            _ = try await channel.finish()
            await XCTAsyncAssertThrowsError(try await channel.finish())
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
fileprivate func XCTAsyncAssertTrue(_ predicate: @autoclosure () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async rethrows {
    let result = try await predicate()
    XCTAssertTrue(result, file: file, line: line)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
fileprivate func XCTAsyncAssertEqual<Element: Equatable>(_ lhs: @autoclosure () async throws -> Element, _ rhs: @autoclosure () async throws -> Element, file: StaticString = #filePath, line: UInt = #line) async rethrows {
    let lhsResult = try await lhs()
    let rhsResult = try await rhs()
    XCTAssertEqual(lhsResult, rhsResult, file: file, line: line)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
fileprivate func XCTAsyncAssertThrowsError<ResultType>(_ expression: @autoclosure () async throws -> ResultType, file: StaticString = #filePath, line: UInt = #line, _ callback: Optional<(Error) -> Void> = nil) async {
    do {
        let _ = try await expression()
        XCTFail("Did not throw", file: file, line: line)
    } catch {
        callback?(error)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
fileprivate func XCTAsyncAssertNil(_ expression: @autoclosure () async throws -> Any?, file: StaticString = #filePath, line: UInt = #line) async rethrows {
    let result = try await expression()
    XCTAssertNil(result, file: file, line: line)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
fileprivate func XCTAsyncAssertNotNil(_ expression: @autoclosure () async throws -> Any?, file: StaticString = #filePath, line: UInt = #line) async rethrows {
    let result = try await expression()
    XCTAssertNotNil(result, file: file, line: line)
}

/// A simple atomic counter.
final class AtomicCounter: @unchecked Sendable {
    // This class has to be `@unchecked Sendable` because ManagedAtomic
    // is not sendable.
    private let baseCounter = ManagedAtomic(0)

    func increment() {
        self.baseCounter.wrappingIncrement(ordering: .relaxed)
    }

    func load() -> Int {
        self.baseCounter.load(ordering: .relaxed)
    }
}
