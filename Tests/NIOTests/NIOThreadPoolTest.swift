//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
@testable import NIO
import Dispatch
import NIOConcurrencyHelpers

class NIOThreadPoolTest: XCTestCase {
    func testThreadNamesAreSetUp() {
        let numberOfThreads = 11
        let pool = NIOThreadPool(numberOfThreads: numberOfThreads)
        pool.start()
        defer {
            XCTAssertNoThrow(try pool.syncShutdownGracefully())
        }

        var allThreadNames: Set<String> = []
        let lock = Lock()
        let threadNameCollectionSem = DispatchSemaphore(value: 0)
        let threadBlockingSem = DispatchSemaphore(value: 0)

        // let's use up all the threads
        for i in (0..<numberOfThreads) {
            pool.submit { s in
                switch s {
                case .cancelled:
                    XCTFail("work item \(i) cancelled")
                case .active:
                    lock.withLock {
                        allThreadNames.formUnion([NIOThread.current.currentName ?? "n/a"])
                    }
                    threadNameCollectionSem.signal()
                }
                threadBlockingSem.wait()
            }
        }

        // now, let's wait for all the threads to have done their work
        (0..<numberOfThreads).forEach { _ in
            threadNameCollectionSem.wait()
        }
        // and finally, let them exit
        (0..<numberOfThreads).forEach { _ in
            threadBlockingSem.signal()
        }

        let localAllThreads = lock.withLock { allThreadNames }
        for threadNumber in (0..<numberOfThreads) {
            XCTAssert(localAllThreads.contains("TP-#\(threadNumber)"), "\(localAllThreads)")
        }
    }
}
