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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

#if !swift(>=4.1)
    public extension UnsafeMutablePointer {
        public func deallocate() {
            /* this is a bit dodgy as we always pass 1 but it's okay as Swift 4.0 would also always deallocate the whole chunk */
            self.deallocate(capacity: 1)
        }
    }
#endif

/// A threading lock based on `libpthread` instead of `libdispatch`.
///
/// This object provides a lock on top of a single `pthread_mutex_t`. This kind
/// of lock is safe to use with `libpthread`-based threading models, such as the
/// one used by NIO.
public final class Lock {
    fileprivate let mutex: UnsafeMutablePointer<pthread_mutex_t> = UnsafeMutablePointer.allocate(capacity: 1)

    /// Create a new lock.
    public init() {
        let err = pthread_mutex_init(self.mutex, nil)
        precondition(err == 0)
    }

    deinit {
        let err = pthread_mutex_destroy(self.mutex)
        precondition(err == 0)
        mutex.deallocate()
    }

    /// Acquire the lock.
    ///
    /// Whenever possible, consider using `withLock` instead of this method and
    /// `unlock`, to simplify lock handling.
    public func lock() {
        let err = pthread_mutex_lock(self.mutex)
        precondition(err == 0)
    }

    /// Release the lock.
    ///
    /// Whenver possible, consider using `withLock` instead of this method and
    /// `lock`, to simplify lock handling.
    public func unlock() {
        let err = pthread_mutex_unlock(self.mutex)
        precondition(err == 0)
    }
}

extension Lock {
    /// Acquire the lock for the duration of the given block.
    ///
    /// This convenience method should be preferred to `lock` and `unlock` in
    /// most situations, as it ensures that the lock will be released regardless
    /// of how `body` exits.
    ///
    /// - Parameter body: The block to execute while holding the lock.
    /// - Returns: The value returned by the block.
    @_inlineable
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        self.lock()
        defer {
            self.unlock()
        }
        return try body()
    }

    // specialise Void return (for performance)
    @_inlineable
    public func withLockVoid(_ body: () throws -> Void) rethrows -> Void {
        try self.withLock(body)
    }
}

/// A `Lock` with a built-in state variable.
///
/// This class provides a convenience addition to `Lock`: it provides the ability to wait
/// until the state variable is set to a specific value to acquire the lock.
public final class ConditionLock<T: Equatable> {
    private var _value: T
    private let mutex: Lock
    private let cond: UnsafeMutablePointer<pthread_cond_t> = UnsafeMutablePointer.allocate(capacity: 1)

    /// Create the lock, and initialize the state variable to `value`.
    ///
    /// - Parameter value: The initial value to give the state variable.
    public init(value: T) {
        self._value = value
        self.mutex = Lock()
        let err = pthread_cond_init(self.cond, nil)
        precondition(err == 0)
    }

    deinit {
        let err = pthread_cond_destroy(self.cond)
        precondition(err == 0)
        self.cond.deallocate()
    }

    /// Acquire the lock, regardless of the value of the state variable.
    public func lock() {
        self.mutex.lock()
    }

    /// Release the lock, regardless of the value of the state variable.
    public func unlock() {
        self.mutex.unlock()
    }

    /// The value of the state variable.
    ///
    /// Obtaining the value of the state variable requires acquiring the lock.
    /// This means that it is not safe to access this property while holding the
    /// lock: it is only safe to use it when not holding it.
    public var value: T {
        self.lock()
        defer {
            self.unlock()
        }
        return self._value
    }

    /// Acquire the lock when the state variable is equal to `wantedValue`.
    ///
    /// - Parameter wantedValue: The value to wait for the state variable
    ///     to have before acquiring the lock.
    public func lock(whenValue wantedValue: T) {
        self.lock()
        while true {
            if self._value == wantedValue {
                break
            }
            let err = pthread_cond_wait(self.cond, self.mutex.mutex)
            precondition(err == 0, "pthread_cond_wait error \(err)")
        }
    }

    /// Acquire the lock when the state variable is equal to `wantedValue`,
    /// waiting no more than `timeoutSeconds` seconds.
    ///
    /// - Parameter wantedValue: The value to wait for the state variable
    ///     to have before acquiring the lock.
    /// - Parameter timeoutSeconds: The number of seconds to wait to acquire
    ///     the lock before giving up.
    /// - Returns: `true` if the lock was acquired, `false` if the wait timed out.
    public func lock(whenValue wantedValue: T, timeoutSeconds: Double) -> Bool {
        precondition(timeoutSeconds >= 0)

        let nsecPerSec: Int64 = 1000000000
        self.lock()
        /* the timeout as a (seconds, nano seconds) pair */
        let timeoutNS = Int64(timeoutSeconds * Double(nsecPerSec))

        var curTime = timeval()
        gettimeofday(&curTime, nil)

        let allNSecs: Int64 = timeoutNS + Int64(curTime.tv_usec) * 1000
        var timeoutAbs = timespec(tv_sec: curTime.tv_sec + Int((allNSecs / nsecPerSec)),
                                  tv_nsec: Int(allNSecs % nsecPerSec))
        assert(timeoutAbs.tv_nsec >= 0 && timeoutAbs.tv_nsec < Int(nsecPerSec))
        assert(timeoutAbs.tv_sec >= curTime.tv_sec)
        while true {
            if self._value == wantedValue {
                return true
            }
            switch pthread_cond_timedwait(self.cond, self.mutex.mutex, &timeoutAbs) {
            case 0:
                continue
            case ETIMEDOUT:
                self.unlock()
                return false
            case let e:
                fatalError("caught error \(e) when calling pthread_cond_timedwait")
            }
        }
    }

    /// Release the lock, setting the state variable to `newValue`.
    ///
    /// - Parameter newValue: The value to give to the state variable when we
    ///     release the lock.
    public func unlock(withValue newValue: T) {
        self._value = newValue
        self.unlock()
        let r = pthread_cond_broadcast(self.cond)
        precondition(r == 0)
    }
}
