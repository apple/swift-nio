//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest

protocol ScheduledCallbackTestRequirements {
    // Some ELs are backed by an ELG.
    var loop: (any EventLoop) { get }

    // Some ELs have a manual time ratchet.
    func advanceTime(by amount: TimeAmount) async throws

    // ELG-backed ELs need to be shutdown via the ELG.
    func shutdownEventLoop() async throws

    // This is here for NIOAsyncTestingEventLoop only.
    func maybeInContext<R: Sendable>(_ body: @escaping @Sendable () throws -> R) async throws -> R
}

final class MTELGScheduledCallbackTests: _BaseScheduledCallbackTests {
    struct Requirements: ScheduledCallbackTestRequirements {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var loop: (any EventLoop) { self.group.next() }

        func advanceTime(by amount: TimeAmount) async throws {
            try await Task.sleep(nanoseconds: UInt64(amount.nanoseconds))
        }

        func shutdownEventLoop() async throws {
            try await self.group.shutdownGracefully()
        }

        func maybeInContext<R: Sendable>(_ body: @escaping @Sendable () throws -> R) async throws -> R {
            try body()
        }
    }

    override func setUp() async throws {
        self.requirements = Requirements()
    }
}

final class EmbeddedScheduledCallbackTests: _BaseScheduledCallbackTests {
    struct Requirements: ScheduledCallbackTestRequirements {
        let _loop = EmbeddedEventLoop()
        var loop: (any EventLoop) { self._loop }

        func advanceTime(by amount: TimeAmount) async throws {
            self._loop.advanceTime(by: amount)
        }

        func shutdownEventLoop() async throws {
            try await self._loop.shutdownGracefully()
        }

        func maybeInContext<R: Sendable>(_ body: @escaping @Sendable () throws -> R) async throws -> R {
            try body()
        }
    }

    override func setUp() async throws {
        self.requirements = Requirements()
    }
}

final class NIOAsyncTestingEventLoopScheduledCallbackTests: _BaseScheduledCallbackTests {
    struct Requirements: ScheduledCallbackTestRequirements {
        let _loop = NIOAsyncTestingEventLoop()
        var loop: (any EventLoop) { self._loop }

        func advanceTime(by amount: TimeAmount) async throws {
            await self._loop.advanceTime(by: amount)
        }

        func shutdownEventLoop() async throws {
            await self._loop.shutdownGracefully()
        }

        func maybeInContext<R: Sendable>(_ body: @escaping @Sendable () throws -> R) async throws -> R {
            try await self._loop.executeInContext(body)
        }
    }

    override func setUp() async throws {
        self.requirements = Requirements()
    }
}

class _BaseScheduledCallbackTests: XCTestCase {
    // EL-specific test requirements.
    var requirements: (any ScheduledCallbackTestRequirements)! = nil

    override func setUp() async throws {
        try XCTSkipIf(type(of: self) == _BaseScheduledCallbackTests.self, "This is the abstract base class")
        preconditionFailure("Subclass should implement setup and initialise EL-specific `self.requirements`")
    }
}

// Provide pass through computed properties to the EL-specific test requirements.
extension _BaseScheduledCallbackTests {
    var loop: (any EventLoop) { self.requirements.loop }

    func advanceTime(by amount: TimeAmount) async throws {
        try await self.requirements.advanceTime(by: amount)
    }

    func shutdownEventLoop() async throws {
        try await self.requirements.shutdownEventLoop()
    }

    func maybeInContext<R: Sendable>(_ body: @escaping @Sendable () throws -> R) async throws -> R {
        try await self.requirements.maybeInContext(body)
    }
}

// The tests, abstracted over any of the event loops.
extension _BaseScheduledCallbackTests {

    func testScheduledCallbackNotExecutedBeforeDeadline() async throws {
        let handler = MockScheduledCallbackHandler()

        _ = try self.loop.scheduleCallback(in: .milliseconds(1), handler: handler)
        try await self.maybeInContext { handler.assert(callbackCount: 0, cancelCount: 0) }

        try await self.advanceTime(by: .microseconds(1))
        try await self.maybeInContext { handler.assert(callbackCount: 0, cancelCount: 0) }
    }

    func testSheduledCallbackExecutedAtDeadline() async throws {
        let handler = MockScheduledCallbackHandler()

        _ = try self.loop.scheduleCallback(in: .milliseconds(1), handler: handler)
        try await self.advanceTime(by: .milliseconds(1))
        try await handler.waitForCallback(timeout: .seconds(1))
        try await self.maybeInContext { handler.assert(callbackCount: 1, cancelCount: 0) }
    }

    func testMultipleSheduledCallbacksUsingSameHandler() async throws {
        let handler = MockScheduledCallbackHandler()

        _ = try self.loop.scheduleCallback(in: .milliseconds(1), handler: handler)
        _ = try self.loop.scheduleCallback(in: .milliseconds(1), handler: handler)

        try await self.advanceTime(by: .milliseconds(1))
        try await handler.waitForCallback(timeout: .seconds(1))
        try await handler.waitForCallback(timeout: .seconds(1))
        try await self.maybeInContext { handler.assert(callbackCount: 2, cancelCount: 0) }

        _ = try self.loop.scheduleCallback(in: .milliseconds(2), handler: handler)
        _ = try self.loop.scheduleCallback(in: .milliseconds(3), handler: handler)

        try await self.advanceTime(by: .milliseconds(3))
        try await handler.waitForCallback(timeout: .seconds(1))
        try await handler.waitForCallback(timeout: .seconds(1))
        try await self.maybeInContext { handler.assert(callbackCount: 4, cancelCount: 0) }
    }

    func testMultipleSheduledCallbacksUsingDifferentHandlers() async throws {
        let handlerA = MockScheduledCallbackHandler()
        let handlerB = MockScheduledCallbackHandler()

        _ = try self.loop.scheduleCallback(in: .milliseconds(1), handler: handlerA)
        _ = try self.loop.scheduleCallback(in: .milliseconds(1), handler: handlerB)

        try await self.advanceTime(by: .milliseconds(1))
        try await handlerA.waitForCallback(timeout: .seconds(1))
        try await handlerB.waitForCallback(timeout: .seconds(1))
        try await self.maybeInContext { handlerA.assert(callbackCount: 1, cancelCount: 0) }
        try await self.maybeInContext { handlerB.assert(callbackCount: 1, cancelCount: 0) }
    }

    func testCancelExecutesCancellationCallback() async throws {
        let handler = MockScheduledCallbackHandler()

        let scheduledCallback = try self.loop.scheduleCallback(in: .milliseconds(1), handler: handler)
        scheduledCallback.cancel()
        try await self.maybeInContext { handler.assert(callbackCount: 0, cancelCount: 1) }
    }

    func testCancelAfterDeadlineDoesNotExecutesCancellationCallback() async throws {
        let handler = MockScheduledCallbackHandler()

        let scheduledCallback = try self.loop.scheduleCallback(in: .milliseconds(1), handler: handler)
        try await self.advanceTime(by: .milliseconds(1))
        try await handler.waitForCallback(timeout: .seconds(1))
        scheduledCallback.cancel()
        try await self.maybeInContext { handler.assert(callbackCount: 1, cancelCount: 0) }
    }

    func testCancelAfterCancelDoesNotCallCancellationCallbackAgain() async throws {
        let handler = MockScheduledCallbackHandler()

        let scheduledCallback = try self.loop.scheduleCallback(in: .milliseconds(1), handler: handler)
        scheduledCallback.cancel()
        scheduledCallback.cancel()
        try await self.maybeInContext { handler.assert(callbackCount: 0, cancelCount: 1) }
    }

    func testCancelAfterShutdownDoesNotCallCancellationCallbackAgain() async throws {
        let handler = MockScheduledCallbackHandler()

        let scheduledCallback = try self.loop.scheduleCallback(in: .milliseconds(1), handler: handler)
        try await self.shutdownEventLoop()
        try await self.maybeInContext { handler.assert(callbackCount: 0, cancelCount: 1) }

        scheduledCallback.cancel()
        try await self.maybeInContext { handler.assert(callbackCount: 0, cancelCount: 1) }
    }

    func testShutdownCancelsOutstandingScheduledCallbacks() async throws {
        let handler = MockScheduledCallbackHandler()

        _ = try self.loop.scheduleCallback(in: .milliseconds(1), handler: handler)
        try await self.shutdownEventLoop()
        try await self.maybeInContext { handler.assert(callbackCount: 0, cancelCount: 1) }
    }

    func testShutdownDoesNotCancelCancelledCallbacksAgain() async throws {
        let handler = MockScheduledCallbackHandler()

        let handle = try self.loop.scheduleCallback(in: .milliseconds(1), handler: handler)
        handle.cancel()
        try await self.maybeInContext { handler.assert(callbackCount: 0, cancelCount: 1) }

        try await self.shutdownEventLoop()
        try await self.maybeInContext { handler.assert(callbackCount: 0, cancelCount: 1) }
    }

    func testShutdownDoesNotCancelPastCallbacks() async throws {
        let handler = MockScheduledCallbackHandler()

        _ = try self.loop.scheduleCallback(in: .milliseconds(1), handler: handler)
        try await self.advanceTime(by: .milliseconds(1))
        try await handler.waitForCallback(timeout: .seconds(1))
        try await self.maybeInContext { handler.assert(callbackCount: 1, cancelCount: 0) }

        try await self.shutdownEventLoop()
        try await self.maybeInContext { handler.assert(callbackCount: 1, cancelCount: 0) }
    }
}

private final class MockScheduledCallbackHandler: NIOScheduledCallbackHandler {
    var callbackCount = 0
    var cancelCount = 0

    let callbackStream: AsyncStream<Void>
    private let callbackStreamContinuation: AsyncStream<Void>.Continuation

    init() {
        (self.callbackStream, self.callbackStreamContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    deinit {
        self.callbackStreamContinuation.finish()
    }

    func handleScheduledCallback(eventLoop: some EventLoop) {
        self.callbackCount += 1
        self.callbackStreamContinuation.yield()
    }

    func didCancelScheduledCallback(eventLoop: some EventLoop) {
        self.cancelCount += 1
    }

    func assert(callbackCount: Int, cancelCount: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(self.callbackCount, callbackCount, "Unexpected callback count", file: file, line: line)
        XCTAssertEqual(self.cancelCount, cancelCount, "Unexpected cancel count", file: file, line: line)
    }

    func waitForCallback(timeout: TimeAmount, file: StaticString = #file, line: UInt = #line) async throws {
        try await XCTWithTimeout(timeout, file: file, line: line) { await self.callbackStream.first { _ in true } }
    }
}

/// This function exists because there's no nice way of waiting in tests for something to happen in the handler
/// without an arbitrary sleep.
///
/// Other options include setting `XCTestCase.allowedExecutionTime` in `setup()` but this doesn't work well because
/// (1), it rounds up to the nearest minute; and (2), it doesn't seem to work reliably.
///
/// Another option is to install a timebomb in `XCTestCase.setup()` that will fail the test. This works, but you
/// don't get any information on where the test was when it fails.
///
/// Alternatively, one can use expectations, but these cannot be awaited more than once so won't work for tests where
/// the same handler is used to schedule multiple callbacks.
///
/// This function is probably a good balance of pragmatism and clarity.
func XCTWithTimeout<Result>(
    _ timeout: TimeAmount,
    file: StaticString = #file,
    line: UInt = #line,
    operation: @escaping @Sendable () async throws -> Result
) async throws -> Result where Result: Sendable {
    do {
        return try await withTimeout(timeout, operation: operation)
    } catch is CancellationError {
        XCTFail("Timed out after \(timeout)", file: file, line: line)
        throw CancellationError()
    }
}

func withTimeout<Result>(
    _ timeout: TimeAmount,
    operation: @escaping @Sendable () async throws -> Result
) async throws -> Result where Result: Sendable {
    try await withThrowingTaskGroup(of: Result.self) { group in
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout.nanoseconds))
            throw CancellationError()
        }
        group.addTask(operation: operation)
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
