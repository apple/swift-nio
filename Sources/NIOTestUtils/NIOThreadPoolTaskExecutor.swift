#if compiler(>=6)

import NIOPosix

/// Run a `NIOThreadPool` based `TaskExecutor` while executing the given `body`.
///
/// Example usage:
/// ```swift
///     await withNIOThreadPoolTaskExecutor(numberOfThreads: 1) { taskExecutor in
///         Task(executorPreference: taskExecutor) { ... }
///     }
/// ```
///
/// - warning: Do not escape the task executor from the closure for later use.
///            This function does not return until the task executor is deinitialized.
///            Any task using the executor will keep the executor alive. In other words, this
///            function will not return until all tasks running on the executor are finished.
///
/// - warning: In case of cancellation, this function will wait for all tasks running on the
///            executor to finish. Note that cancellation does not propagate to unstructured tasks.
///
/// - Parameters:
///   - numberOfThreads: The number of threads in the pool.
///   - body: The closure that will accept the task executor.
///
/// - Throws: When `body` throws.
///
/// - Returns: The value returned by `body`.
///
public func withNIOThreadPoolTaskExecutor<T, Failure>(
    numberOfThreads: Int,
    body: (any TaskExecutor) async throws(Failure) -> T
) async throws(Failure) -> T {
    let nioThreadPool = NIOThreadPool(numberOfThreads: numberOfThreads)
    nioThreadPool.start()

    // Use AsyncStream as an easy way to wait for the deinit of the task executor.
    let (deinitStream, deinitContinuation) = AsyncStream.makeStream(of: Void.self)
    var deinitStreamIterator = deinitStream.makeAsyncIterator()

    let result: Result<T, Failure>
    do {
        let taskExecutor = NIOThreadPoolTaskExecutor(nioThreadPool, deinitContinuation)
        result = .success(try await body(taskExecutor))
    } catch {
        result = .failure(error)
    }

    // Cancellation shield
    await Task {
        // Wait for task executor to deinitialize. This makes sure all tasks are finished.
        // Our own reference to taskExecutor must be dropped by now in order to not keep it alive.
        await deinitStreamIterator.next()
        do {
            try await nioThreadPool.shutdownGracefully()
        } catch {
            fatalError("Failed to shutdown NIOThreadPool")
        }
    }.value

    return try result.get()
}

final class NIOThreadPoolTaskExecutor: TaskExecutor {
    let nioThreadPool: NIOThreadPool
    let deinitContinuation: AsyncStream<Void>.Continuation

    init(
        _ nioThreadPool: NIOThreadPool,
        _ deinitContinuation: AsyncStream<Void>.Continuation
    ) {
        self.nioThreadPool = nioThreadPool
        self.deinitContinuation = deinitContinuation
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        self.nioThreadPool.submit { shouldRun in
            guard case shouldRun = NIOThreadPool.WorkItemState.active else {
                // Should never happen. We keep the thread pool running until self is deinitialized.
                fatalError("Thread pool stopped unexpectedly")
            }
            unownedJob.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }

    deinit {
        self.deinitContinuation.finish()
    }
}

#endif  // compiler(>=6)
