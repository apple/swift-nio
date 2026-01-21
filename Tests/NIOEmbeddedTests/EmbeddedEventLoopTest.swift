//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
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

private final class EmbeddedTestError: Error {}

public final class EmbeddedEventLoopTest: XCTestCase {
    func testExecuteDoesNotImmediatelyRunTasks() throws {
        var callbackRan = false
        let loop = EmbeddedEventLoop()
        loop.execute { callbackRan = true }

        XCTAssertFalse(callbackRan)
        loop.run()
        XCTAssertTrue(callbackRan)
    }

    func testExecuteWillRunAllTasks() throws {
        var runCount = 0
        let loop = EmbeddedEventLoop()
        loop.execute { runCount += 1 }
        loop.execute { runCount += 1 }
        loop.execute { runCount += 1 }

        XCTAssertEqual(runCount, 0)
        loop.run()
        XCTAssertEqual(runCount, 3)
    }

    func testExecuteWillRunTasksAddedRecursively() throws {
        var sentinel = 0
        let loop = EmbeddedEventLoop()

        loop.execute {
            // This should execute first.
            XCTAssertEqual(sentinel, 0)
            sentinel = 1
            loop.execute {
                // This should execute third.
                XCTAssertEqual(sentinel, 2)
                sentinel = 3
            }
        }
        loop.execute {
            // This should execute second.
            XCTAssertEqual(sentinel, 1)
            sentinel = 2
        }

        XCTAssertEqual(sentinel, 0)
        loop.run()
        XCTAssertEqual(sentinel, 3)
    }

    func testTasksSubmittedAfterRunDontRun() throws {
        var callbackRan = false
        let loop = EmbeddedEventLoop()
        loop.execute { callbackRan = true }

        XCTAssertFalse(callbackRan)
        loop.run()
        loop.execute { callbackRan = false }
        XCTAssertTrue(callbackRan)
        loop.run()
        XCTAssertFalse(callbackRan)
    }

    func testShutdownGracefullyRunsTasks() throws {
        var callbackRan = false
        let loop = EmbeddedEventLoop()
        loop.execute { callbackRan = true }

        XCTAssertFalse(callbackRan)
        XCTAssertNoThrow(try loop.syncShutdownGracefully())
        XCTAssertTrue(callbackRan)
    }

    func testCanControlTime() throws {
        var callbackCount = 0
        let loop = EmbeddedEventLoop()
        _ = loop.scheduleTask(in: .nanoseconds(5)) {
            callbackCount += 1
        }

        XCTAssertEqual(callbackCount, 0)
        loop.advanceTime(by: .nanoseconds(4))
        XCTAssertEqual(callbackCount, 0)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(callbackCount, 1)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(callbackCount, 1)
        loop.advanceTime(by: .hours(1))
        XCTAssertEqual(callbackCount, 1)
    }

    func testCanScheduleMultipleTasks() throws {
        var sentinel = 0
        let loop = EmbeddedEventLoop()
        for index in 1...10 {
            _ = loop.scheduleTask(in: .nanoseconds(Int64(index))) {
                sentinel = index
            }
        }

        for val in 1...10 {
            XCTAssertEqual(sentinel, val - 1)
            loop.advanceTime(by: .nanoseconds(1))
            XCTAssertEqual(sentinel, val)
        }
    }

    func testExecutedTasksFromScheduledOnesAreRun() throws {
        var sentinel = 0
        let loop = EmbeddedEventLoop()
        _ = loop.scheduleTask(in: .nanoseconds(5)) {
            sentinel = 1
            loop.execute {
                sentinel = 2
            }
        }

        loop.advanceTime(by: .nanoseconds(4))
        XCTAssertEqual(sentinel, 0)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(sentinel, 2)
    }

    func testScheduledTasksFromScheduledTasksProperlySchedule() throws {
        var sentinel = 0
        let loop = EmbeddedEventLoop()
        _ = loop.scheduleTask(in: .nanoseconds(5)) {
            sentinel = 1
            _ = loop.scheduleTask(in: .nanoseconds(3)) {
                sentinel = 2
            }
            _ = loop.scheduleTask(in: .nanoseconds(5)) {
                sentinel = 3
            }
        }

        loop.advanceTime(by: .nanoseconds(4))
        XCTAssertEqual(sentinel, 0)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(sentinel, 1)
        loop.advanceTime(by: .nanoseconds(2))
        XCTAssertEqual(sentinel, 1)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(sentinel, 2)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(sentinel, 2)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(sentinel, 3)
    }

    func testScheduledTasksFromExecutedTasks() throws {
        var sentinel = 0
        let loop = EmbeddedEventLoop()
        loop.execute {
            XCTAssertEqual(sentinel, 0)
            _ = loop.scheduleTask(in: .nanoseconds(5)) {
                XCTAssertEqual(sentinel, 1)
                sentinel = 2
            }
            loop.execute { sentinel = 1 }
        }

        loop.advanceTime(by: .nanoseconds(5))
        XCTAssertEqual(sentinel, 2)
    }

    func testCancellingScheduledTasks() throws {
        let loop = EmbeddedEventLoop()
        let task = loop.scheduleTask(in: .nanoseconds(10), { XCTFail("Cancelled task ran") })
        _ = loop.scheduleTask(in: .nanoseconds(5)) {
            task.cancel()
        }

        loop.advanceTime(by: .nanoseconds(20))
    }

    func testScheduledTasksFuturesFire() throws {
        let fired = ManagedAtomic(false)
        let loop = EmbeddedEventLoop()
        let task = loop.scheduleTask(in: .nanoseconds(5)) { true }
        task.futureResult.whenSuccess { fired.store($0, ordering: .sequentiallyConsistent) }

        loop.advanceTime(by: .nanoseconds(4))
        XCTAssertFalse(fired.load(ordering: .sequentiallyConsistent))
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertTrue(fired.load(ordering: .sequentiallyConsistent))
    }

    func testScheduledTasksFuturesError() throws {
        let err: NIOLockedValueBox<EmbeddedTestError?> = NIOLockedValueBox(nil)
        let fired = ManagedAtomic(false)
        let loop = EmbeddedEventLoop()
        let task = loop.scheduleTask(in: .nanoseconds(5)) {
            let localErr = EmbeddedTestError()
            err.withLockedValue { $0 = localErr }
            throw localErr
        }
        task.futureResult.map {
            XCTFail("Scheduled future completed")
        }.recover { caughtErr in
            XCTAssertTrue(err.withLockedValue { $0 === caughtErr as? EmbeddedTestError })
        }.whenComplete { (_: Result<Void, Error>) in
            fired.store(true, ordering: .sequentiallyConsistent)
        }

        loop.advanceTime(by: .nanoseconds(4))
        XCTAssertFalse(fired.load(ordering: .sequentiallyConsistent))
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertTrue(fired.load(ordering: .sequentiallyConsistent))
    }

    func testTaskOrdering() {
        // This test validates that the ordering of task firing on EmbeddedEventLoop via
        // advanceTime(by:) is the same as on MultiThreadedEventLoopGroup: specifically, that tasks run via
        // schedule that expire "now" all run at the same time, and that any work they schedule is run
        // after all such tasks expire.
        let loop = EmbeddedEventLoop()
        var firstScheduled: Scheduled<Void>? = nil
        var secondScheduled: Scheduled<Void>? = nil
        var orderingCounter = 0

        // Here's the setup. First, we'll set up two scheduled tasks to fire in 5 nanoseconds. Each of these
        // will attempt to cancel the other, whichever fires first. Additionally, each will execute{} a single
        // callback. Then we'll execute {} one other callback. Finally we'll schedule a task for 10ns, before
        // we advance time. The ordering should be as follows:
        //
        // 1. The task executed by execute {} from this function.
        // 2. One of the first scheduled tasks.
        // 3. The other first scheduled task  (note that the cancellation will fail).
        // 4. One of the execute {} callbacks from a scheduled task.
        // 5. The other execute {} callbacks from the scheduled task.
        // 6. The 10ns task.
        //
        // To validate the ordering, we'll use a counter.

        func delayedExecute() {
            // The acceptable value for the delayed execute callbacks is 3 or 4.
            XCTAssertTrue(orderingCounter == 3 || orderingCounter == 4, "Invalid counter value \(orderingCounter)")
            orderingCounter += 1
        }

        firstScheduled = loop.scheduleTask(in: .nanoseconds(5)) {
            firstScheduled = nil

            let expected: Int
            if let partner = secondScheduled {
                // Ok, this callback fired first. Cancel the other, then set the expected current
                // counter value to 1.
                partner.cancel()
                expected = 1
            } else {
                // This callback fired second.
                expected = 2
            }

            XCTAssertEqual(orderingCounter, expected)
            orderingCounter = expected + 1
            loop.execute(delayedExecute)
        }

        secondScheduled = loop.scheduleTask(in: .nanoseconds(5)) {
            secondScheduled = nil

            let expected: Int
            if let partner = firstScheduled {
                // Ok, this callback fired first. Cancel the other, then set the expected current
                // counter value to 1.
                partner.cancel()
                expected = 1
            } else {
                // This callback fired second.
                expected = 2
            }

            XCTAssertEqual(orderingCounter, expected)
            orderingCounter = expected + 1
            loop.execute(delayedExecute)
        }

        // Ok, now we set one more task to execute.
        loop.execute {
            XCTAssertEqual(orderingCounter, 0)
            orderingCounter = 1
        }

        // Finally schedule a task for 10ns.
        _ = loop.scheduleTask(in: .nanoseconds(10)) {
            XCTAssertEqual(orderingCounter, 5)
            orderingCounter = 6
        }

        // Now we advance time by 10ns.
        loop.advanceTime(by: .nanoseconds(10))

        // Now the final value should be 6.
        XCTAssertEqual(orderingCounter, 6)
    }

    func testCancelledScheduledTasksDoNotHoldOnToRunClosure() {
        let eventLoop = EmbeddedEventLoop()
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
        XCTAssertThrowsError(try scheduled.futureResult.wait()) { error in
            XCTAssertEqual(EventLoopError.cancelled, error as? EventLoopError)
        }
    }

    func testShutdownCancelsFutureScheduledTasks() {
        let eventLoop = EmbeddedEventLoop()
        var tasksRun = 0

        let a = eventLoop.scheduleTask(in: .seconds(1)) { tasksRun += 1 }
        let b = eventLoop.scheduleTask(in: .seconds(2)) { tasksRun += 1 }

        XCTAssertEqual(tasksRun, 0)

        eventLoop.advanceTime(by: .seconds(1))
        XCTAssertEqual(tasksRun, 1)

        XCTAssertNoThrow(try eventLoop.syncShutdownGracefully())
        XCTAssertEqual(tasksRun, 1)

        eventLoop.advanceTime(by: .seconds(1))
        XCTAssertEqual(tasksRun, 1)

        eventLoop.advanceTime(to: .distantFuture)
        XCTAssertEqual(tasksRun, 1)

        XCTAssertNoThrow(try a.futureResult.wait())
        XCTAssertThrowsError(try b.futureResult.wait()) { error in
            XCTAssertEqual(error as? EventLoopError, .cancelled)
            XCTAssertEqual(tasksRun, 1)
        }
    }

    func testTasksScheduledDuringShutdownAreAutomaticallyCancelled() throws {
        let eventLoop = EmbeddedEventLoop()
        var tasksRun = 0
        var childTasks: [Scheduled<Void>] = []

        func scheduleRecursiveTask(
            at taskStartTime: NIODeadline,
            andChildTaskAfter childTaskStartDelay: TimeAmount
        ) -> Scheduled<Void> {
            eventLoop.scheduleTask(deadline: taskStartTime) {
                tasksRun += 1
                try eventLoop.syncShutdownGracefully()
                childTasks.append(
                    scheduleRecursiveTask(
                        at: eventLoop.now + childTaskStartDelay,
                        andChildTaskAfter: childTaskStartDelay
                    )
                )
            }
        }

        let rootTask = scheduleRecursiveTask(at: .uptimeNanoseconds(1), andChildTaskAfter: .zero)

        eventLoop.advanceTime(to: .uptimeNanoseconds(1))

        XCTAssertEqual(tasksRun, 1)
        XCTAssertNoThrow(try rootTask.futureResult.wait())

        for childTask in childTasks {
            XCTAssertThrowsError(try childTask.futureResult.wait()) { error in
                XCTAssertEqual(error as? EventLoopError, .cancelled)
                XCTAssertEqual(tasksRun, 1)
            }
        }
    }

    func testAdvanceTimeToDeadline() {
        let eventLoop = EmbeddedEventLoop()
        let deadline = NIODeadline.uptimeNanoseconds(0) + .seconds(42)

        var tasksRun = 0
        eventLoop.scheduleTask(deadline: deadline) {
            tasksRun += 1
        }

        eventLoop.advanceTime(to: deadline)
        XCTAssertEqual(tasksRun, 1)
    }

    func testWeCantTimeTravelByAdvancingTimeToThePast() {
        let eventLoop = EmbeddedEventLoop()

        var tasksRun = 0
        eventLoop.scheduleTask(deadline: .uptimeNanoseconds(0) + .seconds(42)) {
            tasksRun += 1
        }

        // t=40s
        eventLoop.advanceTime(to: .uptimeNanoseconds(0) + .seconds(40))
        XCTAssertEqual(tasksRun, 0)

        // t=40s (still)
        eventLoop.advanceTime(to: .distantPast)
        XCTAssertEqual(tasksRun, 0)

        // t=42s
        eventLoop.advanceTime(by: .seconds(2))
        XCTAssertEqual(tasksRun, 1)
    }

    func testExecuteInOrder() {
        let eventLoop = EmbeddedEventLoop()
        var counter = 0

        eventLoop.execute {
            XCTAssertEqual(counter, 0)
            counter += 1
        }

        eventLoop.execute {
            XCTAssertEqual(counter, 1)
            counter += 1
        }

        eventLoop.execute {
            XCTAssertEqual(counter, 2)
            counter += 1
        }

        eventLoop.run()
        XCTAssertEqual(counter, 3)
    }

    func testScheduledTasksInOrder() {
        let eventLoop = EmbeddedEventLoop()
        var counter = 0

        eventLoop.scheduleTask(in: .seconds(1)) {
            XCTAssertEqual(counter, 1)
            counter += 1
        }

        eventLoop.scheduleTask(in: .milliseconds(1)) {
            XCTAssertEqual(counter, 0)
            counter += 1
        }

        eventLoop.scheduleTask(in: .seconds(1)) {
            XCTAssertEqual(counter, 2)
            counter += 1
        }

        eventLoop.advanceTime(by: .seconds(1))
        XCTAssertEqual(counter, 3)
    }

    func testCurrentTime() {
        let eventLoop = EmbeddedEventLoop()

        eventLoop.advanceTime(to: .uptimeNanoseconds(42))
        XCTAssertEqual(eventLoop.now, .uptimeNanoseconds(42))

        eventLoop.advanceTime(by: .nanoseconds(42))
        XCTAssertEqual(eventLoop.now, .uptimeNanoseconds(84))
    }

    func testScheduleRepeatedTask() {
        let eventLoop = EmbeddedEventLoop()

        let counter = ManagedAtomic(0)
        eventLoop.scheduleRepeatedTask(initialDelay: .seconds(1), delay: .seconds(1)) { repeatedTask in
            guard counter.load(ordering: .sequentiallyConsistent) < 10 else {
                repeatedTask.cancel()
                return
            }
            counter.wrappingIncrement(ordering: .sequentiallyConsistent)
        }

        XCTAssertEqual(counter.load(ordering: .sequentiallyConsistent), 0)

        eventLoop.advanceTime(by: .seconds(1))
        XCTAssertEqual(counter.load(ordering: .sequentiallyConsistent), 1)

        eventLoop.advanceTime(by: .seconds(9))
        XCTAssertEqual(counter.load(ordering: .sequentiallyConsistent), 10)
    }
}

@available(*, unavailable)
extension EmbeddedEventLoopTest: Sendable {}
