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
import NIOCore
import XCTest

private struct SomeError: Error, Hashable {}

private final class MockAsyncWriterDelegate: NIOAsyncWriterSinkDelegate, @unchecked Sendable {
    typealias Element = String

    var didYieldCallCount = 0
    var didYieldHandler: ((Deque<String>) -> Void)?
    func didYield(contentsOf sequence: Deque<String>) {
        self.didYieldCallCount += 1
        if let didYieldHandler = self.didYieldHandler {
            didYieldHandler(sequence)
        }
    }

    var didTerminateCallCount = 0
    var didTerminateHandler: ((Error?) -> Void)?
    func didTerminate(error: Error?) {
        self.didTerminateCallCount += 1
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

        self.delegate = .init()
        let newWriter = NIOAsyncWriter.makeWriter(
            elementType: String.self,
            isWritable: true,
            delegate: self.delegate
        )
        self.writer = newWriter.writer
        self.sink = newWriter.sink
    }

    override func tearDown() {
        self.delegate = nil
        self.writer = nil
        self.sink = nil

        super.tearDown()
    }

    func testMultipleConcurrentWrites() async throws {
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

        XCTAssertEqual(self.delegate.didYieldCallCount, 30)
    }

    func testWriterCoalescesWrites() async throws {
        var writes = [Deque<String>]()
        self.delegate.didYieldHandler = {
            writes.append($0)
        }
        self.sink.setWritability(to: false)

        let task1 = Task { [writer] in
            try await writer!.yield("message1")
        }
        task1.cancel()
        try await task1.value

        let task2 = Task { [writer] in
            try await writer!.yield("message2")
        }
        task2.cancel()
        try await task2.value

        let task3 = Task { [writer] in
            try await writer!.yield("message3")
        }
        task3.cancel()
        try await task3.value

        self.sink.setWritability(to: true)

        XCTAssertEqual(writes, [Deque(["message1", "message2", "message3"])])
    }

    // MARK: - WriterDeinitialized

    func testWriterDeinitialized_whenInitial() async throws {
        self.writer = nil

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testWriterDeinitialized_whenStreaming() async throws {
        try await writer.yield("message1")
        self.writer = nil

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testWriterDeinitialized_whenWriterFinished() async throws {
        try await writer.yield("message1")
        self.writer.finish()
        self.writer = nil

        XCTAssertEqual(self.delegate.didYieldCallCount, 1)
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testWriterDeinitialized_whenFinished() async throws {
        self.sink.finish()

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)

        self.writer = nil

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    // MARK: - ToggleWritability

    func testSetWritability_whenInitial() async throws {
        self.sink.setWritability(to: false)

        Task { [writer] in
            try await writer!.yield("message1")
        }

        // Sleep a bit so that the other Task suspends on the yield
        try await Task.sleep(nanoseconds: 1_000_000)

        XCTAssertEqual(self.delegate.didYieldCallCount, 0)
        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)
    }

    func testSetWritability_whenStreaming_andBecomingUnwritable() async throws {
        try await self.writer.yield("message1")
        XCTAssertEqual(self.delegate.didYieldCallCount, 1)

        self.sink.setWritability(to: false)

        Task { [writer] in
            try await writer!.yield("message2")
        }

        // Sleep a bit so that the other Task suspends on the yield
        try await Task.sleep(nanoseconds: 1_000_000)

        XCTAssertEqual(self.delegate.didYieldCallCount, 1)
        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)
    }

    func testSetWritability_whenStreaming_andBecomingWritable() async throws {
        self.sink.setWritability(to: false)

        Task { [writer] in
            try await writer!.yield("message2")
        }

        // Sleep a bit so that the other Task suspends on the yield
        try await Task.sleep(nanoseconds: 1_000_000)

        self.sink.setWritability(to: true)

        XCTAssertEqual(self.delegate.didYieldCallCount, 1)
        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)
    }

    func testSetWritability_whenStreaming_andSettingSameWritability() async throws {
        self.sink.setWritability(to: false)

        Task { [writer] in
            try await writer!.yield("message1")
        }

        // Sleep a bit so that the other Task suspends on the yield
        try await Task.sleep(nanoseconds: 1_000_000)

        // Setting the writability to the same state again shouldn't change anything
        self.sink.setWritability(to: false)

        XCTAssertEqual(self.delegate.didYieldCallCount, 0)
        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)
    }

    func testSetWritability_whenWriterFinished() async throws {
        self.sink.setWritability(to: false)

        Task { [writer] in
            try await writer!.yield("message1")
        }

        // Sleep a bit so that the other Task suspends on the yield
        try await Task.sleep(nanoseconds: 1_000_000)

        self.writer.finish()

        XCTAssertEqual(self.delegate.didYieldCallCount, 0)
        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)

        self.sink.setWritability(to: true)

        XCTAssertEqual(self.delegate.didYieldCallCount, 1)
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testSetWritability_whenFinished() async throws {
        self.sink.finish()

        self.sink.setWritability(to: false)

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    // MARK: - Yield

    func testYield_whenInitial_andWritable() async throws {
        try await self.writer.yield("message1")

        XCTAssertEqual(self.delegate.didYieldCallCount, 1)
    }

    func testYield_whenInitial_andNotWritable() async throws {
        self.sink.setWritability(to: false)

        Task { [writer] in
            try await writer!.yield("message2")
        }

        // Sleep a bit so that the other Task suspends on the yield
        try await Task.sleep(nanoseconds: 1_000_000)

        XCTAssertEqual(self.delegate.didYieldCallCount, 0)
    }

    func testYield_whenStreaming_andWritable() async throws {
        try await self.writer.yield("message1")

        XCTAssertEqual(self.delegate.didYieldCallCount, 1)

        try await self.writer.yield("message2")

        XCTAssertEqual(self.delegate.didYieldCallCount, 2)
    }

    func testYield_whenStreaming_andNotWritable() async throws {
        try await self.writer.yield("message1")

        XCTAssertEqual(self.delegate.didYieldCallCount, 1)

        self.sink.setWritability(to: false)

        Task { [writer] in
            try await writer!.yield("message2")
        }

        // Sleep a bit so that the other Task suspends on the yield
        try await Task.sleep(nanoseconds: 1_000_000)

        XCTAssertEqual(self.delegate.didYieldCallCount, 1)
    }

    func testYield_whenStreaming_andYieldCancelled() async throws {
        try await self.writer.yield("message1")

        XCTAssertEqual(self.delegate.didYieldCallCount, 1)

        let task = Task { [writer] in
            // Sleeping here a bit to delay the call to yield
            // The idea is that we call yield once the Task is
            // already cancelled
            try? await Task.sleep(nanoseconds: 1_000_000)
            try await writer!.yield("message2")
        }

        task.cancel()

        await XCTAssertNoThrow(try await task.value)
        XCTAssertEqual(self.delegate.didYieldCallCount, 2)
    }

    func testYield_whenWriterFinished() async throws {
        self.sink.setWritability(to: false)

        Task { [writer] in
            try await writer!.yield("message1")
        }

        // Sleep a bit so that the other Task suspends on the yield
        try await Task.sleep(nanoseconds: 1_000_000)

        self.writer.finish()

        await XCTAssertThrowsError(try await self.writer.yield("message1")) { error in
            XCTAssertEqual(error as? NIOAsyncWriterError, .alreadyFinished())
        }
        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)
    }

    func testYield_whenFinished() async throws {
        self.sink.finish()

        await XCTAssertThrowsError(try await self.writer.yield("message1")) { error in
            XCTAssertEqual(error as? NIOAsyncWriterError, .alreadyFinished())
        }
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testYield_whenFinishedError() async throws {
        self.sink.finish(error: SomeError())

        await XCTAssertThrowsError(try await self.writer.yield("message1")) { error in
            XCTAssertTrue(error is SomeError)
        }
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    // MARK: - Cancel

    func testCancel_whenInitial() async throws {
        let task = Task { [writer] in
            // Sleeping here a bit to delay the call to yield
            // The idea is that we call yield once the Task is
            // already cancelled
            try? await Task.sleep(nanoseconds: 1_000_000)
            try await writer!.yield("message1")
        }

        task.cancel()

        await XCTAssertNoThrow(try await task.value)
        XCTAssertEqual(self.delegate.didYieldCallCount, 1)
        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)
    }

    func testCancel_whenStreaming_andCancelBeforeYield() async throws {
        try await self.writer.yield("message1")

        XCTAssertEqual(self.delegate.didYieldCallCount, 1)

        let task = Task { [writer] in
            // Sleeping here a bit to delay the call to yield
            // The idea is that we call yield once the Task is
            // already cancelled
            try? await Task.sleep(nanoseconds: 1_000_000)
            try await writer!.yield("message2")
        }

        task.cancel()

        await XCTAssertNoThrow(try await task.value)
        XCTAssertEqual(self.delegate.didYieldCallCount, 2)
        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)
    }

    func testCancel_whenStreaming_andCancelAfterSuspendedYield() async throws {
        try await self.writer.yield("message1")

        XCTAssertEqual(self.delegate.didYieldCallCount, 1)

        self.sink.setWritability(to: false)

        let task = Task { [writer] in
            try await writer!.yield("message2")
        }

        // Sleeping here to give the task enough time to suspend on the yield
        try await Task.sleep(nanoseconds: 1_000_000)

        task.cancel()

        await XCTAssertNoThrow(try await task.value)
        XCTAssertEqual(self.delegate.didYieldCallCount, 1)
        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)

        self.sink.setWritability(to: true)
        XCTAssertEqual(self.delegate.didYieldCallCount, 2)
    }

    func testCancel_whenFinished() async throws {
        self.writer.finish()

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)

        let task = Task { [writer] in
            // Sleeping here a bit to delay the call to yield
            // The idea is that we call yield once the Task is
            // already cancelled
            try? await Task.sleep(nanoseconds: 1_000_000)
            try await writer!.yield("message1")
        }

        // Sleeping here to give the task enough time to suspend on the yield
        try await Task.sleep(nanoseconds: 1_000_000)

        task.cancel()

        XCTAssertEqual(self.delegate.didYieldCallCount, 0)
        await XCTAssertThrowsError(try await task.value) { error in
            XCTAssertEqual(error as? NIOAsyncWriterError, .alreadyFinished())
        }
    }

    // MARK: - Writer Finish

    func testWriterFinish_whenInitial() async throws {
        self.writer.finish()

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testWriterFinish_whenInitial_andFailure() async throws {
        self.writer.finish(error: SomeError())

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testWriterFinish_whenStreaming() async throws {
        try await self.writer!.yield("message1")

        self.writer.finish()

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testWriterFinish_whenStreaming_AndBufferedElements() async throws {
        // We are setting up a suspended yield here to check that it gets resumed
        self.sink.setWritability(to: false)

        let task = Task { [writer] in
            try await writer!.yield("message1")
        }

        // Sleeping here to give the task enough time to suspend on the yield
        try await Task.sleep(nanoseconds: 1_000_000)

        self.writer.finish()

        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)
        await XCTAssertNoThrow(try await task.value)
    }

    func testWriterFinish_whenFinished() {
        // This tests just checks that finishing again is a no-op
        self.writer.finish()
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)

        self.writer.finish()
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    // MARK: - Sink Finish

    func testSinkFinish_whenInitial() async throws {
        self.sink = nil

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testSinkFinish_whenStreaming() async throws {
        Task { [writer] in
            try await writer!.yield("message1")
        }

        try await Task.sleep(nanoseconds: 1_000_000)

        self.sink = nil

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testSinkFinish_whenFinished() async throws {
        self.writer.finish()

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)

        self.sink = nil

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }
}
