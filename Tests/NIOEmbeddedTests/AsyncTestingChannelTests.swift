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

import Atomics
import NIOCore
import XCTest

@testable import NIOEmbedded

#if canImport(Android)
import Android
#endif

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
class AsyncTestingChannelTests: XCTestCase {
    func testSingleHandlerInit() async throws {
        final class Handler: ChannelInboundHandler, Sendable {
            typealias InboundIn = Never
        }

        let channel = await NIOAsyncTestingChannel(handler: Handler())
        XCTAssertNoThrow(try channel.pipeline.handler(type: Handler.self).wait())
    }

    func testEmptyInit() throws {

        class Handler: ChannelInboundHandler {
            typealias InboundIn = Never
        }

        let channel = NIOAsyncTestingChannel()
        XCTAssertThrowsError(try channel.pipeline.handler(type: Handler.self).map { _ in }.wait()) { e in
            XCTAssertEqual(e as? ChannelPipelineError, .notFound)
        }

    }

    func testMultipleHandlerInit() async throws {
        final class Handler: ChannelInboundHandler, RemovableChannelHandler, Sendable {
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

    func testClosureInit() async throws {
        final class Handler: ChannelInboundHandler, Sendable {
            typealias InboundIn = Never
        }

        let channel = try await NIOAsyncTestingChannel {
            try $0.pipeline.syncOperations.addHandler(Handler())
        }
        XCTAssertNoThrow(try channel.pipeline.handler(type: Handler.self).wait())
    }

    func testWaitForInboundWrite() async throws {
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

    func testWaitForMultipleInboundWritesInParallel() async throws {
        let channel = NIOAsyncTestingChannel()
        let task = Task {
            let task1 = Task { try await channel.waitForInboundWrite(as: Int.self) }
            let task2 = Task { try await channel.waitForInboundWrite(as: Int.self) }
            let task3 = Task { try await channel.waitForInboundWrite(as: Int.self) }
            try await XCTAsyncAssertEqual(
                Set([
                    try await task1.value,
                    try await task2.value,
                    try await task3.value,
                ]),
                [1, 2, 3]
            )
        }

        try await channel.writeInbound(1)
        try await channel.writeInbound(2)
        try await channel.writeInbound(3)
        try await task.value
    }

    func testWaitForOutboundWrite() async throws {
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

    func testWaitForMultipleOutboundWritesInParallel() async throws {
        let channel = NIOAsyncTestingChannel()
        let task = Task {
            let task1 = Task { try await channel.waitForOutboundWrite(as: Int.self) }
            let task2 = Task { try await channel.waitForOutboundWrite(as: Int.self) }
            let task3 = Task { try await channel.waitForOutboundWrite(as: Int.self) }
            try await XCTAsyncAssertEqual(
                Set([
                    try await task1.value,
                    try await task2.value,
                    try await task3.value,
                ]),
                [1, 2, 3]
            )
        }

        try await channel.writeOutbound(1)
        try await channel.writeOutbound(2)
        try await channel.writeOutbound(3)
        try await task.value
    }

    func testWriteOutboundByteBuffer() async throws {
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

    func testWriteOutboundByteBufferMultipleTimes() async throws {
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

    func testWriteInboundByteBuffer() async throws {
        let channel = NIOAsyncTestingChannel()
        var buf = channel.allocator.buffer(capacity: 1024)
        buf.writeString("hello")

        try await XCTAsyncAssertTrue(await channel.writeInbound(buf).isFull)
        try await XCTAsyncAssertTrue(await channel.finish().hasLeftOvers)
        try await XCTAsyncAssertEqual(buf, await channel.readInbound())
        try await XCTAsyncAssertNil(await channel.readInbound(as: ByteBuffer.self))
        try await XCTAsyncAssertNil(await channel.readOutbound(as: ByteBuffer.self))
    }

    func testWriteInboundByteBufferMultipleTimes() async throws {
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

    func testWriteInboundByteBufferReThrow() async throws {
        let channel = NIOAsyncTestingChannel()
        XCTAssertNoThrow(try channel.pipeline.addHandler(ExceptionThrowingInboundHandler()).wait())
        await XCTAsyncAssertThrowsError(try await channel.writeInbound("msg")) { error in
            XCTAssertEqual(ChannelError.operationUnsupported, error as? ChannelError)
        }
        try await XCTAsyncAssertTrue(await channel.finish().isClean)
    }

    func testWriteOutboundByteBufferReThrow() async throws {
        let channel = NIOAsyncTestingChannel()
        XCTAssertNoThrow(try channel.pipeline.addHandler(ExceptionThrowingOutboundHandler()).wait())
        await XCTAsyncAssertThrowsError(try await channel.writeOutbound("msg")) { error in
            XCTAssertEqual(ChannelError.operationUnsupported, error as? ChannelError)
        }
        try await XCTAsyncAssertTrue(await channel.finish().isClean)
    }

    func testReadOutboundWrongTypeThrows() async throws {
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

    func testReadInboundWrongTypeThrows() async throws {
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

    func testWrongTypesWithFastpathTypes() async throws {
        let channel = NIOAsyncTestingChannel()

        let buffer = channel.allocator.buffer(capacity: 0)

        try await XCTAsyncAssertTrue(await channel.writeOutbound(buffer).isFull)
        try await XCTAsyncAssertTrue(
            await channel.writeOutbound(
                AddressedEnvelope<ByteBuffer>(
                    remoteAddress: SocketAddress(ipAddress: "1.2.3.4", port: 5678),
                    data: buffer
                )
            ).isFull
        )
        try await XCTAsyncAssertTrue(await channel.writeOutbound(buffer).isFull)

        try await XCTAsyncAssertTrue(await channel.writeInbound(buffer).isFull)
        try await XCTAsyncAssertTrue(
            await channel.writeInbound(
                AddressedEnvelope<ByteBuffer>(
                    remoteAddress: SocketAddress(ipAddress: "1.2.3.4", port: 5678),
                    data: buffer
                )
            ).isFull
        )
        try await XCTAsyncAssertTrue(await channel.writeInbound(buffer).isFull)

        func check<Expected: Sendable, Actual>(
            expected: Expected.Type,
            actual: Actual.Type,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
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

    func testCloseMultipleTimesThrows() async throws {
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

    func testCloseOnInactiveIsOk() async throws {
        let channel = NIOAsyncTestingChannel()
        let inactiveHandler = CloseInChannelInactiveHandler()
        XCTAssertNoThrow(try channel.pipeline.addHandler(inactiveHandler).wait())
        try await XCTAsyncAssertTrue(await channel.finish().isClean)

        // channelInactive should fire only once.
        XCTAssertEqual(inactiveHandler.inactiveNotifications.load(ordering: .sequentiallyConsistent), 1)
    }

    func testEmbeddedLifecycle() async throws {
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

    private final class ExceptionThrowingInboundHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = String

        public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.fireErrorCaught(ChannelError.operationUnsupported)
        }
    }

    private final class ExceptionThrowingOutboundHandler: ChannelOutboundHandler, Sendable {
        typealias OutboundIn = String
        typealias OutboundOut = Never

        public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            promise!.fail(ChannelError.operationUnsupported)
        }
    }

    private final class CloseInChannelInactiveHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        public let inactiveNotifications = ManagedAtomic(0)

        public func channelInactive(context: ChannelHandlerContext) {
            inactiveNotifications.wrappingIncrement(by: 1, ordering: .sequentiallyConsistent)
            context.close(promise: nil)
        }
    }

    func testEmbeddedChannelAndPipelineAndChannelCoreShareTheEventLoop() async throws {
        let channel = NIOAsyncTestingChannel()
        let pipelineEventLoop = channel.pipeline.eventLoop
        XCTAssert(pipelineEventLoop === channel.eventLoop)
        XCTAssert(pipelineEventLoop === (channel._channelCore as! EmbeddedChannelCore).eventLoop)
        try await XCTAsyncAssertTrue(await channel.finish().isClean)
    }

    func testSendingAnythingOnEmbeddedChannel() async throws {
        let channel = NIOAsyncTestingChannel()
        let buffer = ByteBufferAllocator().buffer(capacity: 5)
        let socketAddress = try SocketAddress(unixDomainSocketPath: "path")

        try await channel.writeAndFlush(1)
        try await channel.writeAndFlush("1")
        try await channel.writeAndFlush(buffer)
        try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: socketAddress, data: buffer))
    }

    func testActiveWhenConnectPromiseFiresAndInactiveWhenClosePromiseFires() async throws {
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

    func testWriteWithoutFlushDoesNotWrite() async throws {
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

    func testSetLocalAddressAfterSuccessfulBind() throws {
        let channel = NIOAsyncTestingChannel()
        let bindPromise = channel.eventLoop.makePromise(of: Void.self)
        let socketAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        channel.bind(to: socketAddress, promise: bindPromise)
        bindPromise.futureResult.whenComplete { _ in
            XCTAssertEqual(channel.localAddress, socketAddress)
        }
        try bindPromise.futureResult.wait()
    }

    func testSetLocalAddressAfterSuccessfulBindWithoutPromise() throws {
        let channel = NIOAsyncTestingChannel()
        let socketAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        // Call bind on-loop so we know when to expect the result
        try channel.testingEventLoop.submit {
            channel.bind(to: socketAddress, promise: nil)
        }.wait()
        XCTAssertEqual(channel.localAddress, socketAddress)
    }

    func testSetRemoteAddressAfterSuccessfulConnect() throws {
        let channel = NIOAsyncTestingChannel()
        let connectPromise = channel.eventLoop.makePromise(of: Void.self)
        let socketAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        channel.connect(to: socketAddress, promise: connectPromise)
        connectPromise.futureResult.whenComplete { _ in
            XCTAssertEqual(channel.remoteAddress, socketAddress)
        }
        try connectPromise.futureResult.wait()
    }

    func testSetRemoteAddressAfterSuccessfulConnectWithoutPromise() throws {
        let channel = NIOAsyncTestingChannel()
        let socketAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        // Call connect on-loop so we know when to expect the result
        try channel.testingEventLoop.submit {
            channel.connect(to: socketAddress, promise: nil)
        }.wait()
        XCTAssertEqual(channel.remoteAddress, socketAddress)
    }

    func testUnprocessedOutboundUserEventFailsOnEmbeddedChannel() throws {

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

        let channel = NIOAsyncTestingChannel()
        let opaqueChannel: Channel = channel
        XCTAssertTrue(channel.isWritable)
        XCTAssertTrue(opaqueChannel.isWritable)
        channel.isWritable = false
        XCTAssertFalse(channel.isWritable)
        XCTAssertFalse(opaqueChannel.isWritable)

    }

    func testFinishWithRecursivelyScheduledTasks() async throws {
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

    func testSyncOptionsAreSupported() throws {
        let channel = NIOAsyncTestingChannel()
        try channel.testingEventLoop.submit {
            let options = channel.syncOptions
            XCTAssertNotNil(options)
            // Unconditionally returns true.
            XCTAssertEqual(try options?.getOption(.autoRead), true)
            // (Setting options isn't supported.)
        }.wait()
    }

    func testGetChannelOptionAutoReadIsSupported() throws {
        let channel = NIOAsyncTestingChannel()
        try channel.testingEventLoop.submit {
            let options = channel.syncOptions
            XCTAssertNotNil(options)
            // Unconditionally returns true.
            XCTAssertEqual(try options?.getOption(.autoRead), true)
        }.wait()
    }

    func testSetGetChannelOptionAllowRemoteHalfClosureIsSupported() throws {
        let channel = NIOAsyncTestingChannel()
        try channel.testingEventLoop.submit {
            let options = channel.syncOptions
            XCTAssertNotNil(options)

            // allowRemoteHalfClosure should be false by default
            XCTAssertEqual(try options?.getOption(.allowRemoteHalfClosure), false)

            channel.allowRemoteHalfClosure = true
            XCTAssertEqual(try options?.getOption(.allowRemoteHalfClosure), true)

            XCTAssertNoThrow(try options?.setOption(.allowRemoteHalfClosure, value: false))
            XCTAssertEqual(try options?.getOption(.allowRemoteHalfClosure), false)
        }.wait()
    }

    func testSecondFinishThrows() async throws {
        let channel = NIOAsyncTestingChannel()
        _ = try await channel.finish()
        await XCTAsyncAssertThrowsError(try await channel.finish())
    }

    func testWriteOutboundEmptyBufferedByte() async throws {
        let channel = NIOAsyncTestingChannel()
        var buffered: ChannelOptions.Types.BufferedWritableBytesOption.Value = try await channel.getOption(
            .bufferedWritableBytes
        )
        XCTAssertEqual(0, buffered)

        let buf = channel.allocator.buffer(capacity: 10)

        channel.write(buf, promise: nil)
        buffered = try await channel.getOption(.bufferedWritableBytes)
        XCTAssertEqual(0, buffered)

        channel.flush()
        buffered = try await channel.getOption(.bufferedWritableBytes)
        XCTAssertEqual(0, buffered)

        try await XCTAsyncAssertEqual(buf, try await channel.waitForOutboundWrite(as: ByteBuffer.self))
        try await XCTAsyncAssertTrue(try await channel.finish().isClean)
    }

    func testWriteOutboundBufferedBytesSingleWrite() async throws {
        let channel = NIOAsyncTestingChannel()
        var buf = channel.allocator.buffer(capacity: 10)
        buf.writeString("hello")

        channel.write(buf, promise: nil)
        var buffered: ChannelOptions.Types.BufferedWritableBytesOption.Value = try await channel.getOption(
            .bufferedWritableBytes
        )
        XCTAssertEqual(buf.readableBytes, buffered)
        channel.flush()

        buffered = try await channel.getOption(.bufferedWritableBytes).get()
        XCTAssertEqual(0, buffered)
        try await XCTAsyncAssertEqual(buf, try await channel.waitForOutboundWrite(as: ByteBuffer.self))
        try await XCTAsyncAssertTrue(try await channel.finish().isClean)
    }

    func testWriteOuboundBufferedBytesMultipleWrites() async throws {
        let channel = NIOAsyncTestingChannel()
        var buf = channel.allocator.buffer(capacity: 10)
        buf.writeString("hello")
        let totalCount = 5
        for _ in 0..<totalCount {
            channel.write(buf, promise: nil)
        }
        var buffered: ChannelOptions.Types.BufferedWritableBytesOption.Value = try await channel.getOption(
            .bufferedWritableBytes
        )
        XCTAssertEqual(buf.readableBytes * totalCount, buffered)

        channel.flush()
        buffered = try await channel.getOption(.bufferedWritableBytes)
        XCTAssertEqual(0, buffered)

        for _ in 0..<totalCount {
            try await XCTAsyncAssertEqual(buf, try await channel.waitForOutboundWrite(as: ByteBuffer.self))
        }

        try await XCTAsyncAssertTrue(try await channel.finish().isClean)
    }

    func testWriteOuboundBufferedBytesWriteAndFlushInterleaved() async throws {
        let channel = NIOAsyncTestingChannel()
        var buf = channel.allocator.buffer(capacity: 10)
        buf.writeString("hello")

        channel.write(buf, promise: nil)
        channel.write(buf, promise: nil)
        channel.write(buf, promise: nil)
        var buffered: ChannelOptions.Types.BufferedWritableBytesOption.Value = try await channel.getOption(
            .bufferedWritableBytes
        )
        XCTAssertEqual(buf.readableBytes * 3, buffered)

        channel.flush()
        buffered = try await channel.getOption(.bufferedWritableBytes)
        XCTAssertEqual(0, buffered)

        channel.write(buf, promise: nil)
        channel.write(buf, promise: nil)
        buffered = try await channel.getOption(.bufferedWritableBytes)
        XCTAssertEqual(buf.readableBytes * 2, buffered)
        channel.flush()
        buffered = try await channel.getOption(.bufferedWritableBytes)
        XCTAssertEqual(0, buffered)

        for _ in 0..<5 {
            try await XCTAsyncAssertEqual(buf, try await channel.waitForOutboundWrite(as: ByteBuffer.self))
        }

        try await XCTAsyncAssertTrue(try await channel.finish().isClean)
    }

    func testWriteOutboundBufferedBytesWriteAndFlush() async throws {
        let channel = NIOAsyncTestingChannel()
        var buf = channel.allocator.buffer(capacity: 10)
        buf.writeString("hello")

        try await XCTAsyncAssertTrue(await channel.writeOutbound(buf).isFull)
        let buffered: ChannelOptions.Types.BufferedWritableBytesOption.Value = try await channel.getOption(
            .bufferedWritableBytes
        )
        XCTAssertEqual(0, buffered)

        try await XCTAsyncAssertEqual(buf, try await channel.waitForOutboundWrite(as: ByteBuffer.self))
        try await XCTAsyncAssertTrue(try await channel.finish().isClean)
    }

    func testWaitingForWriteTerminatesAfterChannelClose() async throws {
        let channel = NIOAsyncTestingChannel()

        // Write some inbound and outbound data
        for i in 1...3 {
            try await channel.writeInbound(i)
            try await channel.writeOutbound(i)
        }

        // We should successfully see the three inbound and outbound writes
        for i in 1...3 {
            try await XCTAsyncAssertEqual(try await channel.waitForInboundWrite(), i)
            try await XCTAsyncAssertEqual(try await channel.waitForOutboundWrite(), i)
        }

        let task = Task {
            // We close the channel after the third inbound/outbound write. Waiting again should result in a
            // `ChannelError.ioOnClosedChannel` error.
            await XCTAsyncAssertThrowsError(try await channel.waitForInboundWrite(as: Int.self)) {
                XCTAssertEqual($0 as? ChannelError, ChannelError.ioOnClosedChannel)
            }
            await XCTAsyncAssertThrowsError(try await channel.waitForOutboundWrite(as: Int.self)) {
                XCTAssertEqual($0 as? ChannelError, ChannelError.ioOnClosedChannel)
            }
        }

        // Close the channel without performing any writes
        try await channel.close()
        try await task.value
    }

    func testEnqueueWriteConsumersBeforeChannelClosesWithoutAnyWrites() async throws {
        let channel = NIOAsyncTestingChannel()

        let task = Task {
            // We don't write anything to the channel and simply just close it. Waiting for an inbound/outbound write
            // should result in a `ChannelError.ioOnClosedChannel` when the channel closes.
            await XCTAsyncAssertThrowsError(try await channel.waitForInboundWrite(as: Int.self)) {
                XCTAssertEqual($0 as? ChannelError, ChannelError.ioOnClosedChannel)
            }
            await XCTAsyncAssertThrowsError(try await channel.waitForOutboundWrite(as: Int.self)) {
                XCTAssertEqual($0 as? ChannelError, ChannelError.ioOnClosedChannel)
            }
        }

        // Close the channel without performing any inbound or outbound writes
        try await channel.close()
        try await task.value
    }

    func testEnqueueWriteConsumersAfterChannelClosesWithoutAnyWrites() async throws {
        let channel = NIOAsyncTestingChannel()
        // Immediately close the channel without performing any inbound or outbound writes
        try await channel.close()

        // Now try to wait for an inbound/outbound write. This should result in a `ChannelError.ioOnClosedChannel`.
        await XCTAsyncAssertThrowsError(try await channel.waitForInboundWrite(as: Int.self)) {
            XCTAssertEqual($0 as? ChannelError, ChannelError.ioOnClosedChannel)
        }
        await XCTAsyncAssertThrowsError(try await channel.waitForOutboundWrite(as: Int.self)) {
            XCTAssertEqual($0 as? ChannelError, ChannelError.ioOnClosedChannel)
        }
    }

    func testGetSetOption() async throws {
        let channel = NIOAsyncTestingChannel()
        let option = ChannelOptions.socket(IPPROTO_IP, IP_TTL)
        let _ = try await channel.setOption(option, value: 1).get()

        let optionValue1 = try await channel.getOption(option).get()
        XCTAssertEqual(1, optionValue1)

        let _ = try await channel.setOption(option, value: 2).get()
        let optionValue2 = try await channel.getOption(option).get()
        XCTAssertEqual(2, optionValue2)
    }

    func testSocketAddressesOnContext() async throws {
        final class Handler: ChannelInboundHandler, Sendable {
            typealias InboundIn = Never

            func handlerAdded(context: ChannelHandlerContext) {
                XCTAssertNotNil(context.localAddress)
                XCTAssertNotNil(context.remoteAddress)
            }
        }

        let channel = NIOAsyncTestingChannel()
        channel.localAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 8080)
        channel.remoteAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 9090)

        try await channel.pipeline.addHandler(Handler())

        XCTAssertNoThrow(try channel.pipeline.handler(type: Handler.self).wait())
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private func XCTAsyncAssertTrue(
    _ predicate: @autoclosure () async throws -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async rethrows {
    let result = try await predicate()
    XCTAssertTrue(result, file: file, line: line)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private func XCTAsyncAssertEqual<Element: Equatable>(
    _ lhs: @autoclosure () async throws -> Element,
    _ rhs: @autoclosure () async throws -> Element,
    file: StaticString = #filePath,
    line: UInt = #line
) async rethrows {
    let lhsResult = try await lhs()
    let rhsResult = try await rhs()
    XCTAssertEqual(lhsResult, rhsResult, file: file, line: line)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private func XCTAsyncAssertThrowsError<ResultType>(
    _ expression: @autoclosure () async throws -> ResultType,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ callback: ((Error) -> Void)? = nil
) async {
    do {
        let _ = try await expression()
        XCTFail("Did not throw", file: file, line: line)
    } catch {
        callback?(error)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private func XCTAsyncAssertNil(
    _ expression: @autoclosure () async throws -> Any?,
    file: StaticString = #filePath,
    line: UInt = #line
) async rethrows {
    let result = try await expression()
    XCTAssertNil(result, file: file, line: line)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private func XCTAsyncAssertNotNil(
    _ expression: @autoclosure () async throws -> Any?,
    file: StaticString = #filePath,
    line: UInt = #line
) async rethrows {
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
