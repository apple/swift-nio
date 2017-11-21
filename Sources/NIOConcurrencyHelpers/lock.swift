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

public final class Lock {
    fileprivate let mutex: UnsafeMutablePointer<pthread_mutex_t> = UnsafeMutablePointer.allocate(capacity: 1)

    public init() {
        let err = pthread_mutex_init(self.mutex, nil)
        precondition(err == 0)
    }

    deinit {
        mutex.deallocate(capacity: 1)
    }

    public func lock() {
        let err = pthread_mutex_lock(self.mutex)
        precondition(err == 0)
    }

    public func unlock() {
        let err = pthread_mutex_unlock(self.mutex)
        precondition(err == 0)
    }
}

extension Lock {
    public func withLock<T>(_ fn: () throws -> T) rethrows -> T {
        self.lock()
        defer {
            self.unlock()
        }
        return try fn()
    }

    // specialise Void return (for performance)
    public func withLockVoid(_ fn: () throws -> Void) rethrows -> Void {
        try self.withLock(fn)
    }
}

public final class ConditionLock<T: Equatable> {
    private var _value: T
    private let mutex: Lock
    private let cond: UnsafeMutablePointer<pthread_cond_t> = UnsafeMutablePointer.allocate(capacity: 1)

    public init(value: T) {
        self._value = value
        self.mutex = Lock()
        let err = pthread_cond_init(self.cond, nil)
        precondition(err == 0)
    }

    deinit {
        self.cond.deallocate(capacity: 1)
    }

    public func lock() {
        self.mutex.lock()
    }

    public func unlock() {
        self.mutex.unlock()
    }

    public var value: T {
        self.lock()
        defer {
            self.unlock()
        }
        return self._value
    }

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

    public func lock(whenValue wantedValue: T, timeoutSeconds: Double) -> Bool{
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

    public func unlock(withValue newValue: T) {
        self._value = newValue
        self.unlock()
        let r = pthread_cond_broadcast(self.cond)
        precondition(r == 0)
    }
}
