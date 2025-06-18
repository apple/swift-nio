//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// A struct wrapping an ``EventLoop`` that ensures all calls to any method on this struct
/// are coming from the event loop.
///
/// This type is explicitly not `Sendable`. It may only be constructed on an event loop,
/// using ``EventLoop/assumeIsolated()``, and may not subsequently be passed to other isolation
/// domains.
///
/// Using this type relaxes the need to have the closures for ``EventLoop/execute(_:)``,
/// ``EventLoop/submit(_:)``, ``EventLoop/scheduleTask(in:_:)``,
/// and ``EventLoop/scheduleCallback(in:handler:)`` to be `@Sendable`.
public struct NIOIsolatedEventLoop {
    @usableFromInline
    let _wrapped: EventLoop

    @inlinable
    internal init(_ eventLoop: EventLoop) {
        self._wrapped = eventLoop
    }

    /// Submit a given task to be executed by the `EventLoop`
    @available(*, noasync)
    @inlinable
    public func execute(_ task: @escaping () -> Void) {
        self._wrapped._executeIsolatedUnsafeUnchecked(task)
    }

    /// Submit a given task to be executed by the `EventLoop`. Once the execution is complete the returned `EventLoopFuture` is notified.
    ///
    /// - Parameters:
    ///   - task: The closure that will be submitted to the `EventLoop` for execution.
    /// - Returns: `EventLoopFuture` that is notified once the task was executed.
    @available(*, noasync)
    @inlinable
    public func submit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        self._wrapped._submitIsolatedUnsafeUnchecked(task)
    }

    /// Schedule a `task` that is executed by this `EventLoop` at the given time.
    ///
    /// - Parameters:
    ///   - deadline: The time at which the task should run.
    ///   - task: The synchronous task to run. As with everything that runs on the `EventLoop`, it must not block.
    /// - Returns: A `Scheduled` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the completion of the task.
    ///
    /// - Note: You can only cancel a task before it has started executing.
    @discardableResult
    @available(*, noasync)
    @inlinable
    public func scheduleTask<T>(
        deadline: NIODeadline,
        _ task: @escaping () throws -> T
    ) -> Scheduled<T> {
        self._wrapped._scheduleTaskIsolatedUnsafeUnchecked(deadline: deadline, task)
    }

    /// Schedule a `task` that is executed by this `EventLoop` after the given amount of time.
    ///
    /// - Parameters:
    ///   - delay: The time to wait before running the task.
    ///   - task: The synchronous task to run. As with everything that runs on the `EventLoop`, it must not block.
    /// - Returns: A `Scheduled` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the completion of the task.
    ///
    /// - Note: You can only cancel a task before it has started executing.
    /// - Note: The `in` value is clamped to a maximum when running on a Darwin-kernel.
    @discardableResult
    @available(*, noasync)
    @inlinable
    public func scheduleTask<T>(
        in delay: TimeAmount,
        _ task: @escaping () throws -> T
    ) -> Scheduled<T> {
        self._wrapped._scheduleTaskIsolatedUnsafeUnchecked(in: delay, task)
    }

    /// Schedule a `task` that is executed by this `EventLoop` at the given time.
    ///
    /// - Note: The `T` must be `Sendable` since the isolation domains of the event loop future returned from `task` and
    /// this event loop might differ.
    ///
    /// - Parameters:
    ///   - deadline: The time at which we should run the asynchronous task.
    ///   - file: The file in which the task is scheduled.
    ///   - line: The line of the `file` in which the task is scheduled.
    ///   - task: The asynchronous task to run. As with everything that runs on the `EventLoop`, it must not block.
    /// - Returns: A `Scheduled` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the full execution of the task, including its returned `EventLoopFuture`.
    ///
    /// - Note: You can only cancel a task before it has started executing.
    @discardableResult
    @available(*, noasync)
    @inlinable
    public func flatScheduleTask<T: Sendable>(
        deadline: NIODeadline,
        file: StaticString = #file,
        line: UInt = #line,
        _ task: @escaping () throws -> EventLoopFuture<T>
    ) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = self._wrapped.makePromise(file: file, line: line)
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

    /// Schedule a callback at a given time.
    ///
    /// - Parameters:
    ///   - deadline: The instant in time before which the task will not execute.
    ///   - handler: The handler that defines the behavior of the callback when executed or canceled.
    /// - Returns: A ``NIOScheduledCallback`` that can be used to cancel the scheduled callback.
    @discardableResult
    @available(*, noasync)
    @inlinable
    public func scheduleCallback(
        at deadline: NIODeadline,
        handler: some NIOScheduledCallbackHandler
    ) throws -> NIOScheduledCallback {
        try self._wrapped._scheduleCallbackIsolatedUnsafeUnchecked(at: deadline, handler: handler)
    }

    /// Schedule a callback after given time.
    ///
    /// - Parameters:
    ///   - amount: The amount of time before which the task will not execute.
    ///   - handler: The handler that defines the behavior of the callback when executed or canceled.
    ///  - Returns: A ``NIOScheduledCallback`` that can be used to cancel the scheduled callback.
    @discardableResult
    @available(*, noasync)
    @inlinable
    public func scheduleCallback(
        in amount: TimeAmount,
        handler: some NIOScheduledCallbackHandler
    ) throws -> NIOScheduledCallback {
        try self._wrapped._scheduleCallbackIsolatedUnsafeUnchecked(in: amount, handler: handler)
    }

    /// Cancel a scheduled callback.
    @inlinable
    @available(*, noasync)
    public func cancelScheduledCallback(_ scheduledCallback: NIOScheduledCallback) {
        self._wrapped.preconditionInEventLoop()
        self._wrapped.cancelScheduledCallback(scheduledCallback)
    }

    /// Creates and returns a new `EventLoopFuture` that is already marked as success. Notifications
    /// will be done using this `EventLoop` as execution `NIOThread`.
    ///
    /// - Parameters:
    ///   - value: the value that is used by the `EventLoopFuture`.
    /// - Returns: a succeeded `EventLoopFuture`.
    @inlinable
    @available(*, noasync)
    public func makeSucceededFuture<Success>(_ value: Success) -> EventLoopFuture<Success> {
        let promise = self._wrapped.makePromise(of: Success.self)
        promise.assumeIsolatedUnsafeUnchecked().succeed(value)
        return promise.futureResult
    }

    /// Creates and returns a new `EventLoopFuture` that is already marked as failed. Notifications
    /// will be done using this `EventLoop`.
    ///
    /// - Parameters:
    ///   - error: the `Error` that is used by the `EventLoopFuture`.
    /// - Returns: a failed `EventLoopFuture`.
    @inlinable
    @available(*, noasync)
    public func makeFailedFuture<Success>(_ error: Error) -> EventLoopFuture<Success> {
        let promise = self._wrapped.makePromise(of: Success.self)
        promise.fail(error)
        return promise.futureResult
    }

    /// Creates and returns a new `EventLoopFuture` that is marked as succeeded or failed with the
    /// value held by `result`.
    ///
    /// - Parameters:
    ///   - result: The value that is used by the `EventLoopFuture`
    /// - Returns: A completed `EventLoopFuture`.
    @inlinable
    @available(*, noasync)
    public func makeCompletedFuture<Success>(_ result: Result<Success, Error>) -> EventLoopFuture<Success> {
        let promise = self._wrapped.makePromise(of: Success.self)
        promise.assumeIsolatedUnsafeUnchecked().completeWith(result)
        return promise.futureResult
    }

    /// Creates and returns a new `EventLoopFuture` that is marked as succeeded or failed with the
    /// value returned by `body`.
    ///
    /// - Parameters:
    ///   - body: The function that is used to complete the `EventLoopFuture`
    /// - Returns: A completed `EventLoopFuture`.
    @inlinable
    @available(*, noasync)
    public func makeCompletedFuture<Success>(
        withResultOf body: () throws -> Success
    ) -> EventLoopFuture<Success> {
        self.makeCompletedFuture(Result(catching: body))
    }

    /// Returns the wrapped event loop.
    @inlinable
    public func nonisolated() -> any EventLoop {
        self._wrapped
    }
}

extension EventLoop {
    /// Assumes the calling context is isolated to the event loop.
    @inlinable
    @available(*, noasync)
    public func assumeIsolated() -> NIOIsolatedEventLoop {
        self.preconditionInEventLoop()
        return NIOIsolatedEventLoop(self)
    }

    /// Assumes the calling context is isolated to the event loop.
    ///
    /// This version of ``EventLoop/assumeIsolated()`` omits the runtime
    /// isolation check in release builds and doesn't prevent you using it
    /// from using it in async contexts.
    @inlinable
    public func assumeIsolatedUnsafeUnchecked() -> NIOIsolatedEventLoop {
        self.assertInEventLoop()
        return NIOIsolatedEventLoop(self)
    }
}

@available(*, unavailable)
extension NIOIsolatedEventLoop: Sendable {}

extension EventLoopFuture {
    /// A struct wrapping an ``EventLoopFuture`` that ensures all calls to any method on this struct
    /// are coming from the event loop of the future.
    ///
    /// This type is explicitly not `Sendable`. It may only be constructed on an event loop,
    /// using ``EventLoopFuture/assumeIsolated()``, and may not subsequently be passed to other isolation
    /// domains.
    ///
    /// Using this type relaxes the need to have the closures for the various ``EventLoopFuture``
    /// callback-attaching functions be `Sendable`.
    public struct Isolated {
        @usableFromInline
        let _wrapped: EventLoopFuture<Value>

        @inlinable
        init(_wrapped: EventLoopFuture<Value>) {
            self._wrapped = _wrapped
        }

        /// When the current `EventLoopFuture<Value>` is fulfilled, run the provided callback,
        /// which will provide a new `EventLoopFuture`.
        ///
        /// This allows you to dynamically dispatch new asynchronous tasks as phases in a
        /// longer series of processing steps. Note that you can use the results of the
        /// current `EventLoopFuture<Value>` when determining how to dispatch the next operation.
        ///
        /// This works well when you have APIs that already know how to return `EventLoopFuture`s.
        /// You can do something with the result of one and just return the next future:
        ///
        /// ```
        /// let d1 = networkRequest(args).future()
        /// let d2 = d1.flatMap { t -> EventLoopFuture<NewValue> in
        ///     . . . something with t . . .
        ///     return netWorkRequest(args)
        /// }
        /// d2.whenSuccess { u in
        ///     NSLog("Result of second request: \(u)")
        /// }
        /// ```
        ///
        /// Note that the returned ``EventLoopFuture`` still needs a `Sendable` wrapped value,
        /// as it may have been created on a different event loop.
        ///
        /// Note: In a sense, the `EventLoopFuture<NewValue>` is returned before it's created.
        ///
        /// - Parameters:
        ///   - callback: Function that will receive the value of this `EventLoopFuture` and return
        ///         a new `EventLoopFuture`.
        /// - Returns: A future that will receive the eventual value.
        @inlinable
        @available(*, noasync)
        public func flatMap<NewValue: Sendable>(
            _ callback: @escaping (Value) -> EventLoopFuture<NewValue>
        ) -> EventLoopFuture<NewValue>.Isolated {
            let next = EventLoopPromise<NewValue>.makeUnleakablePromise(eventLoop: self._wrapped.eventLoop)
            let base = self._wrapped
            base._whenCompleteIsolated {
                switch base._value! {
                case .success(let t):
                    let futureU = callback(t)
                    if futureU.eventLoop.inEventLoop {
                        return futureU._addCallback {
                            next._setValue(value: futureU._value!)
                        }
                    } else {
                        futureU.cascade(to: next)
                        return CallbackList()
                    }
                case .failure(let error):
                    return next._setValue(value: .failure(error))
                }
            }
            return next.futureResult.assumeIsolatedUnsafeUnchecked()
        }

        /// When the current `EventLoopFuture<Value>` is fulfilled, run the provided callback, which
        /// performs a synchronous computation and returns a new value of type `NewValue`. The provided
        /// callback may optionally `throw`.
        ///
        /// Operations performed in `flatMapThrowing` should not block, or they will block the entire
        /// event loop. `flatMapThrowing` is intended for use when you have a data-driven function that
        /// performs a simple data transformation that can potentially error.
        ///
        /// If your callback function throws, the returned `EventLoopFuture` will error.
        ///
        /// - Parameters:
        ///   - callback: Function that will receive the value of this `EventLoopFuture` and return
        ///         a new value lifted into a new `EventLoopFuture`.
        /// - Returns: A future that will receive the eventual value.
        @inlinable
        @available(*, noasync)
        public func flatMapThrowing<NewValue>(
            _ callback: @escaping (Value) throws -> NewValue
        ) -> EventLoopFuture<NewValue>.Isolated {
            let next = EventLoopPromise<NewValue>.makeUnleakablePromise(eventLoop: self._wrapped.eventLoop)
            let base = self._wrapped
            base._whenCompleteIsolated {
                switch base._value! {
                case .success(let t):
                    do {
                        let r = try callback(t)
                        return next._setValue(value: .success(r))
                    } catch {
                        return next._setValue(value: .failure(error))
                    }
                case .failure(let e):
                    return next._setValue(value: .failure(e))
                }
            }
            return next.futureResult.assumeIsolatedUnsafeUnchecked()
        }

        /// When the current `EventLoopFuture<Value>` is in an error state, run the provided callback, which
        /// may recover from the error and returns a new value of type `Value`. The provided callback may optionally `throw`,
        /// in which case the `EventLoopFuture` will be in a failed state with the new thrown error.
        ///
        /// Operations performed in `flatMapErrorThrowing` should not block, or they will block the entire
        /// event loop. `flatMapErrorThrowing` is intended for use when you have the ability to synchronously
        /// recover from errors.
        ///
        /// If your callback function throws, the returned `EventLoopFuture` will error.
        ///
        /// - Parameters:
        ///   - callback: Function that will receive the error value of this `EventLoopFuture` and return
        ///         a new value lifted into a new `EventLoopFuture`.
        /// - Returns: A future that will receive the eventual value or a rethrown error.
        @inlinable
        @available(*, noasync)
        public func flatMapErrorThrowing(
            _ callback: @escaping (Error) throws -> Value
        ) -> EventLoopFuture<Value>.Isolated {
            let next = EventLoopPromise<Value>.makeUnleakablePromise(eventLoop: self._wrapped.eventLoop)
            let base = self._wrapped
            base._whenCompleteIsolated {
                switch base._value! {
                case .success(let t):
                    return next._setValue(value: .success(t))
                case .failure(let e):
                    do {
                        let r = try callback(e)
                        return next._setValue(value: .success(r))
                    } catch {
                        return next._setValue(value: .failure(error))
                    }
                }
            }
            return next.futureResult.assumeIsolatedUnsafeUnchecked()
        }

        /// When the current `EventLoopFuture<Value>` is fulfilled, run the provided callback, which
        /// performs a synchronous computation and returns a new value of type `NewValue`.
        ///
        /// Operations performed in `map` should not block, or they will block the entire event
        /// loop. `map` is intended for use when you have a data-driven function that performs
        /// a simple data transformation that cannot error.
        ///
        /// If you have a data-driven function that can throw, you should use `flatMapThrowing`
        /// instead.
        ///
        /// ```
        /// let future1 = eventually()
        /// let future2 = future1.map { T -> U in
        ///     ... stuff ...
        ///     return u
        /// }
        /// let future3 = future2.map { U -> V in
        ///     ... stuff ...
        ///     return v
        /// }
        /// ```
        ///
        /// - Parameters:
        ///   - callback: Function that will receive the value of this `EventLoopFuture` and return
        ///         a new value lifted into a new `EventLoopFuture`.
        /// - Returns: A future that will receive the eventual value.
        @inlinable
        @available(*, noasync)
        public func map<NewValue>(
            _ callback: @escaping (Value) -> (NewValue)
        ) -> EventLoopFuture<NewValue>.Isolated {
            if NewValue.self == Value.self && NewValue.self == Void.self {
                self.whenSuccess(callback as! (Value) -> Void)
                return self as! EventLoopFuture<NewValue>.Isolated
            } else {
                let next = EventLoopPromise<NewValue>.makeUnleakablePromise(eventLoop: self._wrapped.eventLoop)
                let base = self._wrapped
                base._whenCompleteIsolated {
                    next._setValue(value: base._value!.map(callback))
                }
                return next.futureResult.assumeIsolatedUnsafeUnchecked()
            }
        }

        /// When the current `EventLoopFuture<Value>` is in an error state, run the provided callback, which
        /// may recover from the error by returning an `EventLoopFuture<NewValue>`. The callback is intended to potentially
        /// recover from the error by returning a new `EventLoopFuture` that will eventually contain the recovered
        /// result.
        ///
        /// If the callback cannot recover it should return a failed `EventLoopFuture`.
        ///
        /// - Note: The `Value` must be `Sendable` since the isolation domains of this future and the future returned from the callback
        /// might differ i.e. they might be bound to different event loops.
        ///
        /// - Parameters:
        ///   - callback: Function that will receive the error value of this `EventLoopFuture` and return
        ///         a new value lifted into a new `EventLoopFuture`.
        /// - Returns: A future that will receive the recovered value.
        @inlinable
        @available(*, noasync)
        public func flatMapError(
            _ callback: @escaping (Error) -> EventLoopFuture<Value>
        ) -> EventLoopFuture<Value>.Isolated where Value: Sendable {
            let next = EventLoopPromise<Value>.makeUnleakablePromise(eventLoop: self._wrapped.eventLoop)
            let base = self._wrapped
            base._whenCompleteIsolated {
                switch base._value! {
                case .success(let t):
                    return next._setValue(value: .success(t))
                case .failure(let e):
                    let t = callback(e)
                    if t.eventLoop.inEventLoop {
                        return t._addCallback {
                            next._setValue(value: t._value!)
                        }
                    } else {
                        t.cascade(to: next)
                        return CallbackList()
                    }
                }
            }
            return next.futureResult.assumeIsolatedUnsafeUnchecked()
        }

        /// When the current `EventLoopFuture<Value>.Isolated` is in an error state, run the provided callback, which
        /// may recover from the error by returning an `EventLoopFuture<NewValue>.Isolated`. The callback is intended to potentially
        /// recover from the error by returning a new `EventLoopFuture.Isolated` that will eventually contain the recovered
        /// result.
        ///
        /// If the callback cannot recover it should return a failed `EventLoopFuture.Isolated`.
        ///
        /// - Note: The `Value` need not be `Sendable` since the isolation domains of this future and the future returned from the callback
        /// must be the same
        ///
        /// - Parameters:
        ///   - callback: Function that will receive the error value of this `EventLoopFuture.Isolated` and return
        ///         a new value lifted into a new `EventLoopFuture.Isolated`.
        /// - Returns: A future that will receive the recovered value.
        @inlinable
        @available(*, noasync)
        public func flatMapError(
            _ callback: @escaping (Error) -> EventLoopFuture<Value>.Isolated
        ) -> EventLoopFuture<Value>.Isolated {
            let next = EventLoopPromise<Value>.makeUnleakablePromise(eventLoop: self._wrapped.eventLoop)
            let base = self._wrapped

            base._whenCompleteIsolated {
                switch base._value! {
                case .success(let t):
                    return next._setValue(value: .success(t))
                case .failure(let e):
                    let t = callback(e)
                    t._wrapped.eventLoop.assertInEventLoop()
                    return t._wrapped._addCallback {
                        next._setValue(value: t._wrapped._value!)
                    }
                }
            }
            return next.futureResult.assumeIsolatedUnsafeUnchecked()
        }

        /// When the current `EventLoopFuture<Value>` is fulfilled, run the provided callback, which
        /// performs a synchronous computation and returns either a new value (of type `NewValue`) or
        /// an error depending on the `Result` returned by the closure.
        ///
        /// Operations performed in `flatMapResult` should not block, or they will block the entire
        /// event loop. `flatMapResult` is intended for use when you have a data-driven function that
        /// performs a simple data transformation that can potentially error.
        ///
        ///
        /// - Parameters:
        ///   - body: Function that will receive the value of this `EventLoopFuture` and return
        ///         a new value or error lifted into a new `EventLoopFuture`.
        /// - Returns: A future that will receive the eventual value.
        @inlinable
        @available(*, noasync)
        public func flatMapResult<NewValue, SomeError: Error>(
            _ body: @escaping (Value) -> Result<NewValue, SomeError>
        ) -> EventLoopFuture<NewValue>.Isolated {
            let next = EventLoopPromise<NewValue>.makeUnleakablePromise(eventLoop: self._wrapped.eventLoop)
            let base = self._wrapped
            base._whenCompleteIsolated {
                switch base._value! {
                case .success(let value):
                    switch body(value) {
                    case .success(let newValue):
                        return next._setValue(value: .success(newValue))
                    case .failure(let error):
                        return next._setValue(value: .failure(error))
                    }
                case .failure(let e):
                    return next._setValue(value: .failure(e))
                }
            }
            return next.futureResult.assumeIsolatedUnsafeUnchecked()
        }

        /// When the current `EventLoopFuture<Value>` is in an error state, run the provided callback, which
        /// can recover from the error and return a new value of type `Value`. The provided callback may not `throw`,
        /// so this function should be used when the error is always recoverable.
        ///
        /// Operations performed in `recover` should not block, or they will block the entire
        /// event loop. `recover` is intended for use when you have the ability to synchronously
        /// recover from errors.
        ///
        /// - Parameters:
        ///   - callback: Function that will receive the error value of this `EventLoopFuture` and return
        ///         a new value lifted into a new `EventLoopFuture`.
        /// - Returns: A future that will receive the recovered value.
        @inlinable
        @available(*, noasync)
        public func recover(
            _ callback: @escaping (Error) -> Value
        ) -> EventLoopFuture<Value>.Isolated {
            let next = EventLoopPromise<Value>.makeUnleakablePromise(eventLoop: self._wrapped.eventLoop)
            let base = self._wrapped
            base._whenCompleteIsolated {
                switch base._value! {
                case .success(let t):
                    return next._setValue(value: .success(t))
                case .failure(let e):
                    return next._setValue(value: .success(callback(e)))
                }
            }
            return next.futureResult.assumeIsolatedUnsafeUnchecked()
        }

        /// Adds an observer callback to this `EventLoopFuture` that is called when the
        /// `EventLoopFuture` has a success result.
        ///
        /// An observer callback cannot return a value, meaning that this function cannot be chained
        /// from. If you are attempting to create a computation pipeline, consider `map` or `flatMap`.
        /// If you find yourself passing the results from this `EventLoopFuture` to a new `EventLoopPromise`
        /// in the body of this function, consider using `cascade` instead.
        ///
        /// - Parameters:
        ///   - callback: The callback that is called with the successful result of the `EventLoopFuture`.
        @inlinable
        @available(*, noasync)
        public func whenSuccess(_ callback: @escaping (Value) -> Void) {
            let base = self._wrapped
            base._whenCompleteIsolated {
                if case .success(let t) = base._value! {
                    callback(t)
                }
                return CallbackList()
            }
        }

        /// Adds an observer callback to this `EventLoopFuture` that is called when the
        /// `EventLoopFuture` has a failure result.
        ///
        /// An observer callback cannot return a value, meaning that this function cannot be chained
        /// from. If you are attempting to create a computation pipeline, consider `recover` or `flatMapError`.
        /// If you find yourself passing the results from this `EventLoopFuture` to a new `EventLoopPromise`
        /// in the body of this function, consider using `cascade` instead.
        ///
        /// - Parameters:
        ///   - callback: The callback that is called with the failed result of the `EventLoopFuture`.
        @inlinable
        @available(*, noasync)
        public func whenFailure(_ callback: @escaping (Error) -> Void) {
            let base = self._wrapped
            base._whenCompleteIsolated {
                if case .failure(let e) = base._value! {
                    callback(e)
                }
                return CallbackList()
            }
        }

        /// Adds an observer callback to this `EventLoopFuture` that is called when the
        /// `EventLoopFuture` has any result.
        ///
        /// - Parameters:
        ///   - callback: The callback that is called when the `EventLoopFuture` is fulfilled.
        @inlinable
        @available(*, noasync)
        public func whenComplete(
            _ callback: @escaping (Result<Value, Error>) -> Void
        ) {
            let base = self._wrapped
            base._whenCompleteIsolated {
                callback(base._value!)
                return CallbackList()
            }
        }

        /// Adds an observer callback to this `EventLoopFuture` that is called when the
        /// `EventLoopFuture` has any result.
        ///
        /// - Parameters:
        ///   - callback: the callback that is called when the `EventLoopFuture` is fulfilled.
        /// - Returns: the current `EventLoopFuture`
        @inlinable
        @available(*, noasync)
        public func always(
            _ callback: @escaping (Result<Value, Error>) -> Void
        ) -> EventLoopFuture<Value>.Isolated {
            self.whenComplete { result in callback(result) }
            return self
        }

        /// Unwrap an `EventLoopFuture` where its type parameter is an `Optional`.
        ///
        /// Unwraps a future returning a new `EventLoopFuture` with either: the value passed in the `orReplace`
        /// parameter when the future resolved with value Optional.none, or the same value otherwise. For example:
        /// ```
        /// promise.futureResult.unwrap(orReplace: 42).wait()
        /// ```
        ///
        /// - Parameters:
        ///   - replacement: the value of the returned `EventLoopFuture` when then resolved future's value is `Optional.some()`.
        /// - Returns: an new `EventLoopFuture` with new type parameter `NewValue` and the value passed in the `orReplace` parameter.
        @inlinable
        @available(*, noasync)
        public func unwrap<NewValue>(
            orReplace replacement: NewValue
        ) -> EventLoopFuture<NewValue>.Isolated where Value == NewValue? {
            self.map { (value) -> NewValue in
                guard let value = value else {
                    return replacement
                }
                return value
            }
        }

        /// Unwrap an `EventLoopFuture` where its type parameter is an `Optional`.
        ///
        /// Unwraps a future returning a new `EventLoopFuture` with either: the value returned by the closure passed in
        /// the `orElse` parameter when the future resolved with value Optional.none, or the same value otherwise. For example:
        /// ```
        /// var x = 2
        /// promise.futureResult.unwrap(orElse: { x * 2 }).wait()
        /// ```
        ///
        /// - Parameters:
        ///   - callback: a closure that returns the value of the returned `EventLoopFuture` when then resolved future's value
        ///         is `Optional.some()`.
        /// - Returns: an new `EventLoopFuture` with new type parameter `NewValue` and with the value returned by the closure
        ///     passed in the `orElse` parameter.
        @inlinable
        @available(*, noasync)
        public func unwrap<NewValue>(
            orElse callback: @escaping () -> NewValue
        ) -> EventLoopFuture<NewValue>.Isolated where Value == NewValue? {
            self.map { (value) -> NewValue in
                guard let value = value else {
                    return callback()
                }
                return value
            }
        }

        /// Returns the wrapped event loop future.
        @inlinable
        public func nonisolated() -> EventLoopFuture<Value> {
            self._wrapped
        }
    }

    /// Returns a variant of this ``EventLoopFuture`` with less strict
    /// `Sendable` requirements. Can only be called from on the
    /// ``EventLoop`` to which this ``EventLoopFuture`` is bound, will crash
    /// if that invariant fails to be met.
    @inlinable
    @available(*, noasync)
    public func assumeIsolated() -> Isolated {
        self.eventLoop.preconditionInEventLoop()
        return Isolated(_wrapped: self)
    }

    /// Returns a variant of this ``EventLoopFuture`` with less strict
    /// `Sendable` requirements. Can only be called from on the
    /// ``EventLoop`` to which this ``EventLoopFuture`` is bound, will crash
    /// if that invariant fails to be met in debug builds.
    ///
    /// This is an unsafe version of ``EventLoopFuture/assumeIsolated()`` which
    /// omits the runtime check in release builds.
    @inlinable
    @available(*, noasync)
    public func assumeIsolatedUnsafeUnchecked() -> Isolated {
        self.eventLoop.assertInEventLoop()
        return Isolated(_wrapped: self)
    }
}

@available(*, unavailable)
extension EventLoopFuture.Isolated: Sendable {}

extension EventLoopPromise {
    /// A struct wrapping an ``EventLoopPromise`` that ensures all calls to any method on this struct
    /// are coming from the event loop of the promise.
    ///
    /// This type is explicitly not `Sendable`. It may only be constructed on an event loop,
    /// using ``EventLoopPromise/assumeIsolated()``, and may not subsequently be passed to other isolation
    /// domains.
    ///
    /// Using this type relaxes the need to have the promise completion functions accept `Sendable`
    /// values, as this type can only be handled on the ``EventLoop``.
    ///
    /// This type does not offer the full suite of completion functions that ``EventLoopPromise``
    /// does, as many of those functions do not require `Sendable` values already. It only offers
    /// versions for the functions that do require `Sendable` types. If you have an
    /// ``EventLoopPromise/Isolated`` but need a regular ``EventLoopPromise``, use
    /// ``EventLoopPromise/Isolated/nonisolated()`` to unwrap the value.
    public struct Isolated {
        @usableFromInline
        let _wrapped: EventLoopPromise<Value>

        @inlinable
        init(_wrapped: EventLoopPromise<Value>) {
            self._wrapped = _wrapped
        }

        /// Returns the `EventLoopFuture.Isolated` which will be notified once the execution of the scheduled task completes.
        @inlinable
        @available(*, noasync)
        public var futureResult: EventLoopFuture<Value>.Isolated {
            self._wrapped.futureResult.assumeIsolated()
        }

        /// Deliver a successful result to the associated `EventLoopFuture<Value>` object.
        ///
        /// - Parameters:
        ///   - value: The successful result of the operation.
        @inlinable
        @available(*, noasync)
        public func succeed(_ value: Value) {
            self._wrapped._setValue(value: .success(value))._run()
        }

        /// Complete the promise with the passed in `Result<Value, Error>`.
        ///
        /// This method is equivalent to invoking:
        /// ```
        /// switch result {
        /// case .success(let value):
        ///     promise.succeed(value)
        /// case .failure(let error):
        ///     promise.fail(error)
        /// }
        /// ```
        ///
        /// - Parameters:
        ///   - result: The result which will be used to succeed or fail this promise.
        @inlinable
        @available(*, noasync)
        public func completeWith(_ result: Result<Value, Error>) {
            self._wrapped._setValue(value: result)._run()
        }

        /// Returns the wrapped event loop promise.
        @inlinable
        public func nonisolated() -> EventLoopPromise<Value> {
            self._wrapped
        }
    }

    /// Returns a variant of this ``EventLoopPromise`` with less strict
    /// `Sendable` requirements. Can only be called from on the
    /// ``EventLoop`` to which this ``EventLoopPromise`` is bound, will crash
    /// if that invariant fails to be met.
    @inlinable
    @available(*, noasync)
    public func assumeIsolated() -> Isolated {
        self.futureResult.eventLoop.preconditionInEventLoop()
        return Isolated(_wrapped: self)
    }

    /// Returns a variant of this ``EventLoopPromise`` with less strict
    /// `Sendable` requirements. Can only be called from on the
    /// ``EventLoop`` to which this ``EventLoopPromise`` is bound, will crash
    /// if that invariant fails to be met.
    ///
    /// This is an unsafe version of ``EventLoopPromise/assumeIsolated()`` which
    /// omits the runtime check in release builds and doesn't prevent you using it
    /// from using it in async contexts.
    @inlinable
    public func assumeIsolatedUnsafeUnchecked() -> Isolated {
        self.futureResult.eventLoop.assertInEventLoop()
        return Isolated(_wrapped: self)
    }
}

@available(*, unavailable)
extension EventLoopPromise.Isolated: Sendable {}
