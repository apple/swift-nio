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
/// - note: ``NIOLockedValueBox`` has reference semantics and holds the `Value`
///         alongside a lock behind a reference.
///
/// This is no different than creating a ``Lock`` and protecting all
/// accesses to a value using the lock. But it's easy to forget to actually
/// acquire/release the lock in the correct place. ``NIOLockedValueBox`` makes
/// that much easier.
public struct NIOLockedValueBox<Value> {
    @usableFromInline
    internal final class _Storage {
        @usableFromInline
        internal let _lock = Lock()
        
        @usableFromInline
        internal var _value: Value
        
        internal init(_value value: Value) {
            self._value = value
        }
    }
    
    @usableFromInline
    internal var _storage: _Storage

    /// Initialize the `Value`.
    public init(_ value: Value) {
        self._storage = _Storage(_value: value)
    }

    /// Access the `Value`, allowing mutation of it.
    @inlinable
    public func withNIOLockedValueBox<T>(_ mutate: (inout Value) throws -> T) rethrows -> T {
        return try self._storage._lock.withLock {
            return try mutate(&self._storage._value)
        }
    }
}
