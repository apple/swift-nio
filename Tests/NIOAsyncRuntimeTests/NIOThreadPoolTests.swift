//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2024 Apple Inc. and the SwiftNIO project authors
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
import NIOCore
import Testing

@testable import NIOAsyncRuntime

@Suite("NIOThreadPoolTest", .timeLimit(.minutes(1)))
class NIOThreadPoolTest {
    private func makeEventLoop() -> AsyncEventLoop {
        AsyncEventLoop(manualTimeModeForTesting: true)
    }

    @Test
    func testThreadPoolStartsMultipleTimes() async throws {
        let numberOfThreads = 1
        let pool = NIOThreadPool(numberOfThreads: numberOfThreads)
        pool.start()

        await withTaskGroup(of: Void.self) { group in
            // The lock here is arguably redundant with the dispatchgroup, but let's make
            // this test thread-safe even something goes wrong
            let threadOne: NIOLockedValueBox<UInt?> = NIOLockedValueBox(UInt?.none)
            let threadTwo: NIOLockedValueBox<UInt?> = NIOLockedValueBox(UInt?.none)

            let expectedValue: UInt = 1

            group.addTask {
                await withCheckedContinuation { continuation in
                    pool.submit { s in
                        precondition(s == .active)
                        threadOne.withLockedValue { threadOne in
                            #expect(threadOne == nil)
                            threadOne = expectedValue
                        }
                        continuation.resume()
                    }
                }
            }

            // Now start the thread pool again. This must not destroy existing threads, so our thread should be the same.
            pool.start()
            group.addTask {
                await withCheckedContinuation { continuation in
                    pool.submit { s in
                        precondition(s == .active)
                        threadTwo.withLockedValue { threadTwo in
                            #expect(threadTwo == nil)
                            threadTwo = expectedValue
                        }
                        continuation.resume()
                    }
                }
            }

            await group.waitForAll()

            #expect(threadOne.withLockedValue { $0 } != nil)
            #expect(threadTwo.withLockedValue { $0 } != nil)
            #expect(threadOne.withLockedValue { $0 } == threadTwo.withLockedValue { $0 })
        }

        await #expect(throws: Never.self) { try await pool.shutdownGracefully() }
    }

    @Test
    func testAsyncThreadPool() async throws {
        let numberOfThreads = 1
        let pool = NIOThreadPool(numberOfThreads: numberOfThreads)
        pool.start()
        do {
            let hitCount = ManagedAtomic(false)
            try await pool.runIfActive {
                hitCount.store(true, ordering: .relaxed)
            }
            #expect(hitCount.load(ordering: .relaxed) == true)
        } catch {}
        try await pool.shutdownGracefully()
    }

    @Test
    func testAsyncThreadPoolErrorPropagation() async throws {
        struct ThreadPoolError: Error {}
        let numberOfThreads = 1
        let pool = NIOThreadPool(numberOfThreads: numberOfThreads)
        pool.start()
        do {
            try await pool.runIfActive {
                throw ThreadPoolError()
            }
            Issue.record("Should not get here as closure sent to runIfActive threw an error")
        } catch {
            #expect(error as? ThreadPoolError != nil, "Error thrown should be of type ThreadPoolError")
        }
        try await pool.shutdownGracefully()
    }

    @Test
    func testAsyncThreadPoolNotActiveError() async throws {
        struct ThreadPoolError: Error {}
        let numberOfThreads = 1
        let pool = NIOThreadPool(numberOfThreads: numberOfThreads)
        do {
            try await pool.runIfActive {
                throw ThreadPoolError()
            }
            Issue.record("Should not get here as thread pool isn't active")
        } catch {
            #expect(
                error as? CancellationError != nil,
                "Error thrown should be of type CancellationError"
            )
        }
        try await pool.shutdownGracefully()
    }

    @Test
    func testAsyncThreadPoolCancellation() async throws {
        let pool = NIOThreadPool(numberOfThreads: 1)
        pool.start()

        await withThrowingTaskGroup(of: Issue.self) { group in
            group.cancelAll()
            group.addTask {
                try await pool.runIfActive {
                    Issue.record("Should be cancelled before executed")
                }
            }

            do {
                try await group.waitForAll()
                Issue.record("Expected CancellationError to be thrown")
            } catch {
                #expect(error is CancellationError)
            }
        }

        try await pool.shutdownGracefully()
    }

    @Test
    func testAsyncShutdownWorks() async throws {
        let threadPool = NIOThreadPool(numberOfThreads: 17)
        let eventLoop = makeEventLoop()

        threadPool.start()
        try await threadPool.shutdownGracefully()

        let future: EventLoopFuture = threadPool.runIfActive(eventLoop: eventLoop) {
            Issue.record("This shouldn't run because the pool is shutdown.")
        }

        await #expect(throws: (any Error).self) {
            try await future.get()
        }

    }
}
