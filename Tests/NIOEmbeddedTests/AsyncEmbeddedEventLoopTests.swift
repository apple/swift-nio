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
import NIOConcurrencyHelpers
@testable import NIOEmbedded
import XCTest

private class EmbeddedTestError: Error { }

final class NIOAsyncEmbeddedEventLoopTests: XCTestCase {
    func testExecuteDoesNotImmediatelyRunTasks() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let callbackRan = NIOAtomic<Bool>.makeAtomic(value: false)
            let loop = NIOAsyncEmbeddedEventLoop()
            try await loop.executeInContext {
                loop.execute { callbackRan.store(true) }
                XCTAssertFalse(callbackRan.load())
            }
            await loop.run()
            XCTAssertTrue(callbackRan.load())
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testExecuteWillRunAllTasks() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let runCount = NIOAtomic<Int>.makeAtomic(value: 0)
            let loop = NIOAsyncEmbeddedEventLoop()
            loop.execute { runCount.add(1) }
            loop.execute { runCount.add(1) }
            loop.execute { runCount.add(1) }

            try await loop.executeInContext {
                XCTAssertEqual(runCount.load(), 0)
            }
            await loop.run()
            try await loop.executeInContext {
                XCTAssertEqual(runCount.load(), 3)
            }
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testExecuteWillRunTasksAddedRecursively() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let sentinel = NIOAtomic<Int>.makeAtomic(value: 0)
            let loop = NIOAsyncEmbeddedEventLoop()

            loop.execute {
                // This should execute first.
                XCTAssertEqual(sentinel.load(), 0)
                sentinel.store(1)
                loop.execute {
                    // This should execute third.
                    XCTAssertEqual(sentinel.load(), 2)
                    sentinel.store(3)
                }
            }
            loop.execute {
                // This should execute second.
                XCTAssertEqual(sentinel.load(), 1)
                sentinel.store(2)
            }

            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(), 0)
            }
            await loop.run()
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(), 3)
            }
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testTasksSubmittedAfterRunDontRun() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let callbackRan = NIOAtomic<Bool>.makeAtomic(value: false)
            let loop = NIOAsyncEmbeddedEventLoop()
            loop.execute { callbackRan.store(true) }

            try await loop.executeInContext {
                XCTAssertFalse(callbackRan.load())
            }
            await loop.run()
            loop.execute { callbackRan.store(false) }

            try await loop.executeInContext {
                XCTAssertTrue(callbackRan.load())
            }
            await loop.run()
            try await loop.executeInContext {
                XCTAssertFalse(callbackRan.load())
            }
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testSyncShutdownGracefullyRunsTasks() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let callbackRan = NIOAtomic<Bool>.makeAtomic(value: false)
            let loop = NIOAsyncEmbeddedEventLoop()
            loop.execute { callbackRan.store(true) }

            try await loop.executeInContext {
                XCTAssertFalse(callbackRan.load())
            }
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
            try await loop.executeInContext {
                XCTAssertTrue(callbackRan.load())
            }
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testShutdownGracefullyRunsTasks() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let callbackRan = NIOAtomic<Bool>.makeAtomic(value: false)
            let loop = NIOAsyncEmbeddedEventLoop()
            loop.execute { callbackRan.store(true) }

            try await loop.executeInContext {
                XCTAssertFalse(callbackRan.load())
            }
            await loop.shutdownGracefully()
            try await loop.executeInContext {
                XCTAssertTrue(callbackRan.load())
            }
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testCanControlTime() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let callbackCount = NIOAtomic<Int>.makeAtomic(value: 0)
            let loop = NIOAsyncEmbeddedEventLoop()
            _ = loop.scheduleTask(in: .nanoseconds(5)) {
                callbackCount.add(1)
            }

            try await loop.executeInContext {
                XCTAssertEqual(callbackCount.load(), 0)
            }
            await loop.advanceTime(by: .nanoseconds(4))
            try await loop.executeInContext {
                XCTAssertEqual(callbackCount.load(), 0)
            }
            await loop.advanceTime(by: .nanoseconds(1))
            try await loop.executeInContext {
                XCTAssertEqual(callbackCount.load(), 1)
            }
            await loop.advanceTime(by: .nanoseconds(1))
            try await loop.executeInContext {
                XCTAssertEqual(callbackCount.load(), 1)
            }
            await loop.advanceTime(by: .hours(1))
            try await loop.executeInContext {
                XCTAssertEqual(callbackCount.load(), 1)
            }
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testCanScheduleMultipleTasks() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let sentinel = NIOAtomic.makeAtomic(value: 0)
            let loop = NIOAsyncEmbeddedEventLoop()
            for index in 1...10 {
                _ = loop.scheduleTask(in: .nanoseconds(Int64(index))) {
                    sentinel.store(index)
                }
            }

            for val in 1...10 {
                try await loop.executeInContext {
                    XCTAssertEqual(sentinel.load(), val - 1)
                }
                await loop.advanceTime(by: .nanoseconds(1))
                try await loop.executeInContext {
                    XCTAssertEqual(sentinel.load(), val)
                }
            }
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testExecutedTasksFromScheduledOnesAreRun() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let sentinel = NIOAtomic.makeAtomic(value: 0)
            let loop = NIOAsyncEmbeddedEventLoop()
            _ = loop.scheduleTask(in: .nanoseconds(5)) {
                sentinel.store(1)
                loop.execute {
                    sentinel.store(2)
                }
            }

            await loop.advanceTime(by: .nanoseconds(4))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(), 0)
            }
            await loop.advanceTime(by: .nanoseconds(1))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(), 2)
            }
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testScheduledTasksFromScheduledTasksProperlySchedule() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let sentinel = NIOAtomic.makeAtomic(value: 0)
            let loop = NIOAsyncEmbeddedEventLoop()
            _ = loop.scheduleTask(in: .nanoseconds(5)) {
                sentinel.store(1)
                _ = loop.scheduleTask(in: .nanoseconds(3)) {
                    sentinel.store(2)
                }
                _ = loop.scheduleTask(in: .nanoseconds(5)) {
                    sentinel.store(3)
                }
            }

            await loop.advanceTime(by: .nanoseconds(4))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(), 0)
            }
            await loop.advanceTime(by: .nanoseconds(1))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(), 1)
            }
            await loop.advanceTime(by: .nanoseconds(2))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(), 1)
            }
            await loop.advanceTime(by: .nanoseconds(1))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(), 2)
            }
            await loop.advanceTime(by: .nanoseconds(1))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(), 2)
            }
            await loop.advanceTime(by: .nanoseconds(1))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(), 3)
            }
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testScheduledTasksFromExecutedTasks() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let sentinel = NIOAtomic.makeAtomic(value: 0)
            let loop = NIOAsyncEmbeddedEventLoop()
            loop.execute {
                XCTAssertEqual(sentinel.load(), 0)
                _ = loop.scheduleTask(in: .nanoseconds(5)) {
                    XCTAssertEqual(sentinel.load(), 1)
                    sentinel.store(2)
                }
                loop.execute { sentinel.store(1) }
            }

            await loop.advanceTime(by: .nanoseconds(5))
            try await loop.executeInContext {
                XCTAssertEqual(sentinel.load(), 2)
            }
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testCancellingScheduledTasks() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let loop = NIOAsyncEmbeddedEventLoop()
            let task = loop.scheduleTask(in: .nanoseconds(10), { XCTFail("Cancelled task ran") })
            _ = loop.scheduleTask(in: .nanoseconds(5)) {
                task.cancel()
            }

            await loop.advanceTime(by: .nanoseconds(20))
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testScheduledTasksFuturesFire() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let fired = NIOAtomic.makeAtomic(value: false)
            let loop = NIOAsyncEmbeddedEventLoop()
            let task = loop.scheduleTask(in: .nanoseconds(5)) { true }
            task.futureResult.whenSuccess { fired.store($0) }

            await loop.advanceTime(by: .nanoseconds(4))
            XCTAssertFalse(fired.load())
            await loop.advanceTime(by: .nanoseconds(1))
            XCTAssertTrue(fired.load())
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testScheduledTasksFuturesError() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let err = EmbeddedTestError()
            let fired = NIOAtomic.makeAtomic(value: false)
            let loop = NIOAsyncEmbeddedEventLoop()
            let task = loop.scheduleTask(in: .nanoseconds(5)) {
                throw err
            }
            task.futureResult.map {
                XCTFail("Scheduled future completed")
            }.recover { caughtErr in
                XCTAssertTrue(err === caughtErr as? EmbeddedTestError)
            }.whenComplete { (_: Result<Void, Error>) in
                fired.store(true)
            }

            await loop.advanceTime(by: .nanoseconds(4))
            XCTAssertFalse(fired.load())
            await loop.advanceTime(by: .nanoseconds(1))
            XCTAssertTrue(fired.load())
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testTaskOrdering() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            // This test validates that the ordering of task firing on NIOAsyncEmbeddedEventLoop via
            // advanceTime(by:) is the same as on MultiThreadedEventLoopGroup: specifically, that tasks run via
            // schedule that expire "now" all run at the same time, and that any work they schedule is run
            // after all such tasks expire.
            let loop = NIOAsyncEmbeddedEventLoop()
            let lock = Lock()
            var firstScheduled: Scheduled<Void>? = nil
            var secondScheduled: Scheduled<Void>? = nil
            let orderingCounter = NIOAtomic.makeAtomic(value: 0)

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

            lock.withLockVoid {
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
                    lock.withLockVoid {
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
            XCTAssertEqual(orderingCounter.load(), 6)
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testCancelledScheduledTasksDoNotHoldOnToRunClosure() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncEmbeddedEventLoop()
            defer {
                XCTAssertNoThrow(try eventLoop.syncShutdownGracefully())
            }

            class Thing {}

            weak var weakThing: Thing? = nil

            func make() -> Scheduled<Never> {
                let aThing = Thing()
                weakThing = aThing
                return eventLoop.scheduleTask(in: .hours(1)) {
                    preconditionFailure("this should definitely not run: \(aThing)")
                }
            }

            let scheduled = make()
            scheduled.cancel()

            XCTAssertNotNil(weakThing)
            await eventLoop.run()
            XCTAssertNil(weakThing)
            await XCTAssertThrowsError(try await eventLoop.awaitFuture(scheduled.futureResult, timeout: .seconds(1))) { error in
                XCTAssertEqual(EventLoopError.cancelled, error as? EventLoopError)
            }
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testWaitingForFutureCanTimeOut() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncEmbeddedEventLoop()
            defer {
                XCTAssertNoThrow(try eventLoop.syncShutdownGracefully())
            }
            let promise = eventLoop.makePromise(of: Void.self)

            await XCTAssertThrowsError(try await eventLoop.awaitFuture(promise.futureResult, timeout: .milliseconds(1))) { error in
                XCTAssertEqual(NIOAsyncEmbeddedEventLoopError.timeoutAwaitingFuture, error as? NIOAsyncEmbeddedEventLoopError)
            }
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testDrainScheduledTasks() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncEmbeddedEventLoop()
            let tasksRun = NIOAtomic.makeAtomic(value: 0)
            let startTime = eventLoop.now

            eventLoop.scheduleTask(in: .nanoseconds(3141592)) {
                XCTAssertEqual(eventLoop.now, startTime + .nanoseconds(3141592))
                tasksRun.add(1)
            }

            eventLoop.scheduleTask(in: .seconds(3141592)) {
                XCTAssertEqual(eventLoop.now, startTime + .seconds(3141592))
                tasksRun.add(1)
            }

            await eventLoop.shutdownGracefully()
            XCTAssertEqual(tasksRun.load(), 2)
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testDrainScheduledTasksDoesNotRunNewlyScheduledTasks() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncEmbeddedEventLoop()
            let tasksRun = NIOAtomic.makeAtomic(value: 0)

            func scheduleNowAndIncrement() {
                eventLoop.scheduleTask(in: .nanoseconds(0)) {
                    tasksRun.add(1)
                    scheduleNowAndIncrement()
                }
            }

            scheduleNowAndIncrement()
            await eventLoop.shutdownGracefully()
            XCTAssertEqual(tasksRun.load(), 1)
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testAdvanceTimeToDeadline() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncEmbeddedEventLoop()
            let deadline = NIODeadline.uptimeNanoseconds(0) + .seconds(42)

            let tasksRun = NIOAtomic.makeAtomic(value: 0)
            eventLoop.scheduleTask(deadline: deadline) {
                tasksRun.add(1)
            }

            await eventLoop.advanceTime(to: deadline)
            XCTAssertEqual(tasksRun.load(), 1)
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testWeCantTimeTravelByAdvancingTimeToThePast() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncEmbeddedEventLoop()

            let tasksRun = NIOAtomic.makeAtomic(value: 0)
            eventLoop.scheduleTask(deadline: .uptimeNanoseconds(0) + .seconds(42)) {
                tasksRun.add(1)
            }

            // t=40s
            await eventLoop.advanceTime(to: .uptimeNanoseconds(0) + .seconds(40))
            XCTAssertEqual(tasksRun.load(), 0)

            // t=40s (still)
            await eventLoop.advanceTime(to: .distantPast)
            XCTAssertEqual(tasksRun.load(), 0)

            // t=42s
            await eventLoop.advanceTime(by: .seconds(2))
            XCTAssertEqual(tasksRun.load(), 1)
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testExecuteInOrder() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncEmbeddedEventLoop()
            let counter = NIOAtomic.makeAtomic(value: 0)

            eventLoop.execute {
                let original = counter.add(1)
                XCTAssertEqual(original, 0)
            }

            eventLoop.execute {
                let original = counter.add(1)
                XCTAssertEqual(original, 1)
            }

            eventLoop.execute {
                let original = counter.add(1)
                XCTAssertEqual(original, 2)
            }

            await eventLoop.run()
            XCTAssertEqual(counter.load(), 3)
        }
        #else
        throw XCTSkip()
        #endif
    }

    func testScheduledTasksInOrder() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { throw XCTSkip() }
        XCTAsyncTest {
            let eventLoop = NIOAsyncEmbeddedEventLoop()
            let counter = NIOAtomic.makeAtomic(value: 0)

            eventLoop.scheduleTask(in: .seconds(1)) {
                let original = counter.add(1)
                XCTAssertEqual(original, 1)
            }

            eventLoop.scheduleTask(in: .milliseconds(1)) {
                let original = counter.add(1)
                XCTAssertEqual(original, 0)
            }

            eventLoop.scheduleTask(in: .seconds(1)) {
                let original = counter.add(1)
                XCTAssertEqual(original, 2)
            }

            await eventLoop.advanceTime(by: .seconds(1))
            XCTAssertEqual(counter.load(), 3)
        }
        #else
        throw XCTSkip()
        #endif
    }
}
