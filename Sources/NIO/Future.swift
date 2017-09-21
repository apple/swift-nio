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

import ConcurrencyHelpers


/** Private to avoid cluttering the public namespace.
 
 If/when a version of this is added to the Standard library, that should be used here.  At that time, it may make sense to expose `resolve(FutureValue<T>)`.
 */
public enum FutureValue<T> {
    case success(T)
    case failure(Error)
}

/** Internal list of callbacks.
 
 Most of these are closures that pull a value from one future, call a user callback, push the result into another, then return a list of callbacks from the target future that are now ready to be invoked.
 
 In particular, note that _run() here continues to obtain and execute lists of callbacks until it completes.  This eliminates recursion when processing `then()` chains.
 */
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
    mutating func append(callback: @escaping () -> CallbackList) {
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
            return [first]+others
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

/** A promise to provide a result later.
 
 This is the provider API for Future<T>.  If you want to return an unfulfilled Future<T> -- presumably because you are interfacing to some asynchronous service that will return a real result later, follow this pattern:
 
 ```
 func someAsyncOperation(args) -> Future<ResultType> {
 let promise = Promise<ResultType>()
 someAsyncOperationWithACallback(args) { result -> () in
 // when finished...
 promise.succeed(result)
 // if error...
 promise.fail(result)
 }
 return promise.futureResult
 }
 ```
 
 Note that the future result is returned before the async process has provided a value.
 
 It's actually not very common to use this directly.  Usually, you really want one of the following:
 
 * If you have a Future and want to do something else after it completes, use `.then()`
 * If you just want to get a value back after running something on another thread, use `Future<ResultType>.async()`
 * If you already have a value and need a Future<> object to plug into some other API, create an already-resolved object with `Future<ResultType>(result:)`
 */
public struct Promise<T> {
    public let futureResult: Future<T>
    
    /**
     Public initializer
     */
    init(eventLoop: EventLoop, checkForPossibleDeadlock: Bool) {
        futureResult = Future<T>(eventLoop: eventLoop, checkForPossibleDeadlock: checkForPossibleDeadlock)
    }
    
    /**
     Deliver a successful result to the associated `Future<T>` object.
     */
    public func succeed(result: T) {
        _resolve(value: .success(result))
    }
    
    /**
     Deliver an error to the associated `Future<T>` object.
     */
    public func fail(error: Error) {
        _resolve(value: .failure(error))
    }
    
    /** Internal only! */
    private func _resolve(value: FutureValue<T>) {
        if futureResult.eventLoop.inEventLoop {
            _setValue(value: value)._run()
        } else {
            futureResult.eventLoop.execute {
                self._setValue(value: value)._run()
            }
        }
    }
    
    /** Internal only! */
    fileprivate func _setValue(value: FutureValue<T>) -> CallbackList {
        return futureResult._setValue(value: value)
    }
}


/** Holder for a result that will be provided later.
 
 Functions that promise to do work asynchronously can return a Future<T>.  The recipient of such an object can then observe it to be notified when the operation completes.
 
 The provider of a `Future<T>` can create and return a placeholder object before the actual result is available.  For example:
 
 ```
 func getNetworkData(args) -> Future<NetworkResponse> {
 let promise = Promise<NetworkResponse>()
 queue.async {
 . . . do some work . . .
 promise.succeed(response)
 . . . if it fails, instead . . .
 promise.fail(error)
 }
 return promise.futureResult
 }
 ```
 
 Note that this function returns immediately; the promise object will be given a value later on.  This is also sometimes referred to as the "IOU Pattern".  Similar structures occur in other programming languages, including Haskell's IO Monad, Scala's Future object, Python Deferred, and Javascript Promises.
 
 The above idiom is common enough that we've provided an `async()` method to encapsulate it.  Note that with this wrapper, you simply return the desired response or `throw` an error; the wrapper will capture it and correctly propagate it to the Future that was returned earlier:
 
 ```
 func getNetworkData(args) -> Future<NetworkResponse> {
 return Future<NetworkResponse>.async(queue) {
 . . . do some work . . .
 return response // Return the NetworkResponse object
 . . . if it fails . . .
 throw error
 }
 }
 ```
 
 If you receive a `Future<T>` from another function, you have a number of options:  The most common operation is to use `then()` to add a function that will be called with the eventual result.  The `then()` method returns a new Future<T> immediately that will receive the return value from your function.
 
 ```
 let networkData = getNetworkData(args)
 
 // When network data is received, convert it
 let processedResult: Future<Processed>
 = networkData.then {
 (n: NetworkResponse) -> Processed in
 ... parse network data ....
 return processedResult
 }
 ```
 
 The function provided to `then()` can also return a new Future object.  In this way, you can kick off another async operation at any time:
 
 ```
 // When converted network data is available,
 // begin the database operation.
 let databaseResult: Future<DBResult>
 = processedResult.then {
 (p: Processed) -> Future<DBResult> in
 return Future<DBResult>.async(queue) {
 . . . perform DB operation . . .
 return result
 }
 }
 ```
 
 In essence, future chains created via `then()` provide a form of data-driven asynchronous programming that allows you to dynamically declare data dependencies for your various operations.
 
 Future chains created via `then()` are sufficient for most purposes.  All of the registered functions will eventually run in order.  If one of those functions throws an error, that error will bypass the remaining functions.  You can use `thenIfError()` to handle and optionally recover from errors in the middle of a chain.
 
 At any point in the Future chain, you can use `whenSuccess()` or `whenFailure()` to add an observer callback that will be invoked with the result or error at that point.  (Note:  If you ever find yourself invoking `promise.succeed()` from inside a `whenSuccess()` callback, you probably should use `then()` instead.)
 
 Future objects are typically obtained by:
 * Using `Future<T>.async` or a similar wrapper function.
 * Using `.then` on an existing future to create a new future for the next step in a series of operations.
 * Initializing a Future that already has a value or an error
 
 TODO: Provide a tracing facility.  It would be nice to be able to set '.debugTrace = true' on any Future or Promise and have every subsequent chained Future report the success result or failure error.  That would simplify some debugging scenarios.
 */

public final class Future<T> {
    fileprivate var value: FutureValue<T>? {
        didSet {
            _fulfilled.store(true)
        }
    }
    fileprivate let _fulfilled: Atomic<Bool>
    fileprivate let checkForPossibleDeadlock: Bool
    public let eventLoop: EventLoop
    
    internal var fulfilled: Bool {
        return _fulfilled.load()
    }

    /// Callbacks that should be run when this Future<> gets a value.
    /// These callbacks may give values to other Futures; if that happens, they return any callbacks from those Futures so that we can run the entire chain from the top without recursing.
    fileprivate var callbacks: CallbackList = CallbackList()

    private init(eventLoop: EventLoop, checkForPossibleDeadlock: Bool, value: FutureValue<T>?, file: StaticString = #file, line: Int = #line) {
        self.eventLoop = eventLoop
        self.checkForPossibleDeadlock = checkForPossibleDeadlock
        self.value = value
        self._fulfilled = Atomic(value: value != nil)
    }


    fileprivate convenience init(eventLoop: EventLoop, checkForPossibleDeadlock: Bool, file: StaticString = #file, line: Int = #line) {
        self.init(eventLoop: eventLoop, checkForPossibleDeadlock: checkForPossibleDeadlock, value: nil, file: file, line: line)
    }
    
    /// A Future<T> that has already succeeded
    convenience init(eventLoop: EventLoop, checkForPossibleDeadlock: Bool, result: T, file: StaticString = #file, line: Int = #line) {
        self.init(eventLoop: eventLoop, checkForPossibleDeadlock: checkForPossibleDeadlock, value: .success(result), file: file, line: line)
    }
    
    /// A Future<T> that has already failed
    convenience init(eventLoop: EventLoop, checkForPossibleDeadlock: Bool, error: Error, file: StaticString = #file, line: Int = #line) {
        self.init(eventLoop: eventLoop, checkForPossibleDeadlock: checkForPossibleDeadlock, value: .failure(error), file: file, line: line)
    }
    
    deinit {
        precondition(fulfilled, "leaking an unfulfilled Promise")
    }
}

public func ==<T>(lhs: Future<T>, rhs: Future<T>) -> Bool {
    return lhs === rhs
}

/**
 'then' implementations.  This is really the key of the entire system.
 */
public extension Future {
    /**
     When the current `Future<T>` is fulfilled, run the provided callback, which will provide a new `Future`.
     
     This allows you to dynamically dispatch new background tasks as phases in a longer series of processing steps.  Note that you can use the results of the current `Future<T>` when determining how to dispatch the next operation.
     
     This works well when you have APIs that already know how to return Futures.  You can do something with the result of one and just return the next future:
     
     let d1 = networkRequest(args).future()
     let d2 = d1.then { t -> Future<U> in
     . . . something with t . . .
     return netWorkRequest(args)
     }
     d2.whenSuccess { u in
     NSLog("Result of second request: \(u)")
     }
     
     Technical trivia:  `Future<>` is a monad, `then()` is the monadic bind operation.
     
     Note:  In a sense, the `Future<U>` is returned before it's created.
     
     - parameter callback: Function that will receive the value of this Future and return a new Future
     - returns: A future that will receive the eventual value
     */
    
    public func then<U>(callback: @escaping (T) throws -> Future<U>) -> Future<U> {
        let next = Promise<U>(eventLoop: eventLoop, checkForPossibleDeadlock: checkForPossibleDeadlock)
        _whenComplete {
            switch self.value! {
            case .success(let t):
                do {
                    let futureU = try callback(t)
                    return futureU._addCallback {
                        return next._setValue(value: futureU.value!)
                    }
                } catch let error {
                    return next._setValue(value: .failure(error))
                }
            case .failure(let error):
                return next._setValue(value: .failure(error))
            }
        }
        return next.futureResult
    }
    
    /** Chainable transformation.
     
     ```
     let future1 = eventually()
     let future2 = future1.then { T -> U in
     ... stuff ...
     return u
     }
     let future3 = future2.then { U -> V in
     ... stuff ...
     return v
     }
     
     future3.whenSuccess { V in
     ... handle final value ...
     }
     ```
     
     If your callback throws an error, the resulting future will fail.
     
     Generally, a simple closure provided to `then()` should never block.  If you need to do something time-consuming, your closure can schedule the operation on another queue and return another `Future<>` object instead.  See `then(queue:callback:)` for a convenient way to do this.
     */
    
    public func then<U>(callback: @escaping (T) throws -> (U)) -> Future<U> {
        return then { return Future<U>(eventLoop: self.eventLoop, checkForPossibleDeadlock: self.checkForPossibleDeadlock, result: try callback($0)) }
    }

    
    /** Recover from an error.
     
     This returns a new Future<> of the same type.  If the original Future<> succeeds, so will the new one.  But if the original Future<> fails, the callback will be executed with the error value.  The callback can either:
     * Throw an error, in which case the chained Future<> will fail with that error.  The thrown error can be the same or different.
     * Return a new result, in which case the chained Future<> will succeed with that value.
     
     Here is a simple example which simply converts any error into a default -1 value.  Usually, of course, you would inspect the provided error and re-throw if the error was unexpected:
     
     ```
     let d: Future<Int>
     let recover = d.thenIfError { error throws -> Int in
     return -1
     }
     ```
     
     This supports the same overloads as `then()`, including allowing the callback to return a `Future<T>`.
     */
    public func thenIfError(callback: @escaping (Error) throws -> Future<T>) -> Future<T> {
        let next = Promise<T>(eventLoop: eventLoop, checkForPossibleDeadlock: checkForPossibleDeadlock)
        _whenComplete {
            switch self.value! {
            case .success(let t):
                return next._setValue(value: .success(t))
            case .failure(let e):
                do {
                    let t = try callback(e)
                    return t._addCallback {
                        return next._setValue(value: t.value!)
                    }
                } catch let error {
                    return next._setValue(value: .failure(error))
                }
            }
        }
        return next.futureResult
    }
    
    public func thenIfError(callback: @escaping (Error) throws -> T) -> Future<T> {
        return thenIfError { return Future<T>(eventLoop: self.eventLoop, checkForPossibleDeadlock: self.checkForPossibleDeadlock, result: try callback($0)) }
    }

    
    /// Add a callback.  If there's already a value, invoke it and return the resulting list of new callback functions.
    fileprivate func _addCallback(callback: @escaping () -> CallbackList) -> CallbackList {
        assert(eventLoop.inEventLoop)
        if value == nil {
            callbacks.append(callback: callback)
            return CallbackList()
        }
        return callback()
    }
    
    /// Add a callback.  If there's already a value, run as much of the chain as we can.
    fileprivate func _whenComplete(callback: @escaping () -> CallbackList) {
        if eventLoop.inEventLoop {
            _addCallback(callback: callback)._run()
        } else {
            eventLoop.execute {
                self._addCallback(callback: callback)._run()
            }
        }
    }
    
    public func whenSuccess(callback: @escaping (T) -> ()) {
        _whenComplete {
            if case .success(let t) = self.value! {
                callback(t)
            }
            return CallbackList()
        }
    }
    
    public func whenFailure(callback: @escaping (Error) -> ()) {
        _whenComplete {
            if case .failure(let e) = self.value! {
                callback(e)
            }
            return CallbackList()
        }
    }
    
    public func whenComplete(callback: @escaping (FutureValue<T>) -> ()) {
        _whenComplete {
            callback(self.value!)
            return CallbackList()
        }
    }

    
    /// Internal:  Set the value and return a list of callbacks that should be invoked as a result.
    fileprivate func _setValue(value: FutureValue<T>) -> CallbackList {
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


public extension Future {
    /**
     * Return a new Future that succeeds when this "and" another
     * provided Future both succeed.  It then provides the pair
     * of results.  If either one fails, the combined Future will fail.
     */
    public func and<U>(_ other: Future<U>) -> Future<(T,U)> {
        let andlock = Lock()
        let promise = Promise<(T,U)>(eventLoop: eventLoop, checkForPossibleDeadlock: checkForPossibleDeadlock)
        var tvalue: T?
        var uvalue: U?
        
        _whenComplete { () -> CallbackList in
            switch self.value! {
            case .failure(let error):
                return promise._setValue(value: .failure(error))
            case .success(let t):
                andlock.lock()
                if let u = uvalue {
                    andlock.unlock()
                    return promise._setValue(value: .success((t, u)))
                } else {
                    andlock.unlock()
                    tvalue = t
                }
            }
            return CallbackList()
        }
        
        other._whenComplete { () -> CallbackList in
            switch other.value! {
            case .failure(let error):
                return promise._setValue(value: .failure(error))
            case .success(let u):
                andlock.lock()
                if let t = tvalue {
                    andlock.unlock()
                    return promise._setValue(value: .success((t, u)))
                } else {
                    andlock.unlock()
                    uvalue = u
                }
            }
            return CallbackList()
        }
        
        return promise.futureResult
    }
    
    /**
     * Return a new Future that contains this "and" another value.
     * This is just syntactic sugar for
     *    future.and(Future<U>(result: result))
     */
    public func and<U>(result: U) -> Future<(T,U)> {
        return and(Future<U>(eventLoop: self.eventLoop, checkForPossibleDeadlock: self.checkForPossibleDeadlock, result:result))
    }
}

extension Future {
    
    public func cascade(promise: Promise<T>) {
        whenComplete(callback: { v in
            switch v {
            case .failure(let err):
                promise.fail(error: err)
            case .success(let value):
                promise.succeed(result: value)
            }
        })
    }
    
    public func cascadeFailure<U>(promise: Promise<U>) {
        self.whenFailure(callback: { err in
            promise.fail(error: err)
        })
    }
}

extension Future {
    public func wait() throws -> T {
        if self.checkForPossibleDeadlock {
            precondition(!eventLoop.inEventLoop, "wait() must not be called when on the EventLoop")
        }
        
        var v: FutureValue <T>? = nil
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

extension Future {
    public static func andAll(_ futures: [Future<Void>], eventLoop: EventLoop) -> Future<Void> {
        let p0: Promise<Void> = eventLoop.newPromise()
        guard futures.count > 0 else {
            p0.succeed(result: ())
            return p0.futureResult
        }

        let fn: Future<Void> = futures.reduce(p0.futureResult, { (f1: Future<Void>, f2: Future<Void>) in f1.and(f2).then(callback: { _ in return () }) })
        p0.succeed(result: ())
        return fn
    }

}
