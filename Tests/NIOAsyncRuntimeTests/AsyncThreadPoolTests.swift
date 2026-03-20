//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2026 Apple Inc. and the SwiftNIO project authors
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
class AsyncThreadPoolTest {
    @Test
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
    func testAsyncThreadPool() async throws {
        let numberOfThreads = 1
        let pool = AsyncThreadPool(numberOfThreads: numberOfThreads)
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
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
    func testAsyncThreadPoolErrorPropagation() async throws {
        struct ThreadPoolError: Error {}
        let numberOfThreads = 1
        let pool = AsyncThreadPool(numberOfThreads: numberOfThreads)
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
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
    func testAsyncThreadPoolNotActiveError() async throws {
        struct ThreadPoolError: Error {}
        let numberOfThreads = 1
        let pool = AsyncThreadPool(numberOfThreads: numberOfThreads)
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
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
    func testAsyncThreadPoolCancellation() async throws {
        let pool = AsyncThreadPool(numberOfThreads: 1)
        pool.start()

        await withThrowingTaskGroup(of: Void.self) { group in
            group.cancelAll()
            group.addTask {
                try await pool.runIfActive {
                    _ = Issue.record("Should be cancelled before executed")
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
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
    func testAsyncShutdownWorks() async throws {
        let threadPool = AsyncThreadPool(numberOfThreads: 17)
        let eventLoop = AsyncEventLoop(__testOnly_manualTimeMode: true)

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
