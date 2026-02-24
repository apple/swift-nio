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

import DequeModule
import Synchronization

/// Provide a `ManualTaskExecutor` for the duration of the given `body`.
///
/// The executor can be used for setting the executor preference of tasks and fully control
/// when execution of the tasks is performed.
///
/// Example usage:
/// ```swift
///     await withDiscardingTaskGroup { group in
///         await withManualTaskExecutor { taskExecutor in
///             group.addTask(executorPreference: taskExecutor) {
///                 print("Running")
///             }
///             taskExecutor.runUntilQueueIsEmpty()  // Run the task synchronously
///         }
///     }
/// ```
///
/// - warning: Do not escape the task executor from the closure for later use and make sure that
///            all tasks running on the executor are completely finished before `body` returns.
///            It is highly recommended to use structured concurrency with this task executor.
///
/// - Parameters:
///   - body: The closure that will accept the task executor.
///
/// - Throws: When `body` throws.
///
/// - Returns: The value returned by `body`.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
@inlinable
package func withManualTaskExecutor<T, Failure>(
    body: (ManualTaskExecutor) async throws(Failure) -> T
) async throws(Failure) -> T {
    let taskExecutor = ManualTaskExecutor()
    defer { taskExecutor.shutdown() }
    return try await body(taskExecutor)
}

/// Provide two `ManualTaskExecutor`s for the duration of the given `body`.
///
/// The executors can be used for setting the executor preference of tasks and fully control
/// when execution of the tasks is performed.
///
/// Example usage:
/// ```swift
///     await withDiscardingTaskGroup { group in
///         await withManualTaskExecutor { taskExecutor1, taskExecutor2 in
///             group.addTask(executorPreference: taskExecutor1) {
///                 print("Running 1")
///             }
///             group.addTask(executorPreference: taskExecutor2) {
///                 print("Running 2")
///             }
///             taskExecutor2.runUntilQueueIsEmpty()  // Run second task synchronously
///             taskExecutor1.runUntilQueueIsEmpty()  // Run first task synchronously
///         }
///     }
/// ```
///
/// - warning: Do not escape the task executors from the closure for later use and make sure that
///            all tasks running on the executors are completely finished before `body` returns.
///            It is highly recommended to use structured concurrency with these task executors.
///
/// - Parameters:
///   - body: The closure that will accept the task executors.
///
/// - Throws: When `body` throws.
///
/// - Returns: The value returned by `body`.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
@inlinable
package func withManualTaskExecutors<T, Failure>(
    body: (ManualTaskExecutor, ManualTaskExecutor) async throws(Failure) -> T
) async throws(Failure) -> T {
    let taskExecutor1 = ManualTaskExecutor()
    defer { taskExecutor1.shutdown() }

    let taskExecutor2 = ManualTaskExecutor()
    defer { taskExecutor2.shutdown() }

    return try await body(taskExecutor1, taskExecutor2)
}

/// Manual task executor.
///
/// A `TaskExecutor` that does not use any threadpool or similar mechanism to run the jobs.
/// Jobs are manually run by calling the `runUntilQueueIsEmpty` method.
///
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
@usableFromInline
package final class ManualTaskExecutor: TaskExecutor {
    struct Storage {
        var isShutdown = false
        var jobs = Deque<UnownedJob>()
    }

    private let storage = Mutex<Storage>(.init())

    @usableFromInline
    init() {}

    /// Run jobs until queue is empty.
    ///
    /// Synchronously runs all enqueued jobs, including any jobs that are enqueued while running.
    /// When this function returns, it means that each task running on this executor is either:
    /// - suspended
    /// - moved (temporarily) to a different executor
    /// - finished
    ///
    /// If not all tasks are finished, this function must be called again.
    package func runUntilQueueIsEmpty() {
        while let job = self.storage.withLock({ $0.jobs.popFirst() }) {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }

    /// Enqueue a job.
    ///
    /// Called by the concurrency runtime.
    ///
    /// - Parameter job: The job to enqueue.
    @usableFromInline
    package func enqueue(_ job: UnownedJob) {
        self.storage.withLock { storage in
            if storage.isShutdown {
                fatalError("A job is enqueued after manual executor shutdown")
            }
            storage.jobs.append(job)
        }
    }

    /// Shutdown.
    ///
    /// Since the manual task executor is not running anything in the background, this is purely to catch
    /// any issues due to incorrect usage of the executor. The shutdown verifies that the queue is empty
    /// and makes sure that no new jobs can be enqueued.
    @usableFromInline
    func shutdown() {
        self.storage.withLock { storage in
            if !storage.jobs.isEmpty {
                fatalError("Shutdown of manual executor with jobs in queue")
            }
            storage.isShutdown = true
        }
    }
}
