//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOTestUtils
import Synchronization
import XCTest

class ManualTaskExecutorTest: XCTestCase {
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func testManualTaskExecutor() async {
        await withDiscardingTaskGroup { group in
            await withManualTaskExecutor { taskExecutor in
                let taskDidRun = Mutex(false)

                group.addTask(executorPreference: taskExecutor) {
                    taskDidRun.withLock { $0 = true }
                }

                // Run task
                XCTAssertFalse(taskDidRun.withLock { $0 })
                taskExecutor.runUntilQueueIsEmpty()
                XCTAssertTrue(taskDidRun.withLock { $0 })
            }
        }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func testTwoManualTaskExecutors() async {
        await withDiscardingTaskGroup { group in
            await withManualTaskExecutors { taskExecutor1, taskExecutor2 in
                let task1DidRun = Mutex(false)
                let task2DidRun = Mutex(false)

                group.addTask(executorPreference: taskExecutor1) {
                    task1DidRun.withLock { $0 = true }
                }

                group.addTask(executorPreference: taskExecutor2) {
                    task2DidRun.withLock { $0 = true }
                }

                // Run task 1
                XCTAssertFalse(task1DidRun.withLock { $0 })
                taskExecutor1.runUntilQueueIsEmpty()
                XCTAssertTrue(task1DidRun.withLock { $0 })

                // Run task 2
                XCTAssertFalse(task2DidRun.withLock { $0 })
                taskExecutor2.runUntilQueueIsEmpty()
                XCTAssertTrue(task2DidRun.withLock { $0 })
            }
        }
    }
}
