//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
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
/// - note: ``NIOLock`` has reference semantics.
///
/// This object provides a lock on top of a single `pthread_mutex_t`. This kind
/// of lock is safe to use with `libpthread`-based threading models, such as the
/// one used by NIO. On Windows, the lock is based on the substantially similar
/// `SRWLOCK` type.
public struct NIOLock {
    @usableFromInline
    internal let _storage: _Storage

#if os(Windows)
    @usableFromInline
    internal typealias LockPrimitive = SRWLOCK
#else
    @usableFromInline
    internal typealias LockPrimitive = pthread_mutex_t
#endif
    
    @usableFromInline
    internal final class _Storage {
        // TODO: We should tail-allocate the pthread_t/SRWLock.
        @usableFromInline
        internal let mutex: UnsafeMutablePointer<LockPrimitive> =
        UnsafeMutablePointer.allocate(capacity: 1)

        /// Create a new lock.
        internal init() {
#if os(Windows)
            InitializeSRWLock(self.mutex)
#else
            var attr = pthread_mutexattr_t()
            pthread_mutexattr_init(&attr)
            debugOnly {
                pthread_mutexattr_settype(&attr, .init(PTHREAD_MUTEX_ERRORCHECK))
            }
            
            let err = pthread_mutex_init(self.mutex, &attr)
            precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
#endif
        }
        
        internal func lock() {
#if os(Windows)
            AcquireSRWLockExclusive(self.mutex)
#else
            let err = pthread_mutex_lock(self.mutex)
            precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
#endif
        }
        
        internal func unlock() {
#if os(Windows)
            ReleaseSRWLockExclusive(self._storage.mutex)
#else
            let err = pthread_mutex_unlock(self.mutex)
            precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
#endif
        }

        internal func withLockPrimitive<T>(_ body: (UnsafeMutablePointer<LockPrimitive>) throws -> T) rethrows -> T {
            return try body(self.mutex)
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
    }
    
    /// Create a new lock.
    public init() {
        self._storage = _Storage()
    }

    /// Acquire the lock.
    ///
    /// Whenever possible, consider using `withLock` instead of this method and
    /// `unlock`, to simplify lock handling.
    public func lock() {
        self._storage.lock()
    }

    /// Release the lock.
    ///
    /// Whenever possible, consider using `withLock` instead of this method and
    /// `lock`, to simplify lock handling.
    public func unlock() {
        self._storage.unlock()
    }

    internal func withLockPrimitive<T>(_ body: (UnsafeMutablePointer<LockPrimitive>) throws -> T) rethrows -> T {
        return try self._storage.withLockPrimitive(body)
    }
}

extension NIOLock {
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

#if compiler(>=5.5) && canImport(_Concurrency)
extension NIOLock: Sendable {}
extension NIOLock._Storage: Sendable {}
#endif
