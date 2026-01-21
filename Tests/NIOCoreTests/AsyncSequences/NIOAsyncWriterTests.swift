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

import DequeModule
import NIOConcurrencyHelpers
import NIOTestUtils
import XCTest

@testable import NIOCore

private struct SomeError: Error, Hashable {}

private final class MockAsyncWriterDelegate: NIOAsyncWriterSinkDelegate, @unchecked Sendable {
    typealias Element = String

    var _didYieldCallCount = NIOLockedValueBox(0)
    var didYieldCallCount: Int {
        self._didYieldCallCount.withLockedValue { $0 }
    }
    var didYieldHandler: ((Deque<String>) -> Void)?
    func didYield(contentsOf sequence: Deque<String>) {
        self._didYieldCallCount.withLockedValue { $0 += 1 }
        if let didYieldHandler = self.didYieldHandler {
            didYieldHandler(sequence)
        }
    }

    var _didSuspendCallCount = NIOLockedValueBox(0)
    var didSuspendCallCount: Int {
        self._didSuspendCallCount.withLockedValue { $0 }
    }
    var didSuspendHandler: (() -> Void)?
    func didSuspend() {
        self._didSuspendCallCount.withLockedValue { $0 += 1 }
        if let didSuspendHandler = self.didSuspendHandler {
            didSuspendHandler()
        }
    }

    var _didTerminateCallCount = NIOLockedValueBox(0)
    var didTerminateCallCount: Int {
        self._didTerminateCallCount.withLockedValue { $0 }
    }
    var didTerminateHandler: ((Error?) -> Void)?
    func didTerminate(error: Error?) {
        self._didTerminateCallCount.withLockedValue { $0 += 1 }
        if let didTerminateHandler = self.didTerminateHandler {
            didTerminateHandler(error)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class NIOAsyncWriterTests: XCTestCase {
    private var writer: NIOAsyncWriter<String, MockAsyncWriterDelegate>!
    private var sink: NIOAsyncWriter<String, MockAsyncWriterDelegate>.Sink!
    private var delegate: MockAsyncWriterDelegate!

    override func setUp() {
        super.setUp()

        let delegate = MockAsyncWriterDelegate()
        self.delegate = delegate
        let newWriter = NIOAsyncWriter.makeWriter(
            elementType: String.self,
            isWritable: true,
            finishOnDeinit: false,
            delegate: self.delegate
        )
        self.writer = newWriter.writer
        self.sink = newWriter.sink
        self.sink._storage._setDidSuspend { delegate.didSuspend() }
    }

    override func tearDown() {
        if let writer = self.writer {
            writer.finish()
        }
        if let sink = self.sink {
            sink.finish()
        }
        self.delegate = nil
        self.writer = nil
        self.sink = nil

        super.tearDown()
    }

    func assert(
        suspendCallCount: Int,
        yieldCallCount: Int,
        terminateCallCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            self.delegate.didSuspendCallCount,
            suspendCallCount,
            "Unexpeced suspends",
            file: file,
            line: line
        )
        XCTAssertEqual(self.delegate.didYieldCallCount, yieldCallCount, "Unexpected yields", file: file, line: line)
        XCTAssertEqual(
            self.delegate.didTerminateCallCount,
            terminateCallCount,
            "Unexpected terminates",
            file: file,
            line: line
        )
    }

    func testMultipleConcurrentWrites() async throws {
        var elements = 0
        self.delegate.didYieldHandler = { elements += $0.count }
        let task1 = Task { [writer] in
            for i in 0...9 {
                try await writer!.yield("message\(i)")
            }
        }
        let task2 = Task { [writer] in
            for i in 10...19 {
                try await writer!.yield("message\(i)")
            }
        }
        let task3 = Task { [writer] in
            for i in 20...29 {
                try await writer!.yield("message\(i)")
            }
        }

        try await task1.value
        try await task2.value
        try await task3.value

        XCTAssertEqual(elements, 30)
    }

    func testMultipleConcurrentBatchWrites() async throws {
        var elements = 0
        self.delegate.didYieldHandler = { elements += $0.count }
        let task1 = Task { [writer] in
            for i in 0...9 {
                try await writer!.yield(contentsOf: ["message\(i).1", "message\(i).2"])
            }
        }
        let task2 = Task { [writer] in
            for i in 10...19 {
                try await writer!.yield(contentsOf: ["message\(i).1", "message\(i).2"])
            }
        }
        let task3 = Task { [writer] in
            for i in 20...29 {
                try await writer!.yield(contentsOf: ["message\(i).1", "message\(i).2"])
            }
        }

        try await task1.value
        try await task2.value
        try await task3.value

        XCTAssertEqual(elements, 60)
    }

    // MARK: - WriterDeinitialized

    func testWriterDeinitialized_whenInitial() async throws {
        var newWriter: NIOAsyncWriter<String, MockAsyncWriterDelegate>.NewWriter? = NIOAsyncWriter.makeWriter(
            elementType: String.self,
            isWritable: true,
            finishOnDeinit: true,
            delegate: self.delegate
        )
        let sink = newWriter!.sink
        var writer: NIOAsyncWriter<String, MockAsyncWriterDelegate>? = newWriter!.writer
        newWriter = nil

        writer = nil

        self.assert(suspendCallCount: 0, yieldCallCount: 0, terminateCallCount: 1)
        XCTAssertNil(writer)

        sink.finish()
    }

    func testWriterDeinitialized_whenStreaming() async throws {
        var newWriter: NIOAsyncWriter<String, MockAsyncWriterDelegate>.NewWriter? = NIOAsyncWriter.makeWriter(
            elementType: String.self,
            isWritable: true,
            finishOnDeinit: true,
            delegate: self.delegate
        )
        let sink = newWriter!.sink
        var writer: NIOAsyncWriter<String, MockAsyncWriterDelegate>? = newWriter!.writer
        newWriter = nil

        try await writer!.yield("message1")
        writer = nil

        self.assert(suspendCallCount: 0, yieldCallCount: 1, terminateCallCount: 1)
        XCTAssertNil(writer)

        sink.finish()
    }

    func testWriterDeinitialized_whenWriterFinished() async throws {
        try await writer.yield("message1")
        self.writer.finish()
        self.writer = nil

        self.assert(suspendCallCount: 0, yieldCallCount: 1, terminateCallCount: 1)
    }

    func testWriterDeinitialized_whenFinished() async throws {
        self.sink.finish()

        self.assert(suspendCallCount: 0, yieldCallCount: 0, terminateCallCount: 0)

        self.writer = nil

        self.assert(suspendCallCount: 0, yieldCallCount: 0, terminateCallCount: 0)
    }

    // MARK: - ToggleWritability

    func testSetWritability_whenInitial() async throws {
        self.sink.setWritability(to: false)

        let suspended = expectation(description: "suspended on yield")
        self.delegate.didSuspendHandler = {
            suspended.fulfill()
        }

        Task { [writer] in
            try await writer!.yield("message1")
        }

        await fulfillment(of: [suspended], timeout: 1)

        self.assert(suspendCallCount: 1, yieldCallCount: 0, terminateCallCount: 0)
    }

    func testSetWritability_whenStreaming_andBecomingUnwritable() async throws {
        try await self.writer.yield("message1")
        XCTAssertEqual(self.delegate.didYieldCallCount, 1)

        self.sink.setWritability(to: false)

        let suspended = expectation(description: "suspended on yield")
        self.delegate.didSuspendHandler = {
            suspended.fulfill()
        }

        Task { [writer] in
            try await writer!.yield("message2")
        }

        await fulfillment(of: [suspended], timeout: 1)

        self.assert(suspendCallCount: 1, yieldCallCount: 1, terminateCallCount: 0)
    }

    func testSetWritability_whenStreaming_andBecomingWritable() async throws {
        self.sink.setWritability(to: false)

        let suspended = expectation(description: "suspended on yield")
        self.delegate.didSuspendHandler = {
            suspended.fulfill()
        }
        let resumed = expectation(description: "yield completed")

        Task { [writer] in
            try await writer!.yield("message2")
            resumed.fulfill()
        }

        await fulfillment(of: [suspended], timeout: 1)

        self.sink.setWritability(to: true)

        await fulfillment(of: [resumed], timeout: 1)

        self.assert(suspendCallCount: 1, yieldCallCount: 1, terminateCallCount: 0)
    }

    func testSetWritability_whenStreaming_andSettingSameWritability() async throws {
        self.sink.setWritability(to: false)

        let suspended = expectation(description: "suspended on yield")
        self.delegate.didSuspendHandler = {
            suspended.fulfill()
        }

        Task { [writer] in
            try await writer!.yield("message1")
        }

        await fulfillment(of: [suspended], timeout: 1)

        // Setting the writability to the same state again shouldn't change anything
        self.sink.setWritability(to: false)

        self.assert(suspendCallCount: 1, yieldCallCount: 0, terminateCallCount: 0)
    }

    func testSetWritability_whenWriterFinished() async throws {
        self.sink.setWritability(to: false)

        let suspended = expectation(description: "suspended on yield")
        self.delegate.didSuspendHandler = {
            suspended.fulfill()
        }
        let resumed = expectation(description: "yield completed")

        Task { [writer] in
            try await writer!.yield("message1")
            resumed.fulfill()
        }

        await fulfillment(of: [suspended], timeout: 1)

        self.writer.finish()

        self.assert(suspendCallCount: 1, yieldCallCount: 0, terminateCallCount: 0)

        self.sink.setWritability(to: true)

        await fulfillment(of: [resumed], timeout: 1)

        self.assert(suspendCallCount: 1, yieldCallCount: 1, terminateCallCount: 1)
    }

    func testSetWritability_whenFinished() async throws {
        self.sink.finish()

        self.sink.setWritability(to: false)

        self.assert(suspendCallCount: 0, yieldCallCount: 0, terminateCallCount: 0)
    }

    // MARK: - Yield

    func testYield_whenInitial_andWritable() async throws {
        try await self.writer.yield("message1")

        self.assert(suspendCallCount: 0, yieldCallCount: 1, terminateCallCount: 0)
    }

    func testYield_whenInitial_andNotWritable() async throws {
        self.sink.setWritability(to: false)

        let suspended = expectation(description: "suspended on yield")
        self.delegate.didSuspendHandler = {
            suspended.fulfill()
        }

        Task { [writer] in
            try await writer!.yield("message2")
        }

        await fulfillment(of: [suspended], timeout: 1)

        self.assert(suspendCallCount: 1, yieldCallCount: 0, terminateCallCount: 0)
    }

    func testYield_whenStreaming_andWritable() async throws {
        try await self.writer.yield("message1")

        self.assert(suspendCallCount: 0, yieldCallCount: 1, terminateCallCount: 0)

        try await self.writer.yield("message2")

        self.assert(suspendCallCount: 0, yieldCallCount: 2, terminateCallCount: 0)
    }

    func testYield_whenStreaming_andNotWritable() async throws {
        try await self.writer.yield("message1")

        self.assert(suspendCallCount: 0, yieldCallCount: 1, terminateCallCount: 0)

        self.sink.setWritability(to: false)

        let suspended = expectation(description: "suspended on yield")
        self.delegate.didSuspendHandler = {
            suspended.fulfill()
        }

        Task { [writer] in
            try await writer!.yield("message2")
        }

        await fulfillment(of: [suspended], timeout: 1)

        self.assert(suspendCallCount: 1, yieldCallCount: 1, terminateCallCount: 0)
    }

    func testYield_whenStreaming_andYieldCancelled() async throws {
        try await self.writer.yield("message1")

        self.assert(suspendCallCount: 0, yieldCallCount: 1, terminateCallCount: 0)

        let cancelled = expectation(description: "task cancelled")

        let task = Task { [writer] in
            await XCTWaiter().fulfillment(of: [cancelled], timeout: 1)
            try await writer!.yield("message2")
        }

        task.cancel()
        cancelled.fulfill()

        await XCTAssertThrowsError(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        self.assert(suspendCallCount: 0, yieldCallCount: 1, terminateCallCount: 0)
    }

    func testYield_cancelWhenStreamingAndNotWritable() async throws {
        try await self.writer.yield("message1")
        self.assert(suspendCallCount: 0, yieldCallCount: 1, terminateCallCount: 0)
        // Ensure the yield suspends
        self.sink.setWritability(to: false)

        let task = Task { [writer] in
            try await writer!.yield("message2")
        }
        task.cancel()

        await XCTAssertThrowsError(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testYield_whenWriterFinished() async throws {
        self.sink.setWritability(to: false)

        let suspended = expectation(description: "suspended on yield")
        self.delegate.didSuspendHandler = {
            suspended.fulfill()
        }

        Task { [writer] in
            try await writer!.yield("message1")
        }

        await fulfillment(of: [suspended], timeout: 1)

        self.writer.finish()

        await XCTAssertThrowsError(try await self.writer.yield("message1")) { error in
            XCTAssertEqual(error as? NIOAsyncWriterError, .alreadyFinished())
        }
        self.assert(suspendCallCount: 1, yieldCallCount: 0, terminateCallCount: 0)
    }

    func testYield_whenFinished() async throws {
        self.sink.finish()

        await XCTAssertThrowsError(try await self.writer.yield("message1")) { error in
            XCTAssertEqual(error as? NIOAsyncWriterError, .alreadyFinished())
        }
        self.assert(suspendCallCount: 0, yieldCallCount: 0, terminateCallCount: 0)
    }

    func testYield_whenFinishedError() async throws {
        self.sink.finish(error: SomeError())

        await XCTAssertThrowsError(try await self.writer.yield("message1")) { error in
            XCTAssertTrue(error is SomeError)
        }
        self.assert(suspendCallCount: 0, yieldCallCount: 0, terminateCallCount: 0)
    }

    // MARK: - Cancel

    func testCancel_whenInitial() async throws {
        let cancelled = expectation(description: "task cancelled")

        let task = Task { [writer] in
            await XCTWaiter().fulfillment(of: [cancelled], timeout: 1)
            try await writer!.yield("message1")
        }

        task.cancel()
        cancelled.fulfill()

        await XCTAssertThrowsError(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        self.assert(suspendCallCount: 0, yieldCallCount: 0, terminateCallCount: 0)
    }

    func testCancel_whenStreaming_andCancelBeforeYield() async throws {
        try await self.writer.yield("message1")

        self.assert(suspendCallCount: 0, yieldCallCount: 1, terminateCallCount: 0)

        let cancelled = expectation(description: "task cancelled")

        let task = Task { [writer] in
            await XCTWaiter().fulfillment(of: [cancelled], timeout: 1)
            try await writer!.yield("message2")
        }

        task.cancel()
        cancelled.fulfill()

        await XCTAssertThrowsError(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        self.assert(suspendCallCount: 0, yieldCallCount: 1, terminateCallCount: 0)
    }

    func testCancel_whenStreaming_andCancelAfterSuspendedYield() async throws {
        try await self.writer.yield("message1")

        self.assert(suspendCallCount: 0, yieldCallCount: 1, terminateCallCount: 0)

        self.sink.setWritability(to: false)

        let suspended = expectation(description: "suspended on yield")
        self.delegate.didSuspendHandler = {
            suspended.fulfill()
        }

        let task = Task { [writer] in
            try await writer!.yield("message2")
        }

        await fulfillment(of: [suspended], timeout: 1)

        self.assert(suspendCallCount: 1, yieldCallCount: 1, terminateCallCount: 0)

        task.cancel()

        await XCTAssertThrowsError(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }

        self.assert(suspendCallCount: 1, yieldCallCount: 1, terminateCallCount: 0)

        self.sink.setWritability(to: true)

        self.assert(suspendCallCount: 1, yieldCallCount: 1, terminateCallCount: 0)
    }

    func testCancel_whenFinished() async throws {
        self.writer.finish()

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)

        let cancelled = expectation(description: "task cancelled")

        let task = Task { [writer] in
            await XCTWaiter().fulfillment(of: [cancelled], timeout: 1)
            try await writer!.yield("message1")
        }

        task.cancel()
        cancelled.fulfill()

        await XCTAssertThrowsError(try await task.value) { error in
            XCTAssertEqual(error as? NIOAsyncWriterError, .alreadyFinished())
        }
        XCTAssertEqual(self.delegate.didYieldCallCount, 0)
    }

    // MARK: - Writer Finish

    func testWriterFinish_whenInitial() async throws {
        self.writer.finish()

        self.assert(suspendCallCount: 0, yieldCallCount: 0, terminateCallCount: 1)
    }

    func testWriterFinish_whenInitial_andFailure() async throws {
        self.writer.finish(error: SomeError())

        self.assert(suspendCallCount: 0, yieldCallCount: 0, terminateCallCount: 1)
    }

    func testWriterFinish_whenStreaming() async throws {
        try await self.writer!.yield("message1")

        self.writer.finish()

        self.assert(suspendCallCount: 0, yieldCallCount: 1, terminateCallCount: 1)
    }

    func testWriterFinish_whenStreaming_AndBufferedElements() async throws {
        // We are setting up a suspended yield here to check that it gets resumed
        self.sink.setWritability(to: false)

        let suspended = expectation(description: "suspended on yield")
        self.delegate.didSuspendHandler = {
            suspended.fulfill()
        }
        let task = Task { [writer] in
            try await writer!.yield("message1")
        }
        await fulfillment(of: [suspended], timeout: 1)

        self.writer.finish()

        self.assert(suspendCallCount: 1, yieldCallCount: 0, terminateCallCount: 0)

        // We have to become writable again to unbuffer the yield
        self.sink.setWritability(to: true)

        await XCTAssertNoThrow(try await task.value)

        self.assert(suspendCallCount: 1, yieldCallCount: 1, terminateCallCount: 1)
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func testWriterFinish_AndSuspendBufferedYield() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            try await withManualTaskExecutors { taskExecutor1, taskExecutor2 in
                self.sink.setWritability(to: false)

                self.delegate.didYieldHandler = { _ in
                    if self.delegate.didYieldCallCount == 1 {
                        // This is the yield of the first task. Run the second task until it suspends again
                        self.assert(suspendCallCount: 2, yieldCallCount: 1, terminateCallCount: 0)
                        taskExecutor2.runUntilQueueIsEmpty()
                        self.assert(suspendCallCount: 3, yieldCallCount: 1, terminateCallCount: 0)
                    }
                }

                group.addTask(executorPreference: taskExecutor1) { [writer] in
                    try await writer!.yield("message1")
                }
                group.addTask(executorPreference: taskExecutor2) { [writer] in
                    try await writer!.yield("message2")
                }

                // Run tasks until they are both suspended
                taskExecutor1.runUntilQueueIsEmpty()
                taskExecutor2.runUntilQueueIsEmpty()
                self.assert(suspendCallCount: 2, yieldCallCount: 0, terminateCallCount: 0)

                self.writer.finish()

                // We have to become writable again to unbuffer the yields
                self.sink.setWritability(to: true)

                // Run the first task, which will complete its yield
                // During this yield, didYieldHandler will run the second task, which will suspend again
                taskExecutor1.runUntilQueueIsEmpty()
                self.assert(suspendCallCount: 3, yieldCallCount: 1, terminateCallCount: 0)

                // Run the second task to complete its yield
                taskExecutor2.runUntilQueueIsEmpty()
                self.assert(suspendCallCount: 3, yieldCallCount: 2, terminateCallCount: 1)

                await XCTAssertNoThrow(try await group.next())
                await XCTAssertNoThrow(try await group.next())
            }
        }
    }

    func testWriterFinish_whenFinished() {
        // This tests just checks that finishing again is a no-op
        self.writer.finish()
        self.assert(suspendCallCount: 0, yieldCallCount: 0, terminateCallCount: 1)

        self.writer.finish()
        self.assert(suspendCallCount: 0, yieldCallCount: 0, terminateCallCount: 1)
    }

    // MARK: - Sink Finish

    func testSinkFinish_whenInitial() async throws {
        var newWriter: NIOAsyncWriter<String, MockAsyncWriterDelegate>.NewWriter? = NIOAsyncWriter.makeWriter(
            elementType: String.self,
            isWritable: true,
            finishOnDeinit: true,
            delegate: self.delegate
        )
        var sink: NIOAsyncWriter<String, MockAsyncWriterDelegate>.Sink? = newWriter!.sink
        let writer = newWriter!.writer
        newWriter = nil

        sink = nil

        XCTAssertNil(sink)
        XCTAssertNotNil(writer)
        self.assert(suspendCallCount: 0, yieldCallCount: 0, terminateCallCount: 0)
    }

    func testSinkFinish_whenStreaming() async throws {
        var newWriter: NIOAsyncWriter<String, MockAsyncWriterDelegate>.NewWriter? = NIOAsyncWriter.makeWriter(
            elementType: String.self,
            isWritable: true,
            finishOnDeinit: true,
            delegate: self.delegate
        )
        var sink: NIOAsyncWriter<String, MockAsyncWriterDelegate>.Sink? = newWriter!.sink
        let writer = newWriter!.writer
        newWriter = nil

        try await writer.yield("message1")

        sink = nil

        XCTAssertNil(sink)
        self.assert(suspendCallCount: 0, yieldCallCount: 1, terminateCallCount: 0)
    }

    func testSinkFinish_whenFinished() async throws {
        self.writer.finish()

        self.assert(suspendCallCount: 0, yieldCallCount: 0, terminateCallCount: 1)

        self.sink = nil

        self.assert(suspendCallCount: 0, yieldCallCount: 0, terminateCallCount: 1)
    }
}
