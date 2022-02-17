//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension EventLoopFuture {
    /// When the current `EventLoopFuture<Value>` is fulfilled, run the provided callback,
    /// which will provide a new `EventLoopFuture` alongside the `EventLoop` associated with this future.
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
    /// let d2 = d1.flatMapWithEventLoop { t, eventLoop -> EventLoopFuture<NewValue> in
    ///     eventLoop.makeSucceededFuture(t + 1)
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
    public func flatMapWithEventLoop<NewValue>(_ callback: @escaping (Value, EventLoop) -> EventLoopFuture<NewValue>) -> EventLoopFuture<NewValue> {
        let next = EventLoopPromise<NewValue>.makeUnleakablePromise(eventLoop: self.eventLoop)
        self._whenComplete { [eventLoop = self.eventLoop] in
            switch self._value! {
            case .success(let t):
                let futureU = callback(t, eventLoop)
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
        return next.futureResult
    }

    /// When the current `EventLoopFuture<Value>` is in an error state, run the provided callback, which
    /// may recover from the error by returning an `EventLoopFuture<NewValue>`. The callback is intended to potentially
    /// recover from the error by returning a new `EventLoopFuture` that will eventually contain the recovered
    /// result.
    ///
    /// If the callback cannot recover it should return a failed `EventLoopFuture`.
    ///
    /// - parameters:
    ///     - callback: Function that will receive the error value of this `EventLoopFuture` and return
    ///         a new value lifted into a new `EventLoopFuture`.
    /// - returns: A future that will receive the recovered value.
    @inlinable
    public func flatMapErrorWithEventLoop(_ callback: @escaping (Error, EventLoop) -> EventLoopFuture<Value>) -> EventLoopFuture<Value> {
        let next = EventLoopPromise<Value>.makeUnleakablePromise(eventLoop: self.eventLoop)
        self._whenComplete { [eventLoop = self.eventLoop] in
            switch self._value! {
            case .success(let t):
                return next._setValue(value: .success(t))
            case .failure(let e):
                let t = callback(e, eventLoop)
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
        return next.futureResult
    }

    /// Returns a new `EventLoopFuture` that fires only when this `EventLoopFuture` and
    /// all the provided `futures` complete. It then provides the result of folding the value of this
    /// `EventLoopFuture` with the values of all the provided `futures`.
    ///
    /// This function is suited when you have APIs that already know how to return `EventLoopFuture`s.
    ///
    /// The returned `EventLoopFuture` will fail as soon as the a failure is encountered in any of the
    /// `futures` (or in this one). However, the failure will not occur until all preceding
    /// `EventLoopFutures` have completed. At the point the failure is encountered, all subsequent
    /// `EventLoopFuture` objects will no longer be waited for. This function therefore fails fast: once
    /// a failure is encountered, it will immediately fail the overall EventLoopFuture.
    ///
    /// - parameters:
    ///     - futures: An array of `EventLoopFuture<NewValue>` to wait for.
    ///     - with: A function that will be used to fold the values of two `EventLoopFuture`s and return a new value wrapped in an `EventLoopFuture`.
    /// - returns: A new `EventLoopFuture` with the folded value whose callbacks run on `self.eventLoop`.
    @inlinable
    public func foldWithEventLoop<OtherValue>(_ futures: [EventLoopFuture<OtherValue>],
                                              with combiningFunction: @escaping (Value, OtherValue, EventLoop) -> EventLoopFuture<Value>) -> EventLoopFuture<Value> {
        func fold0(eventLoop: EventLoop) -> EventLoopFuture<Value> {
            let body = futures.reduce(self) { (f1: EventLoopFuture<Value>, f2: EventLoopFuture<OtherValue>) -> EventLoopFuture<Value> in
                let newFuture = f1.and(f2).flatMap { (args: (Value, OtherValue)) -> EventLoopFuture<Value> in
                    let (f1Value, f2Value) = args
                    self.eventLoop.assertInEventLoop()
                    return combiningFunction(f1Value, f2Value, eventLoop)
                }
                assert(newFuture.eventLoop === self.eventLoop)
                return newFuture
            }
            return body
        }

        if self.eventLoop.inEventLoop {
            return fold0(eventLoop: self.eventLoop)
        } else {
            let promise = self.eventLoop.makePromise(of: Value.self)
            self.eventLoop.execute { [eventLoop = self.eventLoop] in
                fold0(eventLoop: eventLoop).cascade(to: promise)
            }
            return promise.futureResult
        }
    }
}
