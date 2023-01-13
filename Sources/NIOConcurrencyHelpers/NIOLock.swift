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

#if os(Windows)
@usableFromInline
typealias LockPrimitive = SRWLOCK
#else
@usableFromInline
typealias LockPrimitive = pthread_mutex_t
#endif

enum LockOperations { }

extension LockOperations {
    @inlinable
    static func create(_ mutex: UnsafeMutablePointer<LockPrimitive>) {
#if os(Windows)
        InitializeSRWLock(mutex)
#else
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
#if os(Windows)
        // SRWLOCK does not need to be free'd
#else
        let err = pthread_mutex_destroy(mutex)
        precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
#endif
    }
    
    @inlinable
    static func lock(_ mutex: UnsafeMutablePointer<LockPrimitive>) {
#if os(Windows)
        AcquireSRWLockExclusive(mutex)
#else
        let err = pthread_mutex_lock(mutex)
        precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
#endif
    }
    
    @inlinable
    static func unlock(_ mutex: UnsafeMutablePointer<LockPrimitive>) {
#if os(Windows)
        ReleaseSRWLockExclusive(mutex)
#else
        let err = pthread_mutex_unlock(mutex)
        precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
#endif
    }
}

// Tail allocate both the mutex and a generic value using ManagedBuffer.
// Both the header pointer and the elements pointer are stable for
// the class's entire lifetime.
final class LockStorage<Value>: ManagedBuffer<LockPrimitive, Value> {
    
    @inlinable
    static func create(value: Value) -> Self {
        let buffer = Self.create(minimumCapacity: 1) { _ in
            return LockPrimitive()
        }
        let storage = unsafeDowncast(buffer, to: Self.self)
        
        storage.withUnsafeMutablePointers { lockPtr, valuePtr in
            LockOperations.create(lockPtr)
            valuePtr.initialize(to: value)
        }
        
        return storage
    }
    
    @inlinable
    func lock() {
        self.withUnsafeMutablePointerToHeader { lockPtr in
            LockOperations.lock(lockPtr)
        }
    }
    
    @inlinable
    func unlock() {
        self.withUnsafeMutablePointerToHeader { lockPtr in
            LockOperations.unlock(lockPtr)
        }
    }
    
    @inlinable
    deinit {
        self.withUnsafeMutablePointers { lockPtr, valuePtr in
            LockOperations.destroy(lockPtr)
            valuePtr.deinitialize(count: 1)
        }
    }
    
    @inlinable
    func withLockPrimitive<T>(_ body: (UnsafeMutablePointer<LockPrimitive>) throws -> T) rethrows -> T {
        try self.withUnsafeMutablePointerToHeader { lockPtr in
            return try body(lockPtr)
        }
    }
    
    @inlinable
    func withLockedValue<T>(_ mutate: (inout Value) throws -> T) rethrows -> T {
        try self.withUnsafeMutablePointers { lockPtr, valuePtr in
            LockOperations.lock(lockPtr)
            defer { LockOperations.unlock(lockPtr) }
            return try mutate(&valuePtr.pointee)
        }
    }
}

extension LockStorage: @unchecked Sendable { }

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
    internal let _storage: LockStorage<Void>
    
    /// Create a new lock.
    @inlinable
    public init() {
        self._storage = .create(value: ())
    }

    /// Acquire the lock.
    ///
    /// Whenever possible, consider using `withLock` instead of this method and
    /// `unlock`, to simplify lock handling.
    @inlinable
    public func lock() {
        self._storage.lock()
    }

    /// Release the lock.
    ///
    /// Whenever possible, consider using `withLock` instead of this method and
    /// `lock`, to simplify lock handling.
    @inlinable
    public func unlock() {
        self._storage.unlock()
    }

    @inlinable
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

    @inlinable
    public func withLockVoid(_ body: () throws -> Void) rethrows -> Void {
        try self.withLock(body)
    }
}

extension NIOLock: Sendable {}
