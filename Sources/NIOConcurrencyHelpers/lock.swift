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

#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
import WinSDK
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Bionic)
@preconcurrency import Bionic
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#if canImport(wasi_pthread)
import wasi_pthread
#endif
#else
#error("The concurrency lock module was unable to identify your C library.")
#endif

#if os(Windows)
@usableFromInline
typealias LockPrimitive = SRWLOCK
#else
@usableFromInline
typealias LockPrimitive = pthread_mutex_t
#endif

@usableFromInline
enum LockOperations: Sendable {}

extension LockOperations {
    @inlinable
    static func create(_ mutex: UnsafeMutablePointer<LockPrimitive>) {
        mutex.assertValidAlignment()

        #if os(Windows)
        InitializeSRWLock(mutex)
        #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
        var attr = pthread_mutexattr_t()
        pthread_mutexattr_init(&attr)
        debugOnly {
            pthread_mutexattr_settype(&attr, .init(PTHREAD_MUTEX_ERRORCHECK))
        }

        let err = pthread_mutex_init(mutex, &attr)
        precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
        #endif
    }

    @inlinable
    static func destroy(_ mutex: UnsafeMutablePointer<LockPrimitive>) {
        mutex.assertValidAlignment()

        #if os(Windows)
        // SRWLOCK does not need to be free'd
        #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
        let err = pthread_mutex_destroy(mutex)
        precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
        #endif
    }

    @inlinable
    static func lock(_ mutex: UnsafeMutablePointer<LockPrimitive>) {
        mutex.assertValidAlignment()

        #if os(Windows)
        AcquireSRWLockExclusive(mutex)
        #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
        let err = pthread_mutex_lock(mutex)
        precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
        #endif
    }

    @inlinable
    static func unlock(_ mutex: UnsafeMutablePointer<LockPrimitive>) {
        mutex.assertValidAlignment()

        #if os(Windows)
        ReleaseSRWLockExclusive(mutex)
        #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
        let err = pthread_mutex_unlock(mutex)
        precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
        #endif
    }
}

extension UnsafeMutablePointer {
    @inlinable
    func assertValidAlignment() {
        assert(UInt(bitPattern: self) % UInt(MemoryLayout<Pointee>.alignment) == 0)
    }
}

/// A threading lock based on `libpthread` instead of `libdispatch`.
///
/// This object provides a lock on top of a single `pthread_mutex_t`. This kind
/// of lock is safe to use with `libpthread`-based threading models, such as the
/// one used by NIO. On Windows, the lock is based on the substantially similar
/// `SRWLOCK` type.
@available(*, deprecated, renamed: "NIOLock")
public final class Lock {
    fileprivate let mutex: UnsafeMutablePointer<LockPrimitive> = .allocate(capacity: 1)

    /// Create a new lock.
    public init() {
        LockOperations.create(self.mutex)
    }

    deinit {
        LockOperations.destroy(self.mutex)
        self.mutex.deallocate()
    }

    /// Acquire the lock.
    ///
    /// Whenever possible, consider using `withLock` instead of this method and
    /// `unlock`, to simplify lock handling.
    public func lock() {
        LockOperations.lock(self.mutex)
    }

    /// Release the lock.
    ///
    /// Whenever possible, consider using `withLock` instead of this method and
    /// `lock`, to simplify lock handling.
    public func unlock() {
        LockOperations.unlock(self.mutex)
    }

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
    public func withLockVoid(_ body: () throws -> Void) rethrows {
        try self.withLock(body)
    }
}

/// A `Lock` with a built-in state variable.
///
/// This class provides a convenience addition to `Lock`: it provides the ability to wait
/// until the state variable is set to a specific value to acquire the lock.
public final class ConditionLock<T: Equatable> {
    @usableFromInline
    @exclusivity(unchecked)
    var _value: T
    
    @usableFromInline
    let mutex: UnsafeMutablePointer<LockPrimitive> = .allocate(capacity: 1)
    
    #if os(Windows)
    @usableFromInline
    let cond: UnsafeMutablePointer<CONDITION_VARIABLE> =
        UnsafeMutablePointer.allocate(capacity: 1)
    #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
    @usableFromInline
    let cond: UnsafeMutablePointer<pthread_cond_t> =
        UnsafeMutablePointer.allocate(capacity: 1)
    #endif

    /// Create the lock, and initialize the state variable to `value`.
    ///
    /// - Parameter value: The initial value to give the state variable.
    @inlinable
    public init(value: T) {
        self._value = value
        LockOperations.create(self.mutex)
        
        #if os(Windows)
        InitializeConditionVariable(self.cond)
        #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
        let err = pthread_cond_init(self.cond, nil)
        precondition(err == 0, "\(#function) failed in pthread_cond with error \(err)")
        #endif
    }

    @inlinable
    deinit {
        LockOperations.destroy(self.mutex)
        self.mutex.deallocate()
        
        #if os(Windows)
        // condition variables do not need to be explicitly destroyed
        #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
        let err = pthread_cond_destroy(self.cond)
        precondition(err == 0, "\(#function) failed in pthread_cond with error \(err)")
        self.cond.deallocate()
        #endif
    }

    /// Acquire the lock, regardless of the value of the state variable.
    @inlinable
    public func lock() {
        LockOperations.lock(self.mutex)
    }

    /// Release the lock, regardless of the value of the state variable.
    @inlinable
    public func unlock() {
        LockOperations.unlock(self.mutex)
    }

    /// The value of the state variable.
    ///
    /// Obtaining the value of the state variable requires acquiring the lock.
    /// This means that it is not safe to access this property while holding the
    /// lock: it is only safe to use it when not holding it.
    @inlinable
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
    @inlinable
    public func lock(whenValue wantedValue: T) {
        self.lock()
        while true {
            if self._value == wantedValue {
                break
            }
            
            #if os(Windows)
            let result = SleepConditionVariableSRW(self.cond, self.mutex, INFINITE, 0)
            precondition(result, "\(#function) failed in SleepConditionVariableSRW with error \(GetLastError())")
            #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
            let err = pthread_cond_wait(self.cond, self.mutex)
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
    @inlinable
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
            let result = SleepConditionVariableSRW(self.cond, self.mutex, dwMilliseconds, 0)
            
            if !result {
                let dwError = GetLastError()
                if dwError == ERROR_TIMEOUT {
                    self.unlock()
                    return false
                }
                fatalError("SleepConditionVariableSRW: \(dwError)")
            }
            // NOTE: this may be a spurious wakeup, adjust the timeout accordingly
            dwMilliseconds = dwMilliseconds - (timeGetTime() - dwWaitStart)
        }
        #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
        let nsecPerSec: Int64 = 1_000_000_000
        self.lock()
        // the timeout as a (seconds, nano seconds) pair
        let timeoutNS = Int64(timeoutSeconds * Double(nsecPerSec))

        var curTime = timeval()
        gettimeofday(&curTime, nil)

        let allNSecs: Int64 = timeoutNS + Int64(curTime.tv_usec) * 1000
        let tvSec = curTime.tv_sec + time_t((allNSecs / nsecPerSec))

        var timeoutAbs = timespec(
            tv_sec: tvSec,
            tv_nsec: Int(allNSecs % nsecPerSec)
        )
        assert(timeoutAbs.tv_nsec >= 0 && timeoutAbs.tv_nsec < Int(nsecPerSec))
        assert(timeoutAbs.tv_sec >= curTime.tv_sec)
        
        while true {
            if self._value == wantedValue {
                return true
            }
            switch pthread_cond_timedwait(self.cond, self.mutex, &timeoutAbs) {
            case 0:
                continue
            case ETIMEDOUT:
                self.unlock()
                return false
            case let e:
                fatalError("caught error \(e) when calling pthread_cond_timedwait")
            }
        }
        #else
        return true
        #endif
    }

    /// Release the lock, setting the state variable to `newValue`.
    ///
    /// - Parameter newValue: The value to give to the state variable when we
    ///     release the lock.
    @inlinable
    public func unlock(withValue newValue: T) {
        self._value = newValue
        self.unlock()
        #if os(Windows)
        WakeAllConditionVariable(self.cond)
        #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
        let err = pthread_cond_broadcast(self.cond)
        precondition(err == 0, "\(#function) failed in pthread_cond with error \(err)")
        #endif
    }
}

/// A utility function that runs the body code only in debug builds, without
/// emitting compiler warnings.
///
/// This is currently the only way to do this in Swift: see
/// https://forums.swift.org/t/support-debug-only-code/11037 for a discussion.
@inlinable
internal func debugOnly(_ body: () -> Void) {
    assert(
        {
            body()
            return true
        }()
    )
}

@available(*, deprecated)
extension Lock: @unchecked Sendable {}
extension ConditionLock: @unchecked Sendable {}
