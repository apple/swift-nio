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

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
fileprivate func sys_sched_yield() {
    pthread_yield_np()
}
#elseif os(Windows)
import ucrt
import WinSDK
fileprivate func sys_sched_yield() {
  Sleep(0)
}
#else
import Glibc
fileprivate func sys_sched_yield() {
    _ = sched_yield()
}
#endif

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
    @usableFromInline
    internal let value: OpaquePointer

    /// Create an atomic object with `value`.
    @inlinable
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
    @inlinable
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
    @inlinable
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
    @inlinable
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
    @inlinable
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
    @inlinable
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
    @inlinable
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
@available(*, deprecated, message:"please use NIOAtomic instead")
public final class Atomic<T: AtomicPrimitive> {
    @usableFromInline
    internal let embedded: UnsafeEmbeddedAtomic<T>

    /// Create an atomic object with `value`.
    @inlinable
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
    @inlinable
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
    @inlinable
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
    @inlinable
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
    @inlinable
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
    @inlinable
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
    @inlinable
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

#if os(Windows)
extension Int: AtomicPrimitive {
    public static let atomic_create               = catmc_atomic_intptr_t_create
    public static let atomic_destroy              = catmc_atomic_intptr_t_destroy
    public static let atomic_compare_and_exchange = catmc_atomic_intptr_t_compare_and_exchange
    public static let atomic_add                  = catmc_atomic_intptr_t_add
    public static let atomic_sub                  = catmc_atomic_intptr_t_sub
    public static let atomic_exchange             = catmc_atomic_intptr_t_exchange
    public static let atomic_load                 = catmc_atomic_intptr_t_load
    public static let atomic_store                = catmc_atomic_intptr_t_store
}

extension UInt: AtomicPrimitive {
    public static let atomic_create               = catmc_atomic_uintptr_t_create
    public static let atomic_destroy              = catmc_atomic_uintptr_t_destroy
    public static let atomic_compare_and_exchange = catmc_atomic_uintptr_t_compare_and_exchange
    public static let atomic_add                  = catmc_atomic_uintptr_t_add
    public static let atomic_sub                  = catmc_atomic_uintptr_t_sub
    public static let atomic_exchange             = catmc_atomic_uintptr_t_exchange
    public static let atomic_load                 = catmc_atomic_uintptr_t_load
    public static let atomic_store                = catmc_atomic_uintptr_t_store
}
#else
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
#endif

/// `AtomicBox` is a heap-allocated box which allows lock-free access to an instance of a Swift class.
///
/// - warning: The use of `AtomicBox` should be avoided because it requires an implementation of a spin-lock
///            (more precisely a CAS loop) to operate correctly.
@available(*, deprecated, message: "AtomicBox is deprecated without replacement because the original implementation doesn't work.")
public final class AtomicBox<T: AnyObject> {
    private let storage: NIOAtomic<UInt>

    public init(value: T) {
        let ptr = Unmanaged<T>.passRetained(value)
        self.storage = NIOAtomic.makeAtomic(value: UInt(bitPattern: ptr.toOpaque()))
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
    ///
    /// - warning: The implementation of `exchange` contains a _Compare and Exchange loop_, ie. it may busy wait with
    ///            100% CPU load.
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
            let expectedPtrBits = UInt(bitPattern: expectedPtr.toOpaque())
            let desiredPtrBits = UInt(bitPattern: desiredPtr.toOpaque())

            while true {
                if self.storage.compareAndExchange(expected: expectedPtrBits, desired: desiredPtrBits) {
                    if desiredPtrBits != expectedPtrBits {
                        _ = desiredPtr.retain()
                        expectedPtr.release()
                    }
                    return true
                } else {
                    let currentPtrBits = self.storage.load()
                    if currentPtrBits == 0 || currentPtrBits == expectedPtrBits {
                        sys_sched_yield()
                        continue
                    } else {
                        return false
                    }
                }
            }
        }
    }

    /// Atomically exchanges `value` for the current value of this object.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - warning: The implementation of `exchange` contains a _Compare and Exchange loop_, ie. it may busy wait with
    ///            100% CPU load.
    ///
    /// - Parameter value: The new value to set this object to.
    /// - Returns: The value previously held by this object.
    public func exchange(with value: T) -> T {
        let newPtr = Unmanaged<T>.passRetained(value)
        let newPtrBits = UInt(bitPattern: newPtr.toOpaque())

        // step 1: We need to actually CAS loop here to swap out a non-0 value with the new one.
        var oldPtrBits: UInt = 0
        while true {
            let speculativeVal = self.storage.load()
            guard speculativeVal != 0 else {
                sys_sched_yield()
                continue
            }
            if self.storage.compareAndExchange(expected: speculativeVal, desired: newPtrBits) {
                oldPtrBits = speculativeVal
                break
            }
        }

        // step 2: After having gained 'ownership' of the old value, we can release the Unmanged.
        let oldPtr = Unmanaged<T>.fromOpaque(UnsafeRawPointer(bitPattern: oldPtrBits)!)
        return oldPtr.takeRetainedValue()
    }

    /// Atomically loads and returns the value of this object.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - warning: The implementation of `exchange` contains a _Compare and Exchange loop_, ie. it may busy wait with
    ///            100% CPU load.
    ///
    /// - Returns: The value of this object
    public func load() -> T {
        // step 1: We need to gain ownership of the value by successfully swapping 0 (marker value) in.
        var ptrBits: UInt = 0
        while true {
            let speculativeVal = self.storage.load()
            guard speculativeVal != 0 else {
                sys_sched_yield()
                continue
            }
            if self.storage.compareAndExchange(expected: speculativeVal, desired: 0) {
                ptrBits = speculativeVal
                break
            }
        }

        // step 2: We now consumed a +1'd version of val, so we have all the time in the world to retain it.
        let ptr = Unmanaged<T>.fromOpaque(UnsafeRawPointer(bitPattern: ptrBits)!)
        let value = ptr.takeUnretainedValue()

        // step 3: Now, let's exchange it back into the store
        let casWorked = self.storage.compareAndExchange(expected: 0, desired: ptrBits)
        precondition(casWorked) // this _has_ to work because `0` means we own it exclusively.
        return value
    }

    /// Atomically replaces the value of this object with `value`.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - warning: The implementation of `exchange` contains a _Compare and Exchange loop_, ie. it may busy wait with
    ///            100% CPU load.
    ///
    /// - Parameter value: The new value to set the object to.
    public func store(_ value: T) -> Void {
        _ = self.exchange(with: value)
    }
}
