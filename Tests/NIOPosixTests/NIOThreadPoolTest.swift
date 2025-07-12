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
import NIOEmbedded
import XCTest

@testable import NIOPosix

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
class NIOThreadPoolTest: XCTestCase {
    func testThreadNamesAreSetUp() {
        let numberOfThreads = 11
        let pool = NIOThreadPool(numberOfThreads: numberOfThreads)
        pool.start()
        defer {
            XCTAssertNoThrow(try pool.syncShutdownGracefully())
        }

        let allThreadNames = NIOLockedValueBox<Set<String>>([])
        let threadNameCollectionSem = DispatchSemaphore(value: 0)
        let threadBlockingSem = DispatchSemaphore(value: 0)

        // let's use up all the threads
        for i in (0..<numberOfThreads) {
            pool.submit { s in
                switch s {
                case .cancelled:
                    XCTFail("work item \(i) cancelled")
                case .active:
                    allThreadNames.withLockedValue {
                        $0.formUnion([NIOThread.currentThreadName ?? "n/a"])
                    }
                    threadNameCollectionSem.signal()
                }
                threadBlockingSem.wait()
            }
        }

        // now, let's wait for all the threads to have done their work
        for _ in (0..<numberOfThreads) {
            threadNameCollectionSem.wait()
        }
        // and finally, let them exit
        for _ in (0..<numberOfThreads) {
            threadBlockingSem.signal()
        }

        let localAllThreads = allThreadNames.withLockedValue { $0 }
        for threadNumber in (0..<numberOfThreads) {
            XCTAssert(localAllThreads.contains("TP-#\(threadNumber)"), "\(localAllThreads)")
        }
    }

    func testThreadPoolStartsMultipleTimes() throws {
        let numberOfThreads = 1
        let pool = NIOThreadPool(numberOfThreads: numberOfThreads)
        pool.start()
        defer {
            XCTAssertNoThrow(try pool.syncShutdownGracefully())
        }

        let completionGroup = DispatchGroup()

        // The lock here is arguably redundant with the dispatchgroup, but let's make
        // this test thread-safe even if I screw up.
        let threadOne: NIOLockedValueBox<UInt?> = NIOLockedValueBox(UInt?.none)
        let threadTwo: NIOLockedValueBox<UInt?> = NIOLockedValueBox(UInt?.none)

        completionGroup.enter()
        pool.submit { s in
            precondition(s == .active)
            threadOne.withLockedValue { threadOne in
                XCTAssertNil(threadOne)
                threadOne = NIOThread.currentThreadID
            }
            completionGroup.leave()
        }

        // Now start the thread pool again. This must not destroy existing threads, so our thread should be the same.
        pool.start()
        completionGroup.enter()
        pool.submit { s in
            precondition(s == .active)
            threadTwo.withLockedValue { threadTwo in
                XCTAssertNil(threadTwo)
                threadTwo = NIOThread.currentThreadID
            }
            completionGroup.leave()
        }

        completionGroup.wait()

        XCTAssertNotNil(threadOne.withLockedValue { $0 })
        XCTAssertNotNil(threadTwo.withLockedValue { $0 })
        XCTAssert(threadOne.withLockedValue { $0 } == threadTwo.withLockedValue { $0 })
    }

    func testAsyncThreadPool() async throws {
        let numberOfThreads = 1
        let pool = NIOThreadPool(numberOfThreads: numberOfThreads)
        pool.start()
        do {
            let hitCount = ManagedAtomic(false)
            try await pool.runIfActive {
                hitCount.store(true, ordering: .relaxed)
            }
            XCTAssertEqual(hitCount.load(ordering: .relaxed), true)
        } catch {}
        try await pool.shutdownGracefully()
    }

    func testAsyncThreadPoolErrorPropagation() async throws {
        struct ThreadPoolError: Error {}
        let numberOfThreads = 1
        let pool = NIOThreadPool(numberOfThreads: numberOfThreads)
        pool.start()
        do {
            try await pool.runIfActive {
                throw ThreadPoolError()
            }
            XCTFail("Should not get here as closure sent to runIfActive threw an error")
        } catch {
            XCTAssertNotNil(error as? ThreadPoolError, "Error thrown should be of type ThreadPoolError")
        }
        try await pool.shutdownGracefully()
    }

    func testAsyncThreadPoolNotActiveError() async throws {
        struct ThreadPoolError: Error {}
        let numberOfThreads = 1
        let pool = NIOThreadPool(numberOfThreads: numberOfThreads)
        do {
            try await pool.runIfActive {
                throw ThreadPoolError()
            }
            XCTFail("Should not get here as thread pool isn't active")
        } catch {
            XCTAssertNotNil(error as? CancellationError, "Error thrown should be of type CancellationError")
        }
        try await pool.shutdownGracefully()
    }

    func testAsyncThreadPoolCancellation() async throws {
        let pool = NIOThreadPool(numberOfThreads: 1)
        pool.start()

        await withThrowingTaskGroup(of: Void.self) { group in
            group.cancelAll()
            group.addTask {
                try await pool.runIfActive {
                    XCTFail("Should be cancelled before executed")
                }
            }

            do {
                try await group.waitForAll()
                XCTFail("Expected CancellationError to be thrown")
            } catch {
                XCTAssert(error is CancellationError)
            }
        }

        try await pool.shutdownGracefully()
    }

    func testAsyncShutdownWorks() async throws {
        let threadPool = NIOThreadPool(numberOfThreads: 17)
        let eventLoop = NIOAsyncTestingEventLoop()

        threadPool.start()
        try await threadPool.shutdownGracefully()

        let future = threadPool.runIfActive(eventLoop: eventLoop) {
            XCTFail("This shouldn't run because the pool is shutdown.")
        }
        await XCTAssertThrowsError { try await future.get() }
    }
}
