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

import CNIOAtomics

/// An atomic primitive object.
///
/// Before using `UnsafeEmbeddedAtomic`, please consider whether your needs can be met by `Atomic` instead.
/// `UnsafeEmbeddedAtomic` is a value type, but atomics are heap-allocated. Thus, it is only safe to
/// use `UnsafeEmbeddedAtomic` in situations where the atomic can be guaranteed to be cleaned up (via calling `destroy`).
/// If you cannot make these guarantees, use `Atomic` instead, which manages this for you.
///
/// Atomic objects support a wide range of atomic operations:
///
/// - Compare and swap
/// - Add
/// - Subtract
/// - Exchange
/// - Load current value
/// - Store current value
///
/// Atomic primitives are useful when building constructs that need to
/// communicate or cooperate across multiple threads. In the case of
/// SwiftNIO this usually involves communicating across multiple event loops.
public struct UnsafeEmbeddedAtomic<T: AtomicPrimitive> {
    private let value: OpaquePointer

    /// Create an atomic object with `value`.
    @_specialize(where T == Int)
    @_specialize(where T == Bool)
    @_specialize(where T == UInt64)
    // in Swift 4.0 (fixed in 4.0.2), there was a crash that only allowed three specialisations otherwise the compiler would crash
    // FIXME: Bring back when we require Swift >= 4.0.2
    // @_specialize(where T == UInt)
    // @_specialize(where T == Int64)
    public init(value: T) {
        self.value = T.atomic_create(value)
    }

    /// Atomically compares the value against `expected` and, if they are equal,
    /// replaces the value with `desired`.
    ///
    /// This implementation conforms to C11's `atomic_compare_exchange_strong`. This
    /// means that the compare-and-swap will always succeed if `expected` is equal to
    /// value. Additionally, it uses a *sequentially consistent ordering*. For more
    /// details on atomic memory models, check the documentation for C11's
    /// `stdatomic.h`.
    ///
    /// - Parameter expected: The value that this object must currently hold for the
    ///     compare-and-swap to succeed.
    /// - Parameter desired: The new value that this object will hold if the compare
    ///     succeeds.
    /// - Returns: `True` if the exchange occurred, or `False` if `expected` did not
    ///     match the current value and so no exchange occurred.
    @_specialize(where T == Int)
    @_specialize(where T == Bool)
    @_specialize(where T == UInt64)
    // in Swift 4.0 (fixed in 4.0.2), there was a crash that only allowed three specialisations otherwise the compiler would crash
    // FIXME: Bring back when we require Swift >= 4.0.2
    // @_specialize(where T == UInt)
    // @_specialize(where T == Int64)
    public func compareAndExchange(expected: T, desired: T) -> Bool {
        return T.atomic_compare_and_exchange(self.value, expected, desired)
    }

    /// Atomically adds `rhs` to this object.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Parameter rhs: The value to add to this object.
    /// - Returns: The previous value of this object, before the addition occurred.
    @_specialize(where T == Int)
    @_specialize(where T == Bool)
    @_specialize(where T == UInt64)
    // in Swift 4.0 (fixed in 4.0.2), there was a crash that only allowed three specialisations otherwise the compiler would crash
    // FIXME: Bring back when we require Swift >= 4.0.2
    // @_specialize(where T == UInt)
    // @_specialize(where T == Int64)
    public func add(_ rhs: T) -> T {
        return T.atomic_add(self.value, rhs)
    }

    /// Atomically subtracts `rhs` from this object.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Parameter rhs: The value to subtract from this object.
    /// - Returns: The previous value of this object, before the subtraction occurred.
    @_specialize(where T == Int)
    @_specialize(where T == Bool)
    @_specialize(where T == UInt64)
    // in Swift 4.0 (fixed in 4.0.2), there was a crash that only allowed three specialisations otherwise the compiler would crash
    // FIXME: Bring back when we require Swift >= 4.0.2
    // @_specialize(where T == UInt)
    // @_specialize(where T == Int64)
    public func sub(_ rhs: T) -> T {
        return T.atomic_sub(self.value, rhs)
    }

    /// Atomically exchanges `value` for the current value of this object.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Parameter value: The new value to set this object to.
    /// - Returns: The value previously held by this object.
    @_specialize(where T == Int)
    @_specialize(where T == Bool)
    @_specialize(where T == UInt64)
    // in Swift 4.0 (fixed in 4.0.2), there was a crash that only allowed three specialisations otherwise the compiler would crash
    // FIXME: Bring back when we require Swift >= 4.0.2
    // @_specialize(where T == UInt)
    // @_specialize(where T == Int64)
    public func exchange(with value: T) -> T {
        return T.atomic_exchange(self.value, value)
    }

    /// Atomically loads and returns the value of this object.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Returns: The value of this object
    @_specialize(where T == Int)
    @_specialize(where T == Bool)
    @_specialize(where T == UInt64)
    // in Swift 4.0 (fixed in 4.0.2), there was a crash that only allowed three specialisations otherwise the compiler would crash
    // FIXME: Bring back when we require Swift >= 4.0.2
    // @_specialize(where T == UInt)
    // @_specialize(where T == Int64)
    public func load() -> T {
        return T.atomic_load(self.value)
    }

    /// Atomically replaces the value of this object with `value`.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Parameter value: The new value to set the object to.
    @_specialize(where T == Int)
    @_specialize(where T == Bool)
    @_specialize(where T == UInt64)
    // in Swift 4.0 (fixed in 4.0.2), there was a crash that only allowed three specialisations otherwise the compiler would crash
    // FIXME: Bring back when we require Swift >= 4.0.2
    // @_specialize(where T == UInt)
    // @_specialize(where T == Int64)
    public func store(_ value: T) -> Void {
        T.atomic_store(self.value, value)
    }

    /// Destroy the atomic value.
    ///
    /// This method is the source of the unsafety of this structure. This *must* be called, or you will leak memory with each
    /// atomic.
    public func destroy() {
        T.atomic_destroy(self.value)
    }
}

/// An encapsulation of an atomic primitive object.
///
/// Atomic objects support a wide range of atomic operations:
///
/// - Compare and swap
/// - Add
/// - Subtract
/// - Exchange
/// - Load current value
/// - Store current value
///
/// Atomic primitives are useful when building constructs that need to
/// communicate or cooperate across multiple threads. In the case of
/// SwiftNIO this usually involves communicating across multiple event loops.
///
/// By necessity, all atomic values are references: after all, it makes no
/// sense to talk about managing an atomic value when each time it's modified
/// the thread that modified it gets a local copy!
public final class Atomic<T: AtomicPrimitive> {
    private let embedded: UnsafeEmbeddedAtomic<T>

    /// Create an atomic object with `value`.
    @_specialize(where T == Int)
    @_specialize(where T == Bool)
    @_specialize(where T == UInt64)
    // in Swift 4.0 (fixed in 4.0.2), there was a crash that only allowed three specialisations otherwise the compiler would crash
    // FIXME: Bring back when we require Swift >= 4.0.2
    // @_specialize(where T == UInt)
    // @_specialize(where T == Int64)
    public init(value: T) {
        self.embedded = UnsafeEmbeddedAtomic(value: value)
    }

    /// Atomically compares the value against `expected` and, if they are equal,
    /// replaces the value with `desired`.
    ///
    /// This implementation conforms to C11's `atomic_compare_exchange_strong`. This
    /// means that the compare-and-swap will always succeed if `expected` is equal to
    /// value. Additionally, it uses a *sequentially consistent ordering*. For more
    /// details on atomic memory models, check the documentation for C11's
    /// `stdatomic.h`.
    ///
    /// - Parameter expected: The value that this object must currently hold for the
    ///     compare-and-swap to succeed.
    /// - Parameter desired: The new value that this object will hold if the compare
    ///     succeeds.
    /// - Returns: `True` if the exchange occurred, or `False` if `expected` did not
    ///     match the current value and so no exchange occurred.
    @_specialize(where T == Int)
    @_specialize(where T == Bool)
    @_specialize(where T == UInt64)
    // in Swift 4.0 (fixed in 4.0.2), there was a crash that only allowed three specialisations otherwise the compiler would crash
    // FIXME: Bring back when we require Swift >= 4.0.2
    // @_specialize(where T == UInt)
    // @_specialize(where T == Int64)
    public func compareAndExchange(expected: T, desired: T) -> Bool {
        return self.embedded.compareAndExchange(expected: expected, desired: desired)
    }

    /// Atomically adds `rhs` to this object.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Parameter rhs: The value to add to this object.
    /// - Returns: The previous value of this object, before the addition occurred.
    @_specialize(where T == Int)
    @_specialize(where T == Bool)
    @_specialize(where T == UInt64)
    // in Swift 4.0 (fixed in 4.0.2), there was a crash that only allowed three specialisations otherwise the compiler would crash
    // FIXME: Bring back when we require Swift >= 4.0.2
    // @_specialize(where T == UInt)
    // @_specialize(where T == Int64)
    public func add(_ rhs: T) -> T {
        return self.embedded.add(rhs)
    }

    /// Atomically subtracts `rhs` from this object.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Parameter rhs: The value to subtract from this object.
    /// - Returns: The previous value of this object, before the subtraction occurred.
    @_specialize(where T == Int)
    @_specialize(where T == Bool)
    @_specialize(where T == UInt64)
    // in Swift 4.0 (fixed in 4.0.2), there was a crash that only allowed three specialisations otherwise the compiler would crash
    // FIXME: Bring back when we require Swift >= 4.0.2
    // @_specialize(where T == UInt)
    // @_specialize(where T == Int64)
    public func sub(_ rhs: T) -> T {
        return self.embedded.sub(rhs)
    }

    /// Atomically exchanges `value` for the current value of this object.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Parameter value: The new value to set this object to.
    /// - Returns: The value previously held by this object.
    @_specialize(where T == Int)
    @_specialize(where T == Bool)
    @_specialize(where T == UInt64)
    // in Swift 4.0 (fixed in 4.0.2), there was a crash that only allowed three specialisations otherwise the compiler would crash
    // FIXME: Bring back when we require Swift >= 4.0.2
    // @_specialize(where T == UInt)
    // @_specialize(where T == Int64)
    public func exchange(with value: T) -> T {
        return self.embedded.exchange(with: value)
    }

    /// Atomically loads and returns the value of this object.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Returns: The value of this object
    @_specialize(where T == Int)
    @_specialize(where T == Bool)
    @_specialize(where T == UInt64)
    // in Swift 4.0 (fixed in 4.0.2), there was a crash that only allowed three specialisations otherwise the compiler would crash
    // FIXME: Bring back when we require Swift >= 4.0.2
    // @_specialize(where T == UInt)
    // @_specialize(where T == Int64)
    public func load() -> T {
        return self.embedded.load()
    }

    /// Atomically replaces the value of this object with `value`.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Parameter value: The new value to set the object to.
    @_specialize(where T == Int)
    @_specialize(where T == Bool)
    @_specialize(where T == UInt64)
    // in Swift 4.0 (fixed in 4.0.2), there was a crash that only allowed three specialisations otherwise the compiler would crash
    // FIXME: Bring back when we require Swift >= 4.0.2
    // @_specialize(where T == UInt)
    // @_specialize(where T == Int64)
    public func store(_ value: T) -> Void {
        self.embedded.store(value)
    }

    deinit {
        self.embedded.destroy()
    }
}

/// The protocol that all types that can be made atomic must conform to.
///
/// **Do not add conformance to this protocol for arbitrary types**. Only a small range
/// of types have appropriate atomic operations supported by the CPU, and those types
/// already have conformances implemented.
public protocol AtomicPrimitive {
    static var atomic_create: (Self) -> OpaquePointer { get }
    static var atomic_destroy: (OpaquePointer) -> Void { get }
    static var atomic_compare_and_exchange: (OpaquePointer, Self, Self) -> Bool { get }
    static var atomic_add: (OpaquePointer, Self) -> Self { get }
    static var atomic_sub: (OpaquePointer, Self) -> Self { get }
    static var atomic_exchange: (OpaquePointer, Self) -> Self { get }
    static var atomic_load: (OpaquePointer) -> Self { get }
    static var atomic_store: (OpaquePointer, Self) -> Void { get }
}

extension Bool: AtomicPrimitive {
    public static let atomic_create               = catmc_atomic__Bool_create
    public static let atomic_destroy              = catmc_atomic__Bool_destroy
    public static let atomic_compare_and_exchange = catmc_atomic__Bool_compare_and_exchange
    public static let atomic_add                  = catmc_atomic__Bool_add
    public static let atomic_sub                  = catmc_atomic__Bool_sub
    public static let atomic_exchange             = catmc_atomic__Bool_exchange
    public static let atomic_load                 = catmc_atomic__Bool_load
    public static let atomic_store                = catmc_atomic__Bool_store
}

extension Int8: AtomicPrimitive {
    public static let atomic_create               = catmc_atomic_int_least8_t_create
    public static let atomic_destroy              = catmc_atomic_int_least8_t_destroy
    public static let atomic_compare_and_exchange = catmc_atomic_int_least8_t_compare_and_exchange
    public static let atomic_add                  = catmc_atomic_int_least8_t_add
    public static let atomic_sub                  = catmc_atomic_int_least8_t_sub
    public static let atomic_exchange             = catmc_atomic_int_least8_t_exchange
    public static let atomic_load                 = catmc_atomic_int_least8_t_load
    public static let atomic_store                = catmc_atomic_int_least8_t_store
}

extension UInt8: AtomicPrimitive {
    public static let atomic_create               = catmc_atomic_uint_least8_t_create
    public static let atomic_destroy              = catmc_atomic_uint_least8_t_destroy
    public static let atomic_compare_and_exchange = catmc_atomic_uint_least8_t_compare_and_exchange
    public static let atomic_add                  = catmc_atomic_uint_least8_t_add
    public static let atomic_sub                  = catmc_atomic_uint_least8_t_sub
    public static let atomic_exchange             = catmc_atomic_uint_least8_t_exchange
    public static let atomic_load                 = catmc_atomic_uint_least8_t_load
    public static let atomic_store                = catmc_atomic_uint_least8_t_store
}

extension Int16: AtomicPrimitive {
    public static let atomic_create               = catmc_atomic_int_least16_t_create
    public static let atomic_destroy              = catmc_atomic_int_least16_t_destroy
    public static let atomic_compare_and_exchange = catmc_atomic_int_least16_t_compare_and_exchange
    public static let atomic_add                  = catmc_atomic_int_least16_t_add
    public static let atomic_sub                  = catmc_atomic_int_least16_t_sub
    public static let atomic_exchange             = catmc_atomic_int_least16_t_exchange
    public static let atomic_load                 = catmc_atomic_int_least16_t_load
    public static let atomic_store                = catmc_atomic_int_least16_t_store
}

extension UInt16: AtomicPrimitive {
    public static let atomic_create               = catmc_atomic_uint_least16_t_create
    public static let atomic_destroy              = catmc_atomic_uint_least16_t_destroy
    public static let atomic_compare_and_exchange = catmc_atomic_uint_least16_t_compare_and_exchange
    public static let atomic_add                  = catmc_atomic_uint_least16_t_add
    public static let atomic_sub                  = catmc_atomic_uint_least16_t_sub
    public static let atomic_exchange             = catmc_atomic_uint_least16_t_exchange
    public static let atomic_load                 = catmc_atomic_uint_least16_t_load
    public static let atomic_store                = catmc_atomic_uint_least16_t_store
}

extension Int32: AtomicPrimitive {
    public static let atomic_create               = catmc_atomic_int_least32_t_create
    public static let atomic_destroy              = catmc_atomic_int_least32_t_destroy
    public static let atomic_compare_and_exchange = catmc_atomic_int_least32_t_compare_and_exchange
    public static let atomic_add                  = catmc_atomic_int_least32_t_add
    public static let atomic_sub                  = catmc_atomic_int_least32_t_sub
    public static let atomic_exchange             = catmc_atomic_int_least32_t_exchange
    public static let atomic_load                 = catmc_atomic_int_least32_t_load
    public static let atomic_store                = catmc_atomic_int_least32_t_store
}

extension UInt32: AtomicPrimitive {
    public static let atomic_create               = catmc_atomic_uint_least32_t_create
    public static let atomic_destroy              = catmc_atomic_uint_least32_t_destroy
    public static let atomic_compare_and_exchange = catmc_atomic_uint_least32_t_compare_and_exchange
    public static let atomic_add                  = catmc_atomic_uint_least32_t_add
    public static let atomic_sub                  = catmc_atomic_uint_least32_t_sub
    public static let atomic_exchange             = catmc_atomic_uint_least32_t_exchange
    public static let atomic_load                 = catmc_atomic_uint_least32_t_load
    public static let atomic_store                = catmc_atomic_uint_least32_t_store
}

extension Int64: AtomicPrimitive {
    public static let atomic_create               = catmc_atomic_long_long_create
    public static let atomic_destroy              = catmc_atomic_long_long_destroy
    public static let atomic_compare_and_exchange = catmc_atomic_long_long_compare_and_exchange
    public static let atomic_add                  = catmc_atomic_long_long_add
    public static let atomic_sub                  = catmc_atomic_long_long_sub
    public static let atomic_exchange             = catmc_atomic_long_long_exchange
    public static let atomic_load                 = catmc_atomic_long_long_load
    public static let atomic_store                = catmc_atomic_long_long_store
}

extension UInt64: AtomicPrimitive {
    public static let atomic_create               = catmc_atomic_unsigned_long_long_create
    public static let atomic_destroy              = catmc_atomic_unsigned_long_long_destroy
    public static let atomic_compare_and_exchange = catmc_atomic_unsigned_long_long_compare_and_exchange
    public static let atomic_add                  = catmc_atomic_unsigned_long_long_add
    public static let atomic_sub                  = catmc_atomic_unsigned_long_long_sub
    public static let atomic_exchange             = catmc_atomic_unsigned_long_long_exchange
    public static let atomic_load                 = catmc_atomic_unsigned_long_long_load
    public static let atomic_store                = catmc_atomic_unsigned_long_long_store
}

extension Int: AtomicPrimitive {
    public static let atomic_create               = catmc_atomic_long_create
    public static let atomic_destroy              = catmc_atomic_long_destroy
    public static let atomic_compare_and_exchange = catmc_atomic_long_compare_and_exchange
    public static let atomic_add                  = catmc_atomic_long_add
    public static let atomic_sub                  = catmc_atomic_long_sub
    public static let atomic_exchange             = catmc_atomic_long_exchange
    public static let atomic_load                 = catmc_atomic_long_load
    public static let atomic_store                = catmc_atomic_long_store
}

extension UInt: AtomicPrimitive {
    public static let atomic_create               = catmc_atomic_unsigned_long_create
    public static let atomic_destroy              = catmc_atomic_unsigned_long_destroy
    public static let atomic_compare_and_exchange = catmc_atomic_unsigned_long_compare_and_exchange
    public static let atomic_add                  = catmc_atomic_unsigned_long_add
    public static let atomic_sub                  = catmc_atomic_unsigned_long_sub
    public static let atomic_exchange             = catmc_atomic_unsigned_long_exchange
    public static let atomic_load                 = catmc_atomic_unsigned_long_load
    public static let atomic_store                = catmc_atomic_unsigned_long_store
}

/// `AtomicBox` is a heap-allocated box which allows atomic access to an instance of a Swift class.
///
/// It behaves very much like `Atomic<T>` but for objects, maintaining the correct retain counts.
public class AtomicBox<T: AnyObject> {
    private let storage: Atomic<UInt>

    public init(value: T) {
        let ptr = Unmanaged<T>.passRetained(value)
        self.storage = Atomic(value: UInt(bitPattern: ptr.toOpaque()))
    }

    deinit {
        let oldPtrBits = self.storage.exchange(with: 0xdeadbee)
        let oldPtr = Unmanaged<T>.fromOpaque(UnsafeRawPointer(bitPattern: oldPtrBits)!)
        oldPtr.release()
    }

    /// Atomically compares the value against `expected` and, if they are equal,
    /// replaces the value with `desired`.
    ///
    /// This implementation conforms to C11's `atomic_compare_exchange_strong`. This
    /// means that the compare-and-swap will always succeed if `expected` is equal to
    /// value. Additionally, it uses a *sequentially consistent ordering*. For more
    /// details on atomic memory models, check the documentation for C11's
    /// `stdatomic.h`.
    ///
    /// - Parameter expected: The value that this object must currently hold for the
    ///     compare-and-swap to succeed.
    /// - Parameter desired: The new value that this object will hold if the compare
    ///     succeeds.
    /// - Returns: `True` if the exchange occurred, or `False` if `expected` did not
    ///     match the current value and so no exchange occurred.
    public func compareAndExchange(expected: T, desired: T) -> Bool {
        return withExtendedLifetime(desired) {
            let expectedPtr = Unmanaged<T>.passUnretained(expected)
            let desiredPtr = Unmanaged<T>.passUnretained(desired)

            if self.storage.compareAndExchange(expected: UInt(bitPattern: expectedPtr.toOpaque()),
                                               desired: UInt(bitPattern: desiredPtr.toOpaque())) {
                _ = desiredPtr.retain()
                expectedPtr.release()
                return true
            } else {
                return false
            }
        }
    }

    /// Atomically exchanges `value` for the current value of this object.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Parameter value: The new value to set this object to.
    /// - Returns: The value previously held by this object.
    public func exchange(with value: T) -> T {
        let newPtr = Unmanaged<T>.passRetained(value)
        let oldPtrBits = self.storage.exchange(with: UInt(bitPattern: newPtr.toOpaque()))
        let oldPtr = Unmanaged<T>.fromOpaque(UnsafeRawPointer(bitPattern: oldPtrBits)!)
        return oldPtr.takeRetainedValue()
    }

    /// Atomically loads and returns the value of this object.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Returns: The value of this object
    public func load() -> T {
        let ptrBits = self.storage.load()
        let ptr = Unmanaged<T>.fromOpaque(UnsafeRawPointer(bitPattern: ptrBits)!)
        return ptr.takeUnretainedValue()
    }

    /// Atomically replaces the value of this object with `value`.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Parameter value: The new value to set the object to.
    public func store(_ value: T) -> Void {
        _ = self.exchange(with: value)
    }
}
