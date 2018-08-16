//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers


/// A `Result`-like type that is used to track the data through the
/// callback pipeline.
private enum EventLoopFutureValue<T> {
    case success(T)
    case failure(Error)
}

/// Internal list of callbacks.
///
/// Most of these are closures that pull a value from one future, call a user callback, push the
/// result into another, then return a list of callbacks from the target future that are now ready to be invoked.
///
/// In particular, note that _run() here continues to obtain and execute lists of callbacks until it completes.
/// This eliminates recursion when processing `then()` chains.
private struct CallbackList: ExpressibleByArrayLiteral {
    typealias Element = () -> CallbackList
    var firstCallback: Element?
    var furtherCallbacks: [Element]?

    init() {
        firstCallback = nil
        furtherCallbacks = nil
    }

    init(arrayLiteral: Element...) {
        self.init()
        if !arrayLiteral.isEmpty {
            firstCallback = arrayLiteral[0]
            if arrayLiteral.count > 1 {
                furtherCallbacks = Array(arrayLiteral.dropFirst())
            }
        }
    }

    mutating func append(_ callback: @escaping () -> CallbackList) {
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

    private func allCallbacks() -> [Element] {
        switch (self.firstCallback, self.furtherCallbacks) {
        case (.none, _):
            return []
        case (.some(let onlyCallback), .none):
            return [onlyCallback]
        case (.some(let first), .some(let others)):
            return [first] + others
        }
    }

    func _run() {
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
                    var pending = cbl.allCallbacks()
                    while pending.count > 0 {
                        let list = pending
                        pending = []
                        for f in list {
                            let next = f()
                            pending.append(contentsOf: next.allCallbacks())
                        }
                    }
                    break loop
                }
            }
        case (.some(let first), .some(let others)):
            var pending = [first]+others
            while pending.count > 0 {
                let list = pending
                pending = []
                for f in list {
                    let next = f()
                    pending.append(contentsOf: next.allCallbacks())
                }
            }
        }
    }

}

/// A promise to provide a result later.
///
/// This is the provider API for `EventLoopFuture<T>`. If you want to return an
/// unfulfilled `EventLoopFuture<T>` -- presumably because you are interfacing to
/// some asynchronous service that will return a real result later, follow this
/// pattern:
///
/// ```
/// func someAsyncOperation(args) -> EventLoopFuture<ResultType> {
///     let promise: EventLoopPromise<ResultType> = eventLoop.newPromise()
///     someAsyncOperationWithACallback(args) { result -> Void in
///         // when finished...
///         promise.succeed(result: result)
///         // if error...
///         promise.fail(error: error)
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
///     use `.then()`
/// * If you just want to get a value back after running something on another thread,
///     use `EventLoopFuture<ResultType>.async()`
/// * If you already have a value and need an `EventLoopFuture<>` object to plug into
///     some other API, create an already-resolved object with `eventLoop.newSucceededFuture(result)`
///     or `eventLoop.newFailedFuture(error:)`.
///
public struct EventLoopPromise<T> {
    /// The `EventLoopFuture` which is used by the `EventLoopPromise`. You can use it to add callbacks which are notified once the
    /// `EventLoopPromise` is completed.
    public let futureResult: EventLoopFuture<T>

    /// General initializer
    ///
    /// - parameters:
    ///     - eventLoop: The event loop this promise is tied to.
    ///     - file: The file this promise was allocated in, for debugging purposes.
    ///     - line: The line this promise was allocated on, for debugging purposes.
    init(eventLoop: EventLoop, file: StaticString, line: UInt) {
        futureResult = EventLoopFuture<T>(eventLoop: eventLoop, file: file, line: line)
    }

    /// Deliver a successful result to the associated `EventLoopFuture<T>` object.
    ///
    /// - parameters:
    ///     - result: The successful result of the operation.
    public func succeed(result: T) {
        _resolve(value: .success(result))
    }

    /// Deliver an error to the associated `EventLoopFuture<T>` object.
    ///
    /// - parameters:
    ///      - error: The error from the operation.
    public func fail(error: Error) {
        _resolve(value: .failure(error))
    }

    /// Fire the associated `EventLoopFuture` on the appropriate event loop.
    ///
    /// This method provides the primary difference between the `EventLoopPromise` and most
    /// other `Promise` implementations: specifically, all callbacks fire on the `EventLoop`
    /// that was used to create the promise.
    ///
    /// - parameters:
    ///     - value: The value to fire the future with.
    private func _resolve(value: EventLoopFutureValue<T>) {
        if futureResult.eventLoop.inEventLoop {
            _setValue(value: value)._run()
        } else {
            futureResult.eventLoop.execute {
                self._setValue(value: value)._run()
            }
        }
    }

    /// Set the future result and get the associated callbacks.
    ///
    /// - parameters:
    ///     - value: The result of the promise.
    /// - returns: The callback list to run.
    fileprivate func _setValue(value: EventLoopFutureValue<T>) -> CallbackList {
        return futureResult._setValue(value: value)
    }
}


/// Holder for a result that will be provided later.
///
/// Functions that promise to do work asynchronously can return an `EventLoopFuture<T>`.
/// The recipient of such an object can then observe it to be notified when the operation completes.
///
/// The provider of a `EventLoopFuture<T>` can create and return a placeholder object
/// before the actual result is available. For example:
///
/// ```
/// func getNetworkData(args) -> EventLoopFuture<NetworkResponse> {
///     let promise: EventLoopPromise<NetworkResponse> = eventLoop.newPromise()
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
/// If you receive a `EventLoopFuture<T>` from another function, you have a number of options:
/// The most common operation is to use `then()` or `map()` to add a function that will be called
/// with the eventual result.  Both methods returns a new `EventLoopFuture<T>` immediately
/// that will receive the return value from your function, but they behave differently. If you have
/// a function that can return synchronously, the `map` function will transform the result `T` to a
/// the new result value `U` and return an `EventLoopFuture<U>`.
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
/// If however you need to do more asynchronous processing, you can call `then()`. The return value of the
/// function passed to `then` must be a new `EventLoopFuture<U>` object: the return value of `then()` is
/// a new `EventLoopFuture<U>` that will contain the eventual result of both the original operation and
/// the subsequent one.
///
/// ```
/// // When converted network data is available, begin the database operation.
/// let databaseResult: EventLoopFuture<DBResult> = processedResult.then { (p: Processed) -> EventLoopFuture<DBResult> in
///     return someDatabaseOperation(p)
/// }
/// ```
///
/// In essence, future chains created via `then()` provide a form of data-driven asynchronous programming
/// that allows you to dynamically declare data dependencies for your various operations.
///
/// `EventLoopFuture` chains created via `then()` are sufficient for most purposes. All of the registered
/// functions will eventually run in order. If one of those functions throws an error, that error will
/// bypass the remaining functions. You can use `thenIfError()` to handle and optionally recover from
/// errors in the middle of a chain.
///
/// At the end of an `EventLoopFuture` chain, you can use `whenSuccess()` or `whenFailure()` to add an
/// observer callback that will be invoked with the result or error at that point. (Note: If you ever
/// find yourself invoking `promise.succeed()` from inside a `whenSuccess()` callback, you probably should
/// use `then()` or `cascade(promise:)` instead.)
///
/// `EventLoopFuture` objects are typically obtained by:
/// * Using `EventLoopFuture<T>.async` or a similar wrapper function.
/// * Using `.then()` on an existing future to create a new future for the next step in a series of operations.
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
/// `EventLoopFuture.hopTo(eventLoop:)`. This function returns a new `EventLoopFuture` whose callbacks are guaranteed
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
public final class EventLoopFuture<T> {
    // TODO: Provide a tracing facility.  It would be nice to be able to set '.debugTrace = true' on any EventLoopFuture or EventLoopPromise and have every subsequent chained EventLoopFuture report the success result or failure error.  That would simplify some debugging scenarios.
    fileprivate var value: EventLoopFutureValue<T>? {
        didSet {
            _isFulfilled.store(true)
        }
    }

    private let _isFulfilled: UnsafeEmbeddedAtomic<Bool>
    
    /// The `EventLoop` which is tied to the `EventLoopFuture` and is used to notify all registered callbacks.
    public let eventLoop: EventLoop

    /// Whether this `EventLoopFuture` has been fulfilled. This is a thread-safe
    /// computed-property.
    internal var isFulfilled: Bool {
        return _isFulfilled.load()
    }

    /// Callbacks that should be run when this `EventLoopFuture<T>` gets a value.
    /// These callbacks may give values to other `EventLoopFuture`s; if that happens,
    /// they return any callbacks from those `EventLoopFuture`s so that we can run
    /// the entire chain from the top without recursing.
    fileprivate var callbacks: CallbackList = CallbackList()

    private init(eventLoop: EventLoop, value: EventLoopFutureValue<T>?, file: StaticString, line: UInt) {
        self.eventLoop = eventLoop
        self.value = value
        self._isFulfilled = UnsafeEmbeddedAtomic(value: value != nil)

        debugOnly {
            if let me = eventLoop as? SelectableEventLoop {
                me.promiseCreationStoreAdd(future: self, file: file, line: line)
            }
        }
    }


    fileprivate convenience init(eventLoop: EventLoop, file: StaticString, line: UInt) {
        self.init(eventLoop: eventLoop, value: nil, file: file, line: line)
    }

    /// A EventLoopFuture<T> that has already succeeded
    convenience init(eventLoop: EventLoop, result: T, file: StaticString, line: UInt) {
        self.init(eventLoop: eventLoop, value: .success(result), file: file, line: line)
    }

    /// A EventLoopFuture<T> that has already failed
    convenience init(eventLoop: EventLoop, error: Error, file: StaticString, line: UInt) {
        self.init(eventLoop: eventLoop, value: .failure(error), file: file, line: line)
    }

    deinit {
        debugOnly {
            if let eventLoop = self.eventLoop as? SelectableEventLoop {
                let creation = eventLoop.promiseCreationStoreRemove(future: self)
                if !isFulfilled {
                    fatalError("leaking promise created at \(creation)", file: creation.file, line: creation.line)
                }
            } else {
                precondition(isFulfilled, "leaking an unfulfilled Promise")
            }
        }
        
        self._isFulfilled.destroy()
    }
}

extension EventLoopFuture: Equatable {
    public static func ==(lhs: EventLoopFuture, rhs: EventLoopFuture) -> Bool {
        return lhs === rhs
    }
}

// 'then' and 'map' implementations. This is really the key of the entire system.
extension EventLoopFuture {
    /// When the current `EventLoopFuture<T>` is fulfilled, run the provided callback,
    /// which will provide a new `EventLoopFuture`.
    ///
    /// This allows you to dynamically dispatch new asynchronous tasks as phases in a
    /// longer series of processing steps. Note that you can use the results of the
    /// current `EventLoopFuture<T>` when determining how to dispatch the next operation.
    ///
    /// This works well when you have APIs that already know how to return `EventLoopFuture`s.
    /// You can do something with the result of one and just return the next future:
    ///
    /// ```
    /// let d1 = networkRequest(args).future()
    /// let d2 = d1.then { t -> EventLoopFuture<U> in
    ///     . . . something with t . . .
    ///     return netWorkRequest(args)
    /// }
    /// d2.whenSuccess { u in
    ///     NSLog("Result of second request: \(u)")
    /// }
    /// ```
    ///
    /// Note:  In a sense, the `EventLoopFuture<U>` is returned before it's created.
    ///
    /// - parameters:
    ///     - callback: Function that will receive the value of this `EventLoopFuture` and return
    ///         a new `EventLoopFuture`.
    /// - returns: A future that will receive the eventual value.
    public func then<U>(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (T) -> EventLoopFuture<U>) -> EventLoopFuture<U> {
        let next = EventLoopPromise<U>(eventLoop: eventLoop, file: file, line: line)
        _whenComplete {
            switch self.value! {
            case .success(let t):
                let futureU = callback(t)
                if futureU.eventLoop.inEventLoop {
                    return futureU._addCallback {
                        next._setValue(value: futureU.value!)
                    }
                } else {
                    futureU.cascade(promise: next)
                    return CallbackList()
                }
            case .failure(let error):
                return next._setValue(value: .failure(error))
            }
        }
        return next.futureResult
    }

    /// When the current `EventLoopFuture<T>` is fulfilled, run the provided callback, which
    /// performs a synchronous computation and returns a new value of type `U`. The provided
    /// callback may optionally `throw`.
    ///
    /// Operations performed in `thenThrowing` should not block, or they will block the entire
    /// event loop. `thenThrowing` is intended for use when you have a data-driven function that
    /// performs a simple data transformation that can potentially error.
    ///
    /// If your callback function throws, the returned `EventLoopFuture` will error.
    ///
    /// - parameters:
    ///     - callback: Function that will receive the value of this `EventLoopFuture` and return
    ///         a new value lifted into a new `EventLoopFuture`.
    /// - returns: A future that will receive the eventual value.
    public func thenThrowing<U>(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (T) throws -> U) -> EventLoopFuture<U> {
        return self.then(file: file, line: line) { (value: T) -> EventLoopFuture<U> in
            do {
                return EventLoopFuture<U>(eventLoop: self.eventLoop, result: try callback(value), file: file, line: line)
            } catch {
                return EventLoopFuture<U>(eventLoop: self.eventLoop, error: error, file: file, line: line)
            }
        }
    }

    /// When the current `EventLoopFuture<T>` is in an error state, run the provided callback, which
    /// may recover from the error and returns a new value of type `U`. The provided callback may optionally `throw`,
    /// in which case the `EventLoopFuture` will be in a failed state with the new thrown error.
    ///
    /// Operations performed in `thenIfErrorThrowing` should not block, or they will block the entire
    /// event loop. `thenIfErrorThrowing` is intended for use when you have the ability to synchronously
    /// recover from errors.
    ///
    /// If your callback function throws, the returned `EventLoopFuture` will error.
    ///
    /// - parameters:
    ///     - callback: Function that will receive the error value of this `EventLoopFuture` and return
    ///         a new value lifted into a new `EventLoopFuture`.
    /// - returns: A future that will receive the eventual value or a rethrown error.
    public func thenIfErrorThrowing(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (Error) throws -> T) -> EventLoopFuture<T> {
        return self.thenIfError(file: file, line: line) { value in
            do {
                return EventLoopFuture(eventLoop: self.eventLoop, result: try callback(value), file: file, line: line)
            } catch {
                return EventLoopFuture(eventLoop: self.eventLoop, error: error, file: file, line: line)
            }
        }
    }

    /// When the current `EventLoopFuture<T>` is fulfilled, run the provided callback, which
    /// performs a synchronous computation and returns a new value of type `U`.
    ///
    /// Operations performed in `map` should not block, or they will block the entire event
    /// loop. `map` is intended for use when you have a data-driven function that performs
    /// a simple data transformation that can potentially error.
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
    public func map<U>(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (T) -> (U)) -> EventLoopFuture<U> {
        if U.self == T.self && U.self == Void.self {
            whenSuccess(callback as! (T) -> Void)
            return self as! EventLoopFuture<U>
        } else {
            return then { return EventLoopFuture<U>(eventLoop: self.eventLoop, result: callback($0), file: file, line: line) }
        }
    }


    /// When the current `EventLoopFuture<T>` is in an error state, run the provided callback, which
    /// may recover from the error by returning an `EventLoopFuture<U>`. The callback is intended to potentially
    /// recover from the error by returning a new `EventLoopFuture` that will eventually contain the recovered
    /// result.
    ///
    /// If the callback cannot recover it should return a failed `EventLoopFuture`.
    ///
    /// - parameters:
    ///     - callback: Function that will receive the error value of this `EventLoopFuture` and return
    ///         a new value lifted into a new `EventLoopFuture`.
    /// - returns: A future that will receive the recovered value.
    public func thenIfError(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (Error) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        let next = EventLoopPromise<T>(eventLoop: eventLoop, file: file, line: line)
        _whenComplete {
            switch self.value! {
            case .success(let t):
                return next._setValue(value: .success(t))
            case .failure(let e):
                let t = callback(e)
                if t.eventLoop.inEventLoop {
                    return t._addCallback {
                        next._setValue(value: t.value!)
                    }
                } else {
                    t.cascade(promise: next)
                    return CallbackList()
                }
            }
        }
        return next.futureResult
    }

    /// When the current `EventLoopFuture<T>` is in an error state, run the provided callback, which
    /// can recover from the error and return a new value of type `U`. The provided callback may not `throw`,
    /// so this function should be used when the error is always recoverable.
    ///
    /// Operations performed in `mapIfError` should not block, or they will block the entire
    /// event loop. `mapIfError` is intended for use when you have the ability to synchronously
    /// recover from errors.
    ///
    /// - parameters:
    ///     - callback: Function that will receive the error value of this `EventLoopFuture` and return
    ///         a new value lifted into a new `EventLoopFuture`.
    /// - returns: A future that will receive the recovered value.
    public func mapIfError(file: StaticString = #file, line: UInt = #line, _ callback: @escaping (Error) -> T) -> EventLoopFuture<T> {
        return thenIfError(file: file, line: line) {
            return EventLoopFuture<T>(eventLoop: self.eventLoop, result: callback($0), file: file, line: line)
        }
    }


    /// Add a callback.  If there's already a value, invoke it and return the resulting list of new callback functions.
    fileprivate func _addCallback(_ callback: @escaping () -> CallbackList) -> CallbackList {
        assert(eventLoop.inEventLoop)
        if value == nil {
            callbacks.append(callback)
            return CallbackList()
        }
        return callback()
    }

    /// Add a callback.  If there's already a value, run as much of the chain as we can.
    fileprivate func _whenComplete(_ callback: @escaping () -> CallbackList) {
        if eventLoop.inEventLoop {
            _addCallback(callback)._run()
        } else {
            eventLoop.execute {
                self._addCallback(callback)._run()
            }
        }
    }

    fileprivate func _whenCompleteWithValue(_ callback: @escaping (EventLoopFutureValue<T>) -> Void) {
        _whenComplete {
            callback(self.value!)
            return CallbackList()
        }
    }

    /// Adds an observer callback to this `EventLoopFuture` that is called when the
    /// `EventLoopFuture` has a success result.
    ///
    /// An observer callback cannot return a value, meaning that this function cannot be chained
    /// from. If you are attempting to create a computation pipeline, consider `map` or `then`.
    /// If you find yourself passing the results from this `EventLoopFuture` to a new `EventLoopPromise`
    /// in the body of this function, consider using `cascade` instead.
    ///
    /// - parameters:
    ///     - callback: The callback that is called with the successful result of the `EventLoopFuture`.
    public func whenSuccess(_ callback: @escaping (T) -> Void) {
        _whenComplete {
            if case .success(let t) = self.value! {
                callback(t)
            }
            return CallbackList()
        }
    }

    /// Adds an observer callback to this `EventLoopFuture` that is called when the
    /// `EventLoopFuture` has a failure result.
    ///
    /// An observer callback cannot return a value, meaning that this function cannot be chained
    /// from. If you are attempting to create a computation pipeline, consider `mapIfError` or `thenIfError`.
    /// If you find yourself passing the results from this `EventLoopFuture` to a new `EventLoopPromise`
    /// in the body of this function, consider using `cascade` instead.
    ///
    /// - parameters:
    ///     - callback: The callback that is called with the failed result of the `EventLoopFuture`.
    public func whenFailure(_ callback: @escaping (Error) -> Void) {
        _whenComplete {
            if case .failure(let e) = self.value! {
                callback(e)
            }
            return CallbackList()
        }
    }

    /// Adds an observer callback to this `EventLoopFuture` that is called when the
    /// `EventLoopFuture` has any result.
    ///
    /// Unlike its friends `whenSuccess` and `whenFailure`, `whenComplete` does not receive the result
    /// of the `EventLoopFuture`. This is because its primary purpose is to do the appropriate cleanup
    /// of any resources that needed to be kept open until the `EventLoopFuture` had resolved.
    ///
    /// - parameters:
    ///     - callback: The callback that is called when the `EventLoopFuture` is fulfilled.
    public func whenComplete(_ callback: @escaping () -> Void) {
        _whenComplete {
            callback()
            return CallbackList()
        }
    }


    /// Internal:  Set the value and return a list of callbacks that should be invoked as a result.
    fileprivate func _setValue(value: EventLoopFutureValue<T>) -> CallbackList {
        assert(eventLoop.inEventLoop)
        if self.value == nil {
            self.value = value
            let callbacks = self.callbacks
            self.callbacks = CallbackList()
            return callbacks
        }
        return CallbackList()
    }
}


extension EventLoopFuture {
    /// Return a new `EventLoopFuture` that succeeds when this "and" another
    /// provided `EventLoopFuture` both succeed. It then provides the pair
    /// of results. If either one fails, the combined `EventLoopFuture` will fail with
    /// the first error encountered.
    public func and<U>(_ other: EventLoopFuture<U>, file: StaticString = #file, line: UInt = #line) -> EventLoopFuture<(T,U)> {
        let promise = EventLoopPromise<(T,U)>(eventLoop: eventLoop, file: file, line: line)
        var tvalue: T?
        var uvalue: U?

        assert(self.eventLoop === promise.futureResult.eventLoop)
        _whenComplete { () -> CallbackList in
            switch self.value! {
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

        let hopOver = other.hopTo(eventLoop: self.eventLoop)
        hopOver._whenComplete { () -> CallbackList in
            assert(self.eventLoop.inEventLoop)
            switch other.value! {
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
    /// This is just syntactic sugar for `future.and(loop.newSucceedFuture<U>(result: result))`.
    public func and<U>(result: U, file: StaticString = #file, line: UInt = #line) -> EventLoopFuture<(T,U)> {
        return and(EventLoopFuture<U>(eventLoop: self.eventLoop, result: result, file: file, line: line))
    }
}

extension EventLoopFuture {

    /// Fulfill the given `EventLoopPromise` with the results from this `EventLoopFuture`.
    ///
    /// This is useful when allowing users to provide promises for you to fulfill, but
    /// when you are calling functions that return their own promises. They allow you to
    /// tidy up your computational pipelines. For example:
    ///
    /// ```
    /// doWork().then {
    ///     doMoreWork($0)
    /// }.then {
    ///     doYetMoreWork($0)
    /// }.thenIfError {
    ///     maybeRecoverFromError($0)
    /// }.map {
    ///     transformData($0)
    /// }.cascade(promise: userPromise)
    /// ```
    ///
    /// - parameters:
    ///     - promise: The `EventLoopPromise` to fulfill with the results of this future.
    public func cascade(promise: EventLoopPromise<T>) {
        _whenCompleteWithValue { v in
            switch v {
            case .failure(let err):
                promise.fail(error: err)
            case .success(let value):
                promise.succeed(result: value)
            }
        }
    }

    /// Fulfill the given `EventLoopPromise` with the error result from this `EventLoopFuture`,
    /// if one exists.
    ///
    /// This is an alternative variant of `cascade` that allows you to potentially return early failures in
    /// error cases, while passing the user `EventLoopPromise` onwards. In general, however, `cascade` is
    /// more broadly useful.
    ///
    /// - parameters:
    ///     - promise: The `EventLoopPromise` to fulfill with the results of this future.
    public func cascadeFailure<U>(promise: EventLoopPromise<U>) {
        self.whenFailure { err in
            promise.fail(error: err)
        }
    }
}

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
    public func wait(file: StaticString = #file, line: UInt = #line) throws -> T {
        if !(self.eventLoop is EmbeddedEventLoop) {
            let explainer: () -> String = { """
BUG DETECTED: wait() must not be called when on an EventLoop.
Calling wait() on any EventLoop can lead to
- deadlocks
- stalling processing of other connections (Channels) that are handled on the EventLoop that wait was called on

Further information:
- current eventLoop: \(MultiThreadedEventLoopGroup.currentEventLoop.debugDescription)
- event loop associated to future: \(self.eventLoop)
"""
            }
            precondition(!eventLoop.inEventLoop, explainer(), file: file, line: line)
            precondition(MultiThreadedEventLoopGroup.currentEventLoop == nil, explainer(), file: file, line: line)
        }

        var v: EventLoopFutureValue <T>? = nil
        let lock = ConditionLock(value: 0)
        _whenComplete { () -> CallbackList in
            lock.lock()
            v = self.value
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
    ///     - futures: An array of `EventLoopFuture<U>` to wait for.
    ///     - with: A function that will be used to fold the values of two `EventLoopFuture`s and return a new value wrapped in an `EventLoopFuture`.
    /// - returns: A new `EventLoopFuture` with the folded value whose callbacks run on `self.eventLoop`.
    public func fold<U>(_ futures: [EventLoopFuture<U>], with combiningFunction: @escaping (T, U) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        let body = futures.reduce(self) { (f1: EventLoopFuture<T>, f2: EventLoopFuture<U>) -> EventLoopFuture<T> in
            let newFuture = f1.and(f2).then { (args: (T, U)) -> EventLoopFuture<T> in
                let (f1Value, f2Value) = args
                assert(self.eventLoop.inEventLoop)
                return combiningFunction(f1Value, f2Value)
            }
            assert(newFuture.eventLoop === self.eventLoop)
            return newFuture
        }
        return body
    }
}

extension EventLoopFuture {
    /// Returns a new `EventLoopFuture` that fires only when all the provided futures complete.
    ///
    /// This extension is only available when you have a collection of `EventLoopFuture`s that do not provide
    /// result data: that is, they are completion notifiers. In this case, you can wait for all of them. The
    /// returned `EventLoopFuture` will fail as soon as any of the futures fails: otherwise, it will succeed
    /// only when all of them do.
    ///
    /// - parameters:
    ///     - futures: An array of `EventLoopFuture<Void>` to wait for.
    ///     - eventLoop: The `EventLoop` on which the new `EventLoopFuture` callbacks will fire.
    /// - returns: A new `EventLoopFuture`.
    public static func andAll(_ futures: [EventLoopFuture<Void>], eventLoop: EventLoop) -> EventLoopFuture<Void> {
        let body = EventLoopFuture<Void>.reduce((), futures, eventLoop: eventLoop) { (_: (), _: ()) in }
        return body
    }

    /// Returns a new `EventLoopFuture` that fires only when all the provided futures complete.
    /// The new `EventLoopFuture` contains the result of reducing the `initialResult` with the
    /// values of the `[EventLoopFuture<U>]`.
    ///
    /// This function makes copies of the result for each EventLoopFuture, for a version which avoids
    /// making copies, check out `reduce<U>(into:)`.
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
    public static func reduce<U>(_ initialResult: T, _ futures: [EventLoopFuture<U>], eventLoop: EventLoop, _ nextPartialResult: @escaping (T, U) -> T) -> EventLoopFuture<T> {
        let f0 = eventLoop.newSucceededFuture(result: initialResult)

        let body = f0.fold(futures) { (t: T, u: U) -> EventLoopFuture<T> in
            eventLoop.newSucceededFuture(result: nextPartialResult(t, u))
        }

        return body
    }

    /// Returns a new `EventLoopFuture` that fires only when all the provided futures complete.
    /// The new `EventLoopFuture` contains the result of combining the `initialResult` with the
    /// values of the `[EventLoopFuture<U>]`. This funciton is analogous to the standard library's
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
    public static func reduce<U>(into initialResult: T, _ futures: [EventLoopFuture<U>], eventLoop: EventLoop, _ updateAccumulatingResult: @escaping (inout T, U) -> Void) -> EventLoopFuture<T> {
        let p0: EventLoopPromise<T> = eventLoop.newPromise()
        var result: T = initialResult

        let f0 = eventLoop.newSucceededFuture(result: ())
        let future = f0.fold(futures) { (_: (), value: U) -> EventLoopFuture<Void> in
            assert(eventLoop.inEventLoop)
            updateAccumulatingResult(&result, value)
            return eventLoop.newSucceededFuture(result: ())
        }

        future.whenSuccess {
            assert(eventLoop.inEventLoop)
            p0.succeed(result: result)
        }
        future.whenFailure { (error) in
            assert(eventLoop.inEventLoop)
            p0.fail(error: error)
        }
        return p0.futureResult
    }
}

public extension EventLoopFuture {
    /// Returns an `EventLoopFuture` that fires when this future completes, but executes its callbacks on the
    /// target event loop instead of the original one.
    ///
    /// It is common to want to "hop" event loops when you arrange some work: for example, you're closing one channel
    /// from another, and want to hop back when the close completes. This method lets you spell that requirement
    /// succinctly. It also contains an optimisation for the case when the loop you're hopping *from* is the same as
    /// the one you're hopping *to*, allowing you to avoid doing allocations in that case.
    ///
    /// - parameters:
    ///     - target: The `EventLoop` that the returned `EventLoopFuture` will run on.
    /// - returns: An `EventLoopFuture` whose callbacks run on `target` instead of the original loop.
    public func hopTo(eventLoop target: EventLoop) -> EventLoopFuture<T> {
        if target === self.eventLoop {
            // We're already on that event loop, nothing to do here. Save an allocation.
            return self
        }
        let hoppingPromise: EventLoopPromise<T> = target.newPromise()
        self.cascade(promise: hoppingPromise)
        return hoppingPromise.futureResult
    }
}

/// Execute the given function and synchronously complete the given `EventLoopPromise` (if not `nil`).
func executeAndComplete<T>(_ promise: EventLoopPromise<T>?, _ body: () throws -> T) {
    do {
        let result = try body()
        promise?.succeed(result: result)
    } catch let e {
        promise?.fail(error: e)
    }
}
