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

import Foundation
import Dispatch
#if os(macOS) || os(tvOS) || os(iOS)
import Darwin
#endif
#if os(Linux)
import Glibc
#endif

/** Private to avoid cluttering the public namespace.

If/when a version of this is added to the Standard library, that should be used here.  At that time, it may make sense to expose `resolve(FutureValue<T>)`.
*/
private enum FutureValue<T> {
    case success(T)
    case failure(Error)
    case incomplete
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
public class Promise<T> {
   public let futureResult = Future<T>()

   /**
        Public initializer
   */
   public init() {}

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
    fileprivate func _resolve(value: FutureValue<T>) {
        // Set the value and then run all completed callbacks
        _setValue(value: value)._run()
    }

    /** Internal only! */
    fileprivate func _setValue(value: FutureValue<T>) -> CallbackList {
        return futureResult._setValue(value: value)
    }

    deinit {
        assert(futureResult.fulfilled, "leaking an unfulfilled Promise")
    }
}

fileprivate class ConditionLock {
    private var _value: Int
    fileprivate let mutexCond: UnsafeMutablePointer<(pthread_mutex_t, pthread_cond_t)> = UnsafeMutablePointer.allocate(capacity: 1)

    public init(value: Int) {
        self._value = value
        pthread_mutex_init(&mutexCond.pointee.0, nil)
        pthread_cond_init(&mutexCond.pointee.1, nil)
    }

    deinit {
        mutexCond.deallocate(capacity: 1)
    }

    public func lock() {
        pthread_mutex_lock(&mutexCond.pointee.0)
    }

    public func unlock() {
        pthread_mutex_unlock(&mutexCond.pointee.0)
    }

    public var value: Int {
        lock()
        defer {
            unlock()
        }
        return self._value
    }

    public func lock(whenValue wantedValue: Int) {
        lock()
        while true {
            if self._value == wantedValue {
                break
            }
            let err = pthread_cond_wait(&mutexCond.pointee.1, &mutexCond.pointee.0)
            precondition(err == 0, "pthread_cond_wait error \(err)")
        }
    }

    public func lock(whenValue wantedValue: Int, timeoutSeconds: Double) -> Bool{
        let nsecPerSec: Double = 1000000000.0
        lock()
        /* the timeout as a (seconds, nano seconds) pair */
        let timeout = (Int(timeoutSeconds),
                       Int((timeoutSeconds-Double(Int(timeoutSeconds))) * nsecPerSec))

        var ts = timespec()
        var tv = timeval()
        gettimeofday(&tv, nil)
        ts.tv_sec += tv.tv_sec + timeout.0
        ts.tv_nsec += Int(tv.tv_usec * 1000) + timeout.1

        while true {
            if self._value == wantedValue {
                return true
            }
            switch pthread_cond_timedwait(&mutexCond.pointee.1, &mutexCond.pointee.0, &ts) {
            case 0:
                continue
            case ETIMEDOUT:
                unlock()
                return false
            case let e:
                fatalError("caught error \(e) when calling pthread_cond_timedwait")
            }
        }
    }

    public func unlock(withValue newValue: Int) {
        self._value = newValue
        unlock()
        pthread_cond_signal(&mutexCond.pointee.1)
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

public class Future<T>: Hashable {
    fileprivate var value: FutureValue<T> = .incomplete

    public var result: T? {
        get {
            switch value {
            case .incomplete, .failure(_):
                return nil
            case .success(let t):
                return t
            }
        }
    }

    public var error: Error? {
        get {
            switch value {
            case .incomplete, .success(_):
                return nil
            case .failure(let e):
                return e
            }
        }
    }

    /// Callbacks that should be run when this Future<> gets a value.
    /// These callbacks may give values to other Futures; if that happens, they return any callbacks from those Futures so that we can run the entire chain from the top without recursing.
    fileprivate var callbacks: CallbackList = CallbackList()

    // Each instance gets a random hash value
    public lazy var hashValue = NSUUID().hashValue

    /// Becomes 1 when we have a value or an error
    fileprivate let futureLock: ConditionLock

    public var fulfilled: Bool {
        return futureLock.value == 1
    }

    fileprivate init() {
        self.futureLock = ConditionLock(value: 0)
    }

    /// A Future<T> that has already succeeded
    public init(result: T) {
        self.value = .success(result)
        self.futureLock = ConditionLock(value: 1)
    }

    /// A Future<T> that has already failed
    public init(error: Error) {
        self.value = .failure(error)
        self.futureLock = ConditionLock(value: 1)
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
        let next = Promise<U>()
        _whenComplete {
            switch self.value {
            case .success(let t):
                do {
                    let futureU = try callback(t)
                    return futureU._addCallback {
                        return next._setValue(value: futureU.value)
                    }
                } catch let error {
                    return next._setValue(value: .failure(error))
                }
            case .failure(let error):
                return next._setValue(value: .failure(error))
            default:
                assert(false)
            }
            return []
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
        return then { return Future<U>(result: try callback($0)) }
    }


    /**  A variation of `then()` that runs the callback asynchronously on the provided queue.
    */
    public func then<U>(queue: DispatchQueue, callback: @escaping (T) throws -> U) -> Future<U> {
        return then { t -> Future<U> in
            return Future<U>.async(queue: queue) {
                return try callback(t)
            }
        }
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
        let next = Promise<T>()
        _whenComplete {
            switch self.value {
            case .success(let t):
                return next._setValue(value: .success(t))
            case .failure(let e):
                do {
                    let t = try callback(e)
                    return t._addCallback {
                        return next._setValue(value: t.value)
                    }
                } catch let error {
                    return next._setValue(value: .failure(error))
                }
            default:
                assert(false)
            }
            return []
         }
         return next.futureResult
    }

    public func thenIfError(callback: @escaping (Error) throws -> T) -> Future<T> {
        return thenIfError { return Future<T>(result: try callback($0)) }
    }

    /** Block until either result or error is available.

    If the future already has a value, this will return immediately.  If the future has failed, this will throw the error.

    In particular, note that this does behave correctly if you have callbacks registered to run on the same queue on which you call `wait()`.  In that case, the `wait()` call will unblock as soon as the `Future<T>` acquires a result, and the callbacks will be dispatched asynchronously to run at some later time.
    */
    public func wait() throws -> T {
        futureLock.lock(whenValue: 1) // Wait for fulfillment
        futureLock.unlock()
        if let error = error {
            throw error
        } else {
            return result!
        }
    }

    /** Block until result or error becomes set, or until timeout.

    Returns a result if the future succeeds before the timeout, throws an error if it fails before the timeout.  Otherwise, returns nil.
    */
    public func wait(timeoutSeconds: Double) throws -> T? {
        let succeeded = futureLock.lock(whenValue: 1, timeoutSeconds: timeoutSeconds)
        if succeeded {
            futureLock.unlock()
            if let error = error {
                throw error
            } else {
                return result
            }
        } else {
           return nil
        }
    }

    /// Add a callback.  If there's already a value, invoke it and return the resulting list of new callback functions.
    fileprivate func _addCallback(callback: @escaping () -> CallbackList) -> CallbackList {
        futureLock.lock()
        switch value {
        case .incomplete:
            callbacks.append(callback: callback)
            futureLock.unlock()
            return CallbackList()
        default:
            futureLock.unlock()
            return callback()
        }
    }

    /// Add a callback.  If there's already a value, run as much of the chain as we can.
    fileprivate func _whenComplete(callback: @escaping () -> CallbackList) {
        _addCallback(callback: callback)._run()
    }

    public func whenSuccess(callback: @escaping (T) -> ()) {
        _whenComplete {
            if case .success(let t) = self.value {
                callback(t)
            }
            return CallbackList()
        }
    }

    public func whenFailure(callback: @escaping (Error) -> ()) {
        _whenComplete {
            if case .failure(let e) = self.value {
                callback(e)
            }
            return CallbackList()
        }
    }

    /// Internal:  Set the value and return a list of callbacks that should be invoked as a result.
    fileprivate func _setValue(value: FutureValue<T>) -> CallbackList {
        futureLock.lock()
        switch self.value {
        case .incomplete:
            self.value = value
            let callbacks = self.callbacks
            self.callbacks = CallbackList()
            futureLock.unlock(withValue: 1)
            return callbacks
        default:
            futureLock.unlock()
            return CallbackList()
        }
    }

    /**
        An easy way to run code on an async dispatch queue and get a result back:

            let future = Future<Int>.async {
                () -> Int in
                ... do some work ...
                return int
            }

        The provided function can also throw an error; it will be caught and cause the future return object to report a failure.

        By default, this runs the function on the global default concurrent queue.  Success or failure will be dispatched onto the same queue.  Note the various overloads of this function that allow you to control which queues are used.
    */
    public static func async<T>(function: @escaping () throws -> (T)) -> Future<T> {
        return async(qos: .default, function: function)
    }

    /**
        An overload for `async<T>(function)` that runs the function on the global concurrent queue with the specified quality-of-service.  Success or failure will be dispatched on the same queue.
    */
    public static func async<T>(qos: DispatchQoS.QoSClass, function: @escaping () throws -> (T)) -> Future<T> {
        let queue = DispatchQueue.global(qos: qos)
        return async(queue: queue, function: function)
    }

    /**
    An overload for `async<T>(function)` that runs the function on the provided dispatch queue.  Success or failure will be dispatched on the same queue.  This is most useful  when you want to serialize a particular kind of request.
    */
    public static func async<T>(queue: DispatchQueue, function: @escaping () throws -> (T)) -> Future<T> {
        let promise = Promise<T>()
        queue.async {
            do {
                let t = try function()
                promise.succeed(result: t)
            } catch let error {
                promise.fail(error: error)
            }
        }
        return promise.futureResult
    }

    /** Run code synchronously on a queue and return a Future result.

    This uses the same interface as `async()` except that it always waits for a result and then returns a Future that already holds a result or error.  In particular, this allows you to easily switch between sync/async operation without changing your client code.
    */
    public static func sync<T>(queue: DispatchQueue, function: () throws -> (T)) -> Future<T> {
        let promise = Promise<T>()
        queue.sync {
            do {
                let t = try function()
                promise.succeed(result: t)
            } catch let error {
                promise.fail(error: error)
            }
        }
        return promise.futureResult
    }

    /** Return a new `Future<T>` that will deliver the first successful result from the array of `Future<T>` or the last failure if all of the provided `Future<T>` fail.

    Note:  It does not wait for all of the provided `Future<T>` to complete.
    */
    public static func firstSuccess(futures: [Future<T>]) -> Future<T> {
        assert(futures.count > 0)
        let fslock = NSLock()
        let promise = Promise<T>()
        var remaining = futures.count

        for d in futures {
            d._whenComplete {
                fslock.lock()
                remaining -= 1
                let done = (remaining == 0)
                fslock.unlock()
                switch d.value {
                case .failure(let error):
                    if done {
                        return promise._setValue(value: .failure(error))
                    }
                case .success(let t):
                    return promise._setValue(value: .success(t))
                case .incomplete:
                    assert(false)
                }
                return CallbackList()
            }
        }
        return promise.futureResult
    }

    /** Return a new `Future<T>` that will fail on the first failure from the array of `Future<T>` or succeed with the last success if none of the provided `Future<T>` fail.

    Note:  If there is a failure, it will not wait for any remaining `Future<T>` to complete.
    */
    public static func firstFailure(futures: [Future<T>]) -> Future<T> {
        assert(futures.count > 0)
        let fflock = NSLock()
        let promise = Promise<T>()
        var remaining = futures.count

        for d in futures {
            d._whenComplete {
                fflock.lock()
                remaining -= 1
                let done = (remaining == 0)
                fflock.unlock()
                switch d.value {
                case .failure(let error):
                    return promise._setValue(value: .failure(error))
                case .success(let t):
                    if done {
                        return promise._setValue(value: .success(t))
                    }
                default:
                    assert(false)
                }
                return CallbackList()
            }
        }
        return promise.futureResult
    }

    /** Return a new `Future<T>` that will complete only after all of the provided Future<T> have completed.

    When it does complete, it will fail with the first error if any of the members failed.  Otherwise, it will succeed with the first successful result.
    */
    public static func allComplete(futures: [Future<T>]) -> Future<T> {
        assert(futures.count > 0)
        let aclock = NSLock()
        let promise = Promise<T>()
        var firstError: Error?
        var firstSuccess: T?
        var remaining = futures.count

        func acquire() {
            aclock.lock()
        }

        func release() {
            remaining -= 1
            if remaining == 0 {
                aclock.unlock()
                if let firstError = firstError {
                    promise.fail(error: firstError)
                } else {
                    promise.succeed(result: firstSuccess!)
                }
            } else {
                aclock.unlock()
            }
        }

        func failureCallback(error: Error) -> () {
            acquire()
            if firstError == nil {
                firstError = error
            }
            release()
        }

        func successCallback(t: T) -> () {
            acquire()
            if firstSuccess == nil {
                firstSuccess = t
            }
            release()
        }

        for d in futures {
            d.whenSuccess(callback: successCallback)
            d.whenFailure(callback: failureCallback)
        }
        return promise.futureResult
    }
}

public extension Future {
    /** Return a new `Future<[T]>` that will collect the successes of the provided `Future<T>`.

    If any of the provided Futures fail, the new Future will fail.  Otherwise, it succeeds with an array of results in the same order as the provided Futures.

    Note: If there is an error, it will not wait for the remaining `Future<T>` to complete.  If you want to detect completion regardless of failure, look at `allComplete()` instead.
    */
    public static func allSuccess(futures: [Future<T>]) -> Future<[T]> {
        let aslock = NSLock()
        let promise = Promise<[T]>()
        var results = [T]()
        var i = 0

        func callback(value: FutureValue<T>) -> CallbackList {
            switch value {
            case .failure(let error):
                return promise._setValue(value: .failure(error))
            case .success(let t):
                aslock.lock()
                results.append(t)
                i += 1
                if i < futures.count {
                    let next = futures[i]
                    aslock.unlock()
                    return next._addCallback {
                        return callback(value: next.value)
                    }
                } else {
                    aslock.unlock()
                    return promise._setValue(value: .success(results))
                }
            default:
                assert(false)
            }
            return []
        }

        if futures.count == 0 {
            promise.succeed(result: [])
        } else {
            futures[0]._whenComplete {
                return callback(value: futures[0].value)
            }
        }
        return promise.futureResult
    }
}

public extension Future {
    /**
     * Return a new Future that succeeds when this "and" another
     * provided Future both succeed.  It then provides the pair
     * of results.  If either one fails, the combined Future will fail.
     */
    public func and<U>(_ other: Future<U>) -> Future<(T,U)> {
        let andlock = NSLock()
        let promise = Promise<(T,U)>()
        var tvalue: T?
        var uvalue: U?

        _whenComplete { () -> CallbackList in
            switch self.value {
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
            default:
                assert(false)
            }
            return CallbackList()
        }

        other._whenComplete { () -> CallbackList in
            switch other.value {
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
            default:
                assert(false)
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
        return and(Future<U>(result:result))
    }
}
