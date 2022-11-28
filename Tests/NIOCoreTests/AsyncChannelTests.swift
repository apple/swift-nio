//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
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
@testable import NIOCore
import NIOEmbedded
import XCTest

final class AsyncChannelTests: XCTestCase {
    func testAsyncChannelBasicFunctionality() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: String.self, outboundOut: Never.self)

            let iterator = wrapped.inboundStream.makeAsyncIterator()
            try await channel.writeInbound("hello")
            let firstRead = try await iterator.next()
            XCTAssertEqual(firstRead, "hello")

            try await channel.writeInbound("world")
            let secondRead = try await iterator.next()
            XCTAssertEqual(secondRead, "world")

            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            }

            let thirdRead = try await iterator.next()
            XCTAssertNil(thirdRead)

            try await channel.close()
        }
    }

    func testAsyncChannelBasicWrites() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: Never.self, outboundOut: String.self)

            try await wrapped.writeAndFlush("hello")
            try await wrapped.writeAndFlush("world")

            let firstRead = try await channel.waitForOutboundWrite(as: String.self)
            let secondRead = try await channel.waitForOutboundWrite(as: String.self)

            XCTAssertEqual(firstRead, "hello")
            XCTAssertEqual(secondRead, "world")

            try await channel.close()
        }
    }

    func testDroppingTheWriterClosesTheWriteSideOfTheChannel() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let closeRecorder = CloseRecorder()
            try await channel.pipeline.addHandler(closeRecorder)

            let inboundReader: NIOInboundChannelStream<Never>

            do {
                let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: Never.self, outboundOut: Never.self)
                inboundReader = wrapped.inboundStream

                try await channel.testingEventLoop.executeInContext {
                    XCTAssertEqual(0, closeRecorder.outboundCloses)
                }
            }

            try await channel.testingEventLoop.executeInContext {
                XCTAssertEqual(1, closeRecorder.outboundCloses)
            }

            // Just use this to keep the inbound reader alive.
            withExtendedLifetime(inboundReader) { }
            channel.close(promise: nil)
        }
    }

    func testDroppingTheWriterDoesntCloseTheWriteSideOfTheChannelIfHalfClosureIsDisabled() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let closeRecorder = CloseRecorder()
            try await channel.pipeline.addHandler(closeRecorder)

            let inboundReader: NIOInboundChannelStream<Never>

            do {
                let wrapped = try await NIOAsyncChannel(wrapping: channel, enableOutboundHalfClosure: false, inboundIn: Never.self, outboundOut: Never.self)
                inboundReader = wrapped.inboundStream

                try await channel.testingEventLoop.executeInContext {
                    XCTAssertEqual(0, closeRecorder.outboundCloses)
                }
            }

            try await channel.testingEventLoop.executeInContext {
                XCTAssertEqual(0, closeRecorder.outboundCloses)
            }

            // Just use this to keep the inbound reader alive.
            withExtendedLifetime(inboundReader) { }
            channel.close(promise: nil)
        }
    }

    func testDroppingTheWriterFirstLeadsToChannelClosureWhenReaderIsAlsoDropped() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let closeRecorder = CloseRecorder()
            try await channel.pipeline.addHandler(CloseSuppressor())
            try await channel.pipeline.addHandler(closeRecorder)

            do {
                let inboundReader: NIOInboundChannelStream<Never>

                do {
                    let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: Never.self, outboundOut: Never.self)
                    inboundReader = wrapped.inboundStream

                    try await channel.testingEventLoop.executeInContext {
                        XCTAssertEqual(0, closeRecorder.allCloses)
                    }
                }

                // First we see half-closure.
                try await channel.testingEventLoop.executeInContext {
                    XCTAssertEqual(1, closeRecorder.allCloses)
                }

                // Just use this to keep the inbound reader alive.
                withExtendedLifetime(inboundReader) { }
            }

            // Now the inbound reader is dead, we see full closure.
            try await channel.testingEventLoop.executeInContext {
                XCTAssertEqual(2, closeRecorder.allCloses)
            }

            try await channel.closeIgnoringSuppression()
        }
    }

    func testDroppingEverythingClosesTheChannel() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let closeRecorder = CloseRecorder()
            try await channel.pipeline.addHandler(CloseSuppressor())
            try await channel.pipeline.addHandler(closeRecorder)

            do {
                let wrapped = try await NIOAsyncChannel(wrapping: channel, enableOutboundHalfClosure: false, inboundIn: Never.self, outboundOut: Never.self)

                try await channel.testingEventLoop.executeInContext {
                    XCTAssertEqual(0, closeRecorder.allCloses)
                }

                // Just use this to keep the wrapper alive until here.
                withExtendedLifetime(wrapped) { }
            }

            // Now that everything is dead, we see full closure.
            try await channel.testingEventLoop.executeInContext {
                XCTAssertEqual(1, closeRecorder.allCloses)
            }

            try await channel.closeIgnoringSuppression()
        }
    }

    func testReadsArePropagated() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: String.self, outboundOut: Never.self)

            try await channel.writeInbound("hello")
            let propagated = try await channel.readInbound(as: String.self)
            XCTAssertEqual(propagated, "hello")

            try await channel.close().get()

            let reads = try await Array(wrapped.inboundStream)
            XCTAssertEqual(reads, ["hello"])
        }
    }

    func testErrorsArePropagatedButAfterReads() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: String.self, outboundOut: Never.self)

            try await channel.writeInbound("hello")
            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.fireErrorCaught(TestError.bang)
            }

            let iterator = wrapped.inboundStream.makeAsyncIterator()
            let first = try await iterator.next()
            XCTAssertEqual(first, "hello")

            try await XCTAssertThrowsError(await iterator.next()) { error in
                XCTAssertEqual(error as? TestError, .bang)
            }
        }
    }

    func testErrorsArePropagatedToWriters() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: Never.self, outboundOut: String.self)

            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.fireErrorCaught(TestError.bang)
            }

            try await XCTAssertThrowsError(await wrapped.writeAndFlush("hello")) { error in
                XCTAssertEqual(error as? TestError, .bang)
            }
        }
    }

    func testChannelBecomingNonWritableDelaysWriters() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: Never.self, outboundOut: String.self)

            try await channel.testingEventLoop.executeInContext {
                channel.isWritable = false
                channel.pipeline.fireChannelWritabilityChanged()
            }

            let lock = NIOLockedValueBox(false)

            await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await wrapped.writeAndFlush("hello")
                    lock.withLockedValue {
                        XCTAssertTrue($0)
                    }
                }

                group.addTask {
                    // 10ms sleep before we wake the thing up
                    try await Task.sleep(nanoseconds: 10_000_000)

                    try await channel.testingEventLoop.executeInContext {
                        channel.isWritable = true
                        lock.withLockedValue { $0 = true }
                        channel.pipeline.fireChannelWritabilityChanged()
                    }
                }
            }

            try await channel.close().get()
        }
    }

    func testBufferDropsReadsIfTheReaderIsGone() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            try await channel.pipeline.addHandler(CloseSuppressor()).get()
            do {
                // Create the NIOAsyncChannel, then drop it. The handler will still be in the pipeline.
                _ = try await NIOAsyncChannel(wrapping: channel, inboundIn: Sentinel.self, outboundOut: Never.self)
            }

            weak var sentinel: Sentinel? = nil
            do {
                let strongSentinel: Sentinel? = Sentinel()
                sentinel = strongSentinel!
                try await XCTAsyncAssertNotNil(try await channel.pipeline.handler(type: NIOAsyncChannelAdapterHandler<Sentinel>.self).get())
                try await channel.writeInbound(strongSentinel!)
                _ = try await channel.readInbound(as: Sentinel.self)
            }

            XCTAssertNil(sentinel)

            try await channel.closeIgnoringSuppression()
        }
    }

    func testManagingBackpressure() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let readCounter = ReadCounter()
            try await channel.pipeline.addHandler(readCounter)
            let wrapped = try await NIOAsyncChannel(wrapping: channel, backpressureStrategy: .init(lowWatermark: 2, highWatermark: 4), inboundIn: Void.self, outboundOut: Never.self )

            // Attempt to read. This should succeed an arbitrary number of times.
            XCTAssertEqual(readCounter.readCount, 0)
            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.read()
                channel.pipeline.read()
                channel.pipeline.read()
            }
            XCTAssertEqual(readCounter.readCount, 3)

            // Push 3 elements into the buffer. Reads continue to work.
            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.fireChannelRead(NIOAny(()))
                channel.pipeline.fireChannelRead(NIOAny(()))
                channel.pipeline.fireChannelRead(NIOAny(()))
                channel.pipeline.fireChannelReadComplete()

                channel.pipeline.read()
                channel.pipeline.read()
                channel.pipeline.read()
            }
            XCTAssertEqual(readCounter.readCount, 6)

            // Add one more element into the buffer. This should flip our backpressure mode, and the reads should now be delayed.
            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.fireChannelRead(NIOAny(()))
                channel.pipeline.fireChannelReadComplete()

                channel.pipeline.read()
                channel.pipeline.read()
                channel.pipeline.read()
            }
            XCTAssertEqual(readCounter.readCount, 6)

            // More elements don't help.
            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.fireChannelRead(NIOAny(()))
                channel.pipeline.fireChannelReadComplete()

                channel.pipeline.read()
                channel.pipeline.read()
                channel.pipeline.read()
            }
            XCTAssertEqual(readCounter.readCount, 6)

            // Now consume three elements from the pipeline. This should not unbuffer the read, as 3 elements remain.
            let reader = wrapped.inboundStream.makeAsyncIterator()
            for _ in 0..<3 {
                try await XCTAsyncAssertNotNil(try await reader.next())
            }
            await channel.testingEventLoop.run()
            XCTAssertEqual(readCounter.readCount, 6)

            // Removing the next element should trigger an automatic read.
            try await XCTAsyncAssertNotNil(try await reader.next())
            await channel.testingEventLoop.run()
            XCTAssertEqual(readCounter.readCount, 7)

            // Reads now work again, even if more data arrives.
            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.read()
                channel.pipeline.read()
                channel.pipeline.read()

                channel.pipeline.fireChannelRead(NIOAny(()))
                channel.pipeline.fireChannelReadComplete()

                channel.pipeline.read()
                channel.pipeline.read()
                channel.pipeline.read()
            }
            XCTAssertEqual(readCounter.readCount, 13)

            // The next reads arriving pushes us past the limit again.
            // This time we won't read.
            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.fireChannelRead(NIOAny(()))
                channel.pipeline.fireChannelRead(NIOAny(()))
                channel.pipeline.fireChannelReadComplete()
            }
            XCTAssertEqual(readCounter.readCount, 13)

            // This time we'll consume 4 more elements, and we won't find a read at all.
            for _ in 0..<4 {
                try await XCTAsyncAssertNotNil(try await reader.next())
            }
            await channel.testingEventLoop.run()
            XCTAssertEqual(readCounter.readCount, 13)

            // But the next reads work fine.
            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.read()
                channel.pipeline.read()
                channel.pipeline.read()
            }
            XCTAssertEqual(readCounter.readCount, 16)
        }
    }
}

final fileprivate class CloseRecorder: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    var outboundCloses = 0

    var allCloses = 0

    init() { }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        self.allCloses += 1

        if case .output = mode {
            self.outboundCloses += 1
        }

        context.close(mode: mode, promise: promise)
    }
}

final fileprivate class CloseSuppressor: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        // We drop the close here.
        promise?.fail(TestError.bang)
    }
}

extension NIOAsyncTestingChannel {
    fileprivate func closeIgnoringSuppression() async throws {
        try await self.pipeline.context(handlerType: CloseSuppressor.self).flatMap {
            self.pipeline.removeHandler(context: $0)
        }.flatMap {
            self.close()
        }.get()
    }
}

final fileprivate class ReadCounter: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    private let _readCount = ManagedAtomic(0)

    var readCount: Int {
        self._readCount.load(ordering: .acquiring)
    }

    func read(context: ChannelHandlerContext) {
        self._readCount.wrappingIncrement(ordering: .releasing)
        context.read()
    }
}

fileprivate enum TestError: Error {
    case bang
}

extension Array {
    fileprivate init<AS: AsyncSequence>(_ sequence: AS) async throws where AS.Element == Self.Element {
        self = []

        for try await nextElement in sequence {
            self.append(nextElement)
        }
    }
}

final fileprivate class Sentinel { }


