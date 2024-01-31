//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux) || os(Android)
import Atomics
import DequeModule
import Dispatch
import NIOConcurrencyHelpers

@_spi(Testing)
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public final class IOExecutor: Sendable {
    /// Used to generate IDs for work items. Don't use directly,
    /// use ``generateWorkID()`` instead.
    private let workID = ManagedAtomic(UInt64(0))
    /// The workers.
    private let workers: [Worker]

    /// Generates a unique ID for a work item. This is used to identify the work
    /// for cancellation.
    private func generateWorkID() -> UInt64 {
        // We only require uniqueness: relaxed is sufficient.
        return self.workID.loadThenWrappingIncrement(ordering: .relaxed)
    }

    /// Create a running executor with the given number of threads.
    ///
    /// - Precondition: `numberOfThreads` must be greater than zero.
    /// - Returns: a running executor which does work on `numberOfThreads` threads.
    @_spi(Testing)
    public static func running(numberOfThreads: Int) async -> IOExecutor {
        let executor = IOExecutor(numberOfThreads: numberOfThreads)
        await executor.start()
        return executor
    }

    /// Create a running executor with the given number of threads.
    ///
    /// - Precondition: `numberOfThreads` must be greater than zero.
    /// - Returns: a running executor which does work on `numberOfThreads` threads.
    @_spi(Testing)
    public static func runningAsync(numberOfThreads: Int) -> IOExecutor {
        let executor = IOExecutor(numberOfThreads: numberOfThreads)
        Task { await executor.start() }
        return executor
    }

    private init(numberOfThreads: Int) {
        precondition(numberOfThreads > 0, "numberOfThreads must be greater than zero")
        var workers = [Worker]()
        workers.reserveCapacity(numberOfThreads)
        for _ in 0..<numberOfThreads {
            workers.append(Worker())
        }
        self.workers = workers
    }

    private func start() async {
        await withTaskGroup(of: Void.self) { group in
            for (index, worker) in self.workers.enumerated() {
                group.addTask {
                    await worker.start(name: "io-worker-\(index)")
                }
            }
        }
    }

    /// Executes work on a thread owned by the executor and returns its result.
    ///
    /// - Parameter work: A closure to execute.
    /// - Returns: The result of the closure.
    @_spi(Testing)
    public func execute<R: Sendable>(
        _ work: @Sendable @escaping () throws -> R
    ) async throws -> R {
        let workerIndex = self.pickWorker()
        let workID = self.generateWorkID()

        return try await withTaskCancellationHandler {
            return try await withUnsafeThrowingContinuation { continuation in
                self.workers[workerIndex].enqueue(id: workID) { action in
                    switch action {
                    case .run:
                        continuation.resume(with: Result(catching: work))
                    case .cancel:
                        continuation.resume(throwing: CancellationError())
                    case .reject:
                        let error = FileSystemError(
                            code: .unavailable,
                            message: "The executor has been shutdown.",
                            cause: nil,
                            location: .here()
                        )
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.workers[workerIndex].cancel(workID: workID)
        }
    }

    /// Executes work on a thread owned by the executor and notifies a completion
    /// handler with the result.
    ///
    /// - Parameters:
    ///   - work: A closure to execute.
    ///   - onCompletion: A closure to notify with the result of the work.
    @_spi(Testing)
    public func execute<R>(
        work: @Sendable @escaping () throws -> R,
        onCompletion: @Sendable @escaping (Result<R, Error>) -> Void
    ) {
        let workerIndex = self.pickWorker()
        let workID = self.generateWorkID()
        self.workers[workerIndex].enqueue(id: workID) { action in
            switch action {
            case .run:
                onCompletion(Result(catching: work))
            case .cancel:
                onCompletion(.failure(CancellationError()))
            case .reject:
                let error = FileSystemError(
                    code: .unavailable,
                    message: "The executor has been shutdown.",
                    cause: nil,
                    location: .here()
                )
                onCompletion(.failure(error))
            }
        }
    }

    /// Stop accepting new tasks and wait for all enqueued work to finish.
    ///
    /// Any work submitted to the executor whilst it is draining or once it
    /// has finished draining will not be executed.
    @_spi(Testing)
    public func drain() async {
        await withTaskGroup(of: Void.self) { group in
            for worker in self.workers {
                group.addTask {
                    await worker.stop()
                }
            }
        }
    }

    /// Returns the index of the work to submit the next item of work on.
    ///
    /// If there are more than two workers then the "power of two random choices"
    /// approach (https://www.eecs.harvard.edu/~michaelm/postscripts/tpds2001.pdf) is
    /// used whereby two workers are selected at random and the one with the least
    /// amount of work is chosen.
    ///
    /// If there are one or two workers then the one with the least work is
    /// chosen.
    private func pickWorker() -> Int {
        // 'numberOfThreads' is guaranteed to be > 0.
        switch self.workers.count {
        case 1:
            return 0
        case 2:
            return self.indexOfLeastBusyWorkerAtIndices(0, 1)
        default:
            // For more than two threads use the 'power of two random choices'.
            let i = self.workers.indices.randomElement()!
            let j = self.workers.indices.randomElement()!

            if i == j {
                return i
            } else {
                return self.indexOfLeastBusyWorkerAtIndices(i, j)
            }
        }
    }

    private func indexOfLeastBusyWorkerAtIndices(_ i: Int, _ j: Int) -> Int {
        let workOnI = self.workers[i].numberOfQueuedTasks
        let workOnJ = self.workers[j].numberOfQueuedTasks
        return workOnI < workOnJ ? i : j
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension IOExecutor {
    final class Worker: @unchecked Sendable {
        /// An item of work executed by the worker.
        typealias WorkItem = @Sendable (WorkAction) -> Void

        /// Whether the work should be executed or cancelled.
        enum WorkAction {
            case run
            case cancel
            case reject
        }

        /// The state of the worker.
        private enum State {
            case notStarted
            case starting(CheckedContinuation<Void, Never>)
            case active(Thread)
            case draining(CheckedContinuation<Void, Never>)
            case stopped

            mutating func starting(continuation: CheckedContinuation<Void, Never>) {
                switch self {
                case .notStarted:
                    self = .starting(continuation)
                case .active, .starting, .draining, .stopped:
                    fatalError("\(#function) while worker was active/starting/draining/stopped")
                }
            }

            mutating func activate(_ thread: Thread) -> CheckedContinuation<Void, Never> {
                switch self {
                case let .starting(continuation):
                    self = .active(thread)
                    return continuation
                case .notStarted, .active, .draining, .stopped:
                    fatalError("\(#function) while worker was notStarted/active/draining/stopped")
                }
            }

            mutating func drained() -> CheckedContinuation<Void, Never> {
                switch self {
                case let .draining(continuation):
                    self = .stopped
                    return continuation
                case .notStarted, .starting, .active, .stopped:
                    fatalError("\(#function) while worker was notStarted/starting/active/stopped")
                }
            }

            var isStopped: Bool {
                switch self {
                case .stopped:
                    return true
                case .notStarted, .starting, .active, .draining:
                    return true
                }
            }
        }

        private let lock = NIOLock()
        private var state: State
        /// Items of work waiting to be executed and their ID.
        private var workQueue: Deque<(UInt64, WorkItem)>
        /// IDs of work items which have been marked as cancelled but not yet
        /// processed.
        private var cancelledTasks: [UInt64]
        // TODO: make checking for cancellation cheaper by maintaining a heap of cancelled
        // IDs and ensuring work is in order of increasing ID. With that we can check the ID
        // of the popped work item against the top of the heap.

        /// Signalled when an item of work is added to the work queue.
        private let semaphore: DispatchSemaphore
        /// The number of items in the work queue. This is used by the executor to
        /// make decisions on where to enqueue work so relaxed memory ordering is fine.
        private let queuedWork = ManagedAtomic(0)

        internal init() {
            self.state = .notStarted
            self.semaphore = DispatchSemaphore(value: 0)
            self.workQueue = []
            self.cancelledTasks = []
        }

        deinit {
            assert(self.state.isStopped, "The IOExecutor MUST be shutdown before deinit")
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension IOExecutor.Worker {
    func start(name: String) async {
        self.lock.lock()
        await withCheckedContinuation { continuation in
            self.state.starting(continuation: continuation)
            self.lock.unlock()

            Thread.spawnAndRun(name: name, detachThread: false) { thread in
                let continuation = self.lock.withLock { self.state.activate(thread) }
                continuation.resume()
                self.process()
            }
        }
    }

    var numberOfQueuedTasks: Int {
        return self.queuedWork.load(ordering: .relaxed)
    }

    func enqueue(id: UInt64, _ item: @escaping WorkItem) {
        let didEnqueue = self.lock.withLock {
            self._enqueue(id: id, item)
        }

        if didEnqueue {
            self.queuedWork.wrappingIncrement(ordering: .relaxed)
            self.semaphore.signal()
        } else {
            // Draining or stopped.
            item(.reject)
        }
    }

    private func _enqueue(id: UInt64, _ item: @escaping WorkItem) -> Bool {
        switch self.state {
        case .notStarted, .starting, .active:
            self.workQueue.append((id, item))
            return true
        case .draining, .stopped:
            // New work is rejected in these states.
            return false
        }
    }

    func cancel(workID: UInt64) {
        self.lock.withLock {
            // The work will be cancelled when pulled from the work queue. This means
            // there's a delay before the work is actually cancelled; we trade that off
            // against the cost of scanning the work queue for an item to cancel and then
            // removing it which is O(n) (which could be O(n^2) for bulk cancellation).
            self.cancelledTasks.append(workID)
        }
    }

    func stop() async {
        self.lock.lock()
        switch self.state {
        case .notStarted:
            self.state = .stopped
            while let work = self.workQueue.popFirst() {
                work.1(.reject)
            }

        case let .active(thread):
            await withCheckedContinuation { continuation in
                self.state = .draining(continuation)
                self.lock.unlock()

                // Signal the semaphore: 'process()' waits on the semaphore for work so
                // always expects the queue to be non-empty. This is the exception that
                // indicates to 'process()' that it can stop.
                self.semaphore.signal()
            }
            precondition(self.lock.withLock({ self.state.isStopped }))
            // This won't block, we just drained the work queue so 'self.process()' will have
            // returned
            thread.join()

        case .starting, .draining:
            fatalError("Worker is already starting/draining")

        case .stopped:
            self.lock.unlock()
        }
    }

    private func process() {
        enum Instruction {
            case run(WorkItem)
            case cancel(WorkItem)
            case stopWorking(CheckedContinuation<Void, Never>)
        }

        while true {
            // Wait for work to be signalled via the semaphore. It is signalled for every time an
            // item of work is added to the queue. It is signalled an additional time when the worker
            // is shutting down: in that case there is no corresponding work item in the queue so
            // 'popFirst()' will return 'nil'; that's the signal to stop looping.
            self.semaphore.wait()

            let instruction: Instruction = self.lock.withLock {
                switch self.state {
                case let .draining(continuation):
                    if self.workQueue.isEmpty {
                        self.state = .stopped
                        return .stopWorking(continuation)
                    }
                    // There's still work to do: continue as if active.
                    fallthrough

                case .active:
                    let (id, work) = self.workQueue.removeFirst()
                    if let index = self.cancelledTasks.firstIndex(of: id) {
                        self.cancelledTasks.remove(at: index)
                        return .cancel(work)
                    } else {
                        return .run(work)
                    }

                case .notStarted, .starting, .stopped:
                    fatalError("Impossible state")
                }
            }

            switch instruction {
            case let .run(work):
                work(.run)
            case let .cancel(work):
                work(.cancel)
            case let .stopWorking(continuation):
                continuation.resume()
                return
            }
        }
    }
}
#endif
