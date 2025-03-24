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

#if compiler(>=6)

import NIOPosix

/// Run a `NIOThreadPool` based `TaskExecutor` while executing the given `body`.
///
/// This function provides a `TaskExecutor`, **not** a `SerialExecutor`. The executor can be
/// used for setting the executor preference of a task.
///
/// Example usage:
/// ```swift
///     await withNIOThreadPoolTaskExecutor(numberOfThreads: 2) { taskExecutor in
///         await withDiscardingTaskGroup { group in
///             group.addTask(executorPreference: taskExecutor) { ... }
///         }
///     }
/// ```
///
/// - warning: Do not escape the task executor from the closure for later use and make sure that
///            all tasks running on the executor are completely finished before `body` returns.
///            For unstructured tasks, this means awaiting their results. If any task is still
///            running on the executor when `body` returns, this results in a fatalError.
///            It is highly recommended to use structured concurrency with this task executor.
///
/// - Parameters:
///   - numberOfThreads: The number of threads in the pool.
///   - body: The closure that will accept the task executor.
///
/// - Throws: When `body` throws.
///
/// - Returns: The value returned by `body`.
@inlinable
public func withNIOThreadPoolTaskExecutor<T, Failure>(
    numberOfThreads: Int,
    body: (NIOThreadPoolTaskExecutor) async throws(Failure) -> T
) async throws(Failure) -> T {
    let taskExecutor = NIOThreadPoolTaskExecutor(numberOfThreads: numberOfThreads)
    taskExecutor.start()

    let result: Result<T, Failure>
    do {
        result = .success(try await body(taskExecutor))
    } catch {
        result = .failure(error)
    }

    await taskExecutor.shutdownGracefully()

    return try result.get()
}

/// A task executor based on NIOThreadPool.
///
/// Provides a `TaskExecutor`, **not** a `SerialExecutor`. The executor can be
/// used for setting the executor preference of a task.
///
public final class NIOThreadPoolTaskExecutor: TaskExecutor {
    let nioThreadPool: NIOThreadPool

    /// Initialize a `NIOThreadPoolTaskExecutor`, using a thread pool with `numberOfThreads` threads.
    ///
    /// - Parameters:
    ///   - numberOfThreads: The number of threads to use for the thread pool.
    public init(numberOfThreads: Int) {
        self.nioThreadPool = NIOThreadPool(numberOfThreads: numberOfThreads)
    }

    /// Start the `NIOThreadPoolTaskExecutor`.
    public func start() {
        nioThreadPool.start()
    }

    /// Gracefully shutdown this `NIOThreadPoolTaskExecutor`.
    ///
    /// Make sure that all tasks running on the executor are finished before shutting down.
    ///
    /// - warning: If any task is still running on the executor, this results in a fatalError.
    public func shutdownGracefully() async {
        do {
            try await nioThreadPool.shutdownGracefully()
        } catch {
            fatalError("Failed to shutdown NIOThreadPool")
        }
    }

    /// Enqueue a job.
    ///
    /// Called by the concurrency runtime.
    ///
    /// - Parameter job: The job to enqueue.
    public func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        self.nioThreadPool.submit { shouldRun in
            guard case shouldRun = NIOThreadPool.WorkItemState.active else {
                fatalError("Shutdown before all tasks finished")
            }
            unownedJob.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }
}

#endif  // compiler(>=6)
