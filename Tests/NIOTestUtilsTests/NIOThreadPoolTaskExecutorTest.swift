//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import NIOTestUtils
import XCTest

class NIOThreadPoolTaskExecutorTest: XCTestCase {
    struct TestError: Error {}

    func runTasksSimultaneously(numberOfTasks: Int) async {
        await withNIOThreadPoolTaskExecutor(numberOfThreads: numberOfTasks) { taskExecutor in
            await withDiscardingTaskGroup { group in
                var taskBlockers = [ConditionLock<Bool>]()
                defer {
                    // Unblock all tasks
                    for taskBlocker in taskBlockers {
                        taskBlocker.lock()
                        taskBlocker.unlock(withValue: true)
                    }
                }

                for taskNumber in 1...numberOfTasks {
                    let taskStarted = ConditionLock(value: false)
                    let taskBlocker = ConditionLock(value: false)
                    taskBlockers.append(taskBlocker)

                    // Start task and block it
                    group.addTask(executorPreference: taskExecutor) {
                        taskStarted.lock()
                        taskStarted.unlock(withValue: true)
                        taskBlocker.lock(whenValue: true)
                        taskBlocker.unlock()
                    }

                    // Verify that task was able to start
                    if taskStarted.lock(whenValue: true, timeoutSeconds: 5) {
                        taskStarted.unlock()
                    } else {
                        XCTFail("Task \(taskNumber) failed to start.")
                        break
                    }
                }
            }
        }
    }

    func testRunsTaskOnSingleThread() async {
        await runTasksSimultaneously(numberOfTasks: 1)
    }

    func testRunsMultipleTasksOnMultipleThreads() async {
        await runTasksSimultaneously(numberOfTasks: 3)
    }

    func testReturnsBodyResult() async {
        let expectedResult = "result"
        let result = await withNIOThreadPoolTaskExecutor(numberOfThreads: 1) { _ in return expectedResult }
        XCTAssertEqual(result, expectedResult)
    }

    func testRethrows() async {
        do {
            try await withNIOThreadPoolTaskExecutor(numberOfThreads: 1) { _ in throw TestError() }
            XCTFail("Function did not rethrow.")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }
}
