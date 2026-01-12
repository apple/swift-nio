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
import NIOConcurrencyHelpers
import NIOCore
import XCTest

@testable import NIOEmbedded

#if canImport(Android)
import Android
#endif

final class ChannelLifecycleHandler: ChannelInboundHandler, Sendable {
    public typealias InboundIn = Any

    public enum ChannelState {
        case unregistered
        case registered
        case inactive
        case active
    }

    public var currentState: ChannelState {
        get {
            self._state.withLockedValue { $0.currentState }
        }
    }
    public var stateHistory: [ChannelState] {
        get {
            self._state.withLockedValue { $0.stateHistory }
        }
    }

    private let _state: NIOLockedValueBox<(currentState: ChannelState, stateHistory: [ChannelState])>

    public init() {
        self._state = NIOLockedValueBox((currentState: .unregistered, stateHistory: [.unregistered]))
    }

    private func updateState(_ state: ChannelState) {
        self._state.withLockedValue {
            $0.currentState = state
            $0.stateHistory.append(state)
        }
    }

    public func channelRegistered(context: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .unregistered)
        XCTAssertFalse(context.channel.isActive)
        updateState(.registered)
        context.fireChannelRegistered()
    }

    public func channelActive(context: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .registered)
        XCTAssertTrue(context.channel.isActive)
        updateState(.active)
        context.fireChannelActive()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .active)
        XCTAssertFalse(context.channel.isActive)
        updateState(.inactive)
        context.fireChannelInactive()
    }

    public func channelUnregistered(context: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .inactive)
        XCTAssertFalse(context.channel.isActive)
        updateState(.unregistered)
        context.fireChannelUnregistered()
    }
}

class EmbeddedChannelTest: XCTestCase {

    func testSingleHandlerInit() {
        class Handler: ChannelInboundHandler {
            typealias InboundIn = Never
        }

        let channel = EmbeddedChannel(handler: Handler())
        XCTAssertNoThrow(try channel.pipeline.handler(type: Handler.self).map { _ in }.wait())
    }

    func testSingleHandlerInitNil() {
        class Handler: ChannelInboundHandler {
            typealias InboundIn = Never
        }

        let channel = EmbeddedChannel(handler: nil)
        XCTAssertThrowsError(try channel.pipeline.handler(type: Handler.self).map { _ in }.wait()) { e in
            XCTAssertEqual(e as? ChannelPipelineError, .notFound)
        }
    }

    func testMultipleHandlerInit() {
        class Handler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never
            let identifier: String

            init(identifier: String) {
                self.identifier = identifier
            }
        }

        let channel = EmbeddedChannel(
            handlers: [Handler(identifier: "0"), Handler(identifier: "1"), Handler(identifier: "2")]
        )
        XCTAssertNoThrow(
            XCTAssertEqual(try channel.pipeline.handler(type: Handler.self).map { $0.identifier }.wait(), "0")
        )
        XCTAssertNoThrow(try channel.pipeline.removeHandler(name: "handler0").wait())

        XCTAssertNoThrow(
            XCTAssertEqual(try channel.pipeline.handler(type: Handler.self).map { $0.identifier }.wait(), "1")
        )
        XCTAssertNoThrow(try channel.pipeline.removeHandler(name: "handler1").wait())

        XCTAssertNoThrow(
            XCTAssertEqual(try channel.pipeline.handler(type: Handler.self).map { $0.identifier }.wait(), "2")
        )
        XCTAssertNoThrow(try channel.pipeline.removeHandler(name: "handler2").wait())
    }

    func testWriteOutboundByteBuffer() throws {
        let channel = EmbeddedChannel()
        var buf = channel.allocator.buffer(capacity: 1024)
        buf.writeString("hello")

        XCTAssertTrue(try channel.writeOutbound(buf).isFull)
        XCTAssertTrue(try channel.finish().hasLeftOvers)
        XCTAssertNoThrow(XCTAssertEqual(buf, try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
    }

    func testWriteOutboundByteBufferMultipleTimes() throws {
        let channel = EmbeddedChannel()
        var buf = channel.allocator.buffer(capacity: 1024)
        buf.writeString("hello")

        XCTAssertTrue(try channel.writeOutbound(buf).isFull)
        XCTAssertNoThrow(XCTAssertEqual(buf, try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        var bufB = channel.allocator.buffer(capacity: 1024)
        bufB.writeString("again")

        XCTAssertTrue(try channel.writeOutbound(bufB).isFull)
        XCTAssertTrue(try channel.finish().hasLeftOvers)
        XCTAssertNoThrow(XCTAssertEqual(bufB, try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
    }

    func testWriteInboundByteBuffer() throws {
        let channel = EmbeddedChannel()
        var buf = channel.allocator.buffer(capacity: 1024)
        buf.writeString("hello")

        XCTAssertTrue(try channel.writeInbound(buf).isFull)
        XCTAssertTrue(try channel.finish().hasLeftOvers)
        XCTAssertNoThrow(XCTAssertEqual(buf, try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
    }

    func testWriteInboundByteBufferMultipleTimes() throws {
        let channel = EmbeddedChannel()
        var buf = channel.allocator.buffer(capacity: 1024)
        buf.writeString("hello")

        XCTAssertTrue(try channel.writeInbound(buf).isFull)
        XCTAssertNoThrow(XCTAssertEqual(buf, try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))

        var bufB = channel.allocator.buffer(capacity: 1024)
        bufB.writeString("again")

        XCTAssertTrue(try channel.writeInbound(bufB).isFull)
        XCTAssertTrue(try channel.finish().hasLeftOvers)
        XCTAssertNoThrow(XCTAssertEqual(bufB, try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
    }

    func testWriteInboundByteBufferReThrow() {
        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(ExceptionThrowingInboundHandler()))
        XCTAssertThrowsError(try channel.writeInbound("msg")) { error in
            XCTAssertEqual(ChannelError.operationUnsupported, error as? ChannelError)
        }
        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
    }

    func testWriteOutboundByteBufferReThrow() {
        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(ExceptionThrowingOutboundHandler()))
        XCTAssertThrowsError(try channel.writeOutbound("msg")) { error in
            XCTAssertEqual(ChannelError.operationUnsupported, error as? ChannelError)
        }
        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
    }

    func testReadOutboundWrongTypeThrows() {
        let channel = EmbeddedChannel()
        XCTAssertTrue(try channel.writeOutbound("hello").isFull)
        do {
            _ = try channel.readOutbound(as: Int.self)
            XCTFail()
        } catch let error as EmbeddedChannel.WrongTypeError {
            let expectedError = EmbeddedChannel.WrongTypeError(expected: Int.self, actual: String.self)
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail()
        }
    }

    func testReadInboundWrongTypeThrows() {
        let channel = EmbeddedChannel()
        XCTAssertTrue(try channel.writeInbound("hello").isFull)
        do {
            _ = try channel.readInbound(as: Int.self)
            XCTFail()
        } catch let error as EmbeddedChannel.WrongTypeError {
            let expectedError = EmbeddedChannel.WrongTypeError(expected: Int.self, actual: String.self)
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail()
        }
    }

    func testWrongTypesWithFastpathTypes() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
        }

        let buffer = channel.allocator.buffer(capacity: 0)
        let ioData = IOData.byteBuffer(buffer)
        let fileHandle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: -1)
        let fileRegion = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 0)
        defer {
            XCTAssertNoThrow(_ = try fileHandle.takeDescriptorOwnership())
        }

        XCTAssertTrue(try channel.writeOutbound(buffer).isFull)
        XCTAssertTrue(try channel.writeOutbound(ioData).isFull)
        XCTAssertTrue(try channel.writeOutbound(fileHandle).isFull)
        XCTAssertTrue(try channel.writeOutbound(fileRegion).isFull)
        XCTAssertTrue(
            try channel.writeOutbound(
                AddressedEnvelope<ByteBuffer>(
                    remoteAddress: SocketAddress(ipAddress: "1.2.3.4", port: 5678),
                    data: buffer
                )
            ).isFull
        )
        XCTAssertTrue(try channel.writeOutbound(buffer).isFull)
        XCTAssertTrue(try channel.writeOutbound(ioData).isFull)
        XCTAssertTrue(try channel.writeOutbound(fileRegion).isFull)

        XCTAssertTrue(try channel.writeInbound(buffer).isFull)
        XCTAssertTrue(try channel.writeInbound(ioData).isFull)
        XCTAssertTrue(try channel.writeInbound(fileHandle).isFull)
        XCTAssertTrue(try channel.writeInbound(fileRegion).isFull)
        XCTAssertTrue(
            try channel.writeInbound(
                AddressedEnvelope<ByteBuffer>(
                    remoteAddress: SocketAddress(ipAddress: "1.2.3.4", port: 5678),
                    data: buffer
                )
            ).isFull
        )
        XCTAssertTrue(try channel.writeInbound(buffer).isFull)
        XCTAssertTrue(try channel.writeInbound(ioData).isFull)
        XCTAssertTrue(try channel.writeInbound(fileRegion).isFull)

        func check<Expected, Actual>(
            expected: Expected.Type,
            actual: Actual.Type,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            do {
                _ = try channel.readOutbound(as: Expected.self)
                XCTFail("this should have failed", file: (file), line: line)
            } catch let error as EmbeddedChannel.WrongTypeError {
                let expectedError = EmbeddedChannel.WrongTypeError(expected: Expected.self, actual: Actual.self)
                XCTAssertEqual(error, expectedError, file: (file), line: line)
            } catch {
                XCTFail("unexpected error: \(error)", file: (file), line: line)
            }

            do {
                _ = try channel.readInbound(as: Expected.self)
                XCTFail("this should have failed", file: (file), line: line)
            } catch let error as EmbeddedChannel.WrongTypeError {
                let expectedError = EmbeddedChannel.WrongTypeError(expected: Expected.self, actual: Actual.self)
                XCTAssertEqual(error, expectedError, file: (file), line: line)
            } catch {
                XCTFail("unexpected error: \(error)", file: (file), line: line)
            }
        }

        check(expected: Never.self, actual: IOData.self)
        check(expected: Never.self, actual: IOData.self)
        check(expected: Never.self, actual: NIOFileHandle.self)
        check(expected: Never.self, actual: IOData.self)
        check(expected: Never.self, actual: AddressedEnvelope<ByteBuffer>.self)
        check(expected: NIOFileHandle.self, actual: IOData.self)
        check(expected: NIOFileHandle.self, actual: IOData.self)
        check(expected: ByteBuffer.self, actual: IOData.self)
    }

    func testCloseMultipleTimesThrows() throws {
        let channel = EmbeddedChannel()
        XCTAssertTrue(try channel.finish().isClean)

        // Close a second time. This must fail.
        do {
            try channel.close().wait()
            XCTFail("Second close succeeded")
        } catch ChannelError.alreadyClosed {
            // Nothing to do here.
        }
    }

    func testCloseOnInactiveIsOk() throws {
        let channel = EmbeddedChannel()
        let inactiveHandler = CloseInChannelInactiveHandler()
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(inactiveHandler))
        XCTAssertTrue(try channel.finish().isClean)

        // channelInactive should fire only once.
        XCTAssertEqual(inactiveHandler.inactiveNotifications, 1)
    }

    func testEmbeddedLifecycle() throws {
        let handler = ChannelLifecycleHandler()
        XCTAssertEqual(handler.currentState, .unregistered)

        let channel = EmbeddedChannel(handler: handler)

        XCTAssertEqual(handler.currentState, .registered)
        XCTAssertFalse(channel.isActive)

        XCTAssertNoThrow(try channel.connect(to: try SocketAddress(unixDomainSocketPath: "/fake")).wait())
        XCTAssertEqual(handler.currentState, .active)
        XCTAssertTrue(channel.isActive)

        XCTAssertTrue(try channel.finish().isClean)
        XCTAssertEqual(handler.currentState, .unregistered)
        XCTAssertFalse(channel.isActive)
    }

    private final class ExceptionThrowingInboundHandler: ChannelInboundHandler {
        typealias InboundIn = String

        public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.fireErrorCaught(ChannelError.operationUnsupported)
        }
    }

    private final class ExceptionThrowingOutboundHandler: ChannelOutboundHandler {
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

    func testEmbeddedChannelAndPipelineAndChannelCoreShareTheEventLoop() {
        let channel = EmbeddedChannel()
        let pipelineEventLoop = channel.pipeline.eventLoop
        XCTAssert(pipelineEventLoop === channel.eventLoop)
        XCTAssert(pipelineEventLoop === (channel._channelCore as! EmbeddedChannelCore).eventLoop)
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testSendingAnythingOnEmbeddedChannel() throws {
        let channel = EmbeddedChannel()
        let buffer = ByteBufferAllocator().buffer(capacity: 5)
        let socketAddress = try SocketAddress(unixDomainSocketPath: "path")
        let handle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: 1)
        let fileRegion = FileRegion(fileHandle: handle, readerIndex: 1, endIndex: 2)
        defer {
            // fake descriptor, so shouldn't be closed.
            XCTAssertNoThrow(try handle.takeDescriptorOwnership())
        }
        try channel.writeAndFlush(1).wait()
        try channel.writeAndFlush("1").wait()
        try channel.writeAndFlush(buffer).wait()
        try channel.writeOutbound(IOData.byteBuffer(buffer))
        try channel.writeOutbound(IOData.fileRegion(fileRegion))
        try channel.writeAndFlush(AddressedEnvelope(remoteAddress: socketAddress, data: buffer)).wait()
    }

    func testActiveWhenConnectPromiseFiresAndInactiveWhenClosePromiseFires() throws {
        let channel = EmbeddedChannel()
        XCTAssertFalse(channel.isActive)
        let connectPromise = channel.eventLoop.makePromise(of: Void.self)
        connectPromise.futureResult.whenComplete { (_: Result<Void, Error>) in
            XCTAssertTrue(channel.isActive)
        }
        channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0), promise: connectPromise)
        try connectPromise.futureResult.wait()

        let closePromise = channel.eventLoop.makePromise(of: Void.self)
        closePromise.futureResult.whenComplete { (_: Result<Void, Error>) in
            XCTAssertFalse(channel.isActive)
        }

        channel.close(promise: closePromise)
        try closePromise.futureResult.wait()
    }

    func testWriteWithoutFlushDoesNotWrite() throws {
        let channel = EmbeddedChannel()

        let buf = ByteBuffer(bytes: [1])
        let writeFuture = channel.write(buf)
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))
        XCTAssertFalse(writeFuture.isFulfilled)
        channel.flush()
        XCTAssertNoThrow(XCTAssertNotNil(try channel.readOutbound(as: ByteBuffer.self)))
        XCTAssertTrue(writeFuture.isFulfilled)
        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
    }

    func testSetLocalAddressAfterSuccessfulBind() throws {
        let channel = EmbeddedChannel()
        let bindPromise = channel.eventLoop.makePromise(of: Void.self)
        let socketAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        channel.bind(to: socketAddress, promise: bindPromise)
        bindPromise.futureResult.whenComplete { _ in
            XCTAssertEqual(channel.localAddress, socketAddress)
        }
        try bindPromise.futureResult.wait()
    }

    func testSetLocalAddressAfterSuccessfulBindWithoutPromise() throws {
        let channel = EmbeddedChannel()
        let socketAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        channel.bind(to: socketAddress, promise: nil)
        XCTAssertEqual(channel.localAddress, socketAddress)
    }

    func testSetRemoteAddressAfterSuccessfulConnect() throws {
        let channel = EmbeddedChannel()
        let connectPromise = channel.eventLoop.makePromise(of: Void.self)
        let socketAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        channel.connect(to: socketAddress, promise: connectPromise)
        connectPromise.futureResult.whenComplete { _ in
            XCTAssertEqual(channel.remoteAddress, socketAddress)
        }
        try connectPromise.futureResult.wait()
    }

    func testSetRemoteAddressAfterSuccessfulConnectWithoutPromise() throws {
        let channel = EmbeddedChannel()
        let socketAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        channel.connect(to: socketAddress, promise: nil)
        XCTAssertEqual(channel.remoteAddress, socketAddress)
    }

    func testUnprocessedOutboundUserEventFailsOnEmbeddedChannel() {
        let channel = EmbeddedChannel()
        XCTAssertThrowsError(try channel.triggerUserOutboundEvent("event").wait()) { (error: Error) in
            if let error = error as? ChannelError {
                XCTAssertEqual(ChannelError.operationUnsupported, error)
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testEmbeddedChannelWritabilityIsWritable() {
        let channel = EmbeddedChannel()
        let opaqueChannel: Channel = channel
        XCTAssertTrue(channel.isWritable)
        XCTAssertTrue(opaqueChannel.isWritable)
        channel.isWritable = false
        XCTAssertFalse(channel.isWritable)
        XCTAssertFalse(opaqueChannel.isWritable)
    }

    func testFinishWithRecursivelyScheduledTasks() throws {
        let channel = EmbeddedChannel()
        let tasks: NIOLoopBoundBox<[Scheduled<Void>]> = NIOLoopBoundBox([], eventLoop: channel.eventLoop)
        let invocations = ManagedAtomic(0)

        @Sendable
        func recursivelyScheduleAndIncrement() {
            let task = channel.pipeline.eventLoop.scheduleTask(deadline: .distantFuture) {
                invocations.wrappingIncrement(ordering: .sequentiallyConsistent)
                recursivelyScheduleAndIncrement()
            }
            tasks.value.append(task)
        }

        recursivelyScheduleAndIncrement()

        try XCTAssertNoThrow(channel.finish())

        // None of the tasks should have been executed, they were scheduled for distant future.
        XCTAssertEqual(invocations.load(ordering: .sequentiallyConsistent), 0)

        // Because the root task didn't run, it should be the onnly one scheduled.
        XCTAssertEqual(tasks.value.count, 1)

        // Check the task was failed with cancelled error.
        let taskChecked = expectation(description: "task future fulfilled")
        tasks.value.first?.futureResult.whenComplete { result in
            switch result {
            case .success: XCTFail("Expected task to be cancelled, not run.")
            case .failure(let error): XCTAssertEqual(error as? EventLoopError, .cancelled)
            }
            taskChecked.fulfill()
        }
        wait(for: [taskChecked], timeout: 0)
    }

    func testGetChannelOptionAutoReadIsSupported() {
        let channel = EmbeddedChannel()
        let options = channel.syncOptions
        XCTAssertNotNil(options)
        // Unconditionally returns true.
        XCTAssertEqual(try options?.getOption(.autoRead), true)
    }

    func testSetGetChannelOptionAllowRemoteHalfClosureIsSupported() {
        let channel = EmbeddedChannel()
        let options = channel.syncOptions
        XCTAssertNotNil(options)

        // allowRemoteHalfClosure should be false by default
        XCTAssertEqual(try options?.getOption(.allowRemoteHalfClosure), false)

        channel.allowRemoteHalfClosure = true
        XCTAssertEqual(try options?.getOption(.allowRemoteHalfClosure), true)

        XCTAssertNoThrow(try options?.setOption(.allowRemoteHalfClosure, value: false))
        XCTAssertEqual(try options?.getOption(.allowRemoteHalfClosure), false)
    }

    func testLocalAddress0() throws {
        let channel = EmbeddedChannel()

        XCTAssertThrowsError(try channel._channelCore.localAddress0()) { error in
            XCTAssertEqual(error as? ChannelError, ChannelError.operationUnsupported)
        }

        let localAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 1234)
        channel.localAddress = localAddress

        XCTAssertEqual(try channel._channelCore.localAddress0(), localAddress)
    }

    func testRemoteAddress0() throws {
        let channel = EmbeddedChannel()

        XCTAssertThrowsError(try channel._channelCore.remoteAddress0()) { error in
            XCTAssertEqual(error as? ChannelError, ChannelError.operationUnsupported)
        }

        let remoteAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 1234)
        channel.remoteAddress = remoteAddress

        XCTAssertEqual(try channel._channelCore.remoteAddress0(), remoteAddress)
    }

    func testWriteOutboundEmptyBufferedByte() throws {
        let channel = EmbeddedChannel()
        var buffered = try channel.getOption(ChannelOptions.bufferedWritableBytes).wait()
        XCTAssertEqual(0, buffered)

        let buf = channel.allocator.buffer(capacity: 10)

        channel.write(buf, promise: nil)
        buffered = try channel.getOption(ChannelOptions.bufferedWritableBytes).wait()
        XCTAssertEqual(0, buffered)

        channel.flush()
        buffered = try channel.getOption(ChannelOptions.bufferedWritableBytes).wait()
        XCTAssertEqual(0, buffered)
        XCTAssertNoThrow(XCTAssertEqual(buf, try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
    }

    func testWriteOutboundBufferedByteSingleWrite() throws {
        let channel = EmbeddedChannel()
        var buf = channel.allocator.buffer(capacity: 10)
        buf.writeString("hello")

        channel.write(buf, promise: nil)
        var buffered = try channel.getOption(ChannelOptions.bufferedWritableBytes).wait()
        XCTAssertEqual(buf.readableBytes, buffered)
        channel.flush()

        buffered = try channel.getOption(ChannelOptions.bufferedWritableBytes).wait()
        XCTAssertEqual(0, buffered)
        XCTAssertNoThrow(XCTAssertEqual(buf, try channel.readOutbound()))
        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
    }

    func testWriteOuboundBufferedBytesMultipleWrites() throws {
        let channel = EmbeddedChannel()
        var buf = channel.allocator.buffer(capacity: 10)
        buf.writeString("hello")
        let totalCount = 5
        for _ in 0..<totalCount {
            channel.write(buf, promise: nil)
        }

        var buffered = try channel.getOption(ChannelOptions.bufferedWritableBytes).wait()
        XCTAssertEqual(buf.readableBytes * totalCount, buffered)

        channel.flush()
        buffered = try channel.getOption(ChannelOptions.bufferedWritableBytes).wait()
        XCTAssertEqual(0, buffered)
        for _ in 0..<totalCount {
            XCTAssertNoThrow(XCTAssertEqual(buf, try channel.readOutbound()))
        }

        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
    }

    func testWriteOuboundBufferedBytesWriteAndFlushInterleaved() throws {
        let channel = EmbeddedChannel()
        var buf = channel.allocator.buffer(capacity: 10)
        buf.writeString("hello")

        channel.write(buf, promise: nil)
        channel.write(buf, promise: nil)
        channel.write(buf, promise: nil)
        var buffered = try channel.getOption(ChannelOptions.bufferedWritableBytes).wait()
        XCTAssertEqual(buf.readableBytes * 3, buffered)

        channel.flush()
        buffered = try channel.getOption(ChannelOptions.bufferedWritableBytes).wait()
        XCTAssertEqual(0, buffered)

        channel.write(buf, promise: nil)
        channel.write(buf, promise: nil)
        buffered = try channel.getOption(ChannelOptions.bufferedWritableBytes).wait()
        XCTAssertEqual(buf.readableBytes * 2, buffered)
        channel.flush()
        buffered = try channel.getOption(ChannelOptions.bufferedWritableBytes).wait()
        XCTAssertEqual(0, buffered)

        for _ in 0..<5 {
            XCTAssertNoThrow(XCTAssertEqual(buf, try channel.readOutbound()))
        }

        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
    }

    func testWriteOutboundBufferedBytesWriteAndFlush() throws {
        let channel = EmbeddedChannel()
        var buf = channel.allocator.buffer(capacity: 10)
        buf.writeString("hello")

        try XCTAssertTrue(channel.writeOutbound(buf).isFull)
        let buffered = try channel.getOption(.bufferedWritableBytes).wait()
        XCTAssertEqual(0, buffered)

        XCTAssertEqual(buf, try channel.readOutbound(as: ByteBuffer.self))
        XCTAssertTrue(try channel.finish().isClean)
    }

    func testWriteInboundBufferConsumer() throws {
        let channel = EmbeddedChannel()
        let invocationPromise = channel.eventLoop.makePromise(of: Void.self)

        channel.channelcore._enqueueInboundBufferConsumer { element in
            invocationPromise.succeed()
            switch element {
            case .success(let result):
                XCTAssertEqual(
                    channel.channelcore.tryUnwrapData(result, as: ByteBuffer.self),
                    ByteBuffer(string: "hello")
                )
            case .failure(let error):
                XCTFail("Unexpectedly received an error: \(error)")
            }
        }

        var buf = channel.allocator.buffer(capacity: 10)
        buf.writeString("hello")
        try channel.writeInbound(buf)

        XCTAssertTrue(invocationPromise.futureResult.isFulfilled)
    }

    func testWriteOutboundBufferConsumer() throws {
        let channel = EmbeddedChannel()
        let invocationPromise = channel.eventLoop.makePromise(of: Void.self)

        channel.channelcore._enqueueOutboundBufferConsumer { element in
            invocationPromise.succeed()
            switch element {
            case .success(let result):
                XCTAssertEqual(
                    channel.channelcore.tryUnwrapData(result, as: ByteBuffer.self),
                    ByteBuffer(string: "hello")
                )
            case .failure(let error):
                XCTFail("Unexpectedly received an error: \(error)")
            }
        }

        var buf = channel.allocator.buffer(capacity: 10)
        buf.writeString("hello")
        channel.write(buf, promise: nil)
        channel.flush()

        XCTAssertTrue(invocationPromise.futureResult.isFulfilled)
    }

    func testQueueMultipleInboundAndOutboundBufferConsumersBeforeChannelClose() async throws {
        let channel = EmbeddedChannel()
        let inboundInvocationPromises = [EventLoopPromise<Void>](
            repeating: channel.eventLoop.makePromise(of: Void.self),
            count: 3
        )
        let outboundInvocationPromises = [EventLoopPromise<Void>](
            repeating: channel.eventLoop.makePromise(of: Void.self),
            count: 3
        )

        // Enqueue 3 inbound and outbound consumers
        for i in 0..<3 {
            // Since the channel closes, all queued consumers should get a `ChannelError.ioOnClosedChannel`
            channel.channelcore._enqueueInboundBufferConsumer { element in
                inboundInvocationPromises[i].succeed()
                switch element {
                case .failure(let failure):
                    XCTAssertEqual(failure as? ChannelError, ChannelError.ioOnClosedChannel)
                case .success:
                    XCTFail("Unexpectedly received a successful result: no writes were performed on the channel.")
                }
            }

            channel.channelcore._enqueueOutboundBufferConsumer { element in
                outboundInvocationPromises[i].succeed()
                switch element {
                case .failure(let failure):
                    XCTAssertEqual(failure as? ChannelError, ChannelError.ioOnClosedChannel)
                case .success:
                    XCTFail("Unexpectedly received a successful result: no writes were performed on the channel.")
                }
            }
        }

        // Close the channel without performing any writes
        try await channel.close()
        XCTAssertEqual(channel.channelcore.isOpen, false)

        // Check that all consumer closures were invoked
        XCTAssertTrue(inboundInvocationPromises.map(\.futureResult.isFulfilled).allSatisfy { $0 })
        XCTAssertTrue(outboundInvocationPromises.map(\.futureResult.isFulfilled).allSatisfy { $0 })
    }

    func testQueueInboundAndOutboundBufferConsumerAfterChannelClose() async throws {
        let channel = EmbeddedChannel()
        let inboundInvocationPromise = channel.eventLoop.makePromise(of: Void.self)
        let outboundInvocationPromise = channel.eventLoop.makePromise(of: Void.self)

        // Close the channel immediately
        try await channel.close()
        XCTAssertEqual(channel.channelcore.isOpen, false)

        // Since the consumers are enqueued after the channel closed, they should get a `ChannelError.ioOnClosedChannel`
        channel.channelcore._enqueueInboundBufferConsumer { element in
            inboundInvocationPromise.succeed()
            switch element {
            case .failure(let failure):
                XCTAssertEqual(failure as? ChannelError, ChannelError.ioOnClosedChannel)
            case .success:
                XCTFail("Unexpectedly received a successful result: no writes were performed on the channel.")
            }
        }

        channel.channelcore._enqueueOutboundBufferConsumer { element in
            outboundInvocationPromise.succeed()
            switch element {
            case .failure(let failure):
                XCTAssertEqual(failure as? ChannelError, ChannelError.ioOnClosedChannel)
            case .success:
                XCTFail("Unexpectedly received a successful result: no writes were performed on the channel.")
            }
        }

        XCTAssertTrue(inboundInvocationPromise.futureResult.isFulfilled)
        XCTAssertTrue(outboundInvocationPromise.futureResult.isFulfilled)
    }

    func testGetSetOption() throws {
        let channel = EmbeddedChannel()
        let option = ChannelOptions.socket(IPPROTO_IP, IP_TTL)
        let _ = channel.setOption(option, value: 1)

        let optionValue1 = try channel.getOption(option).wait()
        XCTAssertEqual(1, optionValue1)

        let _ = channel.setOption(option, value: 2)
        let optionValue2 = try channel.getOption(option).wait()
        XCTAssertEqual(2, optionValue2)
    }
}
