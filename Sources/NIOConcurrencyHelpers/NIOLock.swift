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

#if canImport(Darwin)
import Darwin
#else
import Synchronization
#endif

@usableFromInline
final class LockStorage<Value> {
    
    #if canImport(Darwin)
    @usableFromInline
    @exclusivity(unchecked)
    var mutex: os_unfair_lock_s
    #else
    @usableFromInline
    let mutex: Mutex<Void>
    #endif
    
    @usableFromInline
    @exclusivity(unchecked)
    var value: Value
    
    @inlinable
    init(value: Value) {
        #if canImport(Darwin)
        self.mutex = os_unfair_lock_s()
        #else
        self.mutex = Mutex(())
        #endif
        self.value = value
    }
    
    @inlinable
    func lock() {
        #if canImport(Darwin)
        let mutex_ptr = _getUnsafePointerToStoredProperties(self).assumingMemoryBound(to: os_unfair_lock_s.self)
        os_unfair_lock_lock(mutex_ptr)
        _fixLifetime(self)
        #else
        self.mutex._unsafeLock()
        #endif
    }
    
    @inlinable
    func unlock() {
        #if canImport(Darwin)
        let mutex_ptr = _getUnsafePointerToStoredProperties(self).assumingMemoryBound(to: os_unfair_lock_s.self)
        os_unfair_lock_unlock(mutex_ptr)
        _fixLifetime(self)
        #else
        self.mutex._unsafeUnlock()
        #endif
    }
}

@available(*, unavailable)
extension LockStorage: Sendable {}

/// A threading lock based on `Synchronization.Mutex` instead of `libdispatch`.
///
/// - Note: ``NIOLock`` has reference semantics.
///
/// This object provides a lock on top of a single `Synchronization.Mutex`. This kind
/// of lock is safe to use with `libpthread`-based threading models, such as the
/// one used by NIO.
public struct NIOLock {
    @usableFromInline
    let _storage: LockStorage<Void>

    /// Create a new lock.
    @inlinable
    public init() {
        self._storage = LockStorage(value: ())
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
    public func withLockVoid(_ body: () throws -> Void) rethrows {
        try self.withLock(body)
    }
}

extension NIOLock: @unchecked Sendable {}
