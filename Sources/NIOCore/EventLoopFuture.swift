//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2020 Apple Inc. and the SwiftNIO project authors
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

/// Internal list of callbacks.
///
/// Most of these are closures that pull a value from one future, call a user callback, push the
/// result into another, then return a list of callbacks from the target future that are now ready to be invoked.
///
/// In particular, note that _run() here continues to obtain and execute lists of callbacks until it completes.
/// This eliminates recursion when processing `flatMap()` chains.
@usableFromInline
internal struct CallbackList {
    @usableFromInline
    internal typealias Element = () -> CallbackList
    @usableFromInline
    internal var firstCallback: Optional<Element>
    @usableFromInline
    internal var furtherCallbacks: Optional<[Element]>

    @inlinable
    internal init() {
        self.firstCallback = nil
        self.furtherCallbacks = nil
    }

    @inlinable
    internal mutating func append(_ callback: @escaping () -> CallbackList) {
        if self.firstCallback == nil {
            self.firstCallback = callback
        } else {
            if self.furtherCallbacks != nil {
                self.furtherCallbacks!.append(callback)
            } else {
                self.furtherCallbacks = [callback]
            }
        }
    }

    @inlinable
    internal func _allCallbacks() -> CircularBuffer<Element> {
        switch (self.firstCallback, self.furtherCallbacks) {
        case (.none, _):
            return []
        case (.some(let onlyCallback), .none):
            return [onlyCallback]
        default:
            var array: CircularBuffer<Element> = []
            self.appendAllCallbacks(&array)
            return array
        }
    }

    @inlinable
    internal func appendAllCallbacks(_ array: inout CircularBuffer<Element>) {
        switch (self.firstCallback, self.furtherCallbacks) {
        case (.none, _):
            return
        case (.some(let onlyCallback), .none):
            array.append(onlyCallback)
        case (.some(let first), .some(let others)):
            array.reserveCapacity(array.count + 1 + others.count)
            array.append(first)
            array.append(contentsOf: others)
        }
    }

    @inlinable
    internal func _run() {
        switch (self.firstCallback, self.furtherCallbacks) {
        case (.none, _):
            return
        case (.some(let onlyCallback), .none):
            var onlyCallback = onlyCallback
            loop: while true {
                let cbl = onlyCallback()
                switch (cbl.firstCallback, cbl.furtherCallbacks) {
                case (.none, _):
                    break loop
                case (.some(let ocb), .none):
                    onlyCallback = ocb
                    continue loop
                case (.some(_), .some(_)):
                    var pending = cbl._allCallbacks()
                    while let f = pending.popFirst() {
                        let next = f()
                        next.appendAllCallbacks(&pending)
                    }
                    break loop
                }
            }
        default:
            var pending = self._allCallbacks()
            while let f = pending.popFirst() {
                let next = f()
                next.appendAllCallbacks(&pending)
            }
        }
    }
}

/// Internal error for operations that return results that were not replaced
@usableFromInline
internal struct OperationPlaceholderError: Error {
    @usableFromInline
    internal init() {}
}

/// A promise to provide a result later.
///
/// This is the provider API for `EventLoopFuture<Value>`. If you want to return an
/// unfulfilled `EventLoopFuture<Value>` -- presumably because you are interfacing to
/// some asynchronous service that will return a real result later, follow this
/// pattern:
///
/// ```
/// func someAsyncOperation(args) -> EventLoopFuture<ResultType> {
///     let promise = eventLoop.makePromise(of: ResultType.self)
///     someAsyncOperationWithACallback(args) { result -> Void in
///         // when finished...
///         promise.succeed(result)
///         // if error...
///         promise.fail(error)
///     }
///     return promise.futureResult
/// }
/// ```
///
/// Note that the future result is returned before the async process has provided a value.
///
/// It's actually not very common to use this directly. Usually, you really want one
/// of the following:
///
/// * If you have an `EventLoopFuture` and want to do something else after it completes,
///     use `.flatMap()`
/// * If you already have a value and need an `EventLoopFuture<>` object to plug into
///     some other API, create an already-resolved object with `eventLoop.makeSucceededFuture(result)`
///     or `eventLoop.newFailedFuture(error:)`.
///
/// - note: `EventLoopPromise` has reference semantics.
public struct EventLoopPromise<Value> {
    /// The `EventLoopFuture` which is used by the `EventLoopPromise`. You can use it to add callbacks which are notified once the
    /// `EventLoopPromise` is completed.
    public let futureResult: EventLoopFuture<Value>

    @inlinable
    internal static func makeUnleakablePromise(eventLoop: EventLoop, line: UInt = #line) -> EventLoopPromise<Value> {
        return EventLoopPromise<Value>(eventLoop: eventLoop,
                                       file: "BUG in SwiftNIO (please report), unleakable promise leaked.",
                                       line: line)
    }

    /// General initializer
    ///
    /// - parameters:
    ///     - eventLoop: The event loop this promise is tied to.
    ///     - file: The file this promise was allocated in, for debugging purposes.
    ///     - line: The line this promise was allocated on, for debugging purposes.
    @inlinable
    internal init(eventLoop: EventLoop, file: StaticString, line: UInt) {
        self.futureResult = EventLoopFuture<Value>(_eventLoop: eventLoop, file: file, line: line)
    }

    /// Deliver a successful result to the associated `EventLoopFuture<Value>` object.
    ///
    /// - parameters:
    ///     - value: The successful result of the operation.
    @inlinable
    public func succeed(_ value: Value) {
        self._resolve(value: .success(value))
    }

    /// Deliver an error to the associated `EventLoopFuture<Value>` object.
    ///
    /// - parameters:
    ///      - error: The error from the operation.
    @inlinable
    public func fail(_ error: Error) {
        self._resolve(value: .failure(error))
    }
    
    /// Complete the promise with the passed in `EventLoopFuture<Value>`.
    ///
    /// This method is equivalent to invoking `future.cascade(to: promise)`,
    /// but sometimes may read better than its cascade counterpart.
    /// 
    /// - parameters:
    ///     - future: The future whose value will be used to succeed or fail this promise.
    /// - seealso: `EventLoopFuture.cascade(to:)`
    @inlinable
    public func completeWith(_ future: EventLoopFuture<Value>) {
        future.cascade(to: self)
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
    public func completeWith(_ result: Result<Value, Error>) {
        self._resolve(value: result)
    }

    /// Fire the associated `EventLoopFuture` on the appropriate event loop.
    ///
    /// This method provides the primary difference between the `EventLoopPromise` and most
    /// other `Promise` implementations: specifically, all callbacks fire on the `EventLoop`
    /// that was used to create the promise.
    ///
    /// - parameters:
    ///     - value: The value to fire the future with.
    @inlinable
    internal func _resolve(value: Result<Value, Error>) {
        if self.futureResult.eventLoop.inEventLoop {
            self._setValue(value: value)._run()
        } else {
            self.futureResult.eventLoop.execute {
                self._setValue(value: value)._run()
            }
        }
    }

    /// Set the future result and get the associated callbacks.
    ///
    /// - parameters:
    ///     - value: The result of the promise.
    /// - returns: The callback list to run.
    @inlinable
    internal func _setValue(value: Result<Value, Error>) -> CallbackList {
        return self.futureResult._setValue(value: value)
    }
}


/// Holder for a result that will be provided later.
///
/// Functions that promise to do work asynchronously can return an `EventLoopFuture<Value>`.
/// The recipient of such an object can then observe it to be notified when the operation completes.
///
/// The provider of a `EventLoopFuture<Value>` can create and return a placeholder object
/// before the actual result is available. For example:
///
/// ```
/// func getNetworkData(args) -> EventLoopFuture<NetworkResponse> {
///     let promise = eventLoop.makePromise(of: NetworkResponse.self)
///     queue.async {
///         . . . do some work . . .
///         promise.succeed(response)
///         . . . if it fails, instead . . .
///         promise.fail(error)
///     }
///     return promise.futureResult
/// }
/// ```
///
/// Note that this function returns immediately; the promise object will be given a value
/// later on. This behaviour is common to Future/Promise implementations in many programming
/// languages. If you are unfamiliar with this kind of object, the following resources may be
/// helpful:
///
/// - [Javascript](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Using_promises)
/// - [Scala](http://docs.scala-lang.org/overviews/core/futures.html)
/// - [Python](https://docs.google.com/document/d/10WOZgLQaYNpOrag-eTbUm-JUCCfdyfravZ4qSOQPg1M/edit)
///
/// If you receive a `EventLoopFuture<Value>` from another function, you have a number of options:
/// The most common operation is to use `flatMap()` or `map()` to add a function that will be called
/// with the eventual result.  Both methods returns a new `EventLoopFuture<Value>` immediately
/// that will receive the return value from your function, but they behave differently. If you have
/// a function that can return synchronously, the `map` function will transform the result of type
/// `Value` to a the new result of type `NewValue` and return an `EventLoopFuture<NewValue>`.
///
/// ```
/// let networkData = getNetworkData(args)
///
/// // When network data is received, convert it.
/// let processedResult: EventLoopFuture<Processed> = networkData.map { (n: NetworkResponse) -> Processed in
///     ... parse network data ....
///     return processedResult
/// }
/// ```
///
/// If however you need to do more asynchronous processing, you can call `flatMap()`. The return value of the
/// function passed to `flatMap` must be a new `EventLoopFuture<NewValue>` object: the return value of `flatMap()` is
/// a new `EventLoopFuture<NewValue>` that will contain the eventual result of both the original operation and
/// the subsequent one.
///
/// ```
/// // When converted network data is available, begin the database operation.
/// let databaseResult: EventLoopFuture<DBResult> = processedResult.flatMap { (p: Processed) -> EventLoopFuture<DBResult> in
///     return someDatabaseOperation(p)
/// }
/// ```
///
/// In essence, future chains created via `flatMap()` provide a form of data-driven asynchronous programming
/// that allows you to dynamically declare data dependencies for your various operations.
///
/// `EventLoopFuture` chains created via `flatMap()` are sufficient for most purposes. All of the registered
/// functions will eventually run in order. If one of those functions throws an error, that error will
/// bypass the remaining functions. You can use `flatMapError()` to handle and optionally recover from
/// errors in the middle of a chain.
///
/// At the end of an `EventLoopFuture` chain, you can use `whenSuccess()` or `whenFailure()` to add an
/// observer callback that will be invoked with the result or error at that point. (Note: If you ever
/// find yourself invoking `promise.succeed()` from inside a `whenSuccess()` callback, you probably should
/// use `flatMap()` or `cascade(to:)` instead.)
///
/// `EventLoopFuture` objects are typically obtained by:
/// * Using `.flatMap()` on an existing future to create a new future for the next step in a series of operations.
/// * Initializing an `EventLoopFuture` that already has a value or an error
///
/// ### Threading and Futures
///
/// One of the major performance advantages of NIO over something like Node.js or Python’s asyncio is that NIO will
/// by default run multiple event loops at once, on different threads. As most network protocols do not require
/// blocking operation, at least in their low level implementations, this provides enormous speedups on machines
/// with many cores such as most modern servers.
///
/// However, it can present a challenge at higher levels of abstraction when coordination between those threads
/// becomes necessary. This is usually the case whenever the events on one connection (that is, one `Channel`) depend
/// on events on another one. As these `Channel`s may be scheduled on different event loops (and so different threads)
/// care needs to be taken to ensure that communication between the two loops is done in a thread-safe manner that
/// avoids concurrent mutation of shared state from multiple loops at once.
///
/// The main primitives NIO provides for this use are the `EventLoopPromise` and `EventLoopFuture`. As their names
/// suggest, these two objects are aware of event loops, and so can help manage the safety and correctness of your
/// programs. However, understanding the exact semantics of these objects is critical to ensuring the safety of your code.
///
/// ####  Callbacks
///
/// The most important principle of the `EventLoopPromise` and `EventLoopFuture` is this: all callbacks registered on
/// an `EventLoopFuture` will execute on the thread corresponding to the event loop that created the `Future`,
/// *regardless* of what thread succeeds or fails the corresponding `EventLoopPromise`.
///
/// This means that if *your code* created the `EventLoopPromise`, you can be extremely confident of what thread the
/// callback will execute on: after all, you held the event loop in hand when you created the `EventLoopPromise`.
/// However, if your code is handed an `EventLoopFuture` or `EventLoopPromise`, and you want to register callbacks
/// on those objects, you cannot be confident that those callbacks will execute on the same `EventLoop` that your
/// code does.
///
/// This presents a problem: how do you ensure thread-safety when registering callbacks on an arbitrary
/// `EventLoopFuture`? The short answer is that when you are holding an `EventLoopFuture`, you can always obtain a
/// new `EventLoopFuture` whose callbacks will execute on your event loop. You do this by calling
/// `EventLoopFuture.hop(to:)`. This function returns a new `EventLoopFuture` whose callbacks are guaranteed
/// to fire on the provided event loop. As an added bonus, `hopTo` will check whether the provided `EventLoopFuture`
/// was already scheduled to dispatch on the event loop in question, and avoid doing any work if that was the case.
///
/// This means that for any `EventLoopFuture` that your code did not create itself (via
/// `EventLoopPromise.futureResult`), use of `hopTo` is **strongly encouraged** to help guarantee thread-safety. It
/// should only be elided when thread-safety is provably not needed.
///
/// The "thread affinity" of `EventLoopFuture`s is critical to writing safe, performant concurrent code without
/// boilerplate. It allows you to avoid needing to write or use locks in your own code, instead using the natural
/// synchronization of the `EventLoop` to manage your thread-safety. In general, if any of your `ChannelHandler`s
/// or `EventLoopFuture` callbacks need to invoke a lock (either directly or in the form of `DispatchQueue`) this
/// should be considered a code smell worth investigating: the `EventLoop`-based synchronization guarantees of
/// `EventLoopFuture` should be sufficient to guarantee thread-safety.
public final class EventLoopFuture<Value> {
    // TODO: Provide a tracing facility.  It would be nice to be able to set '.debugTrace = true' on any EventLoopFuture or EventLoopPromise and have every subsequent chained EventLoopFuture report the success result or failure error.  That would simplify some debugging scenarios.
    @usableFromInline
    internal var _value: Optional<Result<Value, Error>>

    /// The `EventLoop` which is tied to the `EventLoopFuture` and is used to notify all registered callbacks.
    public let eventLoop: EventLoop

    /// Callbacks that should be run when this `EventLoopFuture<Value>` gets a value.
    /// These callbacks may give values to other `EventLoopFuture`s; if that happens,
    /// they return any callbacks from those `EventLoopFuture`s so that we can run
    /// the entire chain from the top without recursing.
    @usableFromInline
    internal var _callbacks: CallbackList

    @inlinable
    internal init(_eventLoop eventLoop: EventLoop, file: StaticString, line: UInt) {
        self.eventLoop = eventLoop
        self._value = nil
        self._callbacks = .init()

        debugOnly {
            eventLoop._promiseCreated(futureIdentifier: _NIOEventLoopFutureIdentifier(self), file: file, line: line)
        }
    }

    /// A EventLoopFuture<Value> that has already succeeded
    @inlinable
    internal init(eventLoop: EventLoop, value: Value) {
        self.eventLoop = eventLoop
        self._value = .success(value)
        self._callbacks = .init()
    }

    /// A EventLoopFuture<Value> that has already failed
    @inlinable
    internal init(eventLoop: EventLoop, error: Error) {
        self.eventLoop = eventLoop
        self._value = .failure(error)
        self._callbacks = .init()
    }

    deinit {
        debugOnly {
            if let creation = eventLoop._promiseCompleted(futureIdentifier: _NIOEventLoopFutureIdentifier(self)) {
                if self._value == nil {
                    fatalError("leaking promise created at \(creation)", file: creation.file, line: creation.line)
                }
            } else {
                precondition(self._value != nil, "leaking an unfulfilled Promise")
            }
        }
    }
}

extension EventLoopFuture: Equatable {
    public static func ==(lhs: EventLoopFuture, rhs: EventLoopFuture) -> Bool {
        return lhs === rhs
    }
}

// MARK: flatMap and map

// 'flatMap' and 'map' implementations. This is really the key of the entire system.
extension EventLoopFuture {
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
    public func flatMap<NewValue>(_ callback: @escaping (Value) -> EventLoopFuture<NewValue>) -> EventLoopFuture<NewValue> {
        let next = EventLoopPromise<NewValue>.makeUnleakablePromise(eventLoop: self.eventLoop)
        self._whenComplete {
            switch self._value! {
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
        return next.futureResult
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
    public func flatMapThrowing<NewValue>(_ callback: @escaping (Value) throws -> NewValue) -> EventLoopFuture<NewValue> {
        let next = EventLoopPromise<NewValue>.makeUnleakablePromise(eventLoop: self.eventLoop)
        self._whenComplete {
            switch self._value! {
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
        return next.futureResult
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
    public func flatMapErrorThrowing(_ callback: @escaping (Error) throws -> Value) -> EventLoopFuture<Value> {
        let next = EventLoopPromise<Value>.makeUnleakablePromise(eventLoop: self.eventLoop)
        self._whenComplete {
            switch self._value! {
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
        return next.futureResult
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
    public func map<NewValue>(_ callback: @escaping (Value) -> (NewValue)) -> EventLoopFuture<NewValue> {
        if NewValue.self == Value.self && NewValue.self == Void.self {
            self.whenSuccess(callback as! (Value) -> Void)
            return self as! EventLoopFuture<NewValue>
        } else {
            let next = EventLoopPromise<NewValue>.makeUnleakablePromise(eventLoop: self.eventLoop)
            self._whenComplete {
                return next._setValue(value: self._value!.map(callback))
            }
            return next.futureResult
        }
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
    public func flatMapError(_ callback: @escaping (Error) -> EventLoopFuture<Value>) -> EventLoopFuture<Value> {
        let next = EventLoopPromise<Value>.makeUnleakablePromise(eventLoop: self.eventLoop)
        self._whenComplete {
            switch self._value! {
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
        return next.futureResult
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
    public func flatMapResult<NewValue, SomeError: Error>(_ body: @escaping (Value) -> Result<NewValue, SomeError>) -> EventLoopFuture<NewValue> {
        let next = EventLoopPromise<NewValue>.makeUnleakablePromise(eventLoop: self.eventLoop)
        self._whenComplete {
            switch self._value! {
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
        return next.futureResult
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
    public func recover(_ callback: @escaping (Error) -> Value) -> EventLoopFuture<Value> {
        let next = EventLoopPromise<Value>.makeUnleakablePromise(eventLoop: self.eventLoop)
        self._whenComplete {
            switch self._value! {
            case .success(let t):
                return next._setValue(value: .success(t))
            case .failure(let e):
                return next._setValue(value: .success(callback(e)))
            }
        }
        return next.futureResult
    }


    /// Add a callback.  If there's already a value, invoke it and return the resulting list of new callback functions.
    @inlinable
    internal func _addCallback(_ callback: @escaping () -> CallbackList) -> CallbackList {
        self.eventLoop.assertInEventLoop()
        if self._value == nil {
            self._callbacks.append(callback)
            return CallbackList()
        }
        return callback()
    }

    /// Add a callback.  If there's already a value, run as much of the chain as we can.
    @inlinable
    internal func _whenComplete(_ callback: @escaping () -> CallbackList) {
        if self.eventLoop.inEventLoop {
            self._addCallback(callback)._run()
        } else {
            self.eventLoop.execute {
                self._addCallback(callback)._run()
            }
        }
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
    public func whenSuccess(_ callback: @escaping (Value) -> Void) {
        self._whenComplete {
            if case .success(let t) = self._value! {
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
    /// - parameters:
    ///     - callback: The callback that is called with the failed result of the `EventLoopFuture`.
    @inlinable
    public func whenFailure(_ callback: @escaping (Error) -> Void) {
        self._whenComplete {
            if case .failure(let e) = self._value! {
                callback(e)
            }
            return CallbackList()
        }
    }

    /// Adds an observer callback to this `EventLoopFuture` that is called when the
    /// `EventLoopFuture` has any result.
    ///
    /// - parameters:
    ///     - callback: The callback that is called when the `EventLoopFuture` is fulfilled.
    @inlinable
    public func whenComplete(_ callback: @escaping (Result<Value, Error>) -> Void) {
        self._whenComplete {
            callback(self._value!)
            return CallbackList()
        }
    }


    /// Internal: Set the value and return a list of callbacks that should be invoked as a result.
    @inlinable
    internal func _setValue(value: Result<Value, Error>) -> CallbackList {
        self.eventLoop.assertInEventLoop()
        if self._value == nil {
            self._value = value
            let callbacks = self._callbacks
            self._callbacks = CallbackList()
            return callbacks
        }
        return CallbackList()
    }
}

// MARK: and

extension EventLoopFuture {
    /// Return a new `EventLoopFuture` that succeeds when this "and" another
    /// provided `EventLoopFuture` both succeed. It then provides the pair
    /// of results. If either one fails, the combined `EventLoopFuture` will fail with
    /// the first error encountered.
    @inlinable
    public func and<OtherValue>(_ other: EventLoopFuture<OtherValue>) -> EventLoopFuture<(Value, OtherValue)> {
        let promise = EventLoopPromise<(Value, OtherValue)>.makeUnleakablePromise(eventLoop: self.eventLoop)
        var tvalue: Value?
        var uvalue: OtherValue?

        assert(self.eventLoop === promise.futureResult.eventLoop)
        self._whenComplete { () -> CallbackList in
            switch self._value! {
            case .failure(let error):
                return promise._setValue(value: .failure(error))
            case .success(let t):
                if let u = uvalue {
                    return promise._setValue(value: .success((t, u)))
                } else {
                    tvalue = t
                }
            }
            return CallbackList()
        }

        let hopOver = other.hop(to: self.eventLoop)
        hopOver._whenComplete { () -> CallbackList in
            self.eventLoop.assertInEventLoop()
            switch other._value! {
            case .failure(let error):
                return promise._setValue(value: .failure(error))
            case .success(let u):
                if let t = tvalue {
                    return promise._setValue(value: .success((t, u)))
                } else {
                    uvalue = u
                }
            }
            return CallbackList()
        }

        return promise.futureResult
    }

    /// Return a new EventLoopFuture that contains this "and" another value.
    /// This is just syntactic sugar for `future.and(loop.makeSucceedFuture(value))`.
    @inlinable
    public func and<OtherValue>(value: OtherValue) -> EventLoopFuture<(Value, OtherValue)> {
        return self.and(EventLoopFuture<OtherValue>(eventLoop: self.eventLoop, value: value))
    }
}

// MARK: cascade

extension EventLoopFuture {
    /// Fulfills the given `EventLoopPromise` with the results from this `EventLoopFuture`.
    ///
    /// This is useful when allowing users to provide promises for you to fulfill, but
    /// when you are calling functions that return their own promises. They allow you to
    /// tidy up your computational pipelines.
    ///
    /// For example:
    /// ```
    /// doWork().flatMap {
    ///     doMoreWork($0)
    /// }.flatMap {
    ///     doYetMoreWork($0)
    /// }.flatMapError {
    ///     maybeRecoverFromError($0)
    /// }.map {
    ///     transformData($0)
    /// }.cascade(to: userPromise)
    /// ```
    ///
    /// - Parameter to: The `EventLoopPromise` to fulfill with the results of this future.
    /// - SeeAlso: `EventLoopPromise.completeWith(_:)`
    @inlinable
    public func cascade(to promise: EventLoopPromise<Value>?) {
        guard let promise = promise else { return }
        self.whenComplete { result in
            switch result {
            case let .success(value): promise.succeed(value)
            case let .failure(error): promise.fail(error)
            }
        }
    }

    /// Fulfills the given `EventLoopPromise` only when this `EventLoopFuture` succeeds.
    ///
    /// If you are doing work that fulfills a type that doesn't match the expected `EventLoopPromise` value, add an
    /// intermediate `map`.
    ///
    /// For example:
    /// ```
    /// let boolPromise = eventLoop.makePromise(of: Bool.self)
    /// doWorkReturningInt().map({ $0 >= 0 }).cascade(to: boolPromise)
    /// ```
    ///
    /// - Parameter to: The `EventLoopPromise` to fulfill when a successful result is available.
    @inlinable
    public func cascadeSuccess(to promise: EventLoopPromise<Value>?) {
        guard let promise = promise else { return }
        self.whenSuccess { promise.succeed($0) }
    }

    /// Fails the given `EventLoopPromise` with the error from this `EventLoopFuture` if encountered.
    ///
    /// This is an alternative variant of `cascade` that allows you to potentially return early failures in
    /// error cases, while passing the user `EventLoopPromise` onwards.
    ///
    /// - Parameter to: The `EventLoopPromise` that should fail with the error of this `EventLoopFuture`.
    @inlinable
    public func cascadeFailure<NewValue>(to promise: EventLoopPromise<NewValue>?) {
        guard let promise = promise else { return }
        self.whenFailure { promise.fail($0) }
    }
}

// MARK: wait

extension EventLoopFuture {
    /// Wait for the resolution of this `EventLoopFuture` by blocking the current thread until it
    /// resolves.
    ///
    /// If the `EventLoopFuture` resolves with a value, that value is returned from `wait()`. If
    /// the `EventLoopFuture` resolves with an error, that error will be thrown instead.
    /// `wait()` will block whatever thread it is called on, so it must not be called on event loop
    /// threads: it is primarily useful for testing, or for building interfaces between blocking
    /// and non-blocking code.
    ///
    /// - returns: The value of the `EventLoopFuture` when it completes.
    /// - throws: The error value of the `EventLoopFuture` if it errors.
    @inlinable
    public func wait(file: StaticString = #file, line: UInt = #line) throws -> Value {
        self.eventLoop._preconditionSafeToWait(file: file, line: line)

        var v: Result<Value, Error>? = nil
        let lock = ConditionLock(value: 0)
        self._whenComplete { () -> CallbackList in
            lock.lock()
            v = self._value
            lock.unlock(withValue: 1)
            return CallbackList()
        }
        lock.lock(whenValue: 1)
        lock.unlock()

        switch(v!) {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}

// MARK: fold

extension EventLoopFuture {
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
    public func fold<OtherValue>(_ futures: [EventLoopFuture<OtherValue>],
                                 with combiningFunction: @escaping (Value, OtherValue) -> EventLoopFuture<Value>) -> EventLoopFuture<Value> {
        func fold0() -> EventLoopFuture<Value> {
            let body = futures.reduce(self) { (f1: EventLoopFuture<Value>, f2: EventLoopFuture<OtherValue>) -> EventLoopFuture<Value> in
                let newFuture = f1.and(f2).flatMap { (args: (Value, OtherValue)) -> EventLoopFuture<Value> in
                    let (f1Value, f2Value) = args
                    self.eventLoop.assertInEventLoop()
                    return combiningFunction(f1Value, f2Value)
                }
                assert(newFuture.eventLoop === self.eventLoop)
                return newFuture
            }
            return body
        }

        if self.eventLoop.inEventLoop {
            return fold0()
        } else {
            let promise = self.eventLoop.makePromise(of: Value.self)
            self.eventLoop.execute {
                fold0().cascade(to: promise)
            }
            return promise.futureResult
        }
    }
}

// MARK: reduce

extension EventLoopFuture {
    /// Returns a new `EventLoopFuture` that fires only when all the provided futures complete.
    /// The new `EventLoopFuture` contains the result of reducing the `initialResult` with the
    /// values of the `[EventLoopFuture<NewValue>]`.
    ///
    /// This function makes copies of the result for each EventLoopFuture, for a version which avoids
    /// making copies, check out `reduce<NewValue>(into:)`.
    ///
    /// The returned `EventLoopFuture` will fail as soon as a failure is encountered in any of the
    /// `futures`. However, the failure will not occur until all preceding
    /// `EventLoopFutures` have completed. At the point the failure is encountered, all subsequent
    /// `EventLoopFuture` objects will no longer be waited for. This function therefore fails fast: once
    /// a failure is encountered, it will immediately fail the overall `EventLoopFuture`.
    ///
    /// - parameters:
    ///     - initialResult: An initial result to begin the reduction.
    ///     - futures: An array of `EventLoopFuture` to wait for.
    ///     - eventLoop: The `EventLoop` on which the new `EventLoopFuture` callbacks will fire.
    ///     - nextPartialResult: The bifunction used to produce partial results.
    /// - returns: A new `EventLoopFuture` with the reduced value.
    public static func reduce<InputValue>(_ initialResult: Value,
                                          _ futures: [EventLoopFuture<InputValue>],
                                          on eventLoop: EventLoop,
                                          _ nextPartialResult: @escaping (Value, InputValue) -> Value) -> EventLoopFuture<Value> {
        let f0 = eventLoop.makeSucceededFuture(initialResult)

        let body = f0.fold(futures) { (t: Value, u: InputValue) -> EventLoopFuture<Value> in
            eventLoop.makeSucceededFuture(nextPartialResult(t, u))
        }

        return body
    }

    /// Returns a new `EventLoopFuture` that fires only when all the provided futures complete.
    /// The new `EventLoopFuture` contains the result of combining the `initialResult` with the
    /// values of the `[EventLoopFuture<NewValue>]`. This function is analogous to the standard library's
    /// `reduce(into:)`, which does not make copies of the result type for each `EventLoopFuture`.
    ///
    /// The returned `EventLoopFuture` will fail as soon as a failure is encountered in any of the
    /// `futures`. However, the failure will not occur until all preceding
    /// `EventLoopFutures` have completed. At the point the failure is encountered, all subsequent
    /// `EventLoopFuture` objects will no longer be waited for. This function therefore fails fast: once
    /// a failure is encountered, it will immediately fail the overall `EventLoopFuture`.
    ///
    /// - parameters:
    ///     - initialResult: An initial result to begin the reduction.
    ///     - futures: An array of `EventLoopFuture` to wait for.
    ///     - eventLoop: The `EventLoop` on which the new `EventLoopFuture` callbacks will fire.
    ///     - updateAccumulatingResult: The bifunction used to combine partialResults with new elements.
    /// - returns: A new `EventLoopFuture` with the combined value.
    public static func reduce<InputValue>(into initialResult: Value,
                                          _ futures: [EventLoopFuture<InputValue>],
                                          on eventLoop: EventLoop,
                                          _ updateAccumulatingResult: @escaping (inout Value, InputValue) -> Void) -> EventLoopFuture<Value> {
        let p0 = eventLoop.makePromise(of: Value.self)
        var value: Value = initialResult

        let f0 = eventLoop.makeSucceededFuture(())
        let future = f0.fold(futures) { (_: (), newValue: InputValue) -> EventLoopFuture<Void> in
            eventLoop.assertInEventLoop()
            updateAccumulatingResult(&value, newValue)
            return eventLoop.makeSucceededFuture(())
        }

        future.whenSuccess {
            eventLoop.assertInEventLoop()
            p0.succeed(value)
        }
        future.whenFailure { (error) in
            eventLoop.assertInEventLoop()
            p0.fail(error)
        }
        return p0.futureResult
    }
}

// MARK: "fail fast" reduce

extension EventLoopFuture {
    /// Returns a new `EventLoopFuture` that succeeds only if all of the provided futures succeed.
    ///
    /// This method acts as a successful completion notifier - values fulfilled by each future are discarded.
    ///
    /// The returned `EventLoopFuture` fails as soon as any of the provided futures fail.
    ///
    /// If it is desired to always succeed, regardless of failures, use `andAllComplete` instead.
    /// - Parameters:
    ///     - futures: An array of homogenous `EventLoopFutures`s to wait for.
    ///     - on: The `EventLoop` on which the new `EventLoopFuture` callbacks will execute on.
    /// - Returns: A new `EventLoopFuture` that waits for the other futures to succeed.
    @inlinable
    public static func andAllSucceed(_ futures: [EventLoopFuture<Value>], on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        EventLoopFuture.andAllSucceed(futures, promise: promise)
        return promise.futureResult
    }

    /// Succeeds the promise if all of the provided futures succeed. If any of the provided
    /// futures fail then the `promise` will be failed -- even if some futures are yet to complete.
    ///
    /// If the results of all futures should be collected use `andAllComplete` instead.
    ///
    /// - Parameters:
    ///     - futures: An array of homogenous `EventLoopFutures`s to wait for.
    ///     - promise: The `EventLoopPromise` to complete with the result of this call.
    @inlinable
    public static func andAllSucceed(_ futures: [EventLoopFuture<Value>], promise: EventLoopPromise<Void>) {
        let eventLoop = promise.futureResult.eventLoop

        if eventLoop.inEventLoop {
            self._reduceSuccesses0(promise, futures, eventLoop, onValue: { _, _ in })
        } else {
            eventLoop.execute {
                self._reduceSuccesses0(promise, futures, eventLoop, onValue: { _, _ in })
            }
        }
    }

    /// Returns a new `EventLoopFuture` that succeeds only if all of the provided futures succeed.
    /// The new `EventLoopFuture` will contain all of the values fulfilled by the futures.
    ///
    /// The returned `EventLoopFuture` will fail as soon as any of the futures fails.
    /// - Parameters:
    ///     - futures: An array of homogenous `EventLoopFuture`s to wait on for fulfilled values.
    ///     - on: The `EventLoop` on which the new `EventLoopFuture` callbacks will fire.
    /// - Returns: A new `EventLoopFuture` with all of the values fulfilled by the provided futures.
    public static func whenAllSucceed(_ futures: [EventLoopFuture<Value>], on eventLoop: EventLoop) -> EventLoopFuture<[Value]> {
        let promise = eventLoop.makePromise(of: [Value].self)
        EventLoopFuture.whenAllSucceed(futures, promise: promise)
        return promise.futureResult
    }

    /// Completes the `promise` with the values of all `futures` if all provided futures succeed. If
    /// any of the provided futures fail then `promise` will be failed.
    ///
    /// If the _results of all futures should be collected use `andAllComplete` instead.
    ///
    /// - Parameters:
    ///     - futures: An array of homogenous `EventLoopFutures`s to wait for.
    ///     - promise: The `EventLoopPromise` to complete with the result of this call.
    public static func whenAllSucceed(_ futures: [EventLoopFuture<Value>], promise: EventLoopPromise<[Value]>) {
        let eventLoop = promise.futureResult.eventLoop
        let reduced = eventLoop.makePromise(of: Void.self)

        var results: [Value?] = .init(repeating: nil, count: futures.count)
        let callback = { (index: Int, result: Value) in
            results[index] = result
        }

        if eventLoop.inEventLoop {
            self._reduceSuccesses0(reduced, futures, eventLoop, onValue: callback)
        } else {
            eventLoop.execute {
                self._reduceSuccesses0(reduced, futures, eventLoop, onValue: callback)
            }
        }

        reduced.futureResult.whenComplete { result in
            switch result {
            case .success:
              // verify that all operations have been completed
              assert(!results.contains(where: { $0 == nil }))
                promise.succeed(results.map { $0! })
            case .failure(let error):
                promise.fail(error)
            }
        }
    }

    /// Loops through the futures array and attaches callbacks to execute `onValue` on the provided `EventLoop` when
    /// they succeed. The `onValue` will receive the index of the future that fulfilled the provided `Result`.
    ///
    /// Once all the futures have succeed, the provided promise will succeed.
    /// Once any future fails, the provided promise will fail.
    @inlinable
    internal static func _reduceSuccesses0<InputValue>(_ promise: EventLoopPromise<Void>,
                                                       _ futures: [EventLoopFuture<InputValue>],
                                                       _ eventLoop: EventLoop,
                                                       onValue: @escaping (Int, InputValue) -> Void) {
        eventLoop.assertInEventLoop()

        var remainingCount = futures.count

        if remainingCount == 0 {
            promise.succeed(())
            return
        }

        // Sends the result to `onValue` in case of success and succeeds/fails the input promise, if appropriate.
        func processResult(_ index: Int, _ result: Result<InputValue, Error>) {
            switch result {
            case .success(let result):
                onValue(index, result)
                remainingCount -= 1

                if remainingCount == 0 {
                    promise.succeed(())
                }
            case .failure(let error):
                promise.fail(error)
            }
        }
        // loop through the futures to chain callbacks to execute on the initiating event loop and grab their index
        // in the "futures" to pass their result to the caller
        for (index, future) in futures.enumerated() {
            if future.eventLoop.inEventLoop,
                let result = future._value {
                // Fast-track already-fulfilled results without the overhead of calling `whenComplete`. This can yield a
                // ~20% performance improvement in the case of large arrays where all elements are already fulfilled.
                processResult(index, result)
                if case .failure = result {
                    return  // Once the promise is failed, future results do not need to be processed.
                }
            } else {
                future.hop(to: eventLoop)
                    .whenComplete { result in processResult(index, result) }
            }
        }
    }
}

// MARK: "fail slow" reduce

extension EventLoopFuture {
    /// Returns a new `EventLoopFuture` that succeeds when all of the provided `EventLoopFuture`s complete.
    ///
    /// The returned `EventLoopFuture` always succeeds, acting as a completion notification.
    /// Values fulfilled by each future are discarded.
    ///
    /// If the results are needed, use `whenAllComplete` instead.
    /// - Parameters:
    ///     - futures: An array of homogenous `EventLoopFuture`s to wait for.
    ///     - on: The `EventLoop` on which the new `EventLoopFuture` callbacks will execute on.
    /// - Returns: A new `EventLoopFuture` that succeeds after all futures complete.
    @inlinable
    public static func andAllComplete(_ futures: [EventLoopFuture<Value>], on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        EventLoopFuture.andAllComplete(futures, promise: promise)
        return promise.futureResult
    }

    /// Completes a `promise` when all of the provided `EventLoopFuture`s have completed.
    ///
    /// The promise will always be succeeded, regardless of the outcome of the individual futures.
    ///
    /// If the results are required, use `whenAllComplete` instead.
    ///
    /// - Parameters:
    ///     - futures: An array of homogenous `EventLoopFuture`s to wait for.
    ///     - promise: The `EventLoopPromise` to succeed when all futures have completed.
    @inlinable
    public static func andAllComplete(_ futures: [EventLoopFuture<Value>], promise: EventLoopPromise<Void>) {
        let eventLoop = promise.futureResult.eventLoop

        if eventLoop.inEventLoop {
            self._reduceCompletions0(promise, futures, eventLoop, onResult: { _, _ in })
        } else {
            eventLoop.execute {
                self._reduceCompletions0(promise, futures, eventLoop, onResult: { _, _ in })
            }
        }
    }

    /// Returns a new `EventLoopFuture` that succeeds when all of the provided `EventLoopFuture`s complete.
    /// The new `EventLoopFuture` will contain an array of results, maintaining ordering for each of the `EventLoopFuture`s.
    ///
    /// The returned `EventLoopFuture` always succeeds, regardless of any failures from the waiting futures.
    ///
    /// If it is desired to flatten them into a single `EventLoopFuture` that fails on the first `EventLoopFuture` failure,
    /// use one of the `reduce` methods instead.
    /// - Parameters:
    ///     - futures: An array of homogenous `EventLoopFuture`s to gather results from.
    ///     - on: The `EventLoop` on which the new `EventLoopFuture` callbacks will fire.
    /// - Returns: A new `EventLoopFuture` with all the results of the provided futures.
    @inlinable
    public static func whenAllComplete(_ futures: [EventLoopFuture<Value>],
                                       on eventLoop: EventLoop) -> EventLoopFuture<[Result<Value, Error>]> {
        let promise = eventLoop.makePromise(of: [Result<Value, Error>].self)
        EventLoopFuture.whenAllComplete(futures, promise: promise)
        return promise.futureResult
    }

    /// Completes a `promise` with the results of all provided `EventLoopFuture`s.
    ///
    /// The promise will always be succeeded, regardless of the outcome of the futures.
    ///
    /// - Parameters:
    ///     - futures: An array of homogenous `EventLoopFuture`s to gather results from.
    ///     - promise: The `EventLoopPromise` to complete with the result of the futures.
    @inlinable
    public static func whenAllComplete(_ futures: [EventLoopFuture<Value>],
                                       promise: EventLoopPromise<[Result<Value, Error>]>) {
        let eventLoop = promise.futureResult.eventLoop
        let reduced = eventLoop.makePromise(of: Void.self)

        var results: [Result<Value, Error>] = .init(repeating: .failure(OperationPlaceholderError()), count: futures.count)
        let callback = { (index: Int, result: Result<Value, Error>) in
            results[index] = result
        }

        if eventLoop.inEventLoop {
            self._reduceCompletions0(reduced, futures, eventLoop, onResult: callback)
        } else {
            eventLoop.execute {
                self._reduceCompletions0(reduced, futures, eventLoop, onResult: callback)
            }
        }

        reduced.futureResult.whenComplete { result in
            switch result {
            case .success:
                // verify that all operations have been completed
                assert(!results.contains(where: {
                    guard case let .failure(error) = $0 else { return false }
                    return error is OperationPlaceholderError
                }))
                promise.succeed(results)

            case .failure(let error):
                promise.fail(error)
            }
        }
    }

    /// Loops through the futures array and attaches callbacks to execute `onResult` on the provided `EventLoop` when
    /// they complete. The `onResult` will receive the index of the future that fulfilled the provided `Result`.
    ///
    /// Once all the futures have completed, the provided promise will succeed.
    @inlinable
    internal static func _reduceCompletions0<InputValue>(_ promise: EventLoopPromise<Void>,
                                                         _ futures: [EventLoopFuture<InputValue>],
                                                         _ eventLoop: EventLoop,
                                                         onResult: @escaping (Int, Result<InputValue, Error>) -> Void) {
        eventLoop.assertInEventLoop()

        var remainingCount = futures.count

        if remainingCount == 0 {
            promise.succeed(())
            return
        }

        // Sends the result to `onResult` in case of success and succeeds the input promise, if appropriate.
        func processResult(_ index: Int, _ result: Result<InputValue, Error>) {
            onResult(index, result)
            remainingCount -= 1

            if remainingCount == 0 {
                promise.succeed(())
            }
        }
        // loop through the futures to chain callbacks to execute on the initiating event loop and grab their index
        // in the "futures" to pass their result to the caller
        for (index, future) in futures.enumerated() {
            if future.eventLoop.inEventLoop,
                let result = future._value {
                // Fast-track already-fulfilled results without the overhead of calling `whenComplete`. This can yield a
                // ~30% performance improvement in the case of large arrays where all elements are already fulfilled.
                processResult(index, result)
            } else {
                future.hop(to: eventLoop)
                    .whenComplete { result in processResult(index, result) }
            }
        }
    }
}

// MARK: hop

extension EventLoopFuture {
    /// Returns an `EventLoopFuture` that fires when this future completes, but executes its callbacks on the
    /// target event loop instead of the original one.
    ///
    /// It is common to want to "hop" event loops when you arrange some work: for example, you're closing one channel
    /// from another, and want to hop back when the close completes. This method lets you spell that requirement
    /// succinctly. It also contains an optimisation for the case when the loop you're hopping *from* is the same as
    /// the one you're hopping *to*, allowing you to avoid doing allocations in that case.
    ///
    /// - parameters:
    ///     - to: The `EventLoop` that the returned `EventLoopFuture` will run on.
    /// - returns: An `EventLoopFuture` whose callbacks run on `target` instead of the original loop.
    @inlinable
    public func hop(to target: EventLoop) -> EventLoopFuture<Value> {
        if target === self.eventLoop {
            // We're already on that event loop, nothing to do here. Save an allocation.
            return self
        }
        let hoppingPromise = target.makePromise(of: Value.self)
        self.cascade(to: hoppingPromise)
        return hoppingPromise.futureResult
    }
}

// MARK: always

extension EventLoopFuture {
    /// Adds an observer callback to this `EventLoopFuture` that is called when the
    /// `EventLoopFuture` has any result.
    ///
    /// - parameters:
    ///     - callback: the callback that is called when the `EventLoopFuture` is fulfilled.   
    /// - returns: the current `EventLoopFuture`
    @inlinable
    public func always(_ callback: @escaping (Result<Value, Error>) -> Void) -> EventLoopFuture<Value> {
        self.whenComplete { result in callback(result) }
        return self
    }
}

// MARK: unwrap

extension EventLoopFuture {
    /// Unwrap an `EventLoopFuture` where its type parameter is an `Optional`.
    ///
    /// Unwrap a future returning a new `EventLoopFuture`. When the resolved future's value is `Optional.some(...)`
    /// the new future is created with the identical value. Otherwise the `Error` passed in the `orError` parameter
    /// is thrown. For example:
    /// ```
    /// do {
    ///     try promise.futureResult.unwrap(orError: ErrorToThrow).wait()
    /// } catch ErrorToThrow {
    ///     ...
    /// }
    /// ```
    ///
    /// - parameters:
    ///     - orError: the `Error` that is thrown when then resolved future's value is `Optional.none`.
    /// - returns: an new `EventLoopFuture` with new type parameter `NewValue` and the same value as the resolved
    ///     future.
    /// - throws: the `Error` passed in the `orError` parameter when the resolved future's value is `Optional.none`.
    @inlinable
    public func unwrap<NewValue>(orError error: Error) -> EventLoopFuture<NewValue> where Value == Optional<NewValue> {
        return self.flatMapThrowing { (value) throws -> NewValue in
            guard let value = value else {
                throw error
            }
            return value
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
    public func unwrap<NewValue>(orReplace replacement: NewValue) -> EventLoopFuture<NewValue> where Value == Optional<NewValue> {
        return self.map { (value) -> NewValue in
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
    public func unwrap<NewValue>(orElse callback: @escaping () -> NewValue) -> EventLoopFuture<NewValue> where Value == Optional<NewValue> {
        return self.map { (value) -> NewValue  in
            guard let value = value else {
                return callback()
            }
            return value 
        }
    }
}

// MARK: may block 

extension EventLoopFuture {
    /// Chain an `EventLoopFuture<NewValue>` providing the result of a IO / task that may block. For example:
    ///
    ///     promise.futureResult.flatMapBlocking(onto: DispatchQueue.global()) { value in Int
    ///         blockingTask(value)
    ///     }
    ///
    /// - parameters:
    ///     - onto: the `DispatchQueue` on which the blocking IO / task specified by `callbackMayBlock` is scheduled.
    ///     - callbackMayBlock: Function that will receive the value of this `EventLoopFuture` and return
    ///         a new `EventLoopFuture`.
    @inlinable
    public func flatMapBlocking<NewValue>(onto queue: DispatchQueue, _ callbackMayBlock: @escaping (Value) throws -> NewValue)
        -> EventLoopFuture<NewValue> {
        return self.flatMap { result in
            queue.asyncWithFuture(eventLoop: self.eventLoop) { try callbackMayBlock(result) }
        }
    }

    /// Adds an observer callback to this `EventLoopFuture` that is called when the
    /// `EventLoopFuture` has a success result. The observer callback is permitted to block.
    ///
    /// An observer callback cannot return a value, meaning that this function cannot be chained
    /// from. If you are attempting to create a computation pipeline, consider `map` or `flatMap`.
    /// If you find yourself passing the results from this `EventLoopFuture` to a new `EventLoopPromise`
    /// in the body of this function, consider using `cascade` instead.
    ///
    /// - parameters:
    ///     - onto: the `DispatchQueue` on which the blocking IO / task specified by `callbackMayBlock` is scheduled.
    ///     - callbackMayBlock: The callback that is called with the successful result of the `EventLoopFuture`.
    @inlinable
    public func whenSuccessBlocking(onto queue: DispatchQueue, _ callbackMayBlock: @escaping (Value) -> Void) {
        self.whenSuccess { value in
            queue.async { callbackMayBlock(value) }
        }
    }

    /// Adds an observer callback to this `EventLoopFuture` that is called when the
    /// `EventLoopFuture` has a failure result. The observer callback is permitted to block.
    ///
    /// An observer callback cannot return a value, meaning that this function cannot be chained
    /// from. If you are attempting to create a computation pipeline, consider `recover` or `flatMapError`.
    /// If you find yourself passing the results from this `EventLoopFuture` to a new `EventLoopPromise`
    /// in the body of this function, consider using `cascade` instead.
    ///
    /// - parameters:
    ///     - onto: the `DispatchQueue` on which the blocking IO / task specified by `callbackMayBlock` is scheduled.
    ///     - callbackMayBlock: The callback that is called with the failed result of the `EventLoopFuture`.
    @inlinable
    public func whenFailureBlocking(onto queue: DispatchQueue, _ callbackMayBlock: @escaping (Error) -> Void) {
        self.whenFailure { err in
            queue.async { callbackMayBlock(err) }
        }
    }

    /// Adds an observer callback to this `EventLoopFuture` that is called when the
    /// `EventLoopFuture` has any result. The observer callback is permitted to block.
    ///
    /// - parameters:
    ///     - onto: the `DispatchQueue` on which the blocking IO / task specified by `callbackMayBlock` is scheduled.
    ///     - callbackMayBlock: The callback that is called when the `EventLoopFuture` is fulfilled.
    @inlinable
    public func whenCompleteBlocking(onto queue: DispatchQueue, _ callbackMayBlock: @escaping (Result<Value, Error>) -> Void) {
        self.whenComplete { value in
            queue.async { callbackMayBlock(value) }
        }
    }
}


/// An opaque identifier for a specific `EventLoopFuture`.
///
/// This is used only when attempting to provide high-fidelity diagnostics of leaked
/// `EventLoopFuture`s. It is entirely opaque and can only be stored in a simple
/// tracking data structure.
public struct _NIOEventLoopFutureIdentifier: Hashable {
    private var opaqueID: UInt

    @usableFromInline
    internal init<T>(_ future: EventLoopFuture<T>) {
        self.opaqueID = _NIOEventLoopFutureIdentifier.obfuscatePointerValue(future: future)
    }


    private static func obfuscatePointerValue<T>(future: EventLoopFuture<T>) -> UInt {
        // Note:
        // 1. 0xbf15ca5d is randomly picked such that it fits into both 32 and 64 bit address spaces
        // 2. XOR with 0xbf15ca5d so that Memory Graph Debugger and other memory debugging tools
        // won't see it as a reference.
        return UInt(bitPattern: ObjectIdentifier(future)) ^ 0xbf15ca5d
    }
}

// EventLoopPromise is a reference type, but by its very nature is Sendable.
extension EventLoopPromise: NIOSendable { }

#if swift(>=5.5) && canImport(_Concurrency)

// EventLoopFuture is a reference type, but it is Sendable. However, we enforce
// that by way of the guarantees of the EventLoop protocol, so the compiler cannot
// check it.
extension EventLoopFuture: @unchecked NIOSendable { }

#endif
