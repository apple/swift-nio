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
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest

final class TaskExecutorTests: XCTestCase {
    #if compiler(>=6.0)
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func _runTests(loop1: some EventLoop, loop2: some EventLoop) async {
        let executor1 = loop1.taskExecutor
        let executor2 = loop2.taskExecutor
        await withTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask(executorPreference: executor1) {
                loop1.assertInEventLoop()
                loop2.assertNotInEventLoop()

                withUnsafeCurrentTask { task in
                    // this currently fails on macOS
                    XCTAssertEqual(task?.unownedTaskExecutor, executor1.asUnownedTaskExecutor())
                }
            }

            taskGroup.addTask(executorPreference: executor2) {
                loop1.assertNotInEventLoop()
                loop2.assertInEventLoop()

                withUnsafeCurrentTask { task in
                    // this currently fails on macOS
                    XCTAssertEqual(task?.unownedTaskExecutor, executor2.asUnownedTaskExecutor())
                }
            }
        }

        let task = Task(executorPreference: executor1) {
            loop1.assertInEventLoop()
            loop2.assertNotInEventLoop()

            withUnsafeCurrentTask { task in
                // this currently fails on macOS
                XCTAssertEqual(task?.unownedTaskExecutor, executor1.asUnownedTaskExecutor())
            }
        }

        await task.value
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func testSelectableEventLoopAsTaskExecutor() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        var iterator = group.makeIterator()
        let loop1 = iterator.next()!
        let loop2 = iterator.next()!

        await self._runTests(loop1: loop1, loop2: loop2)
        try! await group.shutdownGracefully()
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func testAsyncTestingEventLoopAsTaskExecutor() async throws {
        let loop1 = NIOAsyncTestingEventLoop()
        let loop2 = NIOAsyncTestingEventLoop()

        await self._runTests(loop1: loop1, loop2: loop2)

        await loop1.shutdownGracefully()
        await loop2.shutdownGracefully()
    }

    /// Not isolated, so calling it switches to the generic executor, which is the preferred task executor.
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    private static func switchToGenericExecutor() async -> Bool {
        true
    }

    /// Uses the event loop itself as the task executor, as `loop as? any TaskExecutor` hands it out, and suspends in
    /// ways that make the runtime enqueue the task on its preferred executor again.
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func _runSuspendingTests(loop: some EventLoop, other: some EventLoop) async throws {
        let executor = try XCTUnwrap(loop as? any TaskExecutor)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(executorPreference: executor) {
                for _ in 0..<100 {
                    loop.assertInEventLoop()
                    withUnsafeCurrentTask { task in
                        XCTAssertEqual(task?.unownedTaskExecutor, executor.asUnownedTaskExecutor())
                    }
                    // Resumed from another thread.
                    try await other.submit {}.get()
                    loop.assertInEventLoop()
                    _ = await Self.switchToGenericExecutor()
                    loop.assertInEventLoop()
                    await Task.yield()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                XCTFail("A task which prefers the event loop as its task executor stopped making progress")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func testSelectableEventLoopItselfAsTaskExecutor() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        var iterator = group.makeIterator()
        let loop1 = iterator.next()!
        let loop2 = iterator.next()!

        try await self._runSuspendingTests(loop: loop1, other: loop2)
        try! await group.shutdownGracefully()
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func testAsyncTestingEventLoopItselfAsTaskExecutor() async throws {
        let loop1 = NIOAsyncTestingEventLoop()
        let loop2 = NIOAsyncTestingEventLoop()

        try await self._runSuspendingTests(loop: loop1, other: loop2)

        await loop1.shutdownGracefully()
        await loop2.shutdownGracefully()
    }

    /// A task which prefers the loop can be resumed by code which runs on the loop, but not in `run()`, like an
    /// `executeInContext` closure. Its job must still run.
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func testAsyncTestingEventLoopRunsJobsEnqueuedOnTheLoop() async throws {
        let loop = NIOAsyncTestingEventLoop()
        let waiter = NIOLockedValueBox<CheckedContinuation<Void, Never>?>(nil)

        let task = Task(executorPreference: loop as any TaskExecutor) {
            await withCheckedContinuation { continuation in
                waiter.withLockedValue { $0 = continuation }
            }
            loop.assertInEventLoop()
        }

        // Wait for the task to suspend, so that resuming it enqueues a job.
        while waiter.withLockedValue({ $0 == nil }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(50))

        try await loop.executeInContext {
            waiter.withLockedValue { $0.take()! }.resume()
        }

        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let finished = await group.next()!
            if !finished {
                // Unstick the task, so that the group can end.
                await loop.run()
            }
            group.cancelAll()
            return finished
        }
        XCTAssertTrue(finished, "The task's job didn't run until the loop was run")

        await loop.shutdownGracefully()
    }
    #endif
}
