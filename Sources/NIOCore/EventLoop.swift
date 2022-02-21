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
import Dispatch

/// Returned once a task was scheduled on the `EventLoop` for later execution.
///
/// A `Scheduled` allows the user to either `cancel()` the execution of the scheduled task (if possible) or obtain a reference to the `EventLoopFuture` that
/// will be notified once the execution is complete.
public struct Scheduled<T> {
    /* private but usableFromInline */ @usableFromInline let _promise: EventLoopPromise<T>
    /* private but usableFromInline */ @usableFromInline let _cancellationTask: (() -> Void)

    @inlinable
    public init(promise: EventLoopPromise<T>, cancellationTask: @escaping () -> Void) {
        self._promise = promise
        self._cancellationTask = cancellationTask
    }

    /// Try to cancel the execution of the scheduled task.
    ///
    /// Whether this is successful depends on whether the execution of the task already begun.
    ///  This means that cancellation is not guaranteed.
    @inlinable
    public func cancel() {
        self._promise.fail(EventLoopError.cancelled)
        self._cancellationTask()
    }

    /// Returns the `EventLoopFuture` which will be notified once the execution of the scheduled task completes.
    @inlinable
    public var futureResult: EventLoopFuture<T> {
        return self._promise.futureResult
    }
}

/// Returned once a task was scheduled to be repeatedly executed on the `EventLoop`.
///
/// A `RepeatedTask` allows the user to `cancel()` the repeated scheduling of further tasks.
public final class RepeatedTask {
    private let delay: TimeAmount
    private let eventLoop: EventLoop
    private let cancellationPromise: EventLoopPromise<Void>?
    private var scheduled: Optional<Scheduled<EventLoopFuture<Void>>>
    private var task: Optional<(RepeatedTask) -> EventLoopFuture<Void>>

    internal init(interval: TimeAmount, eventLoop: EventLoop, cancellationPromise: EventLoopPromise<Void>? = nil, task: @escaping (RepeatedTask) -> EventLoopFuture<Void>) {
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
    /// - returns: The next `EventLoop` if a next element exists; otherwise, `nil`.
    public mutating func next() -> EventLoop? {
        return self.eventLoops.next()
    }
}

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
    var inEventLoop: Bool { get }

    /// Submit a given task to be executed by the `EventLoop`
    func execute(_ task: @escaping () -> Void)

    /// Submit a given task to be executed by the `EventLoop`. Once the execution is complete the returned `EventLoopFuture` is notified.
    ///
    /// - parameters:
    ///     - task: The closure that will be submitted to the `EventLoop` for execution.
    /// - returns: `EventLoopFuture` that is notified once the task was executed.
    func submit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T>

    /// Schedule a `task` that is executed by this `EventLoop` at the given time.
    ///
    /// - parameters:
    ///     - task: The synchronous task to run. As with everything that runs on the `EventLoop`, it must not block.
    /// - returns: A `Scheduled` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the completion of the task.
    ///
    /// - note: You can only cancel a task before it has started executing.
    @discardableResult
    func scheduleTask<T>(deadline: NIODeadline, _ task: @escaping () throws -> T) -> Scheduled<T>

    /// Schedule a `task` that is executed by this `EventLoop` after the given amount of time.
    ///
    /// - parameters:
    ///     - task: The synchronous task to run. As with everything that runs on the `EventLoop`, it must not block.
    /// - returns: A `Scheduled` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the completion of the task.
    ///
    /// - note: You can only cancel a task before it has started executing.
    /// - note: The `in` value is clamped to a maximum when running on a Darwin-kernel.
    @discardableResult
    func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T>

    /// Asserts that the current thread is the one tied to this `EventLoop`.
    /// Otherwise, the process will be abnormally terminated as per the semantics of `preconditionFailure(_:file:line:)`.
    func preconditionInEventLoop(file: StaticString, line: UInt)

    /// Asserts that the current thread is _not_ the one tied to this `EventLoop`.
    /// Otherwise, the process will be abnormally terminated as per the semantics of `preconditionFailure(_:file:line:)`.
    func preconditionNotInEventLoop(file: StaticString, line: UInt)

    /// Return a succeeded `Void` future.
    ///
    /// Semantically, this function is equivalent to calling `makeSucceededFuture(())`.
    /// Contrary to `makeSucceededFuture`, `makeSucceededVoidFuture` is a customization point for `EventLoop`s which
    /// allows `EventLoop`s to cache a pre-succeeded `Void` future to prevent superfluous allocations.
    func makeSucceededVoidFuture() -> EventLoopFuture<Void>

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
}

extension EventLoop {
    /// Default implementation of `makeSucceededVoidFuture`: Return a fresh future (which will allocate).
    public func makeSucceededVoidFuture() -> EventLoopFuture<Void> {
        return EventLoopFuture(eventLoop: self, value: ())
    }

    public func _preconditionSafeToWait(file: StaticString, line: UInt) {
        self.preconditionNotInEventLoop(file: file, line: line)
    }

    /// Default implementation of `_promiseCreated`: does nothing.
    public func _promiseCreated(futureIdentifier: _NIOEventLoopFutureIdentifier, file: StaticString, line: UInt) {
        return
    }

    /// Default implementation of `_promiseCompleted`: does nothing.
    public func _promiseCompleted(futureIdentifier: _NIOEventLoopFutureIdentifier) -> (file: StaticString, line: UInt)? {
        return nil
    }
}

extension EventLoopGroup {
    public var description: String {
        return String(describing: self)
    }
}

/// Represents a time _interval_.
///
/// - note: `TimeAmount` should not be used to represent a point in time.
public struct TimeAmount: Hashable {
    @available(*, deprecated, message: "This typealias doesn't serve any purpose. Please use Int64 directly.")
    public typealias Value = Int64

    /// The nanoseconds representation of the `TimeAmount`.
    public let nanoseconds: Int64

    private init(_ nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    /// Creates a new `TimeAmount` for the given amount of nanoseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of nanoseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func nanoseconds(_ amount: Int64) -> TimeAmount {
        return TimeAmount(amount)
    }

    /// Creates a new `TimeAmount` for the given amount of microseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of microseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func microseconds(_ amount: Int64) -> TimeAmount {
        return TimeAmount(amount * 1000)
    }

    /// Creates a new `TimeAmount` for the given amount of milliseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of milliseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func milliseconds(_ amount: Int64) -> TimeAmount {
        return TimeAmount(amount * (1000 * 1000))
    }

    /// Creates a new `TimeAmount` for the given amount of seconds.
    ///
    /// - parameters:
    ///     - amount: the amount of seconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func seconds(_ amount: Int64) -> TimeAmount {
        return TimeAmount(amount * (1000 * 1000 * 1000))
    }

    /// Creates a new `TimeAmount` for the given amount of minutes.
    ///
    /// - parameters:
    ///     - amount: the amount of minutes this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func minutes(_ amount: Int64) -> TimeAmount {
        return TimeAmount(amount * (1000 * 1000 * 1000 * 60))
    }

    /// Creates a new `TimeAmount` for the given amount of hours.
    ///
    /// - parameters:
    ///     - amount: the amount of hours this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func hours(_ amount: Int64) -> TimeAmount {
        return TimeAmount(amount * (1000 * 1000 * 1000 * 60 * 60))
    }
}

extension TimeAmount: Comparable {
    public static func < (lhs: TimeAmount, rhs: TimeAmount) -> Bool {
        return lhs.nanoseconds < rhs.nanoseconds
    }
}

extension TimeAmount: AdditiveArithmetic {
    /// The zero value for `TimeAmount`.
    public static var zero: TimeAmount {
        return TimeAmount.nanoseconds(0)
    }

    public static func + (lhs: TimeAmount, rhs: TimeAmount) -> TimeAmount {
        return TimeAmount(lhs.nanoseconds + rhs.nanoseconds)
    }

    public static func +=(lhs: inout TimeAmount, rhs: TimeAmount) {
        lhs = lhs + rhs
    }

    public static func - (lhs: TimeAmount, rhs: TimeAmount) -> TimeAmount {
        return TimeAmount(lhs.nanoseconds - rhs.nanoseconds)
    }

    public static func -=(lhs: inout TimeAmount, rhs: TimeAmount) {
        lhs = lhs - rhs
    }

    public static func * <T: BinaryInteger>(lhs: T, rhs: TimeAmount) -> TimeAmount {
        return TimeAmount(Int64(lhs) * rhs.nanoseconds)
    }

    public static func * <T: BinaryInteger>(lhs: TimeAmount, rhs: T) -> TimeAmount {
        return TimeAmount(lhs.nanoseconds * Int64(rhs))
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
/// - note: `NIODeadline` should not be used to represent a time interval
public struct NIODeadline: Equatable, Hashable {
    @available(*, deprecated, message: "This typealias doesn't serve any purpose, please use UInt64 directly.")
    public typealias Value = UInt64

    // This really should be an UInt63 but we model it as Int64 with >=0 assert
    private var _uptimeNanoseconds: Int64 {
        didSet {
            assert(self._uptimeNanoseconds >= 0)
        }
    }

    /// The nanoseconds since boot representation of the `NIODeadline`.
    public var uptimeNanoseconds: UInt64 {
        return .init(self._uptimeNanoseconds)
    }

    public static let distantPast = NIODeadline(0)
    public static let distantFuture = NIODeadline(.init(Int64.max))

    private init(_ nanoseconds: Int64) {
        precondition(nanoseconds >= 0)
        self._uptimeNanoseconds = nanoseconds
    }

    public static func now() -> NIODeadline {
        return NIODeadline.uptimeNanoseconds(DispatchTime.now().uptimeNanoseconds)
    }

    public static func uptimeNanoseconds(_ nanoseconds: UInt64) -> NIODeadline {
        return NIODeadline(Int64(min(UInt64(Int64.max), nanoseconds)))
    }
}

extension NIODeadline: Comparable {
    public static func < (lhs: NIODeadline, rhs: NIODeadline) -> Bool {
        return lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
    }

    public static func > (lhs: NIODeadline, rhs: NIODeadline) -> Bool {
        return lhs.uptimeNanoseconds > rhs.uptimeNanoseconds
    }
}

extension NIODeadline: CustomStringConvertible {
    public var description: String {
        return self.uptimeNanoseconds.description
    }
}

extension NIODeadline {
    public static func - (lhs: NIODeadline, rhs: NIODeadline) -> TimeAmount {
        // This won't ever crash, NIODeadlines are guaranteed to be within 0 ..< 2^63-1 nanoseconds so the result can
        // definitely be stored in a TimeAmount (which is an Int64).
        return .nanoseconds(Int64(lhs.uptimeNanoseconds) - Int64(rhs.uptimeNanoseconds))
    }

    public static func + (lhs: NIODeadline, rhs: TimeAmount) -> NIODeadline {
        let partial: Int64
        let overflow: Bool
        (partial, overflow) = Int64(lhs.uptimeNanoseconds).addingReportingOverflow(rhs.nanoseconds)
        if overflow {
            assert(rhs.nanoseconds > 0) // this certainly must have overflowed towards +infinity
            return NIODeadline.distantFuture
        }
        guard partial >= 0 else {
            return NIODeadline.uptimeNanoseconds(0)
        }
        return NIODeadline(partial)
    }

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
    /// - parameters:
    ///     - task: The synchronous task to run. As everything that runs on the `EventLoop`, it must not block.
    /// - returns: An `EventLoopFuture` containing the result of `task`'s execution.
    @inlinable
    public func submit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        let promise: EventLoopPromise<T> = makePromise(file: #file, line: #line)

        self.execute {
            do {
                promise.succeed(try task())
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
    /// - parameters:
    ///     - task: The asynchronous task to run. As with everything that runs on the `EventLoop`, it must not block.
    /// - returns: An `EventLoopFuture` identical to the `EventLoopFuture` returned from `task`.
    @inlinable
    public func flatSubmit<T>(_ task: @escaping () -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        return self.submit(task).flatMap { $0 }
    }

    /// Schedule a `task` that is executed by this `EventLoop` at the given time.
    ///
    /// - parameters:
    ///     - task: The asynchronous task to run. As with everything that runs on the `EventLoop`, it must not block.
    /// - returns: A `Scheduled` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the full execution of the task, including its returned `EventLoopFuture`.
    ///
    /// - note: You can only cancel a task before it has started executing.
    @discardableResult
    @inlinable
    public func flatScheduleTask<T>(deadline: NIODeadline,
                                    file: StaticString = #file,
                                    line: UInt = #line,
                                    _ task: @escaping () throws -> EventLoopFuture<T>) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = self.makePromise(file:#file, line: line)
        let scheduled = self.scheduleTask(deadline: deadline, task)

        scheduled.futureResult.flatMap { $0 }.cascade(to: promise)
        return .init(promise: promise, cancellationTask: { scheduled.cancel() })
    }

    /// Schedule a `task` that is executed by this `EventLoop` after the given amount of time.
    ///
    /// - parameters:
    ///     - task: The asynchronous task to run. As everything that runs on the `EventLoop`, it must not block.
    /// - returns: A `Scheduled` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the full execution of the task, including its returned `EventLoopFuture`.
    ///
    /// - note: You can only cancel a task before it has started executing.
    @discardableResult
    @inlinable
    public func flatScheduleTask<T>(in delay: TimeAmount,
                                    file: StaticString = #file,
                                    line: UInt = #line,
                                    _ task: @escaping () throws -> EventLoopFuture<T>) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = self.makePromise(file: file, line: line)
        let scheduled = self.scheduleTask(in: delay, task)

        scheduled.futureResult.flatMap { $0 }.cascade(to: promise)
        return .init(promise: promise, cancellationTask: { scheduled.cancel() })
    }

    /// Creates and returns a new `EventLoopPromise` that will be notified using this `EventLoop` as execution `NIOThread`.
    @inlinable
    public func makePromise<T>(of type: T.Type = T.self, file: StaticString = #file, line: UInt = #line) -> EventLoopPromise<T> {
        return EventLoopPromise<T>(eventLoop: self, file: file, line: line)
    }

    /// Creates and returns a new `EventLoopFuture` that is already marked as failed. Notifications will be done using this `EventLoop` as execution `NIOThread`.
    ///
    /// - parameters:
    ///     - error: the `Error` that is used by the `EventLoopFuture`.
    /// - returns: a failed `EventLoopFuture`.
    @inlinable
    public func makeFailedFuture<T>(_ error: Error) -> EventLoopFuture<T> {
        return EventLoopFuture<T>(eventLoop: self, error: error)
    }

    /// Creates and returns a new `EventLoopFuture` that is already marked as success. Notifications will be done using this `EventLoop` as execution `NIOThread`.
    ///
    /// - parameters:
    ///     - result: the value that is used by the `EventLoopFuture`.
    /// - returns: a succeeded `EventLoopFuture`.
    @inlinable
    public func makeSucceededFuture<Success>(_ value: Success) -> EventLoopFuture<Success> {
        if Success.self == Void.self {
            // The as! will always succeed because we previously checked that Success.self == Void.self.
            return self.makeSucceededVoidFuture() as! EventLoopFuture<Success>
        } else {
            return EventLoopFuture<Success>(eventLoop: self, value: value)
        }
    }

    /// Creates and returns a new `EventLoopFuture` that is marked as succeeded or failed with the value held by `result`.
    ///
    /// - Parameters:
    ///   - result: The value that is used by the `EventLoopFuture`
    /// - Returns: A completed `EventLoopFuture`.
    @inlinable
    public func makeCompletedFuture<Success>(_ result: Result<Success, Error>) -> EventLoopFuture<Success> {
        switch result {
        case .success(let value):
            return self.makeSucceededFuture(value)
        case .failure(let error):
            return self.makeFailedFuture(error)
        }
    }

    /// An `EventLoop` forms a singular `EventLoopGroup`, returning itself as the 'next' `EventLoop`.
    ///
    /// - returns: Itself, because an `EventLoop` forms a singular `EventLoopGroup`.
    public func next() -> EventLoop {
        return self
    }

    /// An `EventLoop` forms a singular `EventLoopGroup`, returning itself as 'any' `EventLoop`.
    ///
    /// - returns: Itself, because an `EventLoop` forms a singular `EventLoopGroup`.
    public func any() -> EventLoop {
        return self
    }

    /// Close this `EventLoop`.
    public func close() throws {
        // Do nothing
    }

    /// Schedule a repeated task to be executed by the `EventLoop` with a fixed delay between the end and start of each
    /// task.
    ///
    /// - parameters:
    ///     - initialDelay: The delay after which the first task is executed.
    ///     - delay: The delay between the end of one task and the start of the next.
    ///     - promise: If non-nil, a promise to fulfill when the task is cancelled and all execution is complete.
    ///     - task: The closure that will be executed.
    /// - return: `RepeatedTask`
    @discardableResult
    public func scheduleRepeatedTask(initialDelay: TimeAmount, delay: TimeAmount, notifying promise: EventLoopPromise<Void>? = nil, _ task: @escaping (RepeatedTask) throws -> Void) -> RepeatedTask {
        let futureTask: (RepeatedTask) -> EventLoopFuture<Void> = { repeatedTask in
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
    /// - note: The delay is measured from the completion of one run's returned future to the start of the execution of
    ///         the next run. For example: If you schedule a task once per second but your task takes two seconds to
    ///         complete, the time interval between two subsequent runs will actually be three seconds (2s run time plus
    ///         the 1s delay.)
    ///
    /// - parameters:
    ///     - initialDelay: The delay after which the first task is executed.
    ///     - delay: The delay between the end of one task and the start of the next.
    ///     - promise: If non-nil, a promise to fulfill when the task is cancelled and all execution is complete.
    ///     - task: The closure that will be executed. Task will keep repeating regardless of whether the future
    ///             gets fulfilled with success or error.
    ///
    /// - return: `RepeatedTask`
    @discardableResult
    public func scheduleRepeatedAsyncTask(initialDelay: TimeAmount,
                                          delay: TimeAmount,
                                          notifying promise: EventLoopPromise<Void>? = nil,
                                          _ task: @escaping (RepeatedTask) -> EventLoopFuture<Void>) -> RepeatedTask {
        let repeated = RepeatedTask(interval: delay, eventLoop: self, cancellationPromise: promise, task: task)
        repeated.begin(in: initialDelay)
        return repeated
    }

    /// Returns an `EventLoopIterator` over this `EventLoop`.
    ///
    /// - returns: `EventLoopIterator`
    public func makeIterator() -> EventLoopIterator {
        return EventLoopIterator([self])
    }

    /// Asserts that the current thread is the one tied to this `EventLoop`.
    /// Otherwise, if running in debug mode, the process will be abnormally terminated as per the semantics of
    /// `preconditionFailure(_:file:line:)`. Never has any effect in release mode.
    ///
    /// - note: This is not a customization point so calls to this function can be fully optimized out in release mode.
    @inlinable
    public func assertInEventLoop(file: StaticString = #file, line: UInt = #line) {
        debugOnly {
            self.preconditionInEventLoop(file: file, line: line)
        }
    }

    /// Asserts that the current thread is _not_ the one tied to this `EventLoop`.
    /// Otherwise, if running in debug mode, the process will be abnormally terminated as per the semantics of
    /// `preconditionFailure(_:file:line:)`. Never has any effect in release mode.
    ///
    /// - note: This is not a customization point so calls to this function can be fully optimized out in release mode.
    @inlinable
    public func assertNotInEventLoop(file: StaticString = #file, line: UInt = #line) {
        debugOnly {
            self.preconditionNotInEventLoop(file: file, line: line)
        }
    }

    /// Checks the necessary condition of currently running on the called `EventLoop` for making forward progress.
    @inlinable
    public func preconditionInEventLoop(file: StaticString = #file, line: UInt = #line) {
        precondition(self.inEventLoop, file: file, line: line)
    }

    /// Checks the necessary condition of currently _not_ running on the called `EventLoop` for making forward progress.
    @inlinable
    public func preconditionNotInEventLoop(file: StaticString = #file, line: UInt = #line) {
        precondition(!self.inEventLoop, file: file, line: line)
    }
}

/// Provides an endless stream of `EventLoop`s to use.
public protocol EventLoopGroup: AnyObject {
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
    /// - note: You will only receive the current `EventLoop` here iff the current `EventLoop` belongs to the
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

    /// Shuts down the eventloop gracefully. This function is clearly an outlier in that it uses a completion
    /// callback instead of an EventLoopFuture. The reason for that is that NIO's EventLoopFutures will call back on an event loop.
    /// The virtue of this function is to shut the event loop down. To work around that we call back on a DispatchQueue
    /// instead.
    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void)

    /// Returns an `EventLoopIterator` over the `EventLoop`s in this `EventLoopGroup`.
    ///
    /// - returns: `EventLoopIterator`
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
        return self.next()
    }
}

extension EventLoopGroup {
    public func shutdownGracefully(_ callback: @escaping (Error?) -> Void) {
        self.shutdownGracefully(queue: .global(), callback)
    }

    public func syncShutdownGracefully() throws {
        self._preconditionSafeToSyncShutdown(file: #file, line: #line)

        let errorStorageLock = Lock()
        var errorStorage: Error? = nil
        let continuation = DispatchWorkItem {}
        self.shutdownGracefully { error in
            if let error = error {
                errorStorageLock.withLock {
                    errorStorage = error
                }
            }
            continuation.perform()
        }
        continuation.wait()
        try errorStorageLock.withLock {
            if let error = errorStorage {
                throw error
            }
        }
    }

    public func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt) {
        return
    }
}

/// This type is intended to be used by libraries which use NIO, and offer their users either the option
/// to `.share` an existing event loop group or create (and manage) a new one (`.createNew`) and let it be
/// managed by given library and its lifecycle.
public enum NIOEventLoopGroupProvider {
    /// Use an `EventLoopGroup` provided by the user.
    /// The owner of this group is responsible for its lifecycle.
    case shared(EventLoopGroup)
    /// Create a new `EventLoopGroup` when necessary.
    /// The library which accepts this provider takes ownership of the created event loop group,
    /// and must ensure its proper shutdown when the library is being shut down.
    case createNew
}

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
