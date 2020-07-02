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

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#elseif os(Windows)
import ucrt
import WinSDK
#else
import Glibc
#endif

/// A threading lock based on `libpthread` instead of `libdispatch`.
///
/// This object provides a lock on top of a single `pthread_mutex_t`. This kind
/// of lock is safe to use with `libpthread`-based threading models, such as the
/// one used by NIO. On Windows, the lock is based on the substantially similar
/// `SRWLOCK` type.
public final class Lock {
#if os(Windows)
    fileprivate let mutex: UnsafeMutablePointer<SRWLOCK> =
        UnsafeMutablePointer.allocate(capacity: 1)
#else
    fileprivate let mutex: UnsafeMutablePointer<pthread_mutex_t> =
        UnsafeMutablePointer.allocate(capacity: 1)
#endif

    /// Create a new lock.
    public init() {
#if os(Windows)
        InitializeSRWLock(self.mutex)
#else
        var attr = pthread_mutexattr_t()
        pthread_mutexattr_init(&attr)
        pthread_mutexattr_settype(&attr, .init(PTHREAD_MUTEX_ERRORCHECK))

        let err = pthread_mutex_init(self.mutex, &attr)
        precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
#endif
    }

    deinit {
#if os(Windows)
        // SRWLOCK does not need to be free'd
#else
        let err = pthread_mutex_destroy(self.mutex)
        precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
#endif
        mutex.deallocate()
    }

    /// Acquire the lock.
    ///
    /// Whenever possible, consider using `withLock` instead of this method and
    /// `unlock`, to simplify lock handling.
    public func lock() {
#if os(Windows)
        AcquireSRWLockExclusive(self.mutex)
#else
        let err = pthread_mutex_lock(self.mutex)
        precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
#endif
    }

    /// Release the lock.
    ///
    /// Whenver possible, consider using `withLock` instead of this method and
    /// `lock`, to simplify lock handling.
    public func unlock() {
#if os(Windows)
        ReleaseSRWLockExclusive(self.mutex)
#else
        let err = pthread_mutex_unlock(self.mutex)
        precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
#endif
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
    @inlinable
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        self.lock()
        defer {
            self.unlock()
        }
        return try body()
    }

    // specialise Void return (for performance)
    @inlinable
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
#if os(Windows)
    private let cond: UnsafeMutablePointer<CONDITION_VARIABLE> =
        UnsafeMutablePointer.allocate(capacity: 1)
#else
    private let cond: UnsafeMutablePointer<pthread_cond_t> =
        UnsafeMutablePointer.allocate(capacity: 1)
#endif

    /// Create the lock, and initialize the state variable to `value`.
    ///
    /// - Parameter value: The initial value to give the state variable.
    public init(value: T) {
        self._value = value
        self.mutex = Lock()
#if os(Windows)
        InitializeConditionVariable(self.cond)
#else
        let err = pthread_cond_init(self.cond, nil)
        precondition(err == 0, "\(#function) failed in pthread_cond with error \(err)")
#endif
    }

    deinit {
#if os(Windows)
        // condition variables do not need to be explicitly destroyed
#else
        let err = pthread_cond_destroy(self.cond)
        precondition(err == 0, "\(#function) failed in pthread_cond with error \(err)")
#endif
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
#if os(Windows)
            let result = SleepConditionVariableSRW(self.cond, self.mutex.mutex, INFINITE, 0)
            precondition(result, "\(#function) failed in SleepConditionVariableSRW with error \(GetLastError())")
#else
            let err = pthread_cond_wait(self.cond, self.mutex.mutex)
            precondition(err == 0, "\(#function) failed in pthread_cond with error \(err)")
#endif
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

#if os(Windows)
        var dwMilliseconds: DWORD = DWORD(timeoutSeconds * 1000)

        self.lock()
        while true {
            if self._value == wantedValue {
                return true
            }

            let dwWaitStart = timeGetTime()
            if !SleepConditionVariableSRW(self.cond, self.mutex.mutex,
                                          dwMilliseconds, 0) {
                let dwError = GetLastError()
                if (dwError == ERROR_TIMEOUT) {
                    self.unlock()
                    return false
                }
                fatalError("SleepConditionVariableSRW: \(dwError)")
            }

            // NOTE: this may be a spurious wakeup, adjust the timeout accordingly
            dwMilliseconds = dwMilliseconds - (timeGetTime() - dwWaitStart)
        }
#else
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
#endif
    }

    /// Release the lock, setting the state variable to `newValue`.
    ///
    /// - Parameter newValue: The value to give to the state variable when we
    ///     release the lock.
    public func unlock(withValue newValue: T) {
        self._value = newValue
        self.unlock()
#if os(Windows)
        WakeAllConditionVariable(self.cond)
#else
        let err = pthread_cond_broadcast(self.cond)
        precondition(err == 0, "\(#function) failed in pthread_cond with error \(err)")
#endif
    }
}
