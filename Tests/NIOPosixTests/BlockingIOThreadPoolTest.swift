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

import Dispatch
import Foundation
import NIOCore
import NIOPosix
import XCTest

class BlockingIOThreadPoolTest: XCTestCase {
    func testDoubleShutdownWorks() throws {
        let threadPool = NIOThreadPool(numberOfThreads: 17)
        threadPool.start()
        try threadPool.syncShutdownGracefully()
        try threadPool.syncShutdownGracefully()
    }

    func testStateCancelled() throws {
        let threadPool = NIOThreadPool(numberOfThreads: 17)
        let group = DispatchGroup()
        group.enter()
        threadPool.submit { state in
            XCTAssertEqual(NIOThreadPool.WorkItemState.cancelled, state)
            group.leave()
        }
        group.wait()
        try threadPool.syncShutdownGracefully()
    }

    func testStateActive() throws {
        let threadPool = NIOThreadPool(numberOfThreads: 17)
        threadPool.start()
        let group = DispatchGroup()
        group.enter()
        threadPool.submit { state in
            XCTAssertEqual(NIOThreadPool.WorkItemState.active, state)
            group.leave()
        }
        group.wait()
        try threadPool.syncShutdownGracefully()
    }

    func testLoseLastReferenceAndShutdownWhileTaskStillRunning() throws {
        let blockThreadSem = DispatchSemaphore(value: 0)
        let allDoneSem = DispatchSemaphore(value: 0)

        ({
            let threadPool = NIOThreadPool(numberOfThreads: 2)
            threadPool.start()
            threadPool.submit { _ in
                Foundation.Thread.sleep(forTimeInterval: 0.1)
            }
            threadPool.submit { _ in
                blockThreadSem.wait()
            }
            threadPool.shutdownGracefully { error in
                XCTAssertNil(error)
                allDoneSem.signal()
            }
        })()
        blockThreadSem.signal()
        allDoneSem.wait()
    }

    func testDeadLockIfCalledOutWithLockHeld() throws {
        let blockRunningSem = DispatchSemaphore(value: 0)
        let blockOneThreadSem = DispatchSemaphore(value: 0)
        let threadPool = NIOThreadPool(numberOfThreads: 1)
        let allDone = DispatchSemaphore(value: 0)
        threadPool.start()
        // enqueue one that'll block the whole pool (1 thread only)
        threadPool.submit { state in
            XCTAssertEqual(state, .active)
            blockRunningSem.signal()
            blockOneThreadSem.wait()
        }
        blockRunningSem.wait()
        // enqueue one that will be cancelled and then calls shutdown again which needs the lock
        threadPool.submit { state in
            XCTAssertEqual(state, .cancelled)
            threadPool.shutdownGracefully { error in
                XCTAssertNil(error)
            }
        }
        threadPool.shutdownGracefully { error in
            XCTAssertNil(error)
            allDone.signal()
        }
        blockOneThreadSem.signal()  // that'll unblock the thread in the pool
        allDone.wait()
    }

    func testPoolDoesGetReleasedWhenStoppedAndReferencedDropped() throws {
        let taskRunningSem = DispatchSemaphore(value: 0)
        let doneSem = DispatchSemaphore(value: 0)
        let shutdownDoneSem = DispatchSemaphore(value: 0)
        weak var weakThreadPool: NIOThreadPool? = nil
        ({
            let threadPool = NIOThreadPool(numberOfThreads: 1)
            weakThreadPool = threadPool
            threadPool.start()
            threadPool.submit { state in
                XCTAssertEqual(.active, state)
                taskRunningSem.signal()
                doneSem.wait()
            }
            taskRunningSem.wait()
            threadPool.shutdownGracefully { error in
                XCTAssertNil(error)
                shutdownDoneSem.signal()
            }
        })()
        XCTAssertNotNil(weakThreadPool)
        doneSem.signal()
        shutdownDoneSem.wait()
        assert(weakThreadPool == nil, within: .seconds(1))
    }

    final class SomeClass: Sendable {
        init() {}
        func dummy() {}
    }

    func testClosureReferenceDroppedAfterSingleWorkItemExecution() throws {
        let taskRunningSem = DispatchSemaphore(value: 0)
        let doneSem = DispatchSemaphore(value: 0)
        let threadPool = NIOThreadPool(numberOfThreads: 1)
        threadPool.start()
        weak var referencedObject: SomeClass? = nil
        ({
            let object = SomeClass()
            referencedObject = object
            threadPool.submit { state in
                XCTAssertEqual(.active, state)
                taskRunningSem.signal()
                object.dummy()
                doneSem.wait()
            }
        })()
        taskRunningSem.wait()
        doneSem.signal()
        assert(referencedObject == nil, within: .seconds(1))
        try threadPool.syncShutdownGracefully()
    }

    func testClosureReferencesDroppedAfterTwoConsecutiveWorkItemsExecution() throws {
        let taskRunningSem = DispatchSemaphore(value: 0)
        let doneSem = DispatchSemaphore(value: 0)
        let threadPool = NIOThreadPool(numberOfThreads: 1)
        threadPool.start()
        weak var referencedObject1: SomeClass? = nil
        weak var referencedObject2: SomeClass? = nil
        ({
            let object1 = SomeClass()
            let object2 = SomeClass()
            referencedObject1 = object1
            referencedObject2 = object2
            threadPool.submit { state in
                XCTAssertEqual(.active, state)
                taskRunningSem.signal()
                object1.dummy()
                doneSem.wait()
            }
            threadPool.submit { state in
                XCTAssertEqual(.active, state)
                taskRunningSem.signal()
                object2.dummy()
                doneSem.wait()
            }
        })()
        taskRunningSem.wait()
        doneSem.signal()
        taskRunningSem.wait()
        doneSem.signal()
        assert(referencedObject1 == nil, within: .seconds(1))
        assert(referencedObject2 == nil, within: .seconds(1))
        try threadPool.syncShutdownGracefully()
    }
}
