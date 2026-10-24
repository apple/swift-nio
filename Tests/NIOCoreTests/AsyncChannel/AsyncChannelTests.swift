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
import NIOEmbedded
import XCTest

@testable import NIOCore

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class AsyncChannelTests: XCTestCase {
    func testAsyncChannelCloseOnWrite() async throws {
        final class CloseOnWriteHandler: ChannelOutboundHandler {
            typealias OutboundIn = String

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                context.close(promise: promise)
            }
        }
        let channel = NIOAsyncTestingChannel()
        let wrapped = try await channel.testingEventLoop.executeInContext {
            try channel.pipeline.syncOperations.addHandler(CloseOnWriteHandler())
            return try NIOAsyncChannel<String, String>(wrappingChannelSynchronously: channel)
        }

        try await wrapped.executeThenClose { _, outbound in
            try await outbound.write("Test")
        }
    }

    func testAsyncChannelBasicFunctionality() async throws {
        let channel = NIOAsyncTestingChannel()
        let wrapped = try await channel.testingEventLoop.executeInContext {
            try NIOAsyncChannel<String, Never>(wrappingChannelSynchronously: channel)
        }

        try await wrapped.executeThenClose { inbound, _ in
            var iterator = inbound.makeAsyncIterator()
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
        }
    }

    func testAsyncChannelBasicWrites() async throws {
        let channel = NIOAsyncTestingChannel()
        let wrapped = try await channel.testingEventLoop.executeInContext {
            try NIOAsyncChannel<Never, String>(wrappingChannelSynchronously: channel)
        }

        try await wrapped.executeThenClose { _, outbound in
            try await outbound.write("hello")
            try await outbound.write("world")

            let firstRead = try await channel.waitForOutboundWrite(as: String.self)
            let secondRead = try await channel.waitForOutboundWrite(as: String.self)

            XCTAssertEqual(firstRead, "hello")
            XCTAssertEqual(secondRead, "world")
        }
    }

    func testAsyncChannelThrowsWhenChannelClosed() async throws {
        let channel = NIOAsyncTestingChannel()
        let wrapped = try await channel.testingEventLoop.executeInContext {
            try NIOAsyncChannel<String, String>(wrappingChannelSynchronously: channel)
        }

        try await channel.close(mode: .all)

        do {
            try await wrapped.executeThenClose { _, outbound in
                try await outbound.write("Test")
            }
            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertEqual(error as? ChannelError, ChannelError.ioOnClosedChannel)
        }
    }

    func testFinishingTheWriterClosesTheWriteSideOfTheChannel() async throws {
        let channel = NIOAsyncTestingChannel()
        let closeRecorder = CloseRecorder()
        try await channel.pipeline.addHandler(closeRecorder)

        let wrapped = try await channel.testingEventLoop.executeInContext {
            try NIOAsyncChannel(
                wrappingChannelSynchronously: channel,
                configuration: .init(
                    isOutboundHalfClosureEnabled: true,
                    inboundType: Never.self,
                    outboundType: Never.self
                )
            )
        }

        try await wrapped.executeThenClose { inbound, outbound in
            outbound.finish()

            await channel.testingEventLoop.run()

            try await channel.testingEventLoop.executeInContext {
                XCTAssertEqual(1, closeRecorder.outboundCloses)
            }

            // Just use this to keep the inbound reader alive.
            withExtendedLifetime(inbound) {}

        }
    }

    func testDroppingEverythingDoesntCloseTheChannel() async throws {
        let channel = NIOAsyncTestingChannel()
        let closeRecorder = CloseRecorder()
        try await channel.pipeline.addHandler(CloseSuppressor())
        try await channel.pipeline.addHandler(closeRecorder)

        do {
            _ = try await channel.testingEventLoop.executeInContext {
                try NIOAsyncChannel(
                    wrappingChannelSynchronously: channel,
                    configuration: .init(
                        isOutboundHalfClosureEnabled: false,
                        inboundType: Never.self,
                        outboundType: Never.self
                    )
                )
            }

            try await channel.testingEventLoop.executeInContext {
                XCTAssertEqual(0, closeRecorder.allCloses)
            }
        }

        // Now that everything is dead, we see full closure.
        try await channel.testingEventLoop.executeInContext {
            XCTAssertEqual(0, closeRecorder.allCloses)
        }

        try await channel.closeIgnoringSuppression()
    }

    func testReadsArePropagated() async throws {
        let channel = NIOAsyncTestingChannel()
        let wrapped = try await channel.testingEventLoop.executeInContext {
            try NIOAsyncChannel<String, Never>(wrappingChannelSynchronously: channel)
        }

        try await channel.writeInbound("hello")
        let propagated = try await channel.readInbound(as: String.self)
        XCTAssertEqual(propagated, "hello")

        try await channel.close().get()

        try await wrapped.executeThenClose { inbound, _ in
            let reads = try await Array(inbound)
            XCTAssertEqual(reads, ["hello"])
        }
    }

    func testErrorsArePropagatedButAfterReads() async throws {
        let channel = NIOAsyncTestingChannel()
        let wrapped = try await channel.testingEventLoop.executeInContext {
            try NIOAsyncChannel<String, Never>(wrappingChannelSynchronously: channel)
        }

        try await channel.writeInbound("hello")
        try await channel.testingEventLoop.executeInContext {
            channel.pipeline.fireErrorCaught(TestError.bang)
        }

        try await wrapped.executeThenClose { inbound, _ in
            var iterator = inbound.makeAsyncIterator()
            let first = try await iterator.next()
            XCTAssertEqual(first, "hello")

            try await XCTAssertThrowsError(await iterator.next()) { error in
                XCTAssertEqual(error as? TestError, .bang)
            }
        }
    }

    func testChannelBecomingNonWritableDelaysWriters() async throws {
        let channel = NIOAsyncTestingChannel()
        let wrapped = try await channel.testingEventLoop.executeInContext {
            try NIOAsyncChannel<Never, String>(wrappingChannelSynchronously: channel)
        }

        try await channel.testingEventLoop.executeInContext {
            channel.isWritable = false
            channel.pipeline.fireChannelWritabilityChanged()
        }

        let lock = NIOLockedValueBox(false)

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await wrapped.executeThenClose { _, outbound in
                    try await outbound.write("hello")
                    lock.withLockedValue {
                        XCTAssertTrue($0)
                    }
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
    }

    func testBufferDropsReadsIfTheReaderIsGone() async throws {
        let channel = NIOAsyncTestingChannel()
        try await channel.pipeline.addHandler(CloseSuppressor()).get()
        do {
            // Create the NIOAsyncChannel, then drop it. The handler will still be in the pipeline.
            _ = try await channel.testingEventLoop.executeInContext {
                _ = try NIOAsyncChannel<Sentinel, Never>(wrappingChannelSynchronously: channel)
            }
        }

        weak var sentinel: Sentinel?
        do {
            let strongSentinel: Sentinel? = Sentinel()
            sentinel = strongSentinel!
            try await XCTAsyncAssertNotNil(
                await channel.pipeline.handler(type: NIOAsyncChannelHandler<Sentinel, Sentinel, Never>.self).map {
                    _ -> Bool in
                    true
                }.get()
            )
            try await channel.writeInbound(strongSentinel!)
            _ = try await channel.readInbound(as: Sentinel.self)
        }

        XCTAssertNil(sentinel)

        try await channel.closeIgnoringSuppression()
    }

    func testManagingBackPressure() async throws {
        let channel = NIOAsyncTestingChannel()
        let readCounter = ReadCounter()
        try await channel.pipeline.addHandler(readCounter)
        let wrapped = try await channel.testingEventLoop.executeInContext {
            try NIOAsyncChannel(
                wrappingChannelSynchronously: channel,
                configuration: .init(
                    backPressureStrategy: .init(lowWatermark: 2, highWatermark: 4),
                    inboundType: Void.self,
                    outboundType: Never.self
                )
            )
        }

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
            channel.pipeline.fireChannelRead(())
            channel.pipeline.fireChannelRead(())
            channel.pipeline.fireChannelRead(())
            channel.pipeline.fireChannelReadComplete()

            channel.pipeline.read()
            channel.pipeline.read()
            channel.pipeline.read()
        }
        XCTAssertEqual(readCounter.readCount, 6)

        // Add one more element into the buffer. This should flip our backpressure mode, and the reads should now be delayed.
        try await channel.testingEventLoop.executeInContext {
            channel.pipeline.fireChannelRead(())
            channel.pipeline.fireChannelReadComplete()

            channel.pipeline.read()
            channel.pipeline.read()
            channel.pipeline.read()
        }
        XCTAssertEqual(readCounter.readCount, 6)

        // More elements don't help.
        try await channel.testingEventLoop.executeInContext {
            channel.pipeline.fireChannelRead(())
            channel.pipeline.fireChannelReadComplete()

            channel.pipeline.read()
            channel.pipeline.read()
            channel.pipeline.read()
        }
        XCTAssertEqual(readCounter.readCount, 6)

        try await wrapped.executeThenClose { inbound, outbound in
            // Now consume three elements from the pipeline. This should not unbuffer the read, as 3 elements remain.
            var reader = inbound.makeAsyncIterator()
            for _ in 0..<3 {
                try await XCTAsyncAssertNotNil(await reader.next())
            }
            await channel.testingEventLoop.run()
            XCTAssertEqual(readCounter.readCount, 6)

            // Removing the next element should trigger an automatic read.
            try await XCTAsyncAssertNotNil(await reader.next())
            await channel.testingEventLoop.run()
            XCTAssertEqual(readCounter.readCount, 7)

            // Reads now work again, even if more data arrives.
            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.read()
                channel.pipeline.read()
                channel.pipeline.read()

                channel.pipeline.fireChannelRead(())
                channel.pipeline.fireChannelReadComplete()

                channel.pipeline.read()
                channel.pipeline.read()
                channel.pipeline.read()
            }
            XCTAssertEqual(readCounter.readCount, 13)

            // The next reads arriving pushes us past the limit again.
            // This time we won't read.
            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.fireChannelRead(())
                channel.pipeline.fireChannelRead(())
                channel.pipeline.fireChannelReadComplete()
            }
            XCTAssertEqual(readCounter.readCount, 13)

            // This time we'll consume 4 more elements, and we won't find a read at all.
            for _ in 0..<4 {
                try await XCTAsyncAssertNotNil(await reader.next())
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

    func testCanWrapAChannelSynchronously() async throws {
        let channel = NIOAsyncTestingChannel()
        let wrapped = try await channel.testingEventLoop.executeInContext {
            try NIOAsyncChannel<String, String>(wrappingChannelSynchronously: channel)
        }

        try await wrapped.executeThenClose { inbound, outbound in
            var iterator = inbound.makeAsyncIterator()
            try await channel.writeInbound("hello")
            let firstRead = try await iterator.next()
            XCTAssertEqual(firstRead, "hello")

            try await outbound.write("world")
            let write = try await channel.waitForOutboundWrite(as: String.self)
            XCTAssertEqual(write, "world")

            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            }

            let secondRead = try await iterator.next()
            XCTAssertNil(secondRead)
        }
    }

    func testExecuteThenCloseFromActor() async throws {
        final actor TestActor {
            func test() async throws {
                let channel = NIOAsyncTestingChannel()
                let wrapped = try await channel.testingEventLoop.executeInContext {
                    try NIOAsyncChannel<String, String>(wrappingChannelSynchronously: channel)
                }

                try await wrapped.executeThenClose { inbound, outbound in
                    var iterator = inbound.makeAsyncIterator()
                    try await channel.writeInbound("hello")
                    let firstRead = try await iterator.next()
                    XCTAssertEqual(firstRead, "hello")

                    try await outbound.write("world")
                    let write = try await channel.waitForOutboundWrite(as: String.self)
                    XCTAssertEqual(write, "world")

                    try await channel.testingEventLoop.executeInContext {
                        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
                    }

                    let secondRead = try await iterator.next()
                    XCTAssertNil(secondRead)
                }
            }
        }

        let actor = TestActor()
        try await actor.test()
    }

    func testExecuteThenCloseFromActorReferencingSelf() async throws {
        final actor TestActor {
            let hello = "hello"
            let world = "world"

            func test() async throws {
                let channel = NIOAsyncTestingChannel()
                let wrapped = try await channel.testingEventLoop.executeInContext {
                    try NIOAsyncChannel<String, String>(wrappingChannelSynchronously: channel)
                }

                try await wrapped.executeThenClose { inbound, outbound in
                    var iterator = inbound.makeAsyncIterator()
                    try await channel.writeInbound(self.hello)
                    let firstRead = try await iterator.next()
                    XCTAssertEqual(firstRead, "hello")

                    try await outbound.write(self.world)
                    let write = try await channel.waitForOutboundWrite(as: String.self)
                    XCTAssertEqual(write, "world")

                    try await channel.testingEventLoop.executeInContext {
                        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
                    }

                    let secondRead = try await iterator.next()
                    XCTAssertNil(secondRead)
                }
            }
        }

        let actor = TestActor()
        try await actor.test()
    }

    func testExecuteThenCloseInboundChannelFromActor() async throws {
        final actor TestActor {
            func test() async throws {
                let channel = NIOAsyncTestingChannel()
                let wrapped = try await channel.testingEventLoop.executeInContext {
                    try NIOAsyncChannel<String, Never>(wrappingChannelSynchronously: channel)
                }

                try await wrapped.executeThenClose { inbound in
                    var iterator = inbound.makeAsyncIterator()
                    try await channel.writeInbound("hello")
                    let firstRead = try await iterator.next()
                    XCTAssertEqual(firstRead, "hello")

                    try await channel.testingEventLoop.executeInContext {
                        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
                    }

                    let secondRead = try await iterator.next()
                    XCTAssertNil(secondRead)
                }
            }
        }

        let actor = TestActor()
        try await actor.test()
    }

    func testExecuteThenCloseNonSendableResultCross() async throws {
        final class NonSendable {
            var someMutableState: Int = 5
        }

        final actor TestActor {
            func test() async throws -> sending NonSendable {
                let channel = NIOAsyncTestingChannel()
                let wrapped = try await channel.testingEventLoop.executeInContext {
                    try NIOAsyncChannel<String, String>(wrappingChannelSynchronously: channel)
                }

                return try await wrapped.executeThenClose { _, _ in
                    NonSendable()
                }
            }
        }

        let actor = TestActor()
        let r = try await actor.test()
        XCTAssertEqual(r.someMutableState, 5)
    }

    func testExecuteThenCloseInboundNonSendableResultCross() async throws {
        final class NonSendable {
            var someMutableState: Int = 5
        }

        final actor TestActor {
            func test() async throws -> sending NonSendable {
                let channel = NIOAsyncTestingChannel()
                let wrapped = try await channel.testingEventLoop.executeInContext {
                    try NIOAsyncChannel<String, Never>(wrappingChannelSynchronously: channel)
                }

                return try await wrapped.executeThenClose { _ in
                    NonSendable()
                }
            }
        }

        let actor = TestActor()
        let r = try await actor.test()
        XCTAssertEqual(r.someMutableState, 5)
    }
}

// This is unchecked Sendable since we only call this in the testing eventloop
private final class CloseRecorder: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = Any
    typealias outbound = Any

    var outboundCloses = 0

    var allCloses = 0

    init() {}

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        self.allCloses += 1

        if case .output = mode {
            self.outboundCloses += 1
        }

        context.close(mode: mode, promise: promise)
    }
}

private final class CloseSuppressor: ChannelOutboundHandler, RemovableChannelHandler, Sendable {
    typealias OutboundIn = Any

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        // We drop the close here.
        promise?.fail(TestError.bang)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncTestingChannel {
    fileprivate func closeIgnoringSuppression() async throws {
        try await self.pipeline.context(handlerType: CloseSuppressor.self).flatMap {
            self.pipeline.syncOperations.removeHandler(context: $0)
        }.flatMap {
            self.close()
        }.get()
    }
}

private final class ReadCounter: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = Any
    typealias outbound = Any

    private let _readCount = ManagedAtomic(0)

    var readCount: Int {
        self._readCount.load(ordering: .acquiring)
    }

    func read(context: ChannelHandlerContext) {
        self._readCount.wrappingIncrement(ordering: .releasing)
        context.read()
    }
}

private enum TestError: Error {
    case bang
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension Array {
    fileprivate init<AS: AsyncSequence>(_ sequence: AS) async throws where AS.Element == Self.Element {
        self = []

        for try await nextElement in sequence {
            self.append(nextElement)
        }
    }
}

private final class Sentinel: Sendable {}
