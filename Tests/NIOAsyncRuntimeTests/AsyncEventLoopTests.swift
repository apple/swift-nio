//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import Dispatch
import NIOConcurrencyHelpers
import Testing

@testable import NIOAsyncRuntime
@testable import NIOCore

// NOTE: These tests are copied and adapted from NIOPosixTests.EventLoopTest
// They have been modified to use async running, among other things.

@Suite("AsyncEventLoopTests", .serialized, .timeLimit(.minutes(1)))
final class AsyncEventLoopTests {
    private func makeEventLoop() -> AsyncEventLoop {
        AsyncEventLoop(manualTimeModeForTesting: true)
    }

    private func assertThat<T>(
        future: EventLoopFuture<T>,
        isFulfilled: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let isFutureFulfilled = future.isFulfilled
        #expect(isFutureFulfilled == isFulfilled, sourceLocation: sourceLocation)
    }

    @Test
    func testSchedule() async throws {
        let eventLoop = makeEventLoop()

        let scheduled = eventLoop.scheduleTask(in: .seconds(1)) { true }

        let result: ManagedAtomic<Bool> = ManagedAtomic(false)
        scheduled.futureResult.whenSuccess {
            result.store($0, ordering: .sequentiallyConsistent)
        }
        await eventLoop.run()  // run without time advancing should do nothing
        await assertThat(future: scheduled.futureResult, isFulfilled: false)
        let result2 = result.load(ordering: .sequentiallyConsistent)
        #expect(!result2)

        try await eventLoop.advanceTime(by: .seconds(2))  // should fire now

        await assertThat(future: scheduled.futureResult, isFulfilled: true)
        let result3 = result.load(ordering: .sequentiallyConsistent)
        #expect(result3)
    }

    @Test
    func testFlatSchedule() async throws {
        let eventLoop = makeEventLoop()

        let scheduled = eventLoop.flatScheduleTask(in: .seconds(1)) {
            eventLoop.makeSucceededFuture(true)
        }

        let result: ManagedAtomic<Bool> = ManagedAtomic(false)
        scheduled.futureResult.whenSuccess { result.store($0, ordering: .sequentiallyConsistent) }

        await eventLoop.run()  // run without time advancing should do nothing
        await assertThat(future: scheduled.futureResult, isFulfilled: false)
        let result2 = result.load(ordering: .sequentiallyConsistent)
        #expect(!result2)

        try await eventLoop.advanceTime(by: .seconds(2))  // should fire now
        await assertThat(future: scheduled.futureResult, isFulfilled: true)

        let result3 = result.load(ordering: .sequentiallyConsistent)
        #expect(result3)
    }

    @Test
    func testScheduledTaskWakesEventLoopFromIdle() async throws {
        let eventLoop = AsyncEventLoop(manualTimeModeForTesting: false)

        let promise = eventLoop.makePromise(of: Void.self)

        eventLoop.execute {
            _ = eventLoop.scheduleTask(in: .milliseconds(50)) {
                promise.succeed(())
            }
        }

        try await waitForFuture(promise.futureResult, timeout: .milliseconds(500))

        await #expect(throws: Never.self) {
            try await eventLoop.shutdownGracefully()
        }
    }

    @Test
    func testCancellingScheduledTaskPromiseIsFailed() async throws {
        let eventLoop = makeEventLoop()

        let executed = ManagedAtomic(false)
        let sawCancellation = ManagedAtomic(false)

        let scheduled = eventLoop.scheduleTask(deadline: .now() + .seconds(1)) {
            executed.store(true, ordering: .sequentiallyConsistent)
            return true
        }

        scheduled.futureResult.whenFailure { error in
            sawCancellation.store(
                error as? EventLoopError == .cancelled,
                ordering: .sequentiallyConsistent
            )
        }

        scheduled.cancel()

        try await eventLoop.advanceTime(by: .seconds(2))

        await assertThat(future: scheduled.futureResult, isFulfilled: true)
        await #expect(throws: EventLoopError.cancelled) {
            try await scheduled.futureResult.get()
        }
        let executedValue = executed.load(ordering: .sequentiallyConsistent)
        let sawCancellationValue = sawCancellation.load(ordering: .sequentiallyConsistent)
        #expect(!executedValue)
        #expect(sawCancellationValue)
    }

    @Test
    func testScheduleCancelled() async throws {
        let eventLoop = makeEventLoop()

        let scheduled = eventLoop.scheduleTask(in: .seconds(1)) { true }

        do {
            try await eventLoop.advanceTime(by: .milliseconds(500))  // advance halfway to firing time
            scheduled.cancel()
            try await eventLoop.advanceTime(by: .milliseconds(500))  // advance the rest of the way
            _ = try await scheduled.futureResult.get()
            Issue.record("We should never reach this point. Cancel should route to catch block")
        } catch {
            await assertThat(future: scheduled.futureResult, isFulfilled: true)
            #expect(error as? EventLoopError == .cancelled)
        }
    }

    @Test
    func testFlatScheduleCancelled() async throws {
        let eventLoop = makeEventLoop()

        let scheduled = eventLoop.flatScheduleTask(in: .seconds(1)) {
            eventLoop.makeSucceededFuture(true)
        }

        do {
            try await eventLoop.advanceTime(by: .milliseconds(500))  // advance halfway to firing time
            scheduled.cancel()
            try await eventLoop.advanceTime(by: .milliseconds(500))  // advance the rest of the way
            _ = try await scheduled.futureResult.get()
            Issue.record("We should never reach this point. Cancel should route to catch block")
        } catch {
            await assertThat(future: scheduled.futureResult, isFulfilled: true)
            #expect(error as? EventLoopError == .cancelled)
        }
    }

    @Test
    func testScheduleRepeatedTask() throws {
        let nanos: NIODeadline = .now()
        let initialDelay: TimeAmount = .milliseconds(5)
        let delay: TimeAmount = .milliseconds(10)
        let count = 5
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let counter = ManagedAtomic<Int>(0)
        let loop = eventLoopGroup.next()
        let allDone = DispatchGroup()
        allDone.enter()
        loop.scheduleRepeatedTask(initialDelay: initialDelay, delay: delay) { repeatedTask -> Void in
            #expect(loop.inEventLoop)
            let initialValue = counter.load(ordering: .relaxed)
            counter.wrappingIncrement(ordering: .relaxed)
            if initialValue == 0 {
                #expect(NIODeadline.now() - nanos >= initialDelay)
            } else if initialValue == count {
                repeatedTask.cancel()
                allDone.leave()
            }
        }

        allDone.wait()

        #expect(counter.load(ordering: .relaxed) == count + 1)
        #expect(NIODeadline.now() - nanos >= initialDelay + Int64(count) * delay)
    }

    @Test
    func testScheduledTaskThatIsImmediatelyCancelledNeverFires() async throws {
        let eventLoop = makeEventLoop()
        let scheduled = eventLoop.scheduleTask(in: .seconds(1)) { true }

        do {
            scheduled.cancel()
            try await eventLoop.advanceTime(by: .seconds(1))
            _ = try await scheduled.futureResult.get()
            Issue.record("We should never reach this point. Cancel should route to catch block")
        } catch {
            await assertThat(future: scheduled.futureResult, isFulfilled: true)
            #expect(error as? EventLoopError == .cancelled)
        }
    }

    @Test
    func testScheduledTasksAreOrdered() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let eventLoop = eventLoopGroup.next()
        let now = NIODeadline.now()

        let result = NIOLockedValueBox([Int]())
        var lastScheduled: Scheduled<Void>?
        for i in 0...100 {
            lastScheduled = eventLoop.scheduleTask(deadline: now) {
                result.withLockedValue { $0.append(i) }
            }
        }
        try await lastScheduled?.futureResult.get()
        #expect(result.withLockedValue { $0 } == Array(0...100))
    }

    @Test
    func testFlatScheduledTaskThatIsImmediatelyCancelledNeverFires() async throws {
        let eventLoop = makeEventLoop()
        let scheduled = eventLoop.flatScheduleTask(in: .seconds(1)) {
            eventLoop.makeSucceededFuture(true)
        }

        do {
            scheduled.cancel()
            try await eventLoop.advanceTime(by: .seconds(1))
            _ = try await scheduled.futureResult.get()
            Issue.record("We should never reach this point. Cancel should route to catch block")
        } catch {
            await assertThat(future: scheduled.futureResult, isFulfilled: true)
            #expect(error as? EventLoopError == .cancelled)
        }
    }

    @Test
    func testRepeatedTaskThatIsImmediatelyCancelledNeverFires() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let loop = eventLoopGroup.next()
        loop.execute {
            let task = loop.scheduleRepeatedTask(initialDelay: .milliseconds(0), delay: .milliseconds(0)) { task in
                Issue.record()
            }
            task.cancel()
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test
    func testScheduleRepeatedTaskCancelFromDifferentThread() throws {
        let nanos: NIODeadline = .now()
        let initialDelay: TimeAmount = .milliseconds(5)
        // this will actually force the race from issue #554 to happen frequently
        let delay: TimeAmount = .milliseconds(0)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let hasFiredGroup = DispatchGroup()
        let isCancelledGroup = DispatchGroup()
        let loop = eventLoopGroup.next()
        hasFiredGroup.enter()
        isCancelledGroup.enter()

        let (isAllowedToFire, hasFired) = try! loop.submit {
            let isAllowedToFire = NIOLoopBoundBox(true, eventLoop: loop)
            let hasFired = NIOLoopBoundBox(false, eventLoop: loop)
            return (isAllowedToFire, hasFired)
        }.wait()

        let repeatedTask = loop.scheduleRepeatedTask(initialDelay: initialDelay, delay: delay) {
            (_: RepeatedTask) -> Void in
            #expect(loop.inEventLoop)
            if !hasFired.value {
                // we can only do this once as we can only leave the DispatchGroup once but we might lose a race and
                // the timer might fire more than once (until `shouldNoLongerFire` becomes true).
                hasFired.value = true
                hasFiredGroup.leave()
            }
            #expect(isAllowedToFire.value)
        }
        hasFiredGroup.notify(queue: DispatchQueue.global()) {
            repeatedTask.cancel()
            loop.execute {
                // only now do we know that the `cancel` must have gone through
                isAllowedToFire.value = false
                isCancelledGroup.leave()
            }
        }

        hasFiredGroup.wait()
        #expect(NIODeadline.now() - nanos >= initialDelay)
        isCancelledGroup.wait()
    }

    @Test
    func testScheduleRepeatedTaskToNotRetainRepeatedTask() throws {
        let initialDelay: TimeAmount = .milliseconds(5)
        let delay: TimeAmount = .milliseconds(10)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        weak var weakRepeated: RepeatedTask?
        let repeated = eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: initialDelay,
            delay: delay
        ) {
            (_: RepeatedTask) -> Void in
        }
        weakRepeated = repeated
        #expect(weakRepeated != nil)
        repeated.cancel()
        #expect(throws: Never.self) {
            try eventLoopGroup.syncShutdownGracefully()
        }
        assert(weakRepeated == nil, within: .seconds(1))
    }

    @Test
    func testScheduleRepeatedTaskToNotRetainEventLoop() throws {
        weak var weakEventLoop: EventLoop? = nil
        let initialDelay: TimeAmount = .milliseconds(5)
        let delay: TimeAmount = .milliseconds(10)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        weakEventLoop = eventLoopGroup.next()
        #expect(weakEventLoop != nil)

        eventLoopGroup.next().scheduleRepeatedTask(initialDelay: initialDelay, delay: delay) {
            (_: RepeatedTask) -> Void in
        }

        #expect(throws: Never.self) {
            try eventLoopGroup.syncShutdownGracefully()
        }
        assert(weakEventLoop == nil, within: .seconds(1))
    }

    @Test
    func testScheduledRepeatedAsyncTask() async throws {
        let eventLoop = makeEventLoop()
        nonisolated(unsafe) var counter: Int = 0

        let repeatedTask = eventLoop.scheduleRepeatedAsyncTask(
            initialDelay: .milliseconds(10),
            delay: .milliseconds(10)
        ) { (_: RepeatedTask) in
            counter += 1
            let p = eventLoop.makePromise(of: Void.self)
            _ = eventLoop.scheduleTask(in: .milliseconds(10)) {

                p.succeed(())
            }
            return p.futureResult
        }
        for _ in 0..<30 {
            // just running shouldn't do anything
            await eventLoop.run()
        }

        // At t == 0, counter == 0
        #expect(0 == counter)

        // At t == 5, counter == 0
        try await eventLoop.advanceTime(by: .milliseconds(5))
        await eventLoop.run()
        #expect(0 == counter)

        // At == 10ms, counter == 1
        try await eventLoop.advanceTime(by: .milliseconds(5))
        await eventLoop.run()
        #expect(1 == counter)

        // At t == 15ms, counter == 1
        try await eventLoop.advanceTime(by: .milliseconds(5))
        await eventLoop.run()
        #expect(1 == counter)

        // At t == 20, counter == 1 (because the task takes 10ms to execute)
        try await eventLoop.advanceTime(by: .milliseconds(5))
        #expect(1 == counter)

        // At t == 25, counter == 1 (because the task takes 10ms to execute)
        try await eventLoop.advanceTime(by: .milliseconds(5))
        #expect(1 == counter)

        // At t == 30ms, counter == 2
        try await eventLoop.advanceTime(by: .milliseconds(5))
        #expect(2 == counter)

        // At t == 40ms, counter == 2
        try await eventLoop.advanceTime(by: .milliseconds(10))
        #expect(2 == counter)

        // At t == 50ms, counter == 3
        try await eventLoop.advanceTime(by: .milliseconds(10))
        #expect(3 == counter)

        // At t == 60ms, counter == 3
        try await eventLoop.advanceTime(by: .milliseconds(10))
        #expect(3 == counter)

        // At t == 70ms, counter == 4 (not testing to allow a large jump in time advancement)
        // At t == 80ms, counter == 4 (not testing to allow a large jump in time advancement)

        // At t == 89ms, counter == 4
        // NOTE: The jump by 29 seconds here covers edge cases
        // to ensure the scheduling properly re-triggers every 20 seconds, even
        // when the time advancement exceeds 20 seconds.
        try await eventLoop.advanceTime(by: .milliseconds(29))
        #expect(4 == counter)

        // At t == 90ms, counter == 5
        try await eventLoop.advanceTime(by: .milliseconds(1))
        #expect(5 == counter)

        // Stop repeating.
        repeatedTask.cancel()

        // At t > 90ms, counter stays at 5 because repeating is stopped
        await eventLoop.run()
        #expect(5 == counter)

        // Event after 10 hours, counter stays at 5, because repeating is stopped
        try await eventLoop.advanceTime(by: .hours(10))
        #expect(5 == counter)
    }

    @Test
    func testScheduledRepeatedAsyncTaskIsJittered() async throws {
        let initialDelay = TimeAmount.minutes(5)
        let delay = TimeAmount.minutes(2)
        let maximumAllowableJitter = TimeAmount.minutes(1)
        let counter = ManagedAtomic<Int64>(0)
        let loop = makeEventLoop()

        _ = loop.scheduleRepeatedAsyncTask(
            initialDelay: initialDelay,
            delay: delay,
            maximumAllowableJitter: maximumAllowableJitter,
            { _ in
                counter.wrappingIncrement(ordering: .relaxed)
                let p = loop.makePromise(of: Void.self)
                _ = loop.scheduleTask(in: .milliseconds(10)) {
                    p.succeed(())
                }
                return p.futureResult
            }
        )

        for _ in 0..<10 {
            // just running shouldn't do anything
            await loop.run()
        }

        let timeRange = TimeAmount.hours(1)
        // Due to jittered delays is not possible to exactly know how many tasks will be executed in a given time range,
        // instead calculate a range representing an estimate of the number of tasks executed during that given time range.
        let minNumberOfExecutedTasks =
            (timeRange.nanoseconds - initialDelay.nanoseconds)
            / (delay.nanoseconds + maximumAllowableJitter.nanoseconds)
        let maxNumberOfExecutedTasks =
            (timeRange.nanoseconds - initialDelay.nanoseconds) / delay.nanoseconds + 1

        try await loop.advanceTime(by: timeRange)
        #expect(
            (minNumberOfExecutedTasks...maxNumberOfExecutedTasks).contains(
                counter.load(ordering: .relaxed)
            )
        )
    }

    @Test
    func testEventLoopGroupMakeIterator() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        var counter = 0
        var innerCounter = 0
        for loop in eventLoopGroup.makeIterator() {
            counter += 1
            for _ in loop.makeIterator() {
                innerCounter += 1
            }
        }

        #expect(counter == System.coreCount)
        #expect(innerCounter == System.coreCount)
    }

    @Test
    func testEventLoopMakeIterator() async throws {
        let eventLoop = makeEventLoop()
        let iterator = eventLoop.makeIterator()

        var counter = 0
        for loop in iterator {
            #expect(loop === eventLoop)
            counter += 1
        }

        #expect(counter == 1)

        await eventLoop.closeGracefully()
    }

    @Test
    func testExecuteRejectedWhileShuttingDown() async {
        let eventLoop = makeEventLoop()
        let didRun = ManagedAtomic(false)

        let shutdownTask = Task {
            await eventLoop.closeGracefully()
        }

        await Task.yield()

        eventLoop.execute {
            didRun.store(true, ordering: .relaxed)
        }

        await shutdownTask.value

        #expect(didRun.load(ordering: .relaxed) == false)
    }

    @Test
    func testShutdownWhileScheduledTasksNotReady() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        _ = eventLoop.scheduleTask(in: .hours(1)) {}
        try group.syncShutdownGracefully()
    }

    @Test
    func testScheduleMultipleTasks() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let eventLoop = eventLoopGroup.next()
        let array = try! await eventLoop.submit {
            NIOLoopBoundBox([(Int, NIODeadline)](), eventLoop: eventLoop)
        }.get()
        let scheduled1 = eventLoop.scheduleTask(in: .milliseconds(500)) {
            array.value.append((1, .now()))
        }

        let scheduled2 = eventLoop.scheduleTask(in: .milliseconds(100)) {
            array.value.append((2, .now()))
        }

        let scheduled3 = eventLoop.scheduleTask(in: .milliseconds(1000)) {
            array.value.append((3, .now()))
        }

        var result = try await eventLoop.scheduleTask(in: .milliseconds(1000)) {
            array.value
        }.futureResult.get()

        await assertThat(future: scheduled1.futureResult, isFulfilled: true)
        await assertThat(future: scheduled2.futureResult, isFulfilled: true)
        await assertThat(future: scheduled3.futureResult, isFulfilled: true)

        let first = result.removeFirst()
        #expect(2 == first.0)
        let second = result.removeFirst()
        #expect(1 == second.0)
        let third = result.removeFirst()
        #expect(3 == third.0)

        #expect(first.1 < second.1)
        #expect(second.1 < third.1)

        #expect(result.isEmpty)
    }

    @Test
    func testRepeatedTaskThatIsImmediatelyCancelledNotifies() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let loop = eventLoopGroup.next()
        let promise1: EventLoopPromise<Void> = loop.makePromise()
        let promise2: EventLoopPromise<Void> = loop.makePromise()
        try await confirmation(expectedCount: 2) { confirmation in
            promise1.futureResult.whenSuccess { confirmation() }
            promise2.futureResult.whenSuccess { confirmation() }
            loop.execute {
                let task = loop.scheduleRepeatedTask(
                    initialDelay: .milliseconds(0),
                    delay: .milliseconds(0),
                    notifying: promise1
                ) { task in
                    Issue.record()
                }
                task.cancel(promise: promise2)
            }

            // NOTE: Must allow a few cycles for executor to run, same as in
            // testRepeatedTaskThatIsImmediatelyCancelledNotifies test for NIOPosix
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test
    func testRepeatedTaskThatIsCancelledAfterRunningAtLeastTwiceNotifies() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let loop = eventLoopGroup.next()
        let promise1: EventLoopPromise<Void> = loop.makePromise()
        let promise2: EventLoopPromise<Void> = loop.makePromise()

        // Wait for task to notify twice
        var task: RepeatedTask?
        nonisolated(unsafe) var confirmCount = 0
        let minimumExpectedCount = 2
        try await confirmation(expectedCount: minimumExpectedCount) { confirmation in
            task = loop.scheduleRepeatedTask(
                initialDelay: .milliseconds(0),
                delay: .milliseconds(10),
                notifying: promise1
            ) { task in
                // We need to confirm two or more occur
                if confirmCount < minimumExpectedCount {
                    confirmation()
                    confirmCount += 1
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        let cancellationHandle = try #require(task)

        try await confirmation(expectedCount: 2) { confirmation in
            promise1.futureResult.whenSuccess { confirmation() }
            promise2.futureResult.whenSuccess { confirmation() }
            cancellationHandle.cancel(promise: promise2)
            try await Task.sleep(for: .seconds(1))
        }
    }

    @Test
    func testRepeatedTaskThatCancelsItselfNotifiesOnlyWhenFinished() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let loop = eventLoopGroup.next()
        let promise1: EventLoopPromise<Void> = loop.makePromise()
        let promise2: EventLoopPromise<Void> = loop.makePromise()
        let semaphore = DispatchSemaphore(value: 0)
        loop.scheduleRepeatedTask(
            initialDelay: .milliseconds(0),
            delay: .milliseconds(0),
            notifying: promise1
        ) {
            task -> Void in
            task.cancel(promise: promise2)
            semaphore.wait()
        }

        nonisolated(unsafe) var expectFail1 = false
        nonisolated(unsafe) var expectFail2 = false
        nonisolated(unsafe) var expect1 = false
        nonisolated(unsafe) var expect2 = false
        promise1.futureResult.whenSuccess {
            expectFail1 = true
            expect1 = true
        }
        promise2.futureResult.whenSuccess {
            expectFail2 = true
            expect2 = true
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!expectFail1)
        #expect(!expectFail2)
        semaphore.signal()
        try await Task.sleep(for: .milliseconds(500))
        #expect(expect1)
        #expect(expect2)
    }

    @Test
    func testRepeatedTaskIsJittered() async throws {
        let initialDelay = TimeAmount.minutes(5)
        let delay = TimeAmount.minutes(2)
        let maximumAllowableJitter = TimeAmount.minutes(1)
        let counter = ManagedAtomic<Int64>(0)
        let loop = makeEventLoop()

        _ = loop.scheduleRepeatedTask(
            initialDelay: initialDelay,
            delay: delay,
            maximumAllowableJitter: maximumAllowableJitter,
            { _ in
                counter.wrappingIncrement(ordering: .relaxed)
            }
        )

        let timeRange = TimeAmount.hours(1)
        // Due to jittered delays is not possible to exactly know how many tasks will be executed in a given time range,
        // instead calculate a range representing an estimate of the number of tasks executed during that given time range.
        let minNumberOfExecutedTasks =
            (timeRange.nanoseconds - initialDelay.nanoseconds)
            / (delay.nanoseconds + maximumAllowableJitter.nanoseconds)
        let maxNumberOfExecutedTasks =
            (timeRange.nanoseconds - initialDelay.nanoseconds) / delay.nanoseconds + 1

        try await loop.advanceTime(by: timeRange)
        #expect(
            (minNumberOfExecutedTasks...maxNumberOfExecutedTasks).contains(
                counter.load(ordering: .relaxed)
            )
        )
    }

    @Test
    func testCancelledScheduledTasksDoNotHoldOnToRunClosure() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
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

        func make(deallocated: ConditionLock<Int>) -> Scheduled<Void> {
            let aThing = Thing(deallocated)
            return group.next().scheduleTask(in: .hours(1)) {
                preconditionFailure("this should definitely not run: \(aThing)")
            }
        }

        let deallocated = ConditionLock(value: 0)
        let scheduled = make(deallocated: deallocated)
        scheduled.cancel()
        if deallocated.lock(whenValue: 1, timeoutSeconds: 60) {
            deallocated.unlock()
        } else {
            Issue.record("Timed out waiting for lock")
        }

        await #expect(throws: EventLoopError.cancelled) {
            try await scheduled.futureResult.get()
        }
    }

    @Test
    func testCancelledScheduledTasksDoNotHoldOnToRunClosureEvenIfTheyWereTheNextTaskToExecute()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        final class Thing: Sendable {
            private let deallocated: ConditionLock<Int>

            init(_ deallocated: ConditionLock<Int>) {
                self.deallocated = deallocated
            }

            deinit {
                self.deallocated.lock()
                self.deallocated.unlock(withValue: 1)
            }
        }

        func make(deallocated: ConditionLock<Int>) -> Scheduled<Void> {
            let aThing = Thing(deallocated)
            return group.next().scheduleTask(in: .hours(1)) {
                preconditionFailure("this should definitely not run: \(aThing)")
            }
        }

        // What are we doing here?
        //
        // Our goal is to arrange for our scheduled task to become "nextReadyTask" in SelectableEventLoop, so that
        // when we cancel it there is still a copy aliasing it. This reproduces a subtle correctness bug that
        // existed in NIO 2.48.0 and earlier.
        //
        // This will happen if:
        //
        // 1. We schedule a task for the future
        // 2. The event loop begins a tick.
        // 3. The event loop finds our scheduled task in the future.
        //
        // We can make that happen by scheduling our task and then waiting for a tick to pass, which we can
        // achieve using `submit`.
        //
        // However, if there are no _other_, _even later_ tasks, we'll free the reference. This is
        // because the nextReadyTask is cleared if the list of scheduled tasks ends up empty, so we don't want that to happen.
        //
        // So the order of operations is:
        //
        // 1. Schedule the task for the future.
        // 2. Schedule another, even later, task.
        // 3. Wait for a tick to pass.
        // 4. Cancel our scheduled.
        //
        // In the correct code, this should invoke deinit. In the buggy code, it does not.
        //
        // Unfortunately, this window is very hard to hit. Cancelling the scheduled task wakes the loop up, and if it is
        // still awake by the time we run the cancellation handler it'll notice the change. So we have to tolerate
        // a somewhat flaky test.
        let deallocated = ConditionLock(value: 0)
        let scheduled = make(deallocated: deallocated)
        scheduled.futureResult.eventLoop.scheduleTask(in: .hours(2)) {}
        try! await scheduled.futureResult.eventLoop.submit {}.get()
        scheduled.cancel()
        if deallocated.lock(whenValue: 1, timeoutSeconds: 60) {
            deallocated.unlock()
        } else {
            Issue.record("Timed out waiting for lock")
        }

        await #expect(throws: EventLoopError.cancelled) {
            try await scheduled.futureResult.get()
        }
    }

    @Test
    func testIllegalCloseOfEventLoopFails() {
        // Vapor 3 closes EventLoops directly which is illegal and makes the `shutdownGracefully` of the owning
        // MultiThreadedEventLoopGroup never succeed.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        #expect(throws: EventLoopError.unsupportedOperation) {
            try group.next().syncShutdownGracefully()
        }
    }

    @Test
    func testSubtractingDeadlineFromPastAndFuturesDeadlinesWorks() async throws {
        let older = NIODeadline.now()
        try await Task.sleep(for: .milliseconds(20))
        let newer = NIODeadline.now()

        #expect(older - newer < .nanoseconds(0))
        #expect(newer - older > .nanoseconds(0))
    }

    @Test
    func testCallingSyncShutdownGracefullyMultipleTimesShouldNotHang() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        try elg.syncShutdownGracefully()
        try elg.syncShutdownGracefully()
        try elg.syncShutdownGracefully()
    }

    @Test
    func testCallingShutdownGracefullyMultipleTimesShouldExecuteAllCallbacks() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        let condition: ConditionLock<Int> = ConditionLock(value: 0)
        elg.shutdownGracefully { _ in
            if condition.lock(whenValue: 0, timeoutSeconds: 1) {
                condition.unlock(withValue: 1)
            }
        }
        elg.shutdownGracefully { _ in
            if condition.lock(whenValue: 1, timeoutSeconds: 1) {
                condition.unlock(withValue: 2)
            }
        }
        elg.shutdownGracefully { _ in
            if condition.lock(whenValue: 2, timeoutSeconds: 1) {
                condition.unlock(withValue: 3)
            }
        }

        guard condition.lock(whenValue: 3, timeoutSeconds: 1) else {
            Issue.record("Not all shutdown callbacks have been executed")
            return
        }
        condition.unlock()
    }

    @Test
    func testEdgeCasesNIODeadlineMinusNIODeadline() {
        let smallestPossibleDeadline = NIODeadline.uptimeNanoseconds(.min)
        let largestPossibleDeadline = NIODeadline.uptimeNanoseconds(.max)
        let distantFuture = NIODeadline.distantFuture
        let distantPast = NIODeadline.distantPast
        let zeroDeadline = NIODeadline.uptimeNanoseconds(0)
        let nowDeadline = NIODeadline.now()

        let allDeadlines = [
            smallestPossibleDeadline, largestPossibleDeadline, distantPast, distantFuture,
            zeroDeadline, nowDeadline,
        ]

        for deadline1 in allDeadlines {
            for deadline2 in allDeadlines {
                if deadline1 > deadline2 {
                    #expect(deadline1 - deadline2 > TimeAmount.nanoseconds(0))
                } else if deadline1 < deadline2 {
                    #expect(deadline1 - deadline2 < TimeAmount.nanoseconds(0))
                } else {
                    // they're equal.
                    #expect(deadline1 - deadline2 == TimeAmount.nanoseconds(0))
                }
            }
        }
    }

    @Test
    func testEdgeCasesNIODeadlinePlusTimeAmount() {
        let smallestPossibleTimeAmount = TimeAmount.nanoseconds(.min)
        let largestPossibleTimeAmount = TimeAmount.nanoseconds(.max)
        let zeroTimeAmount = TimeAmount.nanoseconds(0)

        let smallestPossibleDeadline = NIODeadline.uptimeNanoseconds(.min)
        let largestPossibleDeadline = NIODeadline.uptimeNanoseconds(.max)
        let distantFuture = NIODeadline.distantFuture
        let distantPast = NIODeadline.distantPast
        let zeroDeadline = NIODeadline.uptimeNanoseconds(0)
        let nowDeadline = NIODeadline.now()

        for timeAmount in [smallestPossibleTimeAmount, largestPossibleTimeAmount, zeroTimeAmount] {
            for deadline in [
                smallestPossibleDeadline, largestPossibleDeadline, distantPast, distantFuture,
                zeroDeadline, nowDeadline,
            ] {
                let (partial, overflow) = Int64(deadline.uptimeNanoseconds).addingReportingOverflow(
                    timeAmount.nanoseconds
                )
                let expectedValue: UInt64
                if overflow {
                    #expect(timeAmount.nanoseconds > 0)
                    #expect(deadline.uptimeNanoseconds > 0)
                    // we cap at distantFuture towards +inf
                    expectedValue = NIODeadline.distantFuture.uptimeNanoseconds
                } else if partial < 0 {
                    // we cap at 0 towards -inf
                    expectedValue = 0
                } else {
                    // otherwise we have a result
                    expectedValue = .init(partial)
                }
                #expect((deadline + timeAmount).uptimeNanoseconds == expectedValue)
            }
        }
    }

    @Test
    func testEdgeCasesNIODeadlineMinusTimeAmount() {
        let smallestPossibleTimeAmount = TimeAmount.nanoseconds(.min)
        let largestPossibleTimeAmount = TimeAmount.nanoseconds(.max)
        let zeroTimeAmount = TimeAmount.nanoseconds(0)

        let smallestPossibleDeadline = NIODeadline.uptimeNanoseconds(.min)
        let largestPossibleDeadline = NIODeadline.uptimeNanoseconds(.max)
        let distantFuture = NIODeadline.distantFuture
        let distantPast = NIODeadline.distantPast
        let zeroDeadline = NIODeadline.uptimeNanoseconds(0)
        let nowDeadline = NIODeadline.now()

        for timeAmount in [smallestPossibleTimeAmount, largestPossibleTimeAmount, zeroTimeAmount] {
            for deadline in [
                smallestPossibleDeadline, largestPossibleDeadline, distantPast, distantFuture,
                zeroDeadline, nowDeadline,
            ] {
                let (partial, overflow) = Int64(deadline.uptimeNanoseconds).subtractingReportingOverflow(
                    timeAmount.nanoseconds
                )
                let expectedValue: UInt64
                if overflow {
                    #expect(timeAmount.nanoseconds < 0)
                    #expect(deadline.uptimeNanoseconds >= 0)
                    // we cap at distantFuture towards +inf
                    expectedValue = NIODeadline.distantFuture.uptimeNanoseconds
                } else if partial < 0 {
                    // we cap at 0 towards -inf
                    expectedValue = 0
                } else {
                    // otherwise we have a result
                    expectedValue = .init(partial)
                }
                #expect((deadline - timeAmount).uptimeNanoseconds == expectedValue)
            }
        }
    }

    @Test
    func testSuccessfulFlatSubmit() async throws {
        let eventLoop = makeEventLoop()
        let future = eventLoop.flatSubmit {
            eventLoop.makeSucceededFuture(1)
        }
        let result = try await future.get()
        #expect(result == 1)
    }

    @Test
    func testFailingFlatSubmit() async throws {
        enum TestError: Error { case failed }

        let eventLoop = makeEventLoop()
        let future = eventLoop.flatSubmit { () -> EventLoopFuture<Int> in
            eventLoop.makeFailedFuture(TestError.failed)
        }
        await eventLoop.run()
        await #expect(throws: TestError.failed) {
            try await future.get()
        }
    }

    @Test
    func testSchedulingTaskOnTheEventLoopWithinTheEventLoopsOnlyTask() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try elg.syncShutdownGracefully()
            }
        }

        let el = elg.next()
        let g = DispatchGroup()
        g.enter()
        el.execute {
            // We're the last and only task running, scheduling another task here makes sure that despite not waking
            // up the selector, we will still run this task.
            el.execute {
                g.leave()
            }
        }
        g.wait()
    }

    @Test
    func testCancellingTheLastOutstandingTask() async throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try elg.syncShutdownGracefully()
            }
        }

        let el = elg.next()
        let task = el.scheduleTask(in: .milliseconds(10)) {}
        task.cancel()
        // sleep for 15ms which should have the above scheduled (and cancelled) task have caused an unnecessary wakeup.
        try await Task.sleep(for: .milliseconds(15))
    }

    @Test
    func testSchedulingTaskOnTheEventLoopWithinTheEventLoopsOnlyScheduledTask() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try elg.syncShutdownGracefully()
            }
        }

        let el = elg.next()
        let g = DispatchGroup()
        g.enter()
        el.scheduleTask(in: .nanoseconds(10)) {  // something non-0
            el.execute {
                g.leave()
            }
        }
        g.wait()
    }

    @Test
    func testWeFailOutstandingScheduledTasksOnELShutdown() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let scheduledTask = group.next().scheduleTask(in: .hours(24)) {
            Issue.record("We lost the 24 hour race and aren't even in Le Mans.")
        }
        let waiter = DispatchGroup()
        waiter.enter()
        scheduledTask.futureResult.map { _ in
            Issue.record("didn't expect success")
        }.whenFailure { error in
            #expect(.shutdown == error as? EventLoopError)
            waiter.leave()
        }

        #expect(throws: Never.self) {
            try group.syncShutdownGracefully()
        }
        waiter.wait()
    }

    @Test
    func testSchedulingTaskOnFutureFailedByELShutdownDoesNotMakeUsExplode() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let scheduledTask = group.next().scheduleTask(in: .hours(24)) {
            Issue.record("Task was scheduled in 24 hours, yet it executed.")
        }
        let waiter = DispatchGroup()
        waiter.enter()  // first scheduled task
        waiter.enter()  // scheduled task in the first task's whenFailure.
        scheduledTask.futureResult
            .map { _ in
                Issue.record("didn't expect success")
            }
            .whenFailure { error in
                #expect(.shutdown == error as? EventLoopError)
                group.next().execute {}  // This previously blew up
                group.next().scheduleTask(in: .hours(24)) {
                    Issue.record("Task was scheduled in 24 hours, yet it executed.")
                }.futureResult.map {
                    Issue.record("didn't expect success")
                }.whenFailure { error in
                    #expect(.shutdown == error as? EventLoopError)
                    waiter.leave()
                }
                waiter.leave()
            }

        #expect(throws: Never.self) {
            try group.syncShutdownGracefully()
        }
        waiter.wait()
    }

    @Test
    func testEventLoopGroupProvider() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let provider = NIOEventLoopGroupProvider.shared(eventLoopGroup)

        if case .shared(let sharedEventLoopGroup) = provider {
            #expect(sharedEventLoopGroup is MultiThreadedEventLoopGroup)
            #expect(sharedEventLoopGroup === eventLoopGroup)
        } else {
            Issue.record("Not the same")
        }
    }

    // Test that scheduling a task at the maximum value doesn't crash.
    // (Crashing resulted from an EINVAL/IOException thrown by the kevent
    // syscall when the timeout value exceeded the maximum supported by
    // the Darwin kernel #1056).
    @Test
    func testScheduleMaximum() async throws {
        let eventLoop = makeEventLoop()
        let maxAmount: TimeAmount = .nanoseconds(.max)
        let scheduled = eventLoop.scheduleTask(in: maxAmount) { true }

        do {
            scheduled.cancel()
            _ = try await scheduled.futureResult.get()
            Issue.record("Shouldn't reach this point due to cancellation.")
        } catch {
            await assertThat(future: scheduled.futureResult, isFulfilled: true)
            #expect(error as? EventLoopError == .cancelled)
        }
    }

    @Test
    func testEventLoopsWithPreSucceededFuturesCacheThem() {
        let el = EventLoopWithPreSucceededFuture()
        defer {
            #expect(throws: Never.self) {
                try el.syncShutdownGracefully()
            }
        }

        let future1 = el.makeSucceededFuture(())
        let future2 = el.makeSucceededFuture(())
        let future3 = el.makeSucceededVoidFuture()

        #expect(future1 === future2)
        #expect(future2 === future3)
    }

    @Test
    func testEventLoopsWithoutPreSucceededFuturesDoNotCacheThem() {
        let el = EventLoopWithoutPreSucceededFuture()
        defer {
            #expect(throws: Never.self) {
                try el.syncShutdownGracefully()
            }
        }

        let future1 = el.makeSucceededFuture(())
        let future2 = el.makeSucceededFuture(())
        let future3 = el.makeSucceededVoidFuture()

        #expect(future1 !== future2)
        #expect(future2 !== future3)
        #expect(future1 !== future3)
    }

    @Test
    func testSelectableEventLoopHasPreSucceededFuturesOnlyOnTheEventLoop() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try elg.syncShutdownGracefully()
            }
        }

        let el = elg.next()

        let futureOutside1 = el.makeSucceededVoidFuture()
        let futureOutside2 = el.makeSucceededFuture(())
        #expect(futureOutside1 !== futureOutside2)

        #expect(throws: Never.self) {
            try el.submit {
                let futureInside1 = el.makeSucceededVoidFuture()
                let futureInside2 = el.makeSucceededFuture(())

                #expect(futureOutside1 !== futureInside1)
                #expect(futureInside1 === futureInside2)
            }.wait()
        }
    }

    @Test
    func testMakeCompletedFuture() async throws {
        let eventLoop = makeEventLoop()

        #expect(try await eventLoop.makeCompletedFuture(.success("foo")).get() == "foo")

        struct DummyError: Error {}
        let future = eventLoop.makeCompletedFuture(Result<String, Error>.failure(DummyError()))
        await #expect(throws: DummyError.self) {
            try await future.get()
        }

        await #expect(throws: Never.self) {
            try await eventLoop.shutdownGracefully()
        }
    }

    @Test
    func testMakeCompletedFutureWithResultOf() async throws {
        let eventLoop = makeEventLoop()

        #expect(try await eventLoop.makeCompletedFuture(withResultOf: { "foo" }).get() == "foo")

        struct DummyError: Error {}
        func throwError() throws {
            throw DummyError()
        }

        let future = eventLoop.makeCompletedFuture(withResultOf: throwError)
        await #expect(throws: DummyError.self) {
            try await future.get()
        }

        await #expect(throws: Never.self) {
            try await eventLoop.shutdownGracefully()
        }
    }

    @Test
    func testMakeCompletedVoidFuture() {
        let eventLoop = EventLoopWithPreSucceededFuture()
        defer {
            #expect(throws: Never.self) {
                try eventLoop.syncShutdownGracefully()
            }
        }

        let future1 = eventLoop.makeCompletedFuture(.success(()))
        let future2 = eventLoop.makeSucceededVoidFuture()
        let future3 = eventLoop.makeSucceededFuture(())
        #expect(future1 === future2)
        #expect(future2 === future3)
    }

    @Test
    func testEventLoopGroupsWithoutAnyImplementationAreValid() async throws {
        let group = EventLoopGroupOf3WithoutAnAnyImplementation()
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let submitDone = group.any().submit {
            let el1 = group.any()
            let el2 = group.any()
            // our group doesn't support `any()` and will fall back to `next()`.
            #expect(el1 !== el2)
        }
        for el in group.makeIterator() {
            await (el as! AsyncEventLoop).run()
        }
        await #expect(throws: Never.self) {
            try await submitDone.get()
        }
    }

    @Test
    func testAsyncToFutureConversionSuccess() async throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let result = try await group.next().makeFutureWithTask {
            try await Task.sleep(nanoseconds: 37)
            return "hello from async"
        }.get()
        #expect("hello from async" == result)
    }

    @Test
    func testAsyncToFutureConversionFailure() async throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        struct DummyError: Error {}

        await #expect(throws: DummyError.self) {
            try await group.next().makeFutureWithTask {
                try await Task.sleep(nanoseconds: 37)
                throw DummyError()
            }.get()
        }
    }

    // Test for possible starvation discussed here: https://github.com/apple/swift-nio/pull/2645#discussion_r1486747118
    @Test
    func testNonStarvation() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let eventLoop = group.next()
        let stop = try eventLoop.submit { NIOLoopBoundBox(false, eventLoop: eventLoop) }.wait()

        @Sendable
        func reExecuteTask() {
            if !stop.value {
                eventLoop.execute {
                    reExecuteTask()
                }
            }
        }

        eventLoop.execute {
            // SelectableEventLoop runs batches of up to 4096.
            // Submit significantly over that for good measure.
            for _ in (0..<10000) {
                eventLoop.assumeIsolated().execute(reExecuteTask)
            }
        }
        let stopTask = eventLoop.scheduleTask(in: .microseconds(10)) {
            stop.value = true
        }
        try stopTask.futureResult.wait()
    }

    @Test
    func testMixedImmediateAndScheduledTasks() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let eventLoop = group.next()
        let scheduledTaskMagic = 17
        let scheduledTask = eventLoop.scheduleTask(in: .microseconds(10)) {
            scheduledTaskMagic
        }

        let immediateTaskMagic = 18
        let immediateTask = eventLoop.submit {
            immediateTaskMagic
        }

        let scheduledTaskMagicOut = try await scheduledTask.futureResult.get()
        #expect(scheduledTaskMagicOut == scheduledTaskMagic)

        let immediateTaskMagicOut = try await immediateTask.get()
        #expect(immediateTaskMagicOut == immediateTaskMagic)
    }
}

private final class EventLoopWithPreSucceededFuture: EventLoop {
    var inEventLoop: Bool {
        true
    }

    func execute(_ task: @escaping () -> Void) {
        preconditionFailure("not implemented")
    }

    func submit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        preconditionFailure("not implemented")
    }

    var now: NIODeadline {
        preconditionFailure("not implemented")
    }

    @discardableResult
    func scheduleTask<T>(deadline: NIODeadline, _ task: @escaping () throws -> T) -> Scheduled<T> {
        preconditionFailure("not implemented")
    }

    @discardableResult
    func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T> {
        preconditionFailure("not implemented")
    }

    func preconditionInEventLoop(file: StaticString, line: UInt) {
        preconditionFailure("not implemented")
    }

    func preconditionNotInEventLoop(file: StaticString, line: UInt) {
        preconditionFailure("not implemented")
    }

    // We'd need to use an IUO here in order to use a loop-bound here (self needs to be initialized
    // to create the loop-bound box). That'd require the use of unchecked Sendable. A locked value
    // box is fine, it's only tests.
    private let _succeededVoidFuture: NIOLockedValueBox<EventLoopFuture<Void>?>

    func makeSucceededVoidFuture() -> EventLoopFuture<Void> {
        guard self.inEventLoop, let voidFuture = self._succeededVoidFuture.withLockedValue({ $0 })
        else {
            return self.makeSucceededFuture(())
        }
        return voidFuture
    }

    init() {
        self._succeededVoidFuture = NIOLockedValueBox(nil)
        self._succeededVoidFuture.withLockedValue {
            $0 = EventLoopFuture(eventLoop: self, value: ())
        }
    }

    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping @Sendable (Error?) -> Void) {
        self._succeededVoidFuture.withLockedValue { $0 = nil }
        queue.async {
            callback(nil)
        }
    }
}

private final class EventLoopWithoutPreSucceededFuture: EventLoop {
    var inEventLoop: Bool {
        true
    }

    func execute(_ task: @escaping () -> Void) {
        preconditionFailure("not implemented")
    }

    func submit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        preconditionFailure("not implemented")
    }

    var now: NIODeadline {
        preconditionFailure("not implemented")
    }

    @discardableResult
    func scheduleTask<T>(deadline: NIODeadline, _ task: @escaping () throws -> T) -> Scheduled<T> {
        preconditionFailure("not implemented")
    }

    @discardableResult
    func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T> {
        preconditionFailure("not implemented")
    }

    func preconditionInEventLoop(file: StaticString, line: UInt) {
        preconditionFailure("not implemented")
    }

    func preconditionNotInEventLoop(file: StaticString, line: UInt) {
        preconditionFailure("not implemented")
    }

    func shutdownGracefully(queue: DispatchQueue, _ callback: @Sendable @escaping (Error?) -> Void) {
        queue.async {
            callback(nil)
        }
    }
}

final class EventLoopGroupOf3WithoutAnAnyImplementation: EventLoopGroup {
    private static func makeEventLoop() -> AsyncEventLoop {
        AsyncEventLoop(manualTimeModeForTesting: true)
    }

    private let eventloops = [makeEventLoop(), makeEventLoop(), makeEventLoop()]
    private let nextID = ManagedAtomic<UInt64>(0)

    func next() -> EventLoop {
        self.eventloops[
            Int(self.nextID.loadThenWrappingIncrement(ordering: .relaxed) % UInt64(self.eventloops.count))
        ]
    }

    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        let g = DispatchGroup()

        for el in self.eventloops {
            g.enter()
            el.shutdownGracefully(queue: queue) { error in
                #expect(error != nil)
                g.leave()
            }
        }

        g.notify(queue: queue) {
            callback(nil)
        }
    }

    func makeIterator() -> EventLoopIterator {
        .init(self.eventloops)
    }
}

private enum AsyncEventLoopTestsTimeoutError: Error {
    case timeout
}

private func waitForFuture<T: Sendable>(
    _ future: EventLoopFuture<T>,
    timeout: TimeAmount
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await future.get()
        }
        group.addTask {
            let nanoseconds = UInt64(max(timeout.nanoseconds, 0))
            try await Task.sleep(nanoseconds: nanoseconds)
            throw AsyncEventLoopTestsTimeoutError.timeout
        }

        guard let value = try await group.next() else {
            throw AsyncEventLoopTestsTimeoutError.timeout
        }
        group.cancelAll()
        return value
    }
}
