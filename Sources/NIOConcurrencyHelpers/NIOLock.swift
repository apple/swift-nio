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
#error("The concurrency NIOLock module was unable to identify your C library.")
#endif

#if os(Windows)
@usableFromInline
typealias LockPrimitive = SRWLOCK
#elseif os(OpenBSD)
@usableFromInline
typealias LockPrimitive = pthread_mutex_t?
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
        #elseif os(OpenBSD)
        var attr = pthread_mutexattr_t(bitPattern: 0)
        pthread_mutexattr_init(&attr)
        let err = pthread_mutex_init(mutex, &attr)
        precondition(err == 0, "\(#function) failed in pthread_mutex with error \(err)")
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

// Tail allocate both the mutex and a generic value using ManagedBuffer.
// Both the header pointer and the elements pointer are stable for
// the class's entire lifetime.
//
// However, for safety reasons, we elect to place the lock in the "elements"
// section of the buffer instead of the head. The reasoning here is subtle,
// so buckle in.
//
// _As a practical matter_, the implementation of ManagedBuffer ensures that
// the pointer to the header is stable across the lifetime of the class, and so
// each time you call `withUnsafeMutablePointers` or `withUnsafeMutablePointerToHeader`
// the value of the header pointer will be the same. This is because ManagedBuffer uses
// `Builtin.addressOf` to load the value of the header, and that does ~magic~ to ensure
// that it does not invoke any weird Swift accessors that might copy the value.
//
// _However_, the header is also available via the `.header` field on the ManagedBuffer.
// This presents a problem! The reason there's an issue is that `Builtin.addressOf` and friends
// do not interact with Swift's exclusivity model. That is, the various `with` functions do not
// conceptually trigger a mutating access to `.header`. For elements this isn't a concern because
// there's literally no other way to perform the access, but for `.header` it's entirely possible
// to accidentally recursively read it.
//
// Our implementation is free from these issues, so we don't _really_ need to worry about it.
// However, out of an abundance of caution, we store the Value in the header, and the LockPrimitive
// in the trailing elements. We still don't use `.header`, but it's better to be safe than sorry,
// and future maintainers will be happier that we were cautious.
//
// See also: https://github.com/apple/swift/pull/40000
@usableFromInline
final class LockStorage<Value>: ManagedBuffer<Value, LockPrimitive> {

    @inlinable
    static func create(value: Value) -> Self {
        let buffer = Self.create(minimumCapacity: 1) { _ in
            value
        }
        // Intentionally using a force cast here to avoid a miss compiliation in 5.10.
        // This is as fast as an unsafeDownCast since ManagedBuffer is inlined and the optimizer
        // can eliminate the upcast/downcast pair
        let storage = buffer as! Self

        storage.withUnsafeMutablePointers { _, lockPtr in
            LockOperations.create(lockPtr)
        }

        return storage
    }

    @inlinable
    func lock() {
        self.withUnsafeMutablePointerToElements { lockPtr in
            LockOperations.lock(lockPtr)
        }
    }

    @inlinable
    func unlock() {
        self.withUnsafeMutablePointerToElements { lockPtr in
            LockOperations.unlock(lockPtr)
        }
    }

    @inlinable
    deinit {
        self.withUnsafeMutablePointerToElements { lockPtr in
            LockOperations.destroy(lockPtr)
        }
    }

    @inlinable
    func withLockPrimitive<T>(_ body: (UnsafeMutablePointer<LockPrimitive>) throws -> T) rethrows -> T {
        try self.withUnsafeMutablePointerToElements { lockPtr in
            try body(lockPtr)
        }
    }

    @inlinable
    func withLockedValue<T>(_ mutate: (inout Value) throws -> T) rethrows -> T {
        try self.withUnsafeMutablePointers { valuePtr, lockPtr in
            LockOperations.lock(lockPtr)
            defer { LockOperations.unlock(lockPtr) }
            return try mutate(&valuePtr.pointee)
        }
    }
}

// This compiler guard is here becaue `ManagedBuffer` is already declaring
// Sendable unavailability after 6.1, which `LockStorage` inherits.
#if compiler(<6.2)
@available(*, unavailable)
extension LockStorage: Sendable {}
#endif

/// A threading lock based on `libpthread` instead of `libdispatch`.
///
/// - Note: ``NIOLock`` has reference semantics.
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
        try self._storage.withLockPrimitive(body)
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

extension UnsafeMutablePointer {
    @inlinable
    func assertValidAlignment() {
        assert(UInt(bitPattern: self) % UInt(MemoryLayout<Pointee>.alignment) == 0)
    }
}
