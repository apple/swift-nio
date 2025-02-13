//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Dispatch)
import Atomics

#if canImport(Darwin)
import Dispatch
#else
@preconcurrency import Dispatch
#endif

import NIOConcurrencyHelpers
import NIOCore
import _NIODataStructures

/// An `EventLoop` that is thread safe and whose execution is fully controlled
/// by the user.
///
/// Unlike more complex `EventLoop`s, such as `SelectableEventLoop`, the `NIOAsyncTestingEventLoop`
/// has no proper eventing mechanism. Instead, reads and writes are fully controlled by the
/// entity that instantiates the `NIOAsyncTestingEventLoop`. This property makes `NIOAsyncTestingEventLoop`
/// of limited use for many application purposes, but highly valuable for testing and other
/// kinds of mocking. Unlike `EmbeddedEventLoop`, `NIOAsyncTestingEventLoop` is fully thread-safe and
/// safe to use from within a Swift concurrency context.
///
/// Unlike `EmbeddedEventLoop`, `NIOAsyncTestingEventLoop` does require that user tests appropriately
/// enforce thread safety. Used carefully it is possible to safely operate the event loop without
/// explicit synchronization, but it is recommended to use `executeInContext` in any case where it's
/// necessary to ensure that the event loop is not making progress.
///
/// Time is controllable on an `NIOAsyncTestingEventLoop`. It begins at `NIODeadline.uptimeNanoseconds(0)`
/// and may be advanced by a fixed amount by using `advanceTime(by:)`, or advanced to a point in
/// time with `advanceTime(to:)`.
///
/// If users wish to perform multiple tasks at once on an `NIOAsyncTestingEventLoop`, it is recommended that they
/// use `executeInContext` to perform the operations. For example:
///
/// ```
/// await loop.executeInContext {
///     // All three of these will be queued up simultaneously, and no other code can
///     // get between them.
///     loop.execute { firstTask() }
///     loop.execute { secondTask() }
///     loop.execute { thirdTask() }
/// }
/// ```
///
/// There is a tricky requirement around waiting for `EventLoopFuture`s when working with this
/// event loop. Simply calling `.wait()` from the test thread will never complete. This is because
/// `wait` calls `loop.execute` under the hood, and that callback cannot execute without calling
/// `loop.run()`.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public final class NIOAsyncTestingEventLoop: EventLoop, @unchecked Sendable {
    // This type is `@unchecked Sendable` because of the use of `taskNumber`. This
    // variable is only used from within `queue`, but the compiler cannot see that.

    /// The current "time" for this event loop. This is an amount in nanoseconds.
    /// As we need to access this from any thread, we store this as an atomic.
    private let _now = ManagedAtomic<UInt64>(0)

    /// The current "time" for this event loop. This is an amount in nanoseconds.
    public var now: NIODeadline {
        NIODeadline.uptimeNanoseconds(self._now.load(ordering: .relaxed))
    }

    /// This is used to derive an identifier for this loop.
    private var thisLoopID: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    /// A dispatch specific that we use to determine whether we are on the queue for this
    /// "event loop".
    private static let inQueueKey = DispatchSpecificKey<ObjectIdentifier>()

    // Our scheduledTaskCounter needs to be an atomic because we're going to access it from
    // arbitrary threads. This is required by the EventLoop protocol and cannot be avoided.
    // Specifically, Scheduled<T> creation requires us to be able to define the cancellation
    // operation, so the task ID has to be created early.
    private let scheduledTaskCounter = ManagedAtomic<UInt64>(0)
    private var scheduledTasks = PriorityQueue<EmbeddedScheduledTask>()

    /// Keep track of where promises are allocated to ensure we can identify their source if they leak.
    private let _promiseCreationStore = PromiseCreationStore()

    // The number of the next task to be created. We track the order so that when we execute tasks
    // scheduled at the same time, we may do so in the order in which they were submitted for
    // execution.
    //
    // This can only be accessed from `queue`
    private var taskNumber = UInt64(0)

    /// The queue on which we run all our operations.
    private let queue = DispatchQueue(label: "io.swiftnio.AsyncEmbeddedEventLoop")

    private enum State: Int, AtomicValue { case open, closing, closed }
    private let state = ManagedAtomic(State.open)

    // This function must only be called on queue.
    private func nextTaskNumber() -> UInt64 {
        dispatchPrecondition(condition: .onQueue(self.queue))
        defer {
            self.taskNumber += 1
        }
        return self.taskNumber
    }

    /// - see: `EventLoop.inEventLoop`
    public var inEventLoop: Bool {
        DispatchQueue.getSpecific(key: Self.inQueueKey) == self.thisLoopID
    }

    /// Initialize a new `NIOAsyncTestingEventLoop`.
    public init() {
        self.queue.setSpecific(key: Self.inQueueKey, value: self.thisLoopID)
    }

    private func removeTask(taskID: UInt64) {
        dispatchPrecondition(condition: .onQueue(self.queue))
        self.scheduledTasks.removeFirst { $0.id == taskID }
    }

    private func insertTask<ReturnType>(
        taskID: UInt64,
        deadline: NIODeadline,
        promise: EventLoopPromise<ReturnType>?,
        task: @escaping () throws -> ReturnType
    ) {
        dispatchPrecondition(condition: .onQueue(self.queue))

        let task = EmbeddedScheduledTask(
            id: taskID,
            readyTime: deadline,
            insertOrder: self.nextTaskNumber(),
            task: {
                do {
                    // UnsafeUnchecked is acceptable because we know we're in the loop here.
                    let result = try task()
                    promise?.assumeIsolatedUnsafeUnchecked().succeed(result)
                } catch let err {
                    promise?.fail(err)
                }
            },
            { promise?.fail($0) }
        )

        self.scheduledTasks.push(task)
    }

    /// - see: `EventLoop.scheduleTask(deadline:_:)`
    @discardableResult
    @preconcurrency
    public func scheduleTask<T>(
        deadline: NIODeadline,
        _ task: @escaping @Sendable () throws -> T
    ) -> Scheduled<T> {
        let scheduled: Scheduled<T>
        switch self._prepareToSchedule(returnType: T.self) {
        case .doSchedule(let taskID, let promise, let returned):
            scheduled = returned

            // Ok, actually do it.
            if self.inEventLoop {
                self.insertTask(taskID: taskID, deadline: deadline, promise: promise, task: task)
            } else {
                self.queue.async {
                    self.insertTask(taskID: taskID, deadline: deadline, promise: promise, task: task)
                }
            }

        case .returnImmediately(let returned):
            scheduled = returned
        }

        return scheduled
    }

    /// - see: `EventLoop.scheduleTask(in:_:)`
    @discardableResult
    @preconcurrency
    public func scheduleTask<T>(in: TimeAmount, _ task: @escaping @Sendable () throws -> T) -> Scheduled<T> {
        self.scheduleTask(deadline: self.now + `in`, task)
    }

    @preconcurrency
    public func scheduleCallback(
        at deadline: NIODeadline,
        handler: some (NIOScheduledCallbackHandler & Sendable)
    ) throws -> NIOScheduledCallback {
        /// The default implementation of `scheduledCallback(at:handler)` makes two calls to the event loop because it
        /// needs to hook the future of the backing scheduled task, which can lead to lost cancellation callbacks when
        /// callbacks are scheduled close to event loop shutdown.
        ///
        /// We work around this here by using a blocking `wait()` if we are not on the event loop, which would be very
        /// bad in areal event loop, but _less bad_ for testing.
        ///
        /// For more details, see the documentation attached to the default implementation.
        if self.inEventLoop {
            return self._scheduleCallback(at: deadline, handler: handler)
        } else {
            return try self.submit {
                self._scheduleCallback(at: deadline, handler: handler)
            }.wait()
        }
    }

    @preconcurrency
    @discardableResult
    public func scheduleCallback(
        in amount: TimeAmount,
        handler: some (NIOScheduledCallbackHandler & Sendable)
    ) throws -> NIOScheduledCallback {
        /// Even though this type does not implement a custom `scheduleCallback(at:handler)`, it uses a manual clock so
        /// it cannot rely on the default implementation of `scheduleCallback(in:handler:)`, which computes the deadline
        /// as an offset from `NIODeadline.now`. This event loop needs the deadline to be offset from `self.now`.
        try self.scheduleCallback(at: self.now + amount, handler: handler)
    }

    /// On an `NIOAsyncTestingEventLoop`, `execute` will simply use `scheduleTask` with a deadline of _now_. Unlike with the other operations, this will
    /// immediately execute, to eliminate a common class of bugs.
    @preconcurrency
    public func execute(_ task: @escaping @Sendable () -> Void) {
        if self.inEventLoop {
            self.scheduleTask(deadline: self.now, task)
        } else {
            self.queue.async {
                self.scheduleTask(deadline: self.now, task)
                self._run()
            }
        }
    }

    /// Run all tasks that have previously been submitted to this `NIOAsyncTestingEventLoop`, either by calling `execute` or
    /// events that have been enqueued using `scheduleTask`/`scheduleRepeatedTask`/`scheduleRepeatedAsyncTask` and whose
    /// deadlines have expired.
    ///
    /// - seealso: `NIOAsyncTestingEventLoop.advanceTime`.
    public func run() async {
        // Execute all tasks that are currently enqueued to be executed *now*.
        await self.advanceTime(to: self.now)
    }

    /// Runs the event loop and moves "time" forward by the given amount, running any scheduled
    /// tasks that need to be run.
    public func advanceTime(by increment: TimeAmount) async {
        await self.advanceTime(to: self.now + increment)
    }

    /// Runs the event loop and moves "time" forward to the given point in time, running any scheduled
    /// tasks that need to be run.
    ///
    /// - Note: If `deadline` is before the current time, the current time will not be advanced.
    public func advanceTime(to deadline: NIODeadline) async {
        await withCheckedContinuation { continuation in
            self.queue.async {
                self._advanceTime(to: deadline)
                continuation.resume()
            }
        }
    }

    internal func _advanceTime(to deadline: NIODeadline) {
        dispatchPrecondition(condition: .onQueue(self.queue))

        let newTime = max(deadline, self.now)

        var tasks = CircularBuffer<EmbeddedScheduledTask>()
        while let nextTask = self.scheduledTasks.peek() {
            guard nextTask.readyTime <= newTime else {
                break
            }

            // Now we want to grab all tasks that are ready to execute at the same
            // time as the first.
            while let candidateTask = self.scheduledTasks.peek(), candidateTask.readyTime == nextTask.readyTime {
                tasks.append(candidateTask)
                self.scheduledTasks.pop()
            }

            // Set the time correctly before we call into user code, then
            // call in for all tasks.
            self._now.store(nextTask.readyTime.uptimeNanoseconds, ordering: .relaxed)

            for task in tasks {
                task.task()
            }

            tasks.removeAll(keepingCapacity: true)
        }

        // Finally ensure we got the time right.
        self._now.store(newTime.uptimeNanoseconds, ordering: .relaxed)
    }

    internal func _run() {
        dispatchPrecondition(condition: .onQueue(self.queue))
        self._advanceTime(to: self.now)
    }

    /// Executes the given function in the context of this event loop. This is useful when it's necessary to be confident that an operation
    /// is "blocking" the event loop. As long as you are executing, nothing else can execute in this loop.
    ///
    /// While this call is running, no action can take place on the loop. This function can therefore be a good place to schedule a bunch
    /// of tasks "at once", with a guarantee that none of them can progress. It's also useful if you have types that can only be safely
    /// accessed from the event loop thread and want to be 100% sure of the thread-safety of accessing them.
    ///
    /// Be careful not to try to spin the event loop again from within this callback, however. As long as this function is on the call
    /// stack the `NIOAsyncTestingEventLoop` cannot progress, and so any attempt to progress it will block until this function returns.
    public func executeInContext<ReturnType: Sendable>(
        _ task: @escaping @Sendable () throws -> ReturnType
    ) async throws -> ReturnType {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ReturnType, Error>) in
            self.queue.async {
                do {
                    continuation.resume(returning: try task())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    internal func _cancelRemainingScheduledTasks() {
        dispatchPrecondition(condition: .onQueue(self.queue))
        while let task = self.scheduledTasks.pop() {
            task.fail(EventLoopError.cancelled)
        }
    }

    internal func drainScheduledTasksByRunningAllCurrentlyScheduledTasks() {
        var currentlyScheduledTasks = self.scheduledTasks
        while let nextTask = currentlyScheduledTasks.pop() {
            self._now.store(nextTask.readyTime.uptimeNanoseconds, ordering: .relaxed)
            nextTask.task()
        }
        // Just fail all the remaining scheduled tasks. Despite having run all the tasks that were
        // scheduled when we entered the method this may still contain tasks as running the tasks
        // may have enqueued more tasks.
        while let task = self.scheduledTasks.pop() {
            task.fail(EventLoopError.shutdown)
        }
    }

    private func _shutdownGracefully() {
        dispatchPrecondition(condition: .onQueue(self.queue))
        self._run()
        self._cancelRemainingScheduledTasks()
    }

    /// - see: `EventLoop.shutdownGracefully`
    @preconcurrency
    public func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping @Sendable (Error?) -> Void) {
        self.queue.async {
            self._shutdownGracefully()
            queue.async {
                callback(nil)
            }
        }
    }

    /// The concurrency-aware equivalent of `shutdownGracefully(queue:_:)`.
    public func shutdownGracefully() async {
        await withCheckedContinuation { continuation in
            self.state.store(.closing, ordering: .releasing)
            self.queue.async {
                self._shutdownGracefully()
                self.state.store(.closed, ordering: .releasing)
                continuation.resume()
            }
        }
    }

    public func _preconditionSafeToWait(file: StaticString, line: UInt) {
        dispatchPrecondition(condition: .notOnQueue(self.queue))
    }

    public func _promiseCreated(futureIdentifier: _NIOEventLoopFutureIdentifier, file: StaticString, line: UInt) {
        self._promiseCreationStore.promiseCreated(futureIdentifier: futureIdentifier, file: file, line: line)
    }

    public func _promiseCompleted(futureIdentifier: _NIOEventLoopFutureIdentifier) -> (file: StaticString, line: UInt)?
    {
        self._promiseCreationStore.promiseCompleted(futureIdentifier: futureIdentifier)
    }

    public func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt) {
        dispatchPrecondition(condition: .notOnQueue(self.queue))
    }

    public func _executeIsolatedUnsafeUnchecked(_ task: @escaping () -> Void) {
        // Call directly to insertTask. That function has a thread-safety check, and
        // the rest of this method is using thread-safe operations so we don't
        // need any extra debug-mode checking here.
        let taskID = self.scheduledTaskCounter.loadThenWrappingIncrement(ordering: .relaxed)
        self.insertTask(
            taskID: taskID,
            deadline: self.now,
            promise: nil,
            task: task
        )
    }

    public func _submitIsolatedUnsafeUnchecked<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        // Call directly to insertTask. That function has a thread-safety check, and
        // the rest of this method is using thread-safe operations so we don't
        // need any extra debug-mode checking here.
        let promise = self.makePromise(of: T.self)
        let taskID = self.scheduledTaskCounter.loadThenWrappingIncrement(ordering: .relaxed)
        self.insertTask(
            taskID: taskID,
            deadline: self.now,
            promise: promise,
            task: task
        )
        return promise.futureResult
    }

    @discardableResult
    public func _scheduleTaskIsolatedUnsafeUnchecked<T>(
        deadline: NIODeadline,
        _ task: @escaping () throws -> T
    ) -> Scheduled<T> {
        // Call directly to insertTask. That function has a thread-safety check, and
        // the rest of this method is using thread-safe operations so we don't
        // need any extra debug-mode checking here.
        let scheduled: Scheduled<T>
        switch self._prepareToSchedule(returnType: T.self) {
        case .doSchedule(let taskID, let promise, let returned):
            scheduled = returned
            self.insertTask(taskID: taskID, deadline: deadline, promise: promise, task: task)
        case .returnImmediately(let returned):
            scheduled = returned
        }

        return scheduled
    }

    @discardableResult
    public func _scheduleTaskIsolatedUnsafeUnchecked<T>(
        in delay: TimeAmount,
        _ task: @escaping () throws -> T
    ) -> Scheduled<T> {
        self._scheduleTaskIsolatedUnsafeUnchecked(deadline: self.now + delay, task)
    }

    public func preconditionInEventLoop(file: StaticString, line: UInt) {
        dispatchPrecondition(condition: .onQueue(self.queue))
    }

    public func preconditionNotInEventLoop(file: StaticString, line: UInt) {
        dispatchPrecondition(condition: .notOnQueue(self.queue))
    }

    enum ScheduleCreationResult<TaskReturnType> {
        case doSchedule(taskID: UInt64, promise: EventLoopPromise<TaskReturnType>, scheduled: Scheduled<TaskReturnType>)
        case returnImmediately(Scheduled<TaskReturnType>)
    }
    private func _prepareToSchedule<ReturnType>(
        returnType: ReturnType.Type = ReturnType.self
    ) -> ScheduleCreationResult<ReturnType> {
        let promise = self.makePromise(of: ReturnType.self)

        switch self.state.load(ordering: .acquiring) {
        case .open:
            break
        case .closing, .closed:
            // If the event loop is shut down, or shutting down, immediately cancel the task.
            promise.fail(EventLoopError.cancelled)
            return .returnImmediately(Scheduled(promise: promise, cancellationTask: {}))
        }

        let taskID = self.scheduledTaskCounter.loadThenWrappingIncrement(ordering: .relaxed)

        let scheduled = Scheduled(
            promise: promise,
            cancellationTask: {
                if self.inEventLoop {
                    self.removeTask(taskID: taskID)
                } else {
                    self.queue.async {
                        self.removeTask(taskID: taskID)
                    }
                }
            }
        )
        return .doSchedule(
            taskID: taskID,
            promise: promise,
            scheduled: scheduled
        )
    }

    deinit {
        precondition(scheduledTasks.isEmpty, "NIOAsyncTestingEventLoop freed with unexecuted scheduled tasks!")
    }
}

// MARK: SerialExecutor conformance
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension NIOAsyncTestingEventLoop: NIOSerialEventLoopExecutor {}

/// This is a thread-safe promise creation store.
///
/// We use this to keep track of where promises come from in the `NIOAsyncTestingEventLoop`.
private class PromiseCreationStore {
    private let lock = NIOLock()
    private var promiseCreationStore: [_NIOEventLoopFutureIdentifier: (file: StaticString, line: UInt)] = [:]

    func promiseCreated(futureIdentifier: _NIOEventLoopFutureIdentifier, file: StaticString, line: UInt) {
        precondition(_isDebugAssertConfiguration())
        self.lock.withLock { () -> Void in
            self.promiseCreationStore[futureIdentifier] = (file: file, line: line)
        }
    }

    func promiseCompleted(futureIdentifier: _NIOEventLoopFutureIdentifier) -> (file: StaticString, line: UInt)? {
        precondition(_isDebugAssertConfiguration())
        return self.lock.withLock {
            self.promiseCreationStore.removeValue(forKey: futureIdentifier)
        }
    }

    deinit {
        // We no longer need the lock here.
        precondition(self.promiseCreationStore.isEmpty, "NIOAsyncTestingEventLoop freed with uncompleted promises!")
    }
}
#endif
