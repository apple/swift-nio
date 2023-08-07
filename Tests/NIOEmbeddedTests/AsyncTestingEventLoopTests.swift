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
import NIOCore
@testable import NIOEmbedded
import XCTest
import NIOConcurrencyHelpers
import Atomics

private class EmbeddedTestError: Error { }

final class NIOAsyncTestingEventLoopTests: XCTestCase {
    func testExecuteDoesNotImmediatelyRunTasks() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let callbackRan = ManagedAtomic(false)
            let loop = NIOAsyncTestingEventLoop()
            try await loop.executeInContext {
                loop.execute { callbackRan.store(true, ordering: .relaxed) }
                XCTAssertFalse(callbackRan.load(ordering: .relaxed))
            }
            await loop.run()
            XCTAssertTrue(callbackRan.load(ordering: .relaxed))
        }
    }

    func testExecuteWillRunAllTasks() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let runCount = ManagedAtomic(0)
            let loop = NIOAsyncTestingEventLoop()
            loop.execute { runCount.wrappingIncrement(ordering: .relaxed) }
            loop.execute { runCount.wrappingIncrement(ordering: .relaxed) }
            loop.execute { runCount.wrappingIncrement(ordering: .relaxed) }

            try await loop.executeInContext {
                XCTAssertEqual(runCount.load(ordering: .relaxed), 3)
            }
            await loop.run()
            try await loop.executeInContext {
                XCTAssertEqual(runCount.load(ordering: .relaxed), 3)
            }
        }
    }

    func testExecuteWillRunTasksAddedRecursively() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let sentinel = ManagedAtomic(0)
            let loop = NIOAsyncTestingEventLoop()

            loop.execute {
                // This should execute first.
                XCTAssertEqual(sentinel.load(ordering: .relaxed), 0)
                sentinel.store(1, ordering: .relaxed)
                loop.execute {
                    // This should execute second
                    let loaded = sentinel.loadThenWrappingIncrement(ordering: .relaxed)
                    XCTAssertEqual(loaded, 1)
                }
            }
            loop.execute {
                // This should execute third
                let loaded = sentinel.loadThenWrappingIncrement(ordering: .relaxed)
                XCTAssertEqual(loaded, 2)
            }

            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(ordering: .relaxed), 3)
            }
            await loop.run()
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(ordering: .relaxed), 3)
            }
        }
    }

    func testExecuteRunsImmediately() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let callbackRan = ManagedAtomic(false)
            let loop = NIOAsyncTestingEventLoop()
            loop.execute { callbackRan.store(true, ordering: .relaxed) }

            try await loop.executeInContext {
                XCTAssertTrue(callbackRan.load(ordering: .relaxed))
            }
            loop.execute { callbackRan.store(false, ordering: .relaxed) }

            try await loop.executeInContext {
                XCTAssertFalse(callbackRan.load(ordering: .relaxed))
            }
            try await loop.executeInContext {
                XCTAssertFalse(callbackRan.load(ordering: .relaxed))
            }
        }
    }

    func testTasksScheduledAfterRunDontRun() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let callbackRan = ManagedAtomic(false)
            let loop = NIOAsyncTestingEventLoop()
            loop.scheduleTask(deadline: loop.now) { callbackRan.store(true, ordering: .relaxed) }

            try await loop.executeInContext {
                XCTAssertFalse(callbackRan.load(ordering: .relaxed))
            }
            await loop.run()
            loop.scheduleTask(deadline: loop.now) { callbackRan.store(false, ordering: .relaxed) }

            try await loop.executeInContext {
                XCTAssertTrue(callbackRan.load(ordering: .relaxed))
            }
            await loop.run()
            try await loop.executeInContext {
                XCTAssertFalse(callbackRan.load(ordering: .relaxed))
            }
        }
    }

    func testSubmitRunsImmediately() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let callbackRan = ManagedAtomic(false)
            let loop = NIOAsyncTestingEventLoop()
            _ = loop.submit { callbackRan.store(true, ordering: .relaxed) }

            try await loop.executeInContext {
                XCTAssertTrue(callbackRan.load(ordering: .relaxed))
            }
            _ = loop.submit { callbackRan.store(false, ordering: .relaxed) }

            try await loop.executeInContext {
                XCTAssertFalse(callbackRan.load(ordering: .relaxed))
            }
            try await loop.executeInContext {
                XCTAssertFalse(callbackRan.load(ordering: .relaxed))
            }
        }
    }

    func testSyncShutdownGracefullyRunsTasks() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let callbackRan = ManagedAtomic(false)
            let loop = NIOAsyncTestingEventLoop()
            loop.scheduleTask(deadline: loop.now) { callbackRan.store(true, ordering: .relaxed) }

            try await loop.executeInContext {
                XCTAssertFalse(callbackRan.load(ordering: .relaxed))
            }
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
            try await loop.executeInContext {
                XCTAssertTrue(callbackRan.load(ordering: .relaxed))
            }
        }
    }

    func testShutdownGracefullyRunsTasks() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let callbackRan = ManagedAtomic(false)
            let loop = NIOAsyncTestingEventLoop()
            loop.scheduleTask(deadline: loop.now) { callbackRan.store(true, ordering: .relaxed) }

            try await loop.executeInContext {
                XCTAssertFalse(callbackRan.load(ordering: .relaxed))
            }
            await loop.shutdownGracefully()
            try await loop.executeInContext {
                XCTAssertTrue(callbackRan.load(ordering: .relaxed))
            }
        }
    }

    func testCanControlTime() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let callbackCount = ManagedAtomic(0)
            let loop = NIOAsyncTestingEventLoop()
            _ = loop.scheduleTask(in: .nanoseconds(5)) {
                callbackCount.loadThenWrappingIncrement(ordering: .relaxed)
            }

            try await loop.executeInContext {
                XCTAssertEqual(callbackCount.load(ordering: .relaxed), 0)
            }
            await loop.advanceTime(by: .nanoseconds(4))
            try await loop.executeInContext {
                XCTAssertEqual(callbackCount.load(ordering: .relaxed), 0)
            }
            await loop.advanceTime(by: .nanoseconds(1))
            try await loop.executeInContext {
                XCTAssertEqual(callbackCount.load(ordering: .relaxed), 1)
            }
            await loop.advanceTime(by: .nanoseconds(1))
            try await loop.executeInContext {
                XCTAssertEqual(callbackCount.load(ordering: .relaxed), 1)
            }
            await loop.advanceTime(by: .hours(1))
            try await loop.executeInContext {
                XCTAssertEqual(callbackCount.load(ordering: .relaxed), 1)
            }
        }
    }

    func testCanScheduleMultipleTasks() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let sentinel = ManagedAtomic(0)
            let loop = NIOAsyncTestingEventLoop()
            for index in 1...10 {
                _ = loop.scheduleTask(in: .nanoseconds(Int64(index))) {
                    sentinel.store(index, ordering: .relaxed)
                }
            }

            for val in 1...10 {
                try await loop.executeInContext {
                    XCTAssertEqual(sentinel.load(ordering: .relaxed), val - 1)
                }
                await loop.advanceTime(by: .nanoseconds(1))
                try await loop.executeInContext {
                    XCTAssertEqual(sentinel.load(ordering: .relaxed), val)
                }
            }
        }
    }

    func testExecutedTasksFromScheduledOnesAreRun() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let sentinel = ManagedAtomic(0)
            let loop = NIOAsyncTestingEventLoop()
            _ = loop.scheduleTask(in: .nanoseconds(5)) {
                sentinel.store(1, ordering: .relaxed)
                loop.execute {
                    sentinel.store(2, ordering: .relaxed)
                }
            }

            await loop.advanceTime(by: .nanoseconds(4))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(ordering: .relaxed), 0)
            }
            await loop.advanceTime(by: .nanoseconds(1))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(ordering: .relaxed), 2)
            }
        }
    }

    func testScheduledTasksFromScheduledTasksProperlySchedule() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let sentinel = ManagedAtomic(0)
            let loop = NIOAsyncTestingEventLoop()
            _ = loop.scheduleTask(in: .nanoseconds(5)) {
                sentinel.store(1, ordering: .relaxed)
                _ = loop.scheduleTask(in: .nanoseconds(3)) {
                    sentinel.store(2, ordering: .relaxed)
                }
                _ = loop.scheduleTask(in: .nanoseconds(5)) {
                    sentinel.store(3, ordering: .relaxed)
                }
            }

            await loop.advanceTime(by: .nanoseconds(4))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(ordering: .relaxed), 0)
            }
            await loop.advanceTime(by: .nanoseconds(1))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(ordering: .relaxed), 1)
            }
            await loop.advanceTime(by: .nanoseconds(2))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(ordering: .relaxed), 1)
            }
            await loop.advanceTime(by: .nanoseconds(1))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(ordering: .relaxed), 2)
            }
            await loop.advanceTime(by: .nanoseconds(1))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(ordering: .relaxed), 2)
            }
            await loop.advanceTime(by: .nanoseconds(1))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(ordering: .relaxed), 3)
            }
        }
    }

    func testScheduledTasksFromExecutedTasks() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let sentinel = ManagedAtomic(0)
            let loop = NIOAsyncTestingEventLoop()
            loop.execute {
                XCTAssertEqual(sentinel.load(ordering: .relaxed), 0)
                _ = loop.scheduleTask(in: .nanoseconds(5)) {
                    XCTAssertEqual(sentinel.load(ordering: .relaxed), 1)
                    sentinel.store(2, ordering: .relaxed)
                }
                loop.execute { sentinel.store(1, ordering: .relaxed) }
            }

            await loop.advanceTime(by: .nanoseconds(5))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(ordering: .relaxed), 2)
            }
        }
    }

    func testCancellingScheduledTasks() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let loop = NIOAsyncTestingEventLoop()
            let task = loop.scheduleTask(in: .nanoseconds(10), { XCTFail("Cancelled task ran") })
            _ = loop.scheduleTask(in: .nanoseconds(5)) {
                task.cancel()
            }

            await loop.advanceTime(by: .nanoseconds(20))
        }
    }

    func testScheduledTasksFuturesFire() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let fired = ManagedAtomic(false)
            let loop = NIOAsyncTestingEventLoop()
            let task = loop.scheduleTask(in: .nanoseconds(5)) { true }
            task.futureResult.whenSuccess { fired.store($0, ordering: .relaxed) }

            await loop.advanceTime(by: .nanoseconds(4))
            XCTAssertFalse(fired.load(ordering: .relaxed))
            await loop.advanceTime(by: .nanoseconds(1))
            XCTAssertTrue(fired.load(ordering: .relaxed))
        }
    }

    func testScheduledTasksFuturesError() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let err = EmbeddedTestError()
            let fired = ManagedAtomic(false)
            let loop = NIOAsyncTestingEventLoop()
            let task = loop.scheduleTask(in: .nanoseconds(5)) {
                throw err
            }
            task.futureResult.map {
                XCTFail("Scheduled future completed")
            }.recover { caughtErr in
                XCTAssertTrue(err === caughtErr as? EmbeddedTestError)
            }.whenComplete { (_: Result<Void, Error>) in
                fired.store(true, ordering: .relaxed)
            }

            await loop.advanceTime(by: .nanoseconds(4))
            XCTAssertFalse(fired.load(ordering: .relaxed))
            await loop.advanceTime(by: .nanoseconds(1))
            XCTAssertTrue(fired.load(ordering: .relaxed))
        }
    }

    func testTaskOrdering() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            // This test validates that the ordering of task firing on NIOAsyncTestingEventLoop via
            // advanceTime(by:) is the same as on MultiThreadedEventLoopGroup: specifically, that tasks run via
            // schedule that expire "now" all run at the same time, and that any work they schedule is run
            // after all such tasks expire.
            let loop = NIOAsyncTestingEventLoop()
            let lock = NIOLock()
            var firstScheduled: Scheduled<Void>? = nil
            var secondScheduled: Scheduled<Void>? = nil
            let orderingCounter = ManagedAtomic(0)

            // Here's the setup. First, we'll set up two scheduled tasks to fire in 5 nanoseconds. Each of these
            // will attempt to cancel the other, but the first one scheduled will fire first. Additionally, each will execute{} a single
            // callback. Then we'll execute {} one other callback. Finally we'll schedule a task for 10ns, before
            // we advance time. The ordering should be as follows:
            //
            // 1. The task executed by execute {} from this function.
            // 2. The first scheduled task.
            // 3. The second scheduled task  (note that the cancellation will fail).
            // 4. The execute {} callback from the first scheduled task.
            // 5. The execute {} callbacks from the second scheduled task.
            // 6. The 10ns task.
            //
            // To validate the ordering, we'll use a counter.

            lock.withLock { () -> Void in
                firstScheduled = loop.scheduleTask(in: .nanoseconds(5)) {
                    let second = lock.withLock { () -> Scheduled<Void>? in
                        XCTAssertNotNil(firstScheduled)
                        firstScheduled = nil
                        XCTAssertNotNil(secondScheduled)
                        return secondScheduled
                    }

                    if let partner = second {
                        // Ok, this callback fired first. Cancel the other.
                        partner.cancel()
                    } else {
                        XCTFail("First callback executed second")
                    }

                    XCTAssertCompareAndSwapSucceeds(storage: orderingCounter, expected: 1, desired: 2)

                    loop.execute {
                        XCTAssertCompareAndSwapSucceeds(storage: orderingCounter, expected: 3, desired: 4)
                    }
                }

                secondScheduled = loop.scheduleTask(in: .nanoseconds(5)) {
                    lock.withLock { () -> Void in
                        secondScheduled = nil
                        XCTAssertNil(firstScheduled)
                        XCTAssertNil(secondScheduled)
                    }

                    XCTAssertCompareAndSwapSucceeds(storage: orderingCounter, expected: 2, desired: 3)

                    loop.execute {
                        XCTAssertCompareAndSwapSucceeds(storage: orderingCounter, expected: 4, desired: 5)
                    }
                }
            }

            // Ok, now we set one more task to execute.
            loop.execute {
                XCTAssertCompareAndSwapSucceeds(storage: orderingCounter, expected: 0, desired: 1)
            }

            // Finally schedule a task for 10ns.
            _ = loop.scheduleTask(in: .nanoseconds(10)) {
                XCTAssertCompareAndSwapSucceeds(storage: orderingCounter, expected: 5, desired: 6)
            }

            // Now we advance time by 10ns.
            await loop.advanceTime(by: .nanoseconds(10))

            // Now the final value should be 6.
            XCTAssertEqual(orderingCounter.load(ordering: .relaxed), 6)
        }
    }

    func testCancelledScheduledTasksDoNotHoldOnToRunClosure() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncTestingEventLoop()
            defer {
                XCTAssertNoThrow(try eventLoop.syncShutdownGracefully())
            }

            class Thing: @unchecked Sendable {
                private let deallocated: ConditionLock<Int>

                init(_ deallocated: ConditionLock<Int>) {
                    self.deallocated = deallocated
                }

                deinit {
                    self.deallocated.lock()
                    self.deallocated.unlock(withValue: 1)
                }
            }

            func make(deallocated: ConditionLock<Int>) -> Scheduled<Never> {
                let aThing = Thing(deallocated)
                return eventLoop.next().scheduleTask(in: .hours(1)) {
                    preconditionFailure("this should definitely not run: \(aThing)")
                }
            }

            let deallocated = ConditionLock(value: 0)
            let scheduled = make(deallocated: deallocated)
            scheduled.cancel()
            if deallocated.lock(whenValue: 1, timeoutSeconds: 60) {
                deallocated.unlock()
            } else {
                XCTFail("Timed out waiting for lock")
            }
            await XCTAssertThrowsError(try await scheduled.futureResult.get()) { error in
                XCTAssertEqual(EventLoopError.cancelled, error as? EventLoopError)
            }
        }
    }

    func testDrainScheduledTasks() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncTestingEventLoop()
            let tasksRun = ManagedAtomic(0)
            let startTime = eventLoop.now

            eventLoop.scheduleTask(in: .nanoseconds(3141592)) {
                XCTAssertEqual(eventLoop.now, startTime + .nanoseconds(3141592))
                tasksRun.wrappingIncrement(ordering: .relaxed)
            }

            eventLoop.scheduleTask(in: .seconds(3141592)) {
                XCTAssertEqual(eventLoop.now, startTime + .seconds(3141592))
                tasksRun.wrappingIncrement(ordering: .relaxed)
            }

            await eventLoop.shutdownGracefully()
            XCTAssertEqual(tasksRun.load(ordering: .relaxed), 2)
        }
    }

    func testDrainScheduledTasksDoesNotRunNewlyScheduledTasks() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncTestingEventLoop()
            let tasksRun = ManagedAtomic(0)

            func scheduleNowAndIncrement() {
                eventLoop.scheduleTask(in: .nanoseconds(0)) {
                    tasksRun.wrappingIncrement(ordering: .relaxed)
                    scheduleNowAndIncrement()
                }
            }

            scheduleNowAndIncrement()
            await eventLoop.shutdownGracefully()
            XCTAssertEqual(tasksRun.load(ordering: .relaxed), 1)
        }
    }

    func testAdvanceTimeToDeadline() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncTestingEventLoop()
            let deadline = NIODeadline.uptimeNanoseconds(0) + .seconds(42)

            let tasksRun = ManagedAtomic(0)
            eventLoop.scheduleTask(deadline: deadline) {
                tasksRun.loadThenWrappingIncrement(ordering: .relaxed)
            }

            await eventLoop.advanceTime(to: deadline)
            XCTAssertEqual(tasksRun.load(ordering: .relaxed), 1)
        }
    }

    func testWeCantTimeTravelByAdvancingTimeToThePast() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncTestingEventLoop()

            let tasksRun = ManagedAtomic(0)
            eventLoop.scheduleTask(deadline: .uptimeNanoseconds(0) + .seconds(42)) {
                tasksRun.loadThenWrappingIncrement(ordering: .relaxed)
            }

            // t=40s
            await eventLoop.advanceTime(to: .uptimeNanoseconds(0) + .seconds(40))
            XCTAssertEqual(tasksRun.load(ordering: .relaxed), 0)

            // t=40s (still)
            await eventLoop.advanceTime(to: .distantPast)
            XCTAssertEqual(tasksRun.load(ordering: .relaxed), 0)

            // t=42s
            await eventLoop.advanceTime(by: .seconds(2))
            XCTAssertEqual(tasksRun.load(ordering: .relaxed), 1)
        }
    }

    func testExecuteInOrder() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncTestingEventLoop()
            let counter = ManagedAtomic(0)

            eventLoop.execute {
                let original = counter.loadThenWrappingIncrement(ordering: .relaxed)
                XCTAssertEqual(original, 0)
            }

            eventLoop.execute {
                let original = counter.loadThenWrappingIncrement(ordering: .relaxed)
                XCTAssertEqual(original, 1)
            }

            eventLoop.execute {
                let original = counter.loadThenWrappingIncrement(ordering: .relaxed)
                XCTAssertEqual(original, 2)
            }

            await eventLoop.run()
            XCTAssertEqual(counter.load(ordering: .relaxed), 3)
        }
    }

    func testScheduledTasksInOrder() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncTestingEventLoop()
            let counter = ManagedAtomic(0)

            eventLoop.scheduleTask(in: .seconds(1)) {
                let original = counter.loadThenWrappingIncrement(ordering: .relaxed)
                XCTAssertEqual(original, 1)
            }

            eventLoop.scheduleTask(in: .milliseconds(1)) {
                let original = counter.loadThenWrappingIncrement(ordering: .relaxed)
                XCTAssertEqual(original, 0)
            }

            eventLoop.scheduleTask(in: .seconds(1)) {
                let original = counter.loadThenWrappingIncrement(ordering: .relaxed)
                XCTAssertEqual(original, 2)
            }

            await eventLoop.advanceTime(by: .seconds(1))
            XCTAssertEqual(counter.load(ordering: .relaxed), 3)
        }
    }
}
