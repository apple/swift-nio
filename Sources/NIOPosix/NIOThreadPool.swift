//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import DequeModule
import NIOConcurrencyHelpers
import NIOCore

#if canImport(Dispatch)
import Dispatch
#endif

/// Errors that may be thrown when executing work on a `NIOThreadPool`
public enum NIOThreadPoolError: Sendable {

    /// The `NIOThreadPool` was not active.
    public struct ThreadPoolInactive: Error {
        public init() {}
    }

    /// The `NIOThreadPool` operation is unsupported (e.g. shutdown of a perpetual pool).
    public struct UnsupportedOperation: Error {
        public init() {}
    }
}

/// A thread pool that should be used if some (kernel thread) blocking work
/// needs to be performed for which no non-blocking API exists.
///
/// When using NIO it is crucial not to block any of the `EventLoop`s as that
/// leads to slow downs or stalls of arbitrary other work. Unfortunately though
/// there are tasks that applications need to achieve for which no non-blocking
/// APIs exist. In those cases `NIOThreadPool` can be used but should be
/// treated as a last resort.
///
/// - Note: The prime example for missing non-blocking APIs is file IO on UNIX.
///   The OS does not provide a usable and truly non-blocking API but with
///   `NonBlockingFileIO` NIO provides a high-level API for file IO that should
///   be preferred to running blocking file IO system calls directly on
///   `NIOThreadPool`. Under the covers `NonBlockingFileIO` will use
///   `NIOThreadPool` on all currently supported platforms though.
public final class NIOThreadPool {

    /// The state of the `WorkItem`.
    public enum WorkItemState: Sendable {
        /// The `WorkItem` is active now and in process by the `NIOThreadPool`.
        case active
        /// The `WorkItem` was cancelled and will not be processed by the `NIOThreadPool`.
        case cancelled
    }

    /// The work that should be done by the `NIOThreadPool`.
    public typealias WorkItem = @Sendable (WorkItemState) -> Void

    @usableFromInline
    struct IdentifiableWorkItem: Sendable {
        @usableFromInline
        var workItem: WorkItem

        @usableFromInline
        var id: Int?
    }

    @usableFromInline
    internal enum State: Sendable {
        /// The `NIOThreadPool` is already stopped.
        case stopped
        /// The `NIOThreadPool` is shutting down, the array has one boolean entry for each thread indicating if it has shut down already.
        case shuttingDown([Bool])
        /// The `NIOThreadPool` is up and running, the `Deque` containing the yet unprocessed `IdentifiableWorkItem`s.
        case running(Deque<IdentifiableWorkItem>)
        /// Temporary state used when mutating the .running(items). Used to avoid CoW copies.
        /// It should never be "leaked" outside of the lock block.
        case modifying
    }

    /// Whether threads in the pool have work.
    @usableFromInline
    internal enum _WorkState: Hashable, Sendable {
        case hasWork
        case hasNoWork
    }

    // The condition lock is used in place of a lock and a semaphore to avoid warnings from the
    // thread performance checker.
    //
    // Only the worker threads wait for the condition lock to take a value, no other threads need
    // to wait for a given value. The value indicates whether the thread has some work to do. Work
    // in this case can be either processing a work item or exiting the threads processing
    // loop (i.e. shutting down).
    @usableFromInline
    internal let _conditionLock: ConditionLock<_WorkState>
    private var threads: [NIOThread]? = nil  // protected by `conditionLock`
    @usableFromInline
    internal var _state: State = .stopped

    // WorkItems don't have a handle so they can't be cancelled directly. Instead an ID is assigned
    // to each cancellable work item and the IDs of each work item to cancel is stored in this set.
    // The set is checked when dequeuing work items prior to running them, the presence of an ID
    // indicates it should be cancelled. This approach makes cancellation cheap, but slow, as the
    // task isn't cancelled until it's dequeued.
    //
    // Possible alternatives:
    // - Removing items from the work queue on cancellation. This is linear and runs the risk of
    //   being expensive if a task tree with many enqueued work items is cancelled.
    // - Storing an atomic 'is cancelled' flag with each work item. This adds an allocation per
    //   work item.
    //
    // If a future version of this thread pool has work items which do have a handle this set should
    // be removed.
    //
    // Note: protected by 'lock'.
    @usableFromInline
    internal var _cancelledWorkIDs: Set<Int> = []
    private let nextWorkID = ManagedAtomic(0)

    public let numberOfThreads: Int
    private let canBeStopped: Bool

    /// Gracefully shutdown this `NIOThreadPool`. All tasks will be run before shutdown will take place.
    ///
    /// - Parameters:
    ///   - queue: The `DispatchQueue` used to executed the callback
    ///   - callback: The function to be executed once the shutdown is complete.
    @preconcurrency
    public func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping @Sendable (Error?) -> Void) {
        self._shutdownGracefully(queue: queue, callback)
    }

    private func _shutdownGracefully(queue: DispatchQueue, _ callback: @escaping @Sendable (Error?) -> Void) {
        guard self.canBeStopped else {
            queue.async {
                callback(NIOThreadPoolError.UnsupportedOperation())
            }
            return
        }

        let threadsToJoin = self._conditionLock.withLock {
            switch self._state {
            case .running(let items):
                self._state = .modifying
                queue.async {
                    for item in items {
                        item.workItem(.cancelled)
                    }
                }
                self._state = .shuttingDown(Array(repeating: true, count: self.numberOfThreads))

                let threads = self.threads!
                self.threads = nil

                // Each thread has work to do: shutdown.
                return (unlockWith: .hasWork, result: threads)

            case .shuttingDown, .stopped:
                return (unlockWith: nil, result: [])

            case .modifying:
                fatalError(".modifying state misuse")
            }
        }

        DispatchQueue(label: "io.swiftnio.NIOThreadPool.shutdownGracefully").async {
            for thread in threadsToJoin {
                thread.join()
            }
            queue.async {
                callback(nil)
            }
        }
    }

    /// Submit a `WorkItem` to process.
    ///
    /// - Note: This is a low-level method, in most cases the `runIfActive` method should be used.
    ///
    /// - Parameters:
    ///   - body: The `WorkItem` to process by the `NIOThreadPool`.
    @preconcurrency
    public func submit(_ body: @escaping WorkItem) {
        self._submit(id: nil, body)
    }

    private func _submit(id: Int?, _ body: @escaping WorkItem) {
        let submitted = self._conditionLock.withLock {
            let workState: _WorkState
            let submitted: Bool

            switch self._state {
            case .running(var items):
                self._state = .modifying
                items.append(.init(workItem: body, id: id))
                self._state = .running(items)
                workState = items.isEmpty ? .hasNoWork : .hasWork
                submitted = true

            case .shuttingDown, .stopped:
                workState = .hasNoWork
                submitted = false

            case .modifying:
                fatalError(".modifying state misuse")
            }

            return (unlockWith: workState, result: submitted)
        }

        // if item couldn't be added run it immediately indicating that it couldn't be run
        if !submitted {
            body(.cancelled)
        }
    }

    /// Initialize a `NIOThreadPool` thread pool with `numberOfThreads` threads.
    ///
    /// - Parameters:
    ///   - numberOfThreads: The number of threads to use for the thread pool.
    public convenience init(numberOfThreads: Int) {
        self.init(numberOfThreads: numberOfThreads, canBeStopped: true)
    }

    /// Create a ``NIOThreadPool`` that is already started, cannot be shut down and must not be `deinit`ed.
    ///
    /// This is only useful for global singletons.
    public static func _makePerpetualStartedPool(numberOfThreads: Int, threadNamePrefix: String) -> NIOThreadPool {
        let pool = self.init(numberOfThreads: numberOfThreads, canBeStopped: false)
        pool._start(threadNamePrefix: threadNamePrefix)
        return pool
    }

    private init(numberOfThreads: Int, canBeStopped: Bool) {
        self.numberOfThreads = numberOfThreads
        self.canBeStopped = canBeStopped
        self._conditionLock = ConditionLock(value: .hasNoWork)
    }

    // Do not rename or remove this function.
    //
    // When doing on-/off-CPU analysis, for example with continuous profiling, it's
    // important to recognise certain functions that are purely there to wait.
    //
    // This function is one of those and giving it a consistent name makes it much easier to remove from the profiles
    // when only interested in on-CPU work.
    @inlinable
    internal func _blockingWaitForWork(identifier: Int) -> (item: WorkItem, state: WorkItemState)? {
        self._conditionLock.withLock(when: .hasWork) {
            () -> (unlockWith: _WorkState, result: (WorkItem, WorkItemState)?) in
            let workState: _WorkState
            let result: (WorkItem, WorkItemState)?

            switch self._state {
            case .running(var items):
                self._state = .modifying
                let itemAndID = items.removeFirst()

                let state: WorkItemState
                if let id = itemAndID.id, !self._cancelledWorkIDs.isEmpty {
                    state = self._cancelledWorkIDs.remove(id) == nil ? .active : .cancelled
                } else {
                    state = .active
                }

                self._state = .running(items)

                workState = items.isEmpty ? .hasNoWork : .hasWork
                result = (itemAndID.workItem, state)

            case .shuttingDown(var aliveStates):
                self._state = .modifying
                assert(aliveStates[identifier])
                aliveStates[identifier] = false
                self._state = .shuttingDown(aliveStates)

                // Unlock with '.hasWork' to resume any other threads waiting to shutdown.
                workState = .hasWork
                result = nil

            case .stopped:
                // Unreachable: 'stopped' is the initial state which is left when starting the
                // thread pool, and before any thread calls this function.
                fatalError("Invalid state")

            case .modifying:
                fatalError(".modifying state misuse")
            }

            return (unlockWith: workState, result: result)
        }
    }

    private func process(identifier: Int) {
        repeat {
            let itemAndState = self._blockingWaitForWork(identifier: identifier)

            if let (item, state) = itemAndState {
                // if there was a work item popped, run it
                item(state)
            } else {
                break  // Otherwise, we're done
            }
        } while true
    }

    /// Start the `NIOThreadPool` if not already started.
    public func start() {
        self._start(threadNamePrefix: "TP-#")
    }

    public func _start(threadNamePrefix: String) {
        let alreadyRunning = self._conditionLock.withLock {
            switch self._state {
            case .running:
                // Already running, this has no effect on whether there is more work for the
                // threads to run.
                return (unlockWith: nil, result: true)

            case .shuttingDown:
                // This should never happen
                fatalError("start() called while in shuttingDown")

            case .stopped:
                self._state = .running(Deque(minimumCapacity: 16))
                assert(self.threads == nil)
                self.threads = []
                self.threads!.reserveCapacity(self.numberOfThreads)
                return (unlockWith: .hasNoWork, result: false)

            case .modifying:
                fatalError(".modifying state misuse")
            }
        }

        if alreadyRunning {
            return
        }

        // We use this condition lock as a tricky kind of semaphore.
        // This is done to sidestep the thread performance checker warning
        // that would otherwise be emitted.
        let readyThreads = ConditionLock(value: 0)
        for id in 0..<self.numberOfThreads {
            // We should keep thread names under 16 characters because Linux doesn't allow more.
            NIOThread.spawnAndRun(name: "\(threadNamePrefix)\(id)") { thread in
                readyThreads.withLock {
                    let threadCount = self._conditionLock.withLock {
                        self.threads!.append(thread)
                        let workState: _WorkState

                        switch self._state {
                        case .running(let items):
                            workState = items.isEmpty ? .hasNoWork : .hasWork
                        case .shuttingDown:
                            // The thread has work to do: it's shutting down.
                            workState = .hasWork
                        case .stopped:
                            // Unreachable: .stopped always transitions to .running in the function
                            // and .stopped is never entered again.
                            fatalError("Invalid state")
                        case .modifying:
                            fatalError(".modifying state misuse")
                        }

                        let threadCount = self.threads!.count
                        return (unlockWith: workState, result: threadCount)
                    }

                    return (unlockWith: threadCount, result: ())
                }

                self.process(identifier: id)
                return ()
            }
        }

        readyThreads.lock(whenValue: self.numberOfThreads)
        readyThreads.unlock()

        func threadCount() -> Int {
            self._conditionLock.withLock {
                (unlockWith: nil, result: self.threads?.count ?? -1)
            }
        }
        assert(threadCount() == self.numberOfThreads)
    }

    deinit {
        assert(
            self.canBeStopped,
            "Perpetual NIOThreadPool has been deinited, you must make sure that perpetual pools don't deinit"
        )
        switch self._state {
        case .stopped, .shuttingDown:
            ()
        default:
            assertionFailure("wrong state \(self._state)")
        }
    }
}

extension NIOThreadPool: @unchecked Sendable {}

extension NIOThreadPool {

    /// Runs the submitted closure if the thread pool is still active, otherwise fails the promise.
    /// The closure will be run on the thread pool so can do blocking work.
    ///
    /// - Parameters:
    ///   - eventLoop: The `EventLoop` the returned `EventLoopFuture` will fire on.
    ///   - body: The closure which performs some blocking work to be done on the thread pool.
    /// - Returns: The `EventLoopFuture` of `promise` fulfilled with the result (or error) of the passed closure.
    @preconcurrency
    public func runIfActive<T: Sendable>(
        eventLoop: EventLoop,
        _ body: @escaping @Sendable () throws -> T
    ) -> EventLoopFuture<T> {
        self._runIfActive(eventLoop: eventLoop, body)
    }

    private func _runIfActive<T: Sendable>(
        eventLoop: EventLoop,
        _ body: @escaping @Sendable () throws -> T
    ) -> EventLoopFuture<T> {
        let promise = eventLoop.makePromise(of: T.self)
        self.submit { shouldRun in
            guard case shouldRun = NIOThreadPool.WorkItemState.active else {
                promise.fail(NIOThreadPoolError.ThreadPoolInactive())
                return
            }
            do {
                try promise.succeed(body())
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    /// Runs the submitted closure if the thread pool is still active, otherwise throw an error.
    /// The closure will be run on the thread pool, such that we can do blocking work.
    ///
    /// - Parameters:
    ///   - body: The closure which performs some blocking work to be done on the thread pool.
    /// - Returns: Result of the passed closure.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func runIfActive<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let workID = self.nextWorkID.loadThenWrappingIncrement(ordering: .relaxed)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                self._submit(id: workID) { shouldRun in
                    switch shouldRun {
                    case .active:
                        let result = Result(catching: body)
                        cont.resume(with: result)
                    case .cancelled:
                        cont.resume(throwing: CancellationError())
                    }
                }
            }
        } onCancel: {
            self._conditionLock.withLock {
                self._cancelledWorkIDs.insert(workID)
                return (unlockWith: nil, result: ())
            }
        }
    }
}

extension NIOThreadPool {
    @preconcurrency
    public func shutdownGracefully(_ callback: @escaping @Sendable (Error?) -> Void) {
        self.shutdownGracefully(queue: .global(), callback)
    }

    /// Shuts down the thread pool gracefully.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    public func shutdownGracefully() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.shutdownGracefully { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    @available(*, noasync, message: "this can end up blocking the calling thread", renamed: "shutdownGracefully()")
    public func syncShutdownGracefully() throws {
        try self._syncShutdownGracefully()
    }

    private func _syncShutdownGracefully() throws {
        let errorStorageLock = NIOLockedValueBox<Swift.Error?>(nil)
        let continuation = ConditionLock(value: 0)
        self.shutdownGracefully { error in
            if let error = error {
                errorStorageLock.withLockedValue {
                    $0 = error
                }
            }
            continuation.lock(whenValue: 0)
            continuation.unlock(withValue: 1)
        }
        continuation.lock(whenValue: 1)
        continuation.unlock()
        try errorStorageLock.withLockedValue {
            if let error = $0 {
                throw error
            }
        }
    }
}

extension ConditionLock {
    @inlinable
    func _lock(when value: T?) {
        if let value = value {
            self.lock(whenValue: value)
        } else {
            self.lock()
        }
    }

    @inlinable
    func _unlock(with value: T?) {
        if let value = value {
            self.unlock(withValue: value)
        } else {
            self.unlock()
        }
    }

    @inlinable
    func withLock<Result>(when value: T? = nil, _ body: () -> (unlockWith: T?, result: Result)) -> Result {
        self._lock(when: value)
        let (unlockValue, result) = body()
        self._unlock(with: unlockValue)
        return result
    }
}
