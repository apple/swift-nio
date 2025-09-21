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

import NIOConcurrencyHelpers

#if canImport(Dispatch)
import Dispatch
#endif

#if canImport(WASILibc)
@preconcurrency import WASILibc
import CNIOWASI
#endif

#if os(Linux)
import CNIOLinux
#endif  // os(Linux)

/// Returned once a task was scheduled on the `EventLoop` for later execution.
///
/// A `Scheduled` allows the user to either `cancel()` the execution of the scheduled task (if possible) or obtain a reference to the `EventLoopFuture` that
/// will be notified once the execution is complete.
public struct Scheduled<T> {
    @usableFromInline typealias CancelationCallback = @Sendable () -> Void
    @usableFromInline let _promise: EventLoopPromise<T>
    @usableFromInline let _cancellationTask: CancelationCallback

    @inlinable
    @preconcurrency
    public init(promise: EventLoopPromise<T>, cancellationTask: @escaping @Sendable () -> Void) {
        self._promise = promise
        self._cancellationTask = cancellationTask
    }

    /// Try to cancel the execution of the scheduled task.
    ///
    /// Whether this is successful depends on whether the execution of the task already begun.
    ///  This means that cancellation is not guaranteed.
    @inlinable
    public func cancel() {
        self._promise.fail(EventLoopError._cancelled)
        self._cancellationTask()
    }

    /// Returns the `EventLoopFuture` which will be notified once the execution of the scheduled task completes.
    @inlinable
    public var futureResult: EventLoopFuture<T> {
        self._promise.futureResult
    }
}

extension Scheduled: Sendable {}

/// Returned once a task was scheduled to be repeatedly executed on the `EventLoop`.
///
/// A `RepeatedTask` allows the user to `cancel()` the repeated scheduling of further tasks.
public final class RepeatedTask {
    typealias RepeatedTaskCallback = @Sendable (RepeatedTask) -> EventLoopFuture<Void>
    private let delay: TimeAmount
    private let eventLoop: EventLoop
    private let cancellationPromise: EventLoopPromise<Void>?
    private var scheduled: Optional<Scheduled<EventLoopFuture<Void>>>
    private var task: Optional<RepeatedTaskCallback>

    internal init(
        interval: TimeAmount,
        eventLoop: EventLoop,
        cancellationPromise: EventLoopPromise<Void>? = nil,
        task: @escaping RepeatedTaskCallback
    ) {
        self.delay = interval
        self.eventLoop = eventLoop
        self.cancellationPromise = cancellationPromise
        self.task = task
        self.scheduled = nil
    }

    internal func begin(in delay: TimeAmount) {
        if self.eventLoop.inEventLoop {
            self.begin0(in: delay)
        } else {
            self.eventLoop.execute {
                self.begin0(in: delay)
            }
        }
    }

    private func begin0(in delay: TimeAmount) {
        self.eventLoop.assertInEventLoop()
        guard let task = self.task else {
            return
        }
        self.scheduled = self.eventLoop.scheduleTask(in: delay) {
            task(self)
        }
        self.reschedule()
    }

    /// Try to cancel the execution of the repeated task.
    ///
    /// Whether the execution of the task is immediately canceled depends on whether the execution of a task has already begun.
    ///  This means immediate cancellation is not guaranteed.
    ///
    /// The safest way to cancel is by using the passed reference of `RepeatedTask` inside the task closure.
    ///
    /// If the promise parameter is not `nil`, the passed promise is fulfilled when cancellation is complete.
    /// Passing a promise does not prevent fulfillment of any promise provided on original task creation.
    public func cancel(promise: EventLoopPromise<Void>? = nil) {
        if self.eventLoop.inEventLoop {
            self.cancel0(localCancellationPromise: promise)
        } else {
            self.eventLoop.execute {
                self.cancel0(localCancellationPromise: promise)
            }
        }
    }

    private func cancel0(localCancellationPromise: EventLoopPromise<Void>?) {
        self.eventLoop.assertInEventLoop()
        self.scheduled?.cancel()
        self.scheduled = nil
        self.task = nil

        // Possible states at this time are:
        //  1) Task is scheduled but has not yet executed.
        //  2) Task is currently executing and invoked `cancel()` on itself.
        //  3) Task is currently executing and `cancel0()` has been reentrantly invoked.
        //  4) NOT VALID: Task is currently executing and has NOT invoked `cancel()` (`EventLoop` guarantees serial execution)
        //  5) NOT VALID: Task has completed execution in a success state (`reschedule()` ensures state #2).
        //  6) Task has completed execution in a failure state.
        //  7) Task has been fully cancelled at a previous time.
        //
        // It is desirable that the task has fully completed any execution before any cancellation promise is
        // fulfilled. States 2 and 3 occur during execution, so the requirement is implemented by deferring
        // fulfillment to the next `EventLoop` cycle. The delay is harmless to other states and distinguishing
        // them from 2 and 3 is not practical (or necessarily possible), so is used unconditionally. Check the
        // promises for nil so as not to otherwise invoke `execute()` unnecessarily.
        if self.cancellationPromise != nil || localCancellationPromise != nil {
            self.eventLoop.execute {
                self.cancellationPromise?.succeed(())
                localCancellationPromise?.succeed(())
            }
        }
    }

    private func reschedule() {
        self.eventLoop.assertInEventLoop()
        guard let scheduled = self.scheduled else {
            return
        }

        scheduled.futureResult.whenSuccess { future in
            future.hop(to: self.eventLoop).whenComplete { (_: Result<Void, Error>) in
                self.reschedule0()
            }
        }

        scheduled.futureResult.whenFailure { (_: Error) in
            self.cancel0(localCancellationPromise: nil)
        }
    }

    private func reschedule0() {
        self.eventLoop.assertInEventLoop()
        guard self.task != nil else {
            return
        }
        self.scheduled = self.eventLoop.scheduleTask(in: self.delay) {
            // we need to repeat this as we might have been cancelled in the meantime
            guard let task = self.task else {
                return self.eventLoop.makeSucceededFuture(())
            }
            return task(self)
        }
        self.reschedule()
    }
}

extension RepeatedTask: @unchecked Sendable {}

/// An iterator over the `EventLoop`s forming an `EventLoopGroup`.
///
/// Usually returned by an `EventLoopGroup`'s `makeIterator()` method.
///
///     let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
///     group.makeIterator().forEach { loop in
///         // Do something with each loop
///     }
///
public struct EventLoopIterator: Sequence, IteratorProtocol {
    public typealias Element = EventLoop
    private var eventLoops: IndexingIterator<[EventLoop]>

    /// Create an `EventLoopIterator` from an array of `EventLoop`s.
    public init(_ eventLoops: [EventLoop]) {
        self.eventLoops = eventLoops.makeIterator()
    }

    /// Advances to the next `EventLoop` and returns it, or `nil` if no next element exists.
    ///
    /// - Returns: The next `EventLoop` if a next element exists; otherwise, `nil`.
    public mutating func next() -> EventLoop? {
        self.eventLoops.next()
    }
}

extension EventLoopIterator: Sendable {}

/// An EventLoop processes IO / tasks in an endless loop for `Channel`s until it's closed.
///
/// Usually multiple `Channel`s share the same `EventLoop` for processing IO / tasks and so share the same processing `NIOThread`.
/// For a better understanding of how such an `EventLoop` works internally the following pseudo code may be helpful:
///
/// ```
/// while eventLoop.isOpen {
///     /// Block until there is something to process for 1...n Channels
///     let readyChannels = blockUntilIoOrTasksAreReady()
///     /// Loop through all the Channels
///     for channel in readyChannels {
///         /// Process IO and / or tasks for the Channel.
///         /// This may include things like:
///         ///    - accept new connection
///         ///    - connect to a remote host
///         ///    - read from socket
///         ///    - write to socket
///         ///    - tasks that were submitted via EventLoop methods
///         /// and others.
///         processIoAndTasks(channel)
///     }
/// }
/// ```
///
/// Because an `EventLoop` may be shared between multiple `Channel`s it's important to _NOT_ block while processing IO / tasks. This also includes long running computations which will have the same
/// effect as blocking in this case.
public protocol EventLoop: EventLoopGroup {
    /// Returns `true` if the current `NIOThread` is the same as the `NIOThread` that is tied to this `EventLoop`. `false` otherwise.
    ///
    /// This method is intended principally as an optimization point, allowing users to write code that can provide fast-paths when this
    /// property is true. It is _not suitable_ as a correctness guard. Code must be correct if this value returns `false` _even if_
    /// the event loop context is actually held. That's because this property is allowed to produce false-negatives
    ///
    /// Implementers may implement this method in a way that may produce false-negatives: that is, this value may return `false` in
    /// cases where the code in question actually is executing on the event loop. It may _never_ produce false positives: this value
    /// must never return `true` when event loop context is not actually held.
    ///
    /// If it is necessary for correctness to confirm that you're on an event loop, prefer ``preconditionInEventLoop(file:line:)-7ukrq``.
    var inEventLoop: Bool { get }

    /// Submit a given task to be executed by the `EventLoop`
    @preconcurrency
    func execute(_ task: @escaping @Sendable () -> Void)

    /// Submit a given task to be executed by the `EventLoop`. Once the execution is complete the returned `EventLoopFuture` is notified.
    ///
    /// - Parameters:
    ///   - task: The closure that will be submitted to the `EventLoop` for execution.
    /// - Returns: `EventLoopFuture` that is notified once the task was executed.
    @preconcurrency
    func submit<T>(_ task: @escaping @Sendable () throws -> T) -> EventLoopFuture<T>

    /// The current time of the event loop.
    var now: NIODeadline { get }

    /// Schedule a `task` that is executed by this `EventLoop` at the given time.
    ///
    /// - Parameters:
    ///   - deadline: The instant in time before which the task will not execute.
    ///   - task: The synchronous task to run. As with everything that runs on the `EventLoop`, it must not block.
    /// - Returns: A `Scheduled` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the completion of the task.
    ///
    /// - Note: You can only cancel a task before it has started executing.
    @discardableResult
    @preconcurrency
    func scheduleTask<T>(deadline: NIODeadline, _ task: @escaping @Sendable () throws -> T) -> Scheduled<T>

    /// Schedule a `task` that is executed by this `EventLoop` after the given amount of time.
    ///
    /// - Parameters:
    ///   - in: The amount of time before which the task will not execute.
    ///   - task: The synchronous task to run. As with everything that runs on the `EventLoop`, it must not block.
    /// - Returns: A `Scheduled` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the completion of the task.
    ///
    /// - Note: You can only cancel a task before it has started executing.
    /// - Note: The `in` value is clamped to a maximum when running on a Darwin-kernel.
    @discardableResult
    @preconcurrency
    func scheduleTask<T>(in: TimeAmount, _ task: @escaping @Sendable () throws -> T) -> Scheduled<T>

    /// Asserts that the current thread is the one tied to this `EventLoop`.
    /// Otherwise, the process will be abnormally terminated as per the semantics of `preconditionFailure(_:file:line:)`.
    ///
    /// This method may never produce false positives or false negatives in conforming implementations. It may never
    /// terminate the process when event loop context is actually held, and it may never fail to terminate the process
    /// when event loop context is not held.
    func preconditionInEventLoop(file: StaticString, line: UInt)

    /// Asserts that the current thread is _not_ the one tied to this `EventLoop`.
    /// Otherwise, the process will be abnormally terminated as per the semantics of `preconditionFailure(_:file:line:)`.
    ///
    /// This method may never produce false positives or false negatives in conforming implementations. It may never
    /// terminate the process when event loop context is not held, and it may never fail to terminate the process
    /// when event loop context is held.
    func preconditionNotInEventLoop(file: StaticString, line: UInt)

    /// Return a succeeded `Void` future.
    ///
    /// Semantically, this function is equivalent to calling `makeSucceededFuture(())`.
    /// Contrary to `makeSucceededFuture`, `makeSucceededVoidFuture` is a customization point for `EventLoop`s which
    /// allows `EventLoop`s to cache a pre-succeeded `Void` future to prevent superfluous allocations.
    func makeSucceededVoidFuture() -> EventLoopFuture<Void>

    /// Returns a `SerialExecutor` corresponding to this ``EventLoop``.
    ///
    /// This executor can be used to isolate an actor to a given ``EventLoop``. Implementers are encouraged to customise
    /// this implementation by conforming their ``EventLoop`` to ``NIOSerialEventLoopExecutor`` which will provide an
    /// optimised implementation of this method, and will conform their type to `SerialExecutor`. The default
    /// implementation provides suboptimal performance.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    var executor: any SerialExecutor { get }

    /// Submit a job to be executed by the `EventLoop`
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func enqueue(_ job: consuming ExecutorJob)

    /// Must crash if it is not safe to call `wait()` on an `EventLoopFuture`.
    ///
    /// This method is a debugging hook that can be used to override the behaviour of `EventLoopFuture.wait()` when called.
    /// By default this simply becomes `preconditionNotInEventLoop`, but some `EventLoop`s are capable of more exhaustive
    /// checking and can validate that the wait is not occurring on an entire `EventLoopGroup`, or even more broadly.
    ///
    /// This method should not be called by users directly, it should only be implemented by `EventLoop` implementers that
    /// need to customise the behaviour.
    func _preconditionSafeToWait(file: StaticString, line: UInt)

    /// Debug hook: track a promise creation and its location.
    ///
    /// This debug hook is called by EventLoopFutures and EventLoopPromises when they are created, and tracks the location
    /// of their creation. It combines with `_promiseCompleted` to provide high-fidelity diagnostics for debugging leaked
    /// promises.
    ///
    /// In release mode, this function will never be called.
    ///
    /// It is valid for an `EventLoop` not to implement any of the two `_promise` functions. If either of them are implemented,
    /// however, both of them should be implemented.
    func _promiseCreated(futureIdentifier: _NIOEventLoopFutureIdentifier, file: StaticString, line: UInt)

    /// Debug hook: complete a specific promise and return its creation location.
    ///
    /// This debug hook is called by EventLoopFutures and EventLoopPromises when they are deinited, and removes the data from
    /// the promise tracking map and, if available, provides that data as its return value. It combines with `_promiseCreated`
    /// to provide high-fidelity diagnostics for debugging leaked promises.
    ///
    /// In release mode, this function will never be called.
    ///
    /// It is valid for an `EventLoop` not to implement any of the two `_promise` functions. If either of them are implemented,
    /// however, both of them should be implemented.
    func _promiseCompleted(futureIdentifier: _NIOEventLoopFutureIdentifier) -> (file: StaticString, line: UInt)?

    /// Schedule a callback at a given time.
    ///
    /// - Parameters:
    ///   - deadline: The instant in time before which the task will not execute.
    ///   - handler: The handler that defines the behavior of the callback when executed or canceled.
    /// - Returns: A ``NIOScheduledCallback`` that can be used to cancel the scheduled callback.
    ///
    /// - NOTE: Event loops that provide a custom scheduled callback implementation **must** also implement
    ///         `cancelScheduledCallback`. Failure to do so will result in a runtime error.
    @preconcurrency
    @discardableResult
    func scheduleCallback(
        at deadline: NIODeadline,
        handler: some (NIOScheduledCallbackHandler & Sendable)
    ) throws -> NIOScheduledCallback

    /// Schedule a callback after given time.
    ///
    /// - Parameters:
    ///   - amount: The amount of time before which the task will not execute.
    ///   - handler: The handler that defines the behavior of the callback when executed or canceled.
    ///  - Returns: A ``NIOScheduledCallback`` that can be used to cancel the scheduled callback.
    ///
    /// - NOTE: Event loops that provide a custom scheduled callback implementation **must** also implement
    ///         `cancelScheduledCallback`. Failure to do so will result in a runtime error.
    @preconcurrency
    @discardableResult
    func scheduleCallback(
        in amount: TimeAmount,
        handler: some (NIOScheduledCallbackHandler & Sendable)
    ) throws -> NIOScheduledCallback

    /// Cancel a scheduled callback.
    ///
    /// - NOTE: Event loops only need to implemented this if they provide a custom scheduled callback implementation.
    func cancelScheduledCallback(_ scheduledCallback: NIOScheduledCallback)

    /// Submit a given task to be executed by the ``EventLoop``, from a context where the caller
    /// statically knows that the context is isolated.
    ///
    /// This is an optional performance hook. ``EventLoop`` implementers are not required to implement
    /// this witness, but may choose to do so to enable better performance of the isolated EL views. If
    /// they do so, ``EventLoop/Isolated/execute`` will perform better.
    func _executeIsolatedUnsafeUnchecked(_ task: @escaping () -> Void)

    /// Submit a given task to be executed by the ``EventLoop```, from a context where the caller
    /// statically knows that the context is isolated.
    ///
    /// Once the execution is complete the returned ``EventLoopFuture`` is notified.
    ///
    /// This is an optional performance hook. ``EventLoop`` implementers are not required to implement
    /// this witness, but may choose to do so to enable better performance of the isolated EL views. If
    /// they do so, ``EventLoop/Isolated/submit`` will perform better.
    ///
    /// - Parameters:
    ///   - task: The closure that will be submitted to the ``EventLoop`` for execution.
    /// - Returns: ``EventLoopFuture`` that is notified once the task was executed.
    func _submitIsolatedUnsafeUnchecked<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T>

    /// Schedule a `task` that is executed by this ``EventLoop`` at the given time, from a context where the caller
    /// statically knows that the context is isolated.
    ///
    /// This is an optional performance hook. ``EventLoop`` implementers are not required to implement
    /// this witness, but may choose to do so to enable better performance of the isolated EL views. If
    /// they do so, ``EventLoop/Isolated/scheduleTask(deadline:_:)`` will perform better.
    ///
    /// - Parameters:
    ///   - deadline: The instant in time before which the task will not execute.
    ///   - task: The synchronous task to run. As with everything that runs on the ``EventLoop```, it must not block.
    /// - Returns: A ``Scheduled``` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the completion of the task.
    ///
    /// - Note: You can only cancel a task before it has started executing.
    @discardableResult
    func _scheduleTaskIsolatedUnsafeUnchecked<T>(
        deadline: NIODeadline,
        _ task: @escaping () throws -> T
    ) -> Scheduled<T>

    /// Schedule a `task` that is executed by this ``EventLoop`` after the given amount of time, from a context where the caller
    /// statically knows that the context is isolated.
    ///
    /// This is an optional performance hook. ``EventLoop`` implementers are not required to implement
    /// this witness, but may choose to do so to enable better performance of the isolated EL views. If
    /// they do so, ``EventLoop/Isolated/scheduleTask(in:_:)`` will perform better.
    ///
    /// - Parameters:
    ///   - in: The amount of time before which the task will not execute.
    ///   - task: The synchronous task to run. As with everything that runs on the ``EventLoop``, it must not block.
    /// - Returns: A ``Scheduled`` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the completion of the task.
    ///
    /// - Note: You can only cancel a task before it has started executing.
    /// - Note: The `in` value is clamped to a maximum when running on a Darwin-kernel.
    @discardableResult
    func _scheduleTaskIsolatedUnsafeUnchecked<T>(
        in: TimeAmount,
        _ task: @escaping () throws -> T
    ) -> Scheduled<T>

    /// Schedule a callback that is executed by this ``EventLoop`` at a given time, from a context where the caller
    /// statically knows that the context is isolated.
    ///
    /// This is an optional performance hook. ``EventLoop`` implementers are not required to implement
    /// this witness, but may choose to do so to enable better performance of the isolated EL views. If
    /// they do so, ``EventLoop/Isolated/scheduleCallback(at:_:)`` will perform better.
    ///
    /// - Parameters:
    ///   - at: The instant in time before which the task will not execute.
    ///   - handler: The handler that defines the behavior of the callback when executed or canceled.
    /// - Returns: A ``NIOScheduledCallback`` that can be used to cancel the scheduled callback.
    @discardableResult
    func _scheduleCallbackIsolatedUnsafeUnchecked(
        at deadline: NIODeadline,
        handler: some NIOScheduledCallbackHandler
    ) throws -> NIOScheduledCallback

    /// Schedule a callback that is executed by this ``EventLoop`` after a given time, from a context where the caller
    /// statically knows that the context is isolated.
    ///
    /// This is an optional performance hook. ``EventLoop`` implementers are not required to implement
    /// this witness, but may choose to do so to enable better performance of the isolated EL views. If
    /// they do so, ``EventLoop/Isolated/scheduleCallback(in:_:)`` will perform better.
    ///
    /// - Parameters:
    ///   - in: The amount of time before which the task will not execute.
    ///   - handler: The handler that defines the behavior of the callback when executed or canceled.
    /// - Returns: A ``NIOScheduledCallback`` that can be used to cancel the scheduled callback.
    @discardableResult
    func _scheduleCallbackIsolatedUnsafeUnchecked(
        in amount: TimeAmount,
        handler: some NIOScheduledCallbackHandler
    ) throws -> NIOScheduledCallback
}

extension EventLoop {
    /// Default implementation of `now`: Returns `NIODeadline.now()`.
    public var now: NIODeadline { .now() }
}

extension EventLoop {
    /// Default implementation of `makeSucceededVoidFuture`: Return a fresh future (which will allocate).
    public func makeSucceededVoidFuture() -> EventLoopFuture<Void> {
        EventLoopFuture(eventLoop: self, value: ())
    }

    public func _preconditionSafeToWait(file: StaticString, line: UInt) {
        self.preconditionNotInEventLoop(file: file, line: line)
    }

    /// Default implementation of `_promiseCreated`: does nothing.
    public func _promiseCreated(futureIdentifier: _NIOEventLoopFutureIdentifier, file: StaticString, line: UInt) {
        return
    }

    /// Default implementation of `_promiseCompleted`: does nothing.
    public func _promiseCompleted(futureIdentifier: _NIOEventLoopFutureIdentifier) -> (file: StaticString, line: UInt)?
    {
        nil
    }

    /// Default implementation: wraps the task in an UnsafeTransfer.
    @inlinable
    public func _executeIsolatedUnsafeUnchecked(_ task: @escaping () -> Void) {
        self.assertInEventLoop()
        let unsafeTransfer = UnsafeTransfer(task)
        self.execute {
            unsafeTransfer.wrappedValue()
        }
    }

    /// Default implementation: wraps the task in an UnsafeTransfer.
    @inlinable
    public func _submitIsolatedUnsafeUnchecked<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        self.assertInEventLoop()
        let unsafeTransfer = UnsafeTransfer(task)
        return self.submit {
            try unsafeTransfer.wrappedValue()
        }
    }

    /// Default implementation: wraps the task in an UnsafeTransfer.
    @inlinable
    @discardableResult
    public func _scheduleTaskIsolatedUnsafeUnchecked<T>(
        deadline: NIODeadline,
        _ task: @escaping () throws -> T
    ) -> Scheduled<T> {
        self.assertInEventLoop()
        let unsafeTransfer = UnsafeTransfer(task)
        return self.scheduleTask(deadline: deadline) {
            try unsafeTransfer.wrappedValue()
        }
    }

    /// Default implementation: wraps the task in an UnsafeTransfer.
    @inlinable
    @discardableResult
    public func _scheduleTaskIsolatedUnsafeUnchecked<T>(
        in delay: TimeAmount,
        _ task: @escaping () throws -> T
    ) -> Scheduled<T> {
        self.assertInEventLoop()
        let unsafeTransfer = UnsafeTransfer(task)
        return self.scheduleTask(in: delay) {
            try unsafeTransfer.wrappedValue()
        }
    }

    @inlinable
    @discardableResult
    public func _scheduleCallbackIsolatedUnsafeUnchecked(
        at deadline: NIODeadline,
        handler: some NIOScheduledCallbackHandler
    ) throws -> NIOScheduledCallback {
        let unsafeHandlerWrapper = LoopBoundScheduledCallbackHandlerWrapper(wrapping: handler, eventLoop: self)
        return try self.scheduleCallback(at: deadline, handler: unsafeHandlerWrapper)
    }

    @inlinable
    @discardableResult
    public func _scheduleCallbackIsolatedUnsafeUnchecked(
        in amount: TimeAmount,
        handler: some NIOScheduledCallbackHandler
    ) throws -> NIOScheduledCallback {
        let unsafeHandlerWrapper = LoopBoundScheduledCallbackHandlerWrapper(wrapping: handler, eventLoop: self)
        return try self.scheduleCallback(in: amount, handler: unsafeHandlerWrapper)
    }
}

extension EventLoop {
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    public var executor: any SerialExecutor {
        NIODefaultSerialEventLoopExecutor(self)
    }

    @inlinable
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    public func enqueue(_ job: consuming ExecutorJob) {
        // By default we are just going to use execute to run the job
        // this is quite heavy since it allocates the closure for
        // every single job.
        let unownedJob = UnownedJob(job)
        self.execute {
            unownedJob.runSynchronously(on: self.executor.asUnownedSerialExecutor())
        }
    }
}

extension EventLoopGroup {
    public var description: String {
        String(describing: self)
    }
}

/// Represents a time _interval_.
///
/// - Note: `TimeAmount` should not be used to represent a point in time.
public struct TimeAmount: Hashable, Sendable {
    @available(*, deprecated, message: "This typealias doesn't serve any purpose. Please use Int64 directly.")
    public typealias Value = Int64

    /// The nanoseconds representation of the `TimeAmount`.
    public let nanoseconds: Int64

    @inlinable
    init(_ nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    /// Creates a new `TimeAmount` for the given amount of nanoseconds.
    ///
    /// - Parameters:
    ///   - amount: the amount of nanoseconds this `TimeAmount` represents.
    /// - Returns: the `TimeAmount` for the given amount.
    @inlinable
    public static func nanoseconds(_ amount: Int64) -> TimeAmount {
        TimeAmount(amount)
    }

    /// Creates a new `TimeAmount` for the given amount of microseconds.
    ///
    /// - Parameters:
    ///   - amount: the amount of microseconds this `TimeAmount` represents.
    /// - Returns: the `TimeAmount` for the given amount.
    ///
    /// - Note: returns `TimeAmount(.max)` if the amount overflows when converted to nanoseconds and `TimeAmount(.min)` if it underflows.
    @inlinable
    public static func microseconds(_ amount: Int64) -> TimeAmount {
        TimeAmount(_cappedNanoseconds(amount: amount, multiplier: 1000))
    }

    /// Creates a new `TimeAmount` for the given amount of milliseconds.
    ///
    /// - Parameters:
    ///   - amount: the amount of milliseconds this `TimeAmount` represents.
    /// - Returns: the `TimeAmount` for the given amount.
    ///
    /// - Note: returns `TimeAmount(.max)` if the amount overflows when converted to nanoseconds and `TimeAmount(.min)` if it underflows.
    @inlinable
    public static func milliseconds(_ amount: Int64) -> TimeAmount {
        TimeAmount(_cappedNanoseconds(amount: amount, multiplier: 1000 * 1000))
    }

    /// Creates a new `TimeAmount` for the given amount of seconds.
    ///
    /// - Parameters:
    ///   - amount: the amount of seconds this `TimeAmount` represents.
    /// - Returns: the `TimeAmount` for the given amount.
    ///
    /// - Note: returns `TimeAmount(.max)` if the amount overflows when converted to nanoseconds and `TimeAmount(.min)` if it underflows.
    @inlinable
    public static func seconds(_ amount: Int64) -> TimeAmount {
        TimeAmount(_cappedNanoseconds(amount: amount, multiplier: 1000 * 1000 * 1000))
    }

    /// Creates a new `TimeAmount` for the given amount of minutes.
    ///
    /// - Parameters:
    ///   - amount: the amount of minutes this `TimeAmount` represents.
    /// - Returns: the `TimeAmount` for the given amount.
    ///
    /// - Note: returns `TimeAmount(.max)` if the amount overflows when converted to nanoseconds and `TimeAmount(.min)` if it underflows.
    @inlinable
    public static func minutes(_ amount: Int64) -> TimeAmount {
        TimeAmount(_cappedNanoseconds(amount: amount, multiplier: 1000 * 1000 * 1000 * 60))
    }

    /// Creates a new `TimeAmount` for the given amount of hours.
    ///
    /// - Parameters:
    ///   - amount: the amount of hours this `TimeAmount` represents.
    /// - Returns: the `TimeAmount` for the given amount.
    ///
    /// - Note: returns `TimeAmount(.max)` if the amount overflows when converted to nanoseconds and `TimeAmount(.min)` if it underflows.
    @inlinable
    public static func hours(_ amount: Int64) -> TimeAmount {
        TimeAmount(_cappedNanoseconds(amount: amount, multiplier: 1000 * 1000 * 1000 * 60 * 60))
    }

    /// Converts `amount` to nanoseconds multiplying it by `multiplier`. The return value is capped to `Int64.max` if the multiplication overflows and `Int64.min` if it underflows.
    ///
    ///  - parameters:
    ///   - amount: the amount to be converted to nanoseconds.
    ///   - multiplier: the multiplier that converts the given amount to nanoseconds.
    ///  - returns: the amount converted to nanoseconds within [Int64.min, Int64.max].
    @inlinable
    static func _cappedNanoseconds(amount: Int64, multiplier: Int64) -> Int64 {
        let nanosecondsMultiplication = amount.multipliedReportingOverflow(by: multiplier)
        if nanosecondsMultiplication.overflow {
            return amount >= 0 ? .max : .min
        } else {
            return nanosecondsMultiplication.partialValue
        }
    }
}

/// Contains the logic for parsing time amounts from strings,
/// and printing pretty strings to represent time amounts.
extension TimeAmount: CustomStringConvertible {

    /// Errors thrown when parsint a TimeAmount from a string
    internal enum ValidationError: Error, Equatable {
        /// Can't parse the provided unit
        case unsupportedUnit(String)

        /// Can't parse the number into a Double
        case invalidNumber(String)
    }

    /// Creates a TimeAmount from a string representation with an optional default unit.
    ///
    /// Supports formats like:
    /// - "5s" (5 seconds)
    /// - "100ms" (100 milliseconds)
    /// - "42" (42 of default unit)
    /// - "1 hr" (1 hour)
    ///
    /// This function only supports one pair of the number and units, i.e. "5s" or "100ms" but not "5s 100ms".
    ///
    /// Supported units:
    /// - h, hr, hrs (hours)
    /// - m, min (minutes)
    /// - s, sec, secs (seconds)
    /// - ms, millis (milliseconds)
    /// - us, µs, micros (microseconds)
    /// - ns, nanos (nanoseconds)
    ///
    /// - Parameters:
    ///   - userProvidedString: The string to parse
    ///
    /// - Throws: ValidationError if the string cannot be parsed
    public init(_ userProvidedString: String) throws {
        let lowercased = String(userProvidedString.filter { !$0.isWhitespace }).lowercased()
        let parsedNumbers = lowercased.prefix(while: { $0.isWholeNumber || $0 == "," || $0 == "." })
        let parsedUnit = String(lowercased.dropFirst(parsedNumbers.count))

        guard let numbers = Int64(parsedNumbers) else {
            throw ValidationError.invalidNumber("'\(userProvidedString)' cannot be parsed as number and unit")
        }

        switch parsedUnit {
        case "h", "hr", "hrs":
            self = .hours(numbers)
        case "m", "min":
            self = .minutes(numbers)
        case "s", "sec", "secs":
            self = .seconds(numbers)
        case "ms", "millis":
            self = .milliseconds(numbers)
        case "us", "µs", "micros":
            self = .microseconds(numbers)
        case "ns", "nanos":
            self = .nanoseconds(numbers)
        default:
            throw ValidationError.unsupportedUnit("Unknown unit '\(parsedUnit)' in '\(userProvidedString)'")
        }
    }

    /// Returns a human-readable string representation of the time amount
    /// using the most appropriate unit
    public var description: String {
        let fullNS = self.nanoseconds
        let (fullUS, remUS) = fullNS.quotientAndRemainder(dividingBy: 1_000)
        let (fullMS, remMS) = fullNS.quotientAndRemainder(dividingBy: 1_000_000)
        let (fullS, remS) = fullNS.quotientAndRemainder(dividingBy: 1_000_000_000)

        if remS == 0 {
            return "\(fullS) s"
        } else if remMS == 0 {
            return "\(fullMS) ms"
        } else if remUS == 0 {
            return "\(fullUS) us"
        } else {
            return "\(fullNS) ns"
        }
    }
}

extension TimeAmount: Comparable {
    @inlinable
    public static func < (lhs: TimeAmount, rhs: TimeAmount) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

extension TimeAmount: AdditiveArithmetic {
    /// The zero value for `TimeAmount`.
    @inlinable
    public static var zero: TimeAmount {
        TimeAmount.nanoseconds(0)
    }

    @inlinable
    public static func + (lhs: TimeAmount, rhs: TimeAmount) -> TimeAmount {
        TimeAmount(lhs.nanoseconds + rhs.nanoseconds)
    }

    @inlinable
    public static func += (lhs: inout TimeAmount, rhs: TimeAmount) {
        lhs = lhs + rhs
    }

    @inlinable
    public static func - (lhs: TimeAmount, rhs: TimeAmount) -> TimeAmount {
        TimeAmount(lhs.nanoseconds - rhs.nanoseconds)
    }

    @inlinable
    public static func -= (lhs: inout TimeAmount, rhs: TimeAmount) {
        lhs = lhs - rhs
    }

    @inlinable
    public static func * <T: BinaryInteger>(lhs: T, rhs: TimeAmount) -> TimeAmount {
        TimeAmount(Int64(lhs) * rhs.nanoseconds)
    }

    @inlinable
    public static func * <T: BinaryInteger>(lhs: TimeAmount, rhs: T) -> TimeAmount {
        TimeAmount(lhs.nanoseconds * Int64(rhs))
    }
}

/// Represents a point in time.
///
/// Stores the time in nanoseconds as returned by `DispatchTime.now().uptimeNanoseconds`
///
/// `NIODeadline` allow chaining multiple tasks with the same deadline without needing to
/// compute new timeouts for each step
///
/// ```
/// func doSomething(deadline: NIODeadline) -> EventLoopFuture<Void> {
///     return step1(deadline: deadline).flatMap {
///         step2(deadline: deadline)
///     }
/// }
/// doSomething(deadline: .now() + .seconds(5))
/// ```
///
/// - Note: `NIODeadline` should not be used to represent a time interval
public struct NIODeadline: Equatable, Hashable, Sendable {
    @available(*, deprecated, message: "This typealias doesn't serve any purpose, please use UInt64 directly.")
    public typealias Value = UInt64

    // This really should be an UInt63 but we model it as Int64 with >=0 assert
    @usableFromInline var _uptimeNanoseconds: Int64 {
        didSet {
            assert(self._uptimeNanoseconds >= 0)
        }
    }

    /// The nanoseconds since boot representation of the `NIODeadline`.
    @inlinable
    public var uptimeNanoseconds: UInt64 {
        .init(self._uptimeNanoseconds)
    }

    @inlinable
    public static var distantPast: NIODeadline { NIODeadline(0) }

    @inlinable
    public static var distantFuture: NIODeadline { NIODeadline(.init(Int64.max)) }

    @inlinable init(_ nanoseconds: Int64) {
        precondition(nanoseconds >= 0)
        self._uptimeNanoseconds = nanoseconds
    }

    /// Getting the time is a very common operation so it warrants optimization.
    ///
    /// Prior to this function, NIO relied on `DispatchTime.now()`, on all platforms. In addition to
    /// the overhead of making a library call, the underlying implementation has a lot of branches
    /// because `libdispatch` supports many more usecases than we are making use of here.
    ///
    /// On Linux, `DispachTime.now()` _always_ results in a simple call to `clock_gettime(3)` and so
    /// we make that call here, directly from NIO.
    ///
    /// - TODO: Investigate optimizing the call to `DispatchTime.now()` away on other platforms too.
    @inlinable
    static func timeNow() -> UInt64 {
        #if os(Linux)
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        /// We use unsafe arithmetic here because `UInt64.max` nanoseconds is more than 580 years,
        /// and the odds that this code will still be running 530 years from now is very, very low,
        /// so as a practical matter this will never overflow.
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
        #elseif os(WASI)
        var ts = timespec()
        CNIOWASI_gettime(&ts)
        /// We use unsafe arithmetic here because `UInt64.max` nanoseconds is more than 580 years,
        /// and the odds that this code will still be running 530 years from now is very, very low,
        /// so as a practical matter this will never overflow.
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
        #else
        return DispatchTime.now().uptimeNanoseconds
        #endif  // os(Linux)
    }

    @inlinable
    public static func now() -> NIODeadline {
        NIODeadline.uptimeNanoseconds(timeNow())
    }

    @inlinable
    public static func uptimeNanoseconds(_ nanoseconds: UInt64) -> NIODeadline {
        NIODeadline(Int64(min(UInt64(Int64.max), nanoseconds)))
    }

    @inlinable
    public static func == (lhs: NIODeadline, rhs: NIODeadline) -> Bool {
        lhs.uptimeNanoseconds == rhs.uptimeNanoseconds
    }

    @inlinable
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.uptimeNanoseconds)
    }
}

extension NIODeadline: Comparable {
    @inlinable
    public static func < (lhs: NIODeadline, rhs: NIODeadline) -> Bool {
        lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
    }

    @inlinable
    public static func > (lhs: NIODeadline, rhs: NIODeadline) -> Bool {
        lhs.uptimeNanoseconds > rhs.uptimeNanoseconds
    }
}

extension NIODeadline: CustomStringConvertible {
    @inlinable
    public var description: String {
        self.uptimeNanoseconds.description
    }
}

extension NIODeadline {
    @inlinable
    public static func - (lhs: NIODeadline, rhs: NIODeadline) -> TimeAmount {
        // This won't ever crash, NIODeadlines are guaranteed to be within 0 ..< 2^63-1 nanoseconds so the result can
        // definitely be stored in a TimeAmount (which is an Int64).
        .nanoseconds(Int64(lhs.uptimeNanoseconds) - Int64(rhs.uptimeNanoseconds))
    }

    @inlinable
    public static func + (lhs: NIODeadline, rhs: TimeAmount) -> NIODeadline {
        let partial: Int64
        let overflow: Bool
        (partial, overflow) = Int64(lhs.uptimeNanoseconds).addingReportingOverflow(rhs.nanoseconds)
        if overflow {
            assert(rhs.nanoseconds > 0)  // this certainly must have overflowed towards +infinity
            return NIODeadline.distantFuture
        }
        guard partial >= 0 else {
            return NIODeadline.uptimeNanoseconds(0)
        }
        return NIODeadline(partial)
    }

    @inlinable
    public static func - (lhs: NIODeadline, rhs: TimeAmount) -> NIODeadline {
        if rhs.nanoseconds < 0 {
            // The addition won't crash because the worst that could happen is `UInt64(Int64.max) + UInt64(Int64.max)`
            // which fits into an UInt64 (and will then be capped to Int64.max == distantFuture by `uptimeNanoseconds`).
            return NIODeadline.uptimeNanoseconds(lhs.uptimeNanoseconds + rhs.nanoseconds.magnitude)
        } else if rhs.nanoseconds > lhs.uptimeNanoseconds {
            // Cap it at `0` because otherwise this would be negative.
            return NIODeadline.init(0)
        } else {
            // This will be positive but still fix in an Int64.
            let result = Int64(lhs.uptimeNanoseconds) - rhs.nanoseconds
            assert(result >= 0)
            return NIODeadline(result)
        }
    }
}

extension EventLoop {
    /// Submit `task` to be run on this `EventLoop`.
    ///
    /// The returned `EventLoopFuture` will be completed when `task` has finished running. It will be succeeded with
    /// `task`'s return value or failed if the execution of `task` threw an error.
    ///
    /// - Parameters:
    ///   - task: The synchronous task to run. As everything that runs on the `EventLoop`, it must not block.
    /// - Returns: An `EventLoopFuture` containing the result of `task`'s execution.
    @inlinable
    @preconcurrency
    public func submit<T>(_ task: @escaping @Sendable () throws -> T) -> EventLoopFuture<T> {
        let promise: EventLoopPromise<T> = makePromise(file: #fileID, line: #line)

        self.execute {
            do {
                // UnsafeUnchecked is allowed here because we know we are on the EL.
                promise.assumeIsolatedUnsafeUnchecked().succeed(try task())
            } catch let err {
                promise.fail(err)
            }
        }

        return promise.futureResult
    }

    /// Submit `task` to be run on this `EventLoop`.
    ///
    /// The returned `EventLoopFuture` will be completed when `task` has finished running. It will be identical to
    /// the `EventLoopFuture` returned by `task`.
    ///
    /// - Parameters:
    ///   - task: The asynchronous task to run. As with everything that runs on the `EventLoop`, it must not block.
    /// - Returns: An `EventLoopFuture` identical to the `EventLoopFuture` returned from `task`.
    @inlinable
    @preconcurrency
    public func flatSubmit<T: Sendable>(_ task: @escaping @Sendable () -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        self.submit(task).flatMap { $0 }
    }

    /// Schedule a `task` that is executed by this `EventLoop` at the given time.
    ///
    /// - Note: The `T` must be `Sendable` since the isolation domains of the event loop future returned from `task` and
    /// this event loop might differ.
    ///
    /// - Parameters:
    ///   - deadline: The instant in time before which the task will not execute.
    ///   - file: The file this function was called in, for debugging purposes.
    ///   - line: The line this function was called on, for debugging purposes.
    ///   - task: The asynchronous task to run. As with everything that runs on the `EventLoop`, it must not block.
    /// - Returns: A `Scheduled` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the full execution of the task, including its returned `EventLoopFuture`.
    ///
    /// - Note: You can only cancel a task before it has started executing.
    @discardableResult
    @inlinable
    @preconcurrency
    public func flatScheduleTask<T: Sendable>(
        deadline: NIODeadline,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ task: @escaping @Sendable () throws -> EventLoopFuture<T>
    ) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = self.makePromise(file: file, line: line)
        let scheduled = self.scheduleTask(deadline: deadline, task)

        scheduled.futureResult.whenComplete { result in
            switch result {
            case .success(let futureResult):
                promise.completeWith(futureResult)
            case .failure(let error):
                promise.fail(error)
            }
        }

        return .init(promise: promise, cancellationTask: { scheduled.cancel() })
    }

    /// Schedule a `task` that is executed by this `EventLoop` after the given amount of time.
    ///
    /// - Note: The `T` must be `Sendable` since the isolation domains of the event loop future returned from `task` and
    /// this event loop might differ.
    ///
    /// - Parameters:
    ///   - delay: The amount of time before which the task will not execute.
    ///   - file: The file this function was called in, for debugging purposes.
    ///   - line: The line this function was called on, for debugging purposes.
    ///   - task: The asynchronous task to run. As everything that runs on the `EventLoop`, it must not block.
    /// - Returns: A `Scheduled` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the full execution of the task, including its returned `EventLoopFuture`.
    ///
    /// - Note: You can only cancel a task before it has started executing.
    @discardableResult
    @inlinable
    @preconcurrency
    public func flatScheduleTask<T: Sendable>(
        in delay: TimeAmount,
        file: StaticString = #fileID,
        line: UInt = #line,
        _ task: @escaping @Sendable () throws -> EventLoopFuture<T>
    ) -> Scheduled<T> {
        self._flatScheduleTask(in: delay, file: file, line: line, task)
    }

    @usableFromInline typealias FlatScheduleTaskDelayCallback<T> = @Sendable () throws -> EventLoopFuture<T>

    @inlinable
    func _flatScheduleTask<T: Sendable>(
        in delay: TimeAmount,
        file: StaticString,
        line: UInt,
        _ task: @escaping FlatScheduleTaskDelayCallback<T>
    ) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = self.makePromise(file: file, line: line)
        let scheduled = self.scheduleTask(in: delay, task)

        scheduled.futureResult.whenComplete { result in
            switch result {
            case .success(let futureResult):
                promise.completeWith(futureResult)
            case .failure(let error):
                promise.fail(error)
            }
        }

        return .init(promise: promise, cancellationTask: { scheduled.cancel() })
    }

    /// Creates and returns a new `EventLoopPromise` that will be notified using this `EventLoop` as execution `NIOThread`.
    @inlinable
    public func makePromise<T>(
        of type: T.Type = T.self,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> EventLoopPromise<T> {
        EventLoopPromise<T>(eventLoop: self, file: file, line: line)
    }

    /// Creates and returns a new `EventLoopFuture` that is already marked as failed. Notifications will be done using this `EventLoop` as execution `NIOThread`.
    ///
    /// - Parameters:
    ///   - error: the `Error` that is used by the `EventLoopFuture`.
    /// - Returns: a failed `EventLoopFuture`.
    @inlinable
    public func makeFailedFuture<T>(_ error: Error) -> EventLoopFuture<T> {
        EventLoopFuture<T>(eventLoop: self, error: error)
    }

    /// Creates and returns a new `EventLoopFuture` that is already marked as success. Notifications will be done using this `EventLoop` as execution `NIOThread`.
    ///
    /// - Parameters:
    ///   - value: the value that is used by the `EventLoopFuture`.
    /// - Returns: a succeeded `EventLoopFuture`.
    @preconcurrency
    @inlinable
    public func makeSucceededFuture<Success: Sendable>(_ value: Success) -> EventLoopFuture<Success> {
        if Success.self == Void.self {
            // The as! will always succeed because we previously checked that Success.self == Void.self.
            return self.makeSucceededVoidFuture() as! EventLoopFuture<Success>
        } else {
            return EventLoopFuture<Success>(eventLoop: self, value: value)
        }
    }

    /// Creates and returns a new isolated `EventLoopFuture` that is already marked as success. Notifications will be done using this `EventLoop.
    ///
    /// - Parameters:
    ///   - value: the value that is used by the `EventLoopFuture.Isolated`.
    /// - Returns: a succeeded `EventLoopFuture.Isolated`.
    @inlinable
    @available(*, noasync)
    public func makeSucceededIsolatedFuture<Success>(_ value: Success) -> EventLoopFuture<Success>.Isolated {
        if Success.self == Void.self {
            // The as! will always succeed because we previously checked that Success.self == Void.self.
            return self.makeSucceededVoidFuture().assumeIsolated() as! EventLoopFuture<Success>.Isolated
        } else {
            return EventLoopFuture.Isolated(_wrapped: EventLoopFuture(eventLoop: self, isolatedValue: value))
        }
    }

    /// Creates and returns a new `EventLoopFuture` that is marked as succeeded or failed with the value held by `result`.
    ///
    /// - Parameters:
    ///   - result: The value that is used by the `EventLoopFuture`
    /// - Returns: A completed `EventLoopFuture`.
    @preconcurrency
    @inlinable
    public func makeCompletedFuture<Success: Sendable>(_ result: Result<Success, Error>) -> EventLoopFuture<Success> {
        switch result {
        case .success(let value):
            return self.makeSucceededFuture(value)
        case .failure(let error):
            return self.makeFailedFuture(error)
        }
    }

    /// Creates and returns a new `EventLoopFuture` that is marked as succeeded or failed with the value returned by `body`.
    ///
    /// - Parameters:
    ///   - body: The function that is used to complete the `EventLoopFuture`
    /// - Returns: A completed `EventLoopFuture`.
    @preconcurrency
    @inlinable
    public func makeCompletedFuture<Success: Sendable>(
        withResultOf body: () throws -> Success
    ) -> EventLoopFuture<Success> {
        let trans = Result(catching: body)
        return self.makeCompletedFuture(trans)
    }

    /// An `EventLoop` forms a singular `EventLoopGroup`, returning itself as the 'next' `EventLoop`.
    ///
    /// - Returns: Itself, because an `EventLoop` forms a singular `EventLoopGroup`.
    public func next() -> EventLoop {
        self
    }

    /// An `EventLoop` forms a singular `EventLoopGroup`, returning itself as 'any' `EventLoop`.
    ///
    /// - Returns: Itself, because an `EventLoop` forms a singular `EventLoopGroup`.
    public func any() -> EventLoop {
        self
    }

    /// Close this `EventLoop`.
    public func close() throws {
        // Do nothing
    }

    /// Schedule a repeated task to be executed by the `EventLoop` with a fixed delay between the end and start of each
    /// task.
    ///
    /// - Parameters:
    ///   - initialDelay: The delay after which the first task is executed.
    ///   - delay: The delay between the end of one task and the start of the next.
    ///   - promise: If non-nil, a promise to fulfill when the task is cancelled and all execution is complete.
    ///   - task: The closure that will be executed.
    /// - return: `RepeatedTask`
    @discardableResult
    @preconcurrency
    public func scheduleRepeatedTask(
        initialDelay: TimeAmount,
        delay: TimeAmount,
        notifying promise: EventLoopPromise<Void>? = nil,
        _ task: @escaping @Sendable (RepeatedTask) throws -> Void
    ) -> RepeatedTask {
        self._scheduleRepeatedTask(initialDelay: initialDelay, delay: delay, notifying: promise, task)
    }

    /// Schedule a repeated task to be executed by the `EventLoop` with a fixed delay between the end and start of each
    /// task.
    ///
    /// - Parameters:
    ///   - initialDelay: The delay after which the first task is executed.
    ///   - delay: The delay between the end of one task and the start of the next.
    ///   - maximumAllowableJitter: Exclusive upper bound of jitter range added to the `delay` parameter.
    ///   - promise: If non-nil, a promise to fulfill when the task is cancelled and all execution is complete.
    ///   - task: The closure that will be executed.
    /// - return: `RepeatedTask`
    @discardableResult
    public func scheduleRepeatedTask(
        initialDelay: TimeAmount,
        delay: TimeAmount,
        maximumAllowableJitter: TimeAmount,
        notifying promise: EventLoopPromise<Void>? = nil,
        _ task: @escaping @Sendable (RepeatedTask) throws -> Void
    ) -> RepeatedTask {
        let jitteredInitialDelay = Self._getJitteredDelay(
            delay: initialDelay,
            maximumAllowableJitter: maximumAllowableJitter
        )
        let jitteredDelay = Self._getJitteredDelay(delay: delay, maximumAllowableJitter: maximumAllowableJitter)
        return self.scheduleRepeatedTask(
            initialDelay: jitteredInitialDelay,
            delay: jitteredDelay,
            notifying: promise,
            task
        )
    }
    typealias ScheduleRepeatedTaskCallback = @Sendable (RepeatedTask) throws -> Void

    func _scheduleRepeatedTask(
        initialDelay: TimeAmount,
        delay: TimeAmount,
        notifying promise: EventLoopPromise<Void>?,
        _ task: @escaping ScheduleRepeatedTaskCallback
    ) -> RepeatedTask {
        let futureTask: @Sendable (RepeatedTask) -> EventLoopFuture<Void> = { repeatedTask in
            do {
                try task(repeatedTask)
                return self.makeSucceededFuture(())
            } catch {
                return self.makeFailedFuture(error)
            }
        }
        return self.scheduleRepeatedAsyncTask(initialDelay: initialDelay, delay: delay, notifying: promise, futureTask)
    }

    /// Schedule a repeated asynchronous task to be executed by the `EventLoop` with a fixed delay between the end and
    /// start of each task.
    ///
    /// - Note: The delay is measured from the completion of one run's returned future to the start of the execution of
    ///         the next run. For example: If you schedule a task once per second but your task takes two seconds to
    ///         complete, the time interval between two subsequent runs will actually be three seconds (2s run time plus
    ///         the 1s delay.)
    ///
    /// - Parameters:
    ///   - initialDelay: The delay after which the first task is executed.
    ///   - delay: The delay between the end of one task and the start of the next.
    ///   - promise: If non-nil, a promise to fulfill when the task is cancelled and all execution is complete.
    ///   - task: The closure that will be executed. Task will keep repeating regardless of whether the future
    ///             gets fulfilled with success or error.
    ///
    /// - return: `RepeatedTask`
    @discardableResult
    @preconcurrency
    public func scheduleRepeatedAsyncTask(
        initialDelay: TimeAmount,
        delay: TimeAmount,
        notifying promise: EventLoopPromise<Void>? = nil,
        _ task: @escaping @Sendable (RepeatedTask) -> EventLoopFuture<Void>
    ) -> RepeatedTask {
        self._scheduleRepeatedAsyncTask(initialDelay: initialDelay, delay: delay, notifying: promise, task)
    }

    /// Schedule a repeated asynchronous task to be executed by the `EventLoop` with a fixed delay between the end and
    /// start of each task.
    ///
    /// - Note: The delay is measured from the completion of one run's returned future to the start of the execution of
    ///         the next run. For example: If you schedule a task once per second but your task takes two seconds to
    ///         complete, the time interval between two subsequent runs will actually be three seconds (2s run time plus
    ///         the 1s delay.)
    ///
    /// - Parameters:
    ///   - initialDelay: The delay after which the first task is executed.
    ///   - delay: The delay between the end of one task and the start of the next.
    ///   - maximumAllowableJitter: Exclusive upper bound of jitter range added to the `delay` parameter.
    ///   - promise: If non-nil, a promise to fulfill when the task is cancelled and all execution is complete.
    ///   - task: The closure that will be executed. Task will keep repeating regardless of whether the future
    ///             gets fulfilled with success or error.
    ///
    /// - return: `RepeatedTask`
    @discardableResult
    public func scheduleRepeatedAsyncTask(
        initialDelay: TimeAmount,
        delay: TimeAmount,
        maximumAllowableJitter: TimeAmount,
        notifying promise: EventLoopPromise<Void>? = nil,
        _ task: @escaping @Sendable (RepeatedTask) -> EventLoopFuture<Void>
    ) -> RepeatedTask {
        let jitteredInitialDelay = Self._getJitteredDelay(
            delay: initialDelay,
            maximumAllowableJitter: maximumAllowableJitter
        )
        let jitteredDelay = Self._getJitteredDelay(delay: delay, maximumAllowableJitter: maximumAllowableJitter)
        return self._scheduleRepeatedAsyncTask(
            initialDelay: jitteredInitialDelay,
            delay: jitteredDelay,
            notifying: promise,
            task
        )
    }
    typealias ScheduleRepeatedAsyncTaskCallback = @Sendable (RepeatedTask) -> EventLoopFuture<Void>

    func _scheduleRepeatedAsyncTask(
        initialDelay: TimeAmount,
        delay: TimeAmount,
        notifying promise: EventLoopPromise<Void>?,
        _ task: @escaping ScheduleRepeatedAsyncTaskCallback
    ) -> RepeatedTask {
        let repeated = RepeatedTask(interval: delay, eventLoop: self, cancellationPromise: promise, task: task)
        repeated.begin(in: initialDelay)
        return repeated
    }

    /// Adds a random amount of `.nanoseconds` (within `.zero..<maximumAllowableJitter`) to the delay.
    ///
    /// - Parameters:
    ///   - delay: the `TimeAmount` delay to jitter.
    ///   - maximumAllowableJitter: Exclusive upper bound of jitter range added to the `delay` parameter.
    /// - Returns: The jittered delay.
    @inlinable
    static func _getJitteredDelay(
        delay: TimeAmount,
        maximumAllowableJitter: TimeAmount
    ) -> TimeAmount {
        let jitter = TimeAmount.nanoseconds(Int64.random(in: .zero..<maximumAllowableJitter.nanoseconds))
        return delay + jitter
    }

    /// Returns an `EventLoopIterator` over this `EventLoop`.
    ///
    /// - Returns: `EventLoopIterator`
    public func makeIterator() -> EventLoopIterator {
        EventLoopIterator([self])
    }

    /// Asserts that the current thread is the one tied to this `EventLoop`.
    /// Otherwise, if running in debug mode, the process will be abnormally terminated as per the semantics of
    /// `preconditionFailure(_:file:line:)`. Never has any effect in release mode.
    ///
    /// - Note: This is not a customization point so calls to this function can be fully optimized out in release mode.
    @inlinable
    public func assertInEventLoop(file: StaticString = #fileID, line: UInt = #line) {
        debugOnly {
            self.preconditionInEventLoop(file: file, line: line)
        }
    }

    /// Asserts that the current thread is _not_ the one tied to this `EventLoop`.
    /// Otherwise, if running in debug mode, the process will be abnormally terminated as per the semantics of
    /// `preconditionFailure(_:file:line:)`. Never has any effect in release mode.
    ///
    /// - Note: This is not a customization point so calls to this function can be fully optimized out in release mode.
    @inlinable
    public func assertNotInEventLoop(file: StaticString = #fileID, line: UInt = #line) {
        debugOnly {
            self.preconditionNotInEventLoop(file: file, line: line)
        }
    }

    /// Checks the necessary condition of currently running on the called `EventLoop` for making forward progress.
    @inlinable
    public func preconditionInEventLoop(file: StaticString = #fileID, line: UInt = #line) {
        precondition(self.inEventLoop, file: file, line: line)
    }

    /// Checks the necessary condition of currently _not_ running on the called `EventLoop` for making forward progress.
    @inlinable
    public func preconditionNotInEventLoop(file: StaticString = #fileID, line: UInt = #line) {
        precondition(!self.inEventLoop, file: file, line: line)
    }
}

/// Provides an endless stream of `EventLoop`s to use.
public protocol EventLoopGroup: AnyObject, _NIOPreconcurrencySendable {
    /// Returns the next `EventLoop` to use, this is useful for load balancing.
    ///
    /// The algorithm that is used to select the next `EventLoop` is specific to each `EventLoopGroup`. A common choice
    /// is _round robin_.
    ///
    /// Please note that you should only be using `next()` if you want to load balance over all `EventLoop`s of the
    /// `EventLoopGroup`. If the actual `EventLoop` does not matter much, `any()` should be preferred because it can
    /// try to return you the _current_ `EventLoop` which usually is faster because the number of thread switches can
    /// be reduced.
    ///
    /// The rule of thumb is: If you are trying to do _load balancing_, use `next()`. If you just want to create a new
    /// future or kick off some operation, use `any()`.

    func next() -> EventLoop

    /// Returns any `EventLoop` from the `EventLoopGroup`, a common choice is the current `EventLoop`.
    ///
    /// - warning: You cannot rely on the returned `EventLoop` being the current one, not all `EventLoopGroup`s support
    ///            choosing the current one. Use this method only if you are truly happy with _any_ `EventLoop` of this
    ///            `EventLoopGroup` instance.
    ///
    /// - Note: You will only receive the current `EventLoop` here iff the current `EventLoop` belongs to the
    ///         `EventLoopGroup` you call `any()` on.
    ///
    /// This method is useful having access to an `EventLoopGroup` without the knowledge of which `EventLoop` would be
    /// the best one to select to create a new `EventLoopFuture`. This commonly happens in libraries where the user
    /// cannot indicate what `EventLoop` they would like their futures on.
    ///
    /// Typically, it is faster to kick off a new operation on the _current_ `EventLoop` because that minimised thread
    /// switches. Hence, if situations where you don't need precise knowledge of what `EventLoop` some code is running
    /// on, use `any()` to indicate this.
    ///
    /// The rule of thumb is: If you are trying to do _load balancing_, use `next()`. If you just want to create a new
    /// future or kick off some operation, use `any()`.
    func any() -> EventLoop

    #if canImport(Dispatch)
    /// Shuts down the eventloop gracefully. This function is clearly an outlier in that it uses a completion
    /// callback instead of an EventLoopFuture. The reason for that is that NIO's EventLoopFutures will call back on an event loop.
    /// The virtue of this function is to shut the event loop down. To work around that we call back on a DispatchQueue
    /// instead.
    @preconcurrency func shutdownGracefully(queue: DispatchQueue, _ callback: @Sendable @escaping (Error?) -> Void)
    #endif

    /// Returns an `EventLoopIterator` over the `EventLoop`s in this `EventLoopGroup`.
    ///
    /// - Returns: `EventLoopIterator`
    func makeIterator() -> EventLoopIterator

    /// Must crash if it's not safe to call `syncShutdownGracefully` in the current context.
    ///
    /// This method is a debug hook that can be used to override the behaviour of `syncShutdownGracefully`
    /// when called. By default it does nothing.
    func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt)
}

extension EventLoopGroup {
    /// The default implementation of `any()` just returns the `next()` EventLoop but it's highly recommended to
    /// override this and return the current `EventLoop` if possible.
    public func any() -> EventLoop {
        self.next()
    }
}

#if canImport(Dispatch)
extension EventLoopGroup {
    @preconcurrency public func shutdownGracefully(_ callback: @escaping @Sendable (Error?) -> Void) {
        self.shutdownGracefully(queue: .global(), callback)
    }

    @available(*, noasync, message: "this can end up blocking the calling thread", renamed: "shutdownGracefully()")
    public func syncShutdownGracefully() throws {
        try self._syncShutdownGracefully()
    }

    private func _syncShutdownGracefully() throws {
        self._preconditionSafeToSyncShutdown(file: #fileID, line: #line)
        let error = NIOLockedValueBox<Error?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        self.shutdownGracefully { shutdownError in
            if let shutdownError = shutdownError {
                error.withLockedValue {
                    $0 = shutdownError
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        try error.withLockedValue { error in
            if let error = error {
                throw error
            }
        }
    }

    public func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt) {
        return
    }
}
#endif

/// Deprecated.
///
/// This type was intended to be used by libraries which use NIO, and offer their users either the option
/// to `.share` an existing event loop group or create (and manage) a new one (`.createNew`) and let it be
/// managed by given library and its lifecycle.
///
/// Please use a `group: any EventLoopGroup` parameter instead. If you want to default to a global
/// singleton group instead, consider group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton` or
/// similar.
///
/// - See also: https://github.com/apple/swift-nio/issues/2142
public enum NIOEventLoopGroupProvider {
    /// Use an `EventLoopGroup` provided by the user.
    /// The owner of this group is responsible for its lifecycle.
    case shared(EventLoopGroup)

    /// Deprecated. Create a new `EventLoopGroup` when necessary.
    /// The library which accepts this provider takes ownership of the created event loop group,
    /// and must ensure its proper shutdown when the library is being shut down.
    @available(
        *,
        deprecated,
        message: """
            Please use `.shared(existingGroup)` or use the singleton via \
            `.shared(MultiThreadedEventLoopGroup.singleton)` or similar
            """
    )
    case createNew
}

extension NIOEventLoopGroupProvider: Sendable {}

/// Different `Error`s that are specific to `EventLoop` operations / implementations.
public enum EventLoopError: Error {
    /// An operation was executed that is not supported by the `EventLoop`
    case unsupportedOperation

    /// An scheduled task was cancelled.
    case cancelled

    /// The `EventLoop` was shutdown already.
    case shutdown

    /// Shutting down the `EventLoop` failed.
    case shutdownFailed
}

extension EventLoopError {
    @usableFromInline
    static let _cancelled: any Error = EventLoopError.cancelled
}

extension EventLoopError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unsupportedOperation:
            return "EventLoopError: the executed operation is not supported by the event loop"
        case .cancelled:
            return "EventLoopError: the scheduled task was cancelled"
        case .shutdown:
            return "EventLoopError: the event loop is shutdown"
        case .shutdownFailed:
            return "EventLoopError: failed to shutdown the event loop"
        }
    }
}
