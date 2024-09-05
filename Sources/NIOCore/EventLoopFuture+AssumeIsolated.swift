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
@usableFromInline
struct IsolatedEventLoop {
    @usableFromInline
    let _wrapped: EventLoop

    @inlinable
    internal init(_ eventLoop: EventLoop) {
        self._wrapped = eventLoop
    }

    /// Submit a given task to be executed by the `EventLoop`
    @inlinable
    func execute(_ task: @escaping () -> Void) {
        self._wrapped.assertInEventLoop()
        let unsafeTransfer = UnsafeTransfer(task)
        self._wrapped.execute {
            unsafeTransfer.wrappedValue()
        }
    }

    /// Submit a given task to be executed by the `EventLoop`. Once the execution is complete the returned `EventLoopFuture` is notified.
    ///
    /// - parameters:
    ///     - task: The closure that will be submitted to the `EventLoop` for execution.
    /// - returns: `EventLoopFuture` that is notified once the task was executed.
    @inlinable
    func submit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        self._wrapped.assertInEventLoop()
        let unsafeTransfer = UnsafeTransfer(task)
        return self._wrapped.submit {
            try unsafeTransfer.wrappedValue()
        }
    }

    /// Schedule a `task` that is executed by this `EventLoop` at the given time.
    ///
    /// - parameters:
    ///     - task: The synchronous task to run. As with everything that runs on the `EventLoop`, it must not block.
    /// - returns: A `Scheduled` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the completion of the task.
    ///
    /// - note: You can only cancel a task before it has started executing.
    @discardableResult
    @inlinable
    func scheduleTask<T>(
        deadline: NIODeadline,
        _ task: @escaping () throws -> T
    ) -> Scheduled<T> {
        self._wrapped.assertInEventLoop()
        let unsafeTransfer = UnsafeTransfer(task)
        return self._wrapped.scheduleTask(deadline: deadline) {
            try unsafeTransfer.wrappedValue()
        }
    }

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
    @inlinable
    func scheduleTask<T>(
        in delay: TimeAmount,
        _ task: @escaping () throws -> T
    ) -> Scheduled<T> {
        self._wrapped.assertInEventLoop()
        let unsafeTransfer = UnsafeTransfer(task)
        return self._wrapped.scheduleTask(in: delay) {
            try unsafeTransfer.wrappedValue()
        }
    }

    /// Schedule a `task` that is executed by this `EventLoop` at the given time.
    ///
    /// - Note: The `T` must be `Sendable` since the isolation domains of the event loop future returned from `task` and
    /// this event loop might differ.
    ///
    /// - parameters:
    ///     - task: The asynchronous task to run. As with everything that runs on the `EventLoop`, it must not block.
    /// - returns: A `Scheduled` object which may be used to cancel the task if it has not yet run, or to wait
    ///            on the full execution of the task, including its returned `EventLoopFuture`.
    ///
    /// - note: You can only cancel a task before it has started executing.
    @discardableResult
    @inlinable
    func flatScheduleTask<T: Sendable>(
        deadline: NIODeadline,
        file: StaticString = #file,
        line: UInt = #line,
        _ task: @escaping () throws -> EventLoopFuture<T>
    ) -> Scheduled<T> {
        self._wrapped.assertInEventLoop()
        let unsafeTransfer = UnsafeTransfer(task)
        return self._wrapped.flatScheduleTask(deadline: deadline, file: file, line: line) {
            try unsafeTransfer.wrappedValue()
        }
    }

    /// Returns the wrapped event loop.
    @inlinable
    func nonisolated() -> any EventLoop {
        self._wrapped
    }
}
extension EventLoop {
    /// Assumes the calling context is isolated to the event loop.
    @usableFromInline
    func assumeIsolated() -> IsolatedEventLoop {
        IsolatedEventLoop(self)
    }
}

extension EventLoopFuture {
    /// A struct wrapping an ``EventLoopFuture`` that ensures all calls to any method on this struct
    /// are coming from the event loop of the future.
    @usableFromInline
    struct Isolated {
        @usableFromInline
        let _wrapped: EventLoopFuture<Value>

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
        /// Note: In a sense, the `EventLoopFuture<NewValue>` is returned before it's created.
        ///
        /// - parameters:
        ///     - callback: Function that will receive the value of this `EventLoopFuture` and return
        ///         a new `EventLoopFuture`.
        /// - returns: A future that will receive the eventual value.
        @inlinable
        func flatMap<NewValue: Sendable>(
            _ callback: @escaping (Value) -> EventLoopFuture<NewValue>
        ) -> EventLoopFuture<NewValue>.Isolated {
            self._wrapped.eventLoop.assertInEventLoop()
            let unsafeTransfer = UnsafeTransfer(callback)
            return self._wrapped.flatMap {
                unsafeTransfer.wrappedValue($0)
            }.assumeIsolated()
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
        /// - parameters:
        ///     - callback: Function that will receive the value of this `EventLoopFuture` and return
        ///         a new value lifted into a new `EventLoopFuture`.
        /// - returns: A future that will receive the eventual value.
        @inlinable
        func flatMapThrowing<NewValue>(
            _ callback: @escaping (Value) throws -> NewValue
        ) -> EventLoopFuture<NewValue>.Isolated {
            self._wrapped.eventLoop.assertInEventLoop()
            let unsafeTransfer = UnsafeTransfer(callback)
            return self._wrapped.flatMapThrowing {
                try unsafeTransfer.wrappedValue($0)
            }.assumeIsolated()
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
        /// - parameters:
        ///     - callback: Function that will receive the error value of this `EventLoopFuture` and return
        ///         a new value lifted into a new `EventLoopFuture`.
        /// - returns: A future that will receive the eventual value or a rethrown error.
        @inlinable
        func flatMapErrorThrowing(
            _ callback: @escaping (Error) throws -> Value
        ) -> EventLoopFuture<Value>.Isolated {
            self._wrapped.eventLoop.assertInEventLoop()
            let unsafeTransfer = UnsafeTransfer(callback)
            return self._wrapped.flatMapErrorThrowing {
                try unsafeTransfer.wrappedValue($0)
            }.assumeIsolated()
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
        /// - parameters:
        ///     - callback: Function that will receive the value of this `EventLoopFuture` and return
        ///         a new value lifted into a new `EventLoopFuture`.
        /// - returns: A future that will receive the eventual value.
        @inlinable
        func map<NewValue>(
            _ callback: @escaping (Value) -> (NewValue)
        ) -> EventLoopFuture<NewValue>.Isolated {
            self._wrapped.eventLoop.assertInEventLoop()
            let unsafeTransfer = UnsafeTransfer(callback)
            return self._wrapped.map {
                unsafeTransfer.wrappedValue($0)
            }.assumeIsolated()
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
        /// - parameters:
        ///     - callback: Function that will receive the error value of this `EventLoopFuture` and return
        ///         a new value lifted into a new `EventLoopFuture`.
        /// - returns: A future that will receive the recovered value.
        @inlinable
        func flatMapError(
            _ callback: @escaping (Error) -> EventLoopFuture<Value>
        ) -> EventLoopFuture<Value>.Isolated where Value: Sendable {
            self._wrapped.eventLoop.assertInEventLoop()
            let unsafeTransfer = UnsafeTransfer(callback)
            return self._wrapped.flatMapError {
                unsafeTransfer.wrappedValue($0)
            }.assumeIsolated()
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
        /// - parameters:
        ///     - body: Function that will receive the value of this `EventLoopFuture` and return
        ///         a new value or error lifted into a new `EventLoopFuture`.
        /// - returns: A future that will receive the eventual value.
        @inlinable
        func flatMapResult<NewValue, SomeError: Error>(
            _ body: @escaping (Value) -> Result<NewValue, SomeError>
        ) -> EventLoopFuture<NewValue>.Isolated {
            self._wrapped.eventLoop.assertInEventLoop()
            let unsafeTransfer = UnsafeTransfer(body)
            return self._wrapped.flatMapResult {
                unsafeTransfer.wrappedValue($0)
            }.assumeIsolated()
        }

        /// When the current `EventLoopFuture<Value>` is in an error state, run the provided callback, which
        /// can recover from the error and return a new value of type `Value`. The provided callback may not `throw`,
        /// so this function should be used when the error is always recoverable.
        ///
        /// Operations performed in `recover` should not block, or they will block the entire
        /// event loop. `recover` is intended for use when you have the ability to synchronously
        /// recover from errors.
        ///
        /// - parameters:
        ///     - callback: Function that will receive the error value of this `EventLoopFuture` and return
        ///         a new value lifted into a new `EventLoopFuture`.
        /// - returns: A future that will receive the recovered value.
        @inlinable
        func recover(
            _ callback: @escaping (Error) -> Value
        ) -> EventLoopFuture<Value>.Isolated {
            self._wrapped.eventLoop.assertInEventLoop()
            let unsafeTransfer = UnsafeTransfer(callback)
            return self._wrapped.recover {
                unsafeTransfer.wrappedValue($0)
            }.assumeIsolated()
        }

        /// Adds an observer callback to this `EventLoopFuture` that is called when the
        /// `EventLoopFuture` has a success result.
        ///
        /// An observer callback cannot return a value, meaning that this function cannot be chained
        /// from. If you are attempting to create a computation pipeline, consider `map` or `flatMap`.
        /// If you find yourself passing the results from this `EventLoopFuture` to a new `EventLoopPromise`
        /// in the body of this function, consider using `cascade` instead.
        ///
        /// - parameters:
        ///     - callback: The callback that is called with the successful result of the `EventLoopFuture`.
        @inlinable
        func whenSuccess(_ callback: @escaping (Value) -> Void) {
            self._wrapped.eventLoop.assertInEventLoop()
            let unsafeTransfer = UnsafeTransfer(callback)
            return self._wrapped.whenSuccess {
                unsafeTransfer.wrappedValue($0)
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
        /// - parameters:
        ///     - callback: The callback that is called with the failed result of the `EventLoopFuture`.
        @inlinable
        func whenFailure(_ callback: @escaping (Error) -> Void) {
            self._wrapped.eventLoop.assertInEventLoop()
            let unsafeTransfer = UnsafeTransfer(callback)
            return self._wrapped.whenFailure {
                unsafeTransfer.wrappedValue($0)
            }
        }

        /// Adds an observer callback to this `EventLoopFuture` that is called when the
        /// `EventLoopFuture` has any result.
        ///
        /// - parameters:
        ///     - callback: The callback that is called when the `EventLoopFuture` is fulfilled.
        @inlinable
        func whenComplete(
            _ callback: @escaping (Result<Value, Error>) -> Void
        ) {
            self._wrapped.eventLoop.assertInEventLoop()
            let unsafeTransfer = UnsafeTransfer(callback)
            return self._wrapped.whenComplete {
                unsafeTransfer.wrappedValue($0)
            }
        }

        /// Adds an observer callback to this `EventLoopFuture` that is called when the
        /// `EventLoopFuture` has any result.
        ///
        /// - parameters:
        ///     - callback: the callback that is called when the `EventLoopFuture` is fulfilled.
        /// - returns: the current `EventLoopFuture`
        @inlinable
        func always(
            _ callback: @escaping (Result<Value, Error>) -> Void
        ) -> EventLoopFuture<Value> {
            self._wrapped.eventLoop.assertInEventLoop()
            let unsafeTransfer = UnsafeTransfer(callback)
            return self._wrapped.always {
                unsafeTransfer.wrappedValue($0)
            }
        }

        /// Unwrap an `EventLoopFuture` where its type parameter is an `Optional`.
        ///
        /// Unwraps a future returning a new `EventLoopFuture` with either: the value passed in the `orReplace`
        /// parameter when the future resolved with value Optional.none, or the same value otherwise. For example:
        /// ```
        /// promise.futureResult.unwrap(orReplace: 42).wait()
        /// ```
        ///
        /// - parameters:
        ///     - orReplace: the value of the returned `EventLoopFuture` when then resolved future's value is `Optional.some()`.
        /// - returns: an new `EventLoopFuture` with new type parameter `NewValue` and the value passed in the `orReplace` parameter.
        @inlinable
        func unwrap<NewValue>(
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
        /// - parameters:
        ///     - orElse: a closure that returns the value of the returned `EventLoopFuture` when then resolved future's value
        ///         is `Optional.some()`.
        /// - returns: an new `EventLoopFuture` with new type parameter `NewValue` and with the value returned by the closure
        ///     passed in the `orElse` parameter.
        @inlinable
        func unwrap<NewValue>(
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
        func nonisolated() -> EventLoopFuture<Value> {
            self._wrapped
        }
    }

    /// Assumes the calling context is isolated to the future's event loop.
    @usableFromInline
    func assumeIsolated() -> Isolated {
        self.eventLoop.assertInEventLoop()
        return Isolated(_wrapped: self)
    }
}

extension EventLoopPromise {
    /// A struct wrapping an ``EventLoopPromise`` that ensures all calls to any method on this struct
    /// are coming from the event loop of the promise.
    @usableFromInline
    struct Isolated {
        @usableFromInline
        let _wrapped: EventLoopPromise<Value>

        /// Deliver a successful result to the associated `EventLoopFuture<Value>` object.
        ///
        /// - parameters:
        ///     - value: The successful result of the operation.
        @inlinable
        func succeed(_ value: Value) {
            self._wrapped.futureResult.eventLoop.assertInEventLoop()
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
        /// - parameters:
        ///     - result: The result which will be used to succeed or fail this promise.
        @inlinable
        func completeWith(_ result: Result<Value, Error>) {
            self._wrapped.futureResult.eventLoop.assertInEventLoop()
            self._wrapped._setValue(value: result)._run()
        }

        /// Returns the wrapped event loop promise.
        @inlinable
        func nonisolated() -> EventLoopPromise<Value> {
            self._wrapped
        }
    }

    /// Assumes the calling context is isolated to the promise's event loop.
    @usableFromInline
    func assumeIsolated() -> Isolated {
        self.futureResult.eventLoop.assertInEventLoop()
        return Isolated(_wrapped: self)
    }
}
