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
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            class Handler: ChannelInboundHandler {
                typealias InboundIn = Never
            }

            let channel = await NIOAsyncTestingChannel(handler: Handler())
            XCTAssertNoThrow(try channel.pipeline.handler(type: Handler.self).wait())
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testEmptyInit() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }

        class Handler: ChannelInboundHandler {
            typealias InboundIn = Never
        }

        let channel = NIOAsyncTestingChannel()
        XCTAssertThrowsError(try channel.pipeline.handler(type: Handler.self).wait()) { e in
            XCTAssertEqual(e as? ChannelPipelineError, .notFound)
        }

        #else
        throw XCTSkip()
        #endif
    }

    func testMultipleHandlerInit() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
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
        #else
        throw XCTSkip()
        #endif
    }

    func testWriteOutboundByteBuffer() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
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
        #else
        throw XCTSkip()
        #endif
    }

    func testWriteOutboundByteBufferMultipleTimes() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
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
        #else
        throw XCTSkip()
        #endif
    }

    func testWriteInboundByteBuffer() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
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
        #else
        throw XCTSkip()
        #endif
    }

    func testWriteInboundByteBufferMultipleTimes() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
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
        #else
        throw XCTSkip()
        #endif
    }

    func testWriteInboundByteBufferReThrow() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            XCTAssertNoThrow(try channel.pipeline.addHandler(ExceptionThrowingInboundHandler()).wait())
            await XCTAsyncAssertThrowsError(try await channel.writeInbound("msg")) { error in
                XCTAssertEqual(ChannelError.operationUnsupported, error as? ChannelError)
            }
            try await XCTAsyncAssertTrue(await channel.finish().isClean)
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testWriteOutboundByteBufferReThrow() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            XCTAssertNoThrow(try channel.pipeline.addHandler(ExceptionThrowingOutboundHandler()).wait())
            await XCTAsyncAssertThrowsError(try await channel.writeOutbound("msg")) { error in
                XCTAssertEqual(ChannelError.operationUnsupported, error as? ChannelError)
            }
            try await XCTAsyncAssertTrue(await channel.finish().isClean)
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testReadOutboundWrongTypeThrows() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
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
        #else
        throw XCTSkip()
        #endif
    }

    func testReadInboundWrongTypeThrows() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
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
        #else
        throw XCTSkip()
        #endif
    }

    func testWrongTypesWithFastpathTypes() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
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
                                                   file: StaticString = #file,
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
        #else
        throw XCTSkip()
        #endif
    }

    func testCloseMultipleTimesThrows() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
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
        #else
        throw XCTSkip()
        #endif
    }

    func testCloseOnInactiveIsOk() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            let inactiveHandler = CloseInChannelInactiveHandler()
            XCTAssertNoThrow(try channel.pipeline.addHandler(inactiveHandler).wait())
            try await XCTAsyncAssertTrue(await channel.finish().isClean)

            // channelInactive should fire only once.
            XCTAssertEqual(inactiveHandler.inactiveNotifications, 1)
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testEmbeddedLifecycle() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
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
        #else
        throw XCTSkip()
        #endif
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
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            let pipelineEventLoop = channel.pipeline.eventLoop
            XCTAssert(pipelineEventLoop === channel.eventLoop)
            XCTAssert(pipelineEventLoop === (channel._channelCore as! EmbeddedChannelCore).eventLoop)
            try await XCTAsyncAssertTrue(await channel.finish().isClean)
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testSendingAnythingOnEmbeddedChannel() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
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
        #else
        throw XCTSkip()
        #endif
    }

    func testActiveWhenConnectPromiseFiresAndInactiveWhenClosePromiseFires() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
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
        #else
        throw XCTSkip()
        #endif
    }

    func testWriteWithoutFlushDoesNotWrite() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
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
        #else
        throw XCTSkip()
        #endif
    }

    func testSetLocalAddressAfterSuccessfulBind() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }

        let channel = NIOAsyncTestingChannel()
        let bindPromise = channel.eventLoop.makePromise(of: Void.self)
        let socketAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        channel.bind(to: socketAddress, promise: bindPromise)
        bindPromise.futureResult.whenComplete { _ in
            XCTAssertEqual(channel.localAddress, socketAddress)
        }
        try bindPromise.futureResult.wait()

        #else
        throw XCTSkip()
        #endif
    }

    func testSetRemoteAddressAfterSuccessfulConnect() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }

        let channel = NIOAsyncTestingChannel()
        let connectPromise = channel.eventLoop.makePromise(of: Void.self)
        let socketAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        channel.connect(to: socketAddress, promise: connectPromise)
        connectPromise.futureResult.whenComplete { _ in
            XCTAssertEqual(channel.remoteAddress, socketAddress)
        }
        try connectPromise.futureResult.wait()

        #else
        throw XCTSkip()
        #endif
    }

    func testUnprocessedOutboundUserEventFailsOnEmbeddedChannel() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }

        let channel = NIOAsyncTestingChannel()
        XCTAssertThrowsError(try channel.triggerUserOutboundEvent("event").wait()) { (error: Error) in
            if let error = error as? ChannelError {
                XCTAssertEqual(ChannelError.operationUnsupported, error)
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }

        #else
        throw XCTSkip()
        #endif
    }

    func testEmbeddedChannelWritabilityIsWritable() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }

        let channel = NIOAsyncTestingChannel()
        let opaqueChannel: Channel = channel
        XCTAssertTrue(channel.isWritable)
        XCTAssertTrue(opaqueChannel.isWritable)
        channel.isWritable = false
        XCTAssertFalse(channel.isWritable)
        XCTAssertFalse(opaqueChannel.isWritable)

        #else
        throw XCTSkip()
        #endif
    }

    func testFinishWithRecursivelyScheduledTasks() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
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
        #else
        throw XCTSkip()
        #endif
    }

    func testSyncOptionsAreSupported() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        let channel = NIOAsyncTestingChannel()
        try channel.testingEventLoop.submit {
            let options = channel.syncOptions
            XCTAssertNotNil(options)
            // Unconditionally returns true.
            XCTAssertEqual(try options?.getOption(ChannelOptions.autoRead), true)
            // (Setting options isn't supported.)
        }.wait()
        #else
        throw XCTSkip()
        #endif
    }

    func testSecondFinishThrows() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let channel = NIOAsyncTestingChannel()
            _ = try await channel.finish()
            await XCTAsyncAssertThrowsError(try await channel.finish())
        }
        #else
        throw XCTSkip()
        #endif
    }
}

#if compiler(>=5.5.2) && canImport(_Concurrency)
fileprivate func XCTAsyncAssertTrue(_ predicate: @autoclosure () async throws -> Bool, file: StaticString = #file, line: UInt = #line) async rethrows {
    let result = try await predicate()
    XCTAssertTrue(result, file: file, line: line)
}

fileprivate func XCTAsyncAssertEqual<Element: Equatable>(_ lhs: @autoclosure () async throws -> Element, _ rhs: @autoclosure () async throws -> Element, file: StaticString = #file, line: UInt = #line) async rethrows {
    let lhsResult = try await lhs()
    let rhsResult = try await rhs()
    XCTAssertEqual(lhsResult, rhsResult, file: file, line: line)
}

fileprivate func XCTAsyncAssertThrowsError<ResultType>(_ expression: @autoclosure () async throws -> ResultType, file: StaticString = #file, line: UInt = #line, _ callback: Optional<(Error) -> Void> = nil) async {
    do {
        let _ = try await expression()
        XCTFail("Did not throw", file: file, line: line)
    } catch {
        callback?(error)
    }
}

fileprivate func XCTAsyncAssertNil(_ expression: @autoclosure () async throws -> Any?, file: StaticString = #file, line: UInt = #line) async rethrows {
    let result = try await expression()
    XCTAssertNil(result, file: file, line: line)
}

fileprivate func XCTAsyncAssertNotNil(_ expression: @autoclosure () async throws -> Any?, file: StaticString = #file, line: UInt = #line) async rethrows {
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
#endif
