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

import NIOConcurrencyHelpers
import Testing

@testable import NIOAsyncRuntime
@testable import NIOCore

// NOTE: These tests are copied and adapted from NIOPosixTests.EventLoopTest
// They have been modified to use async running, among other things.

@Suite("MultiThreadedEventLoopGroupTests", .serialized, .timeLimit(.minutes(1)))
final class MultiThreadedEventLoopGroupTests {
    @Test
    func testLotsOfMixedImmediateAndScheduledTasks() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let eventLoop = group.next()
        struct Counter: Sendable {
            private var _submitCount = NIOLockedValueBox(0)
            var submitCount: Int {
                get { self._submitCount.withLockedValue { $0 } }
                nonmutating set { self._submitCount.withLockedValue { $0 = newValue } }
            }
            private var _scheduleCount = NIOLockedValueBox(0)
            var scheduleCount: Int {
                get { self._scheduleCount.withLockedValue { $0 } }
                nonmutating set { self._scheduleCount.withLockedValue { $0 = newValue } }
            }
        }

        let achieved = Counter()
        var immediateTasks = [EventLoopFuture<Void>]()
        var scheduledTasks = [Scheduled<Void>]()
        for _ in (0..<100_000) {
            if Bool.random() {
                let task = eventLoop.submit {
                    achieved.submitCount += 1
                }
                immediateTasks.append(task)
            }
            if Bool.random() {
                let task = eventLoop.scheduleTask(in: .microseconds(10)) {
                    achieved.scheduleCount += 1
                }
                scheduledTasks.append(task)
            }
        }

        let submitCount = try await EventLoopFuture.whenAllSucceed(immediateTasks, on: eventLoop).map({
            _ in
            achieved.submitCount
        }).get()
        #expect(submitCount == achieved.submitCount)

        let scheduleCount = try await EventLoopFuture.whenAllSucceed(
            scheduledTasks.map { $0.futureResult },
            on: eventLoop
        )
        .map({ _ in
            achieved.scheduleCount
        }).get()
        #expect(scheduleCount == scheduledTasks.count)
    }

    @Test
    func testLotsOfMixedImmediateAndScheduledTasksFromEventLoop() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let eventLoop = group.next()
        struct Counter: Sendable {
            private var _submitCount = NIOLockedValueBox(0)
            var submitCount: Int {
                get { self._submitCount.withLockedValue { $0 } }
                nonmutating set { self._submitCount.withLockedValue { $0 = newValue } }
            }
            private var _scheduleCount = NIOLockedValueBox(0)
            var scheduleCount: Int {
                get { self._scheduleCount.withLockedValue { $0 } }
                nonmutating set { self._scheduleCount.withLockedValue { $0 = newValue } }
            }
        }

        let achieved = Counter()
        let (immediateTasks, scheduledTasks) = try await eventLoop.submit {
            var immediateTasks = [EventLoopFuture<Void>]()
            var scheduledTasks = [Scheduled<Void>]()
            for _ in (0..<100_000) {
                if Bool.random() {
                    let task = eventLoop.submit {
                        achieved.submitCount += 1
                    }
                    immediateTasks.append(task)
                }
                if Bool.random() {
                    let task = eventLoop.scheduleTask(in: .microseconds(10)) {
                        achieved.scheduleCount += 1
                    }
                    scheduledTasks.append(task)
                }
            }
            return (immediateTasks, scheduledTasks)
        }.get()

        let submitCount = try await EventLoopFuture.whenAllSucceed(immediateTasks, on: eventLoop)
            .map({ _ in
                achieved.submitCount
            }).get()
        #expect(submitCount == achieved.submitCount)

        let scheduleCount = try await EventLoopFuture.whenAllSucceed(
            scheduledTasks.map { $0.futureResult },
            on: eventLoop
        )
        .map({ _ in
            achieved.scheduleCount
        }).get()
        #expect(scheduleCount == scheduledTasks.count)
    }

    @Test
    func testImmediateTasksDontGetStuck() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let eventLoop = group.next()
        let testEventLoop = MultiThreadedEventLoopGroup.singleton.any()

        let longWait = TimeAmount.seconds(60)
        let failDeadline = NIODeadline.now() + longWait
        let (immediateTasks, scheduledTask) = try await eventLoop.submit {
            // Submit over the 4096 immediate tasks, and some scheduled tasks
            // with expiry deadline in (nearish) future.
            // We want to make sure immediate tasks, even those that don't fit
            // in the first batch, don't get stuck waiting for scheduled task
            // expiry
            let immediateTasks = (0..<5000).map { _ in
                eventLoop.submit {}.hop(to: testEventLoop)
            }
            let scheduledTask = eventLoop.scheduleTask(in: longWait) {
            }

            return (immediateTasks, scheduledTask)
        }.get()

        // The immediate tasks should all succeed ~immediately.
        // We're testing for a case where the EventLoop gets confused
        // into waiting for the scheduled task expiry to complete
        // some immediate tasks.
        _ = try await EventLoopFuture.whenAllSucceed(immediateTasks, on: testEventLoop).get()
        #expect(.now() < failDeadline)

        scheduledTask.cancel()
    }

    @Test
    func testInEventLoopABAProblem() async throws {
        // Older SwiftNIO versions had a bug here, they held onto `pthread_t`s for ever (which is illegal) and then
        // used `pthread_equal(pthread_self(), myPthread)`. `pthread_equal` just compares the pointer values which
        // means there's an ABA problem here. This test checks that we don't suffer from that issue now.
        let allELs: NIOLockedValueBox<[any EventLoop]> = NIOLockedValueBox([])

        for _ in 0..<100 {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
            defer {
                #expect(throws: Never.self) {
                    try group.syncShutdownGracefully()
                }
            }
            for loop in group.makeIterator() {
                try! await loop.submit {
                    allELs.withLockedValue { allELs in
                        #expect(loop.inEventLoop)
                        for otherEL in allELs {
                            #expect(
                                !otherEL.inEventLoop,
                                "should only be in \(loop) but turns out also in \(otherEL)"
                            )
                        }
                        allELs.append(loop)
                    }
                }.get()
            }
        }
    }
}
