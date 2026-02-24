//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Provides locked access to `Value`.
///
/// - Note: ``NIOLockedValueBox`` has reference semantics and holds the `Value`
///         alongside a lock behind a reference.
///
/// This is no different than creating a ``Lock`` and protecting all
/// accesses to a value using the lock. But it's easy to forget to actually
/// acquire/release the lock in the correct place. ``NIOLockedValueBox`` makes
/// that much easier.
public struct NIOLockedValueBox<Value> {

    @usableFromInline
    internal let _storage: LockStorage<Value>

    /// Initialize the `Value`.
    @inlinable
    public init(_ value: Value) {
        self._storage = .create(value: value)
    }

    /// Access the `Value`, allowing mutation of it.
    @inlinable
    public func withLockedValue<T>(_ mutate: (inout Value) throws -> T) rethrows -> T {
        try self._storage.withLockedValue(mutate)
    }

    /// Provides an unsafe view over the lock and its value.
    ///
    /// This can be beneficial when you require fine grained control over the lock in some
    /// situations but don't want lose the benefits of ``withLockedValue(_:)`` in others by
    /// switching to ``NIOLock``.
    public var unsafe: Unsafe {
        Unsafe(_storage: self._storage)
    }

    /// Provides an unsafe view over the lock and its value.
    public struct Unsafe {
        @usableFromInline
        let _storage: LockStorage<Value>

        /// Manually acquire the lock.
        @inlinable
        public func lock() {
            self._storage.lock()
        }

        /// Manually release the lock.
        @inlinable
        public func unlock() {
            self._storage.unlock()
        }

        /// Mutate the value, assuming the lock has been acquired manually.
        ///
        /// - Parameter mutate: A closure with scoped access to the value.
        /// - Returns: The result of the `mutate` closure.
        @inlinable
        public func withValueAssumingLockIsAcquired<Result>(
            _ mutate: (_ value: inout Value) throws -> Result
        ) rethrows -> Result {
            try self._storage.withUnsafeMutablePointerToHeader { value in
                try mutate(&value.pointee)
            }
        }
    }
}

extension NIOLockedValueBox: @unchecked Sendable where Value: Sendable {}

extension NIOLockedValueBox.Unsafe: @unchecked Sendable where Value: Sendable {}
