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

/// The protocol that all types that can be made atomic must conform to.
///
/// **Do not add conformance to this protocol for arbitrary types**. Only a small range
/// of types have appropriate atomic operations supported by the CPU, and those types
/// already have conformances implemented.
public protocol FastAtomicPrimitive {
    associatedtype AtomicWrapper
    static var fast_atomic_create_with_existing_storage: (UnsafeMutablePointer<AtomicWrapper>, Self) -> Void { get }
    static var fast_atomic_compare_and_exchange: (UnsafeMutablePointer<AtomicWrapper>, Self, Self) -> Bool { get }
    static var fast_atomic_add: (UnsafeMutablePointer<AtomicWrapper>, Self) -> Self { get }
    static var fast_atomic_sub: (UnsafeMutablePointer<AtomicWrapper>, Self) -> Self { get }
    static var fast_atomic_exchange: (UnsafeMutablePointer<AtomicWrapper>, Self) -> Self { get }
    static var fast_atomic_load: (UnsafeMutablePointer<AtomicWrapper>) -> Self { get }
    static var fast_atomic_store: (UnsafeMutablePointer<AtomicWrapper>, Self) -> Void { get }
}

extension Bool: FastAtomicPrimitive {
    public typealias AtomicWrapper = catmc_fast_atomic__Bool
    public static let fast_atomic_create_with_existing_storage = catmc_fast_atomic__Bool_create_with_existing_storage
    public static let fast_atomic_compare_and_exchange         = catmc_fast_atomic__Bool_compare_and_exchange
    public static let fast_atomic_add                          = catmc_fast_atomic__Bool_add
    public static let fast_atomic_sub                          = catmc_fast_atomic__Bool_sub
    public static let fast_atomic_exchange                     = catmc_fast_atomic__Bool_exchange
    public static let fast_atomic_load                         = catmc_fast_atomic__Bool_load
    public static let fast_atomic_store                        = catmc_fast_atomic__Bool_store
}

extension Int8: FastAtomicPrimitive {
    public typealias AtomicWrapper = catmc_fast_atomic_int_least8_t
    public static let fast_atomic_create_with_existing_storage = catmc_fast_atomic_int_least8_t_create_with_existing_storage
    public static let fast_atomic_compare_and_exchange         = catmc_fast_atomic_int_least8_t_compare_and_exchange
    public static let fast_atomic_add                          = catmc_fast_atomic_int_least8_t_add
    public static let fast_atomic_sub                          = catmc_fast_atomic_int_least8_t_sub
    public static let fast_atomic_exchange                     = catmc_fast_atomic_int_least8_t_exchange
    public static let fast_atomic_load                         = catmc_fast_atomic_int_least8_t_load
    public static let fast_atomic_store                        = catmc_fast_atomic_int_least8_t_store
}

extension UInt8: FastAtomicPrimitive {
    public typealias AtomicWrapper = catmc_fast_atomic_uint_least8_t
    public static let fast_atomic_create_with_existing_storage = catmc_fast_atomic_uint_least8_t_create_with_existing_storage
    public static let fast_atomic_compare_and_exchange         = catmc_fast_atomic_uint_least8_t_compare_and_exchange
    public static let fast_atomic_add                          = catmc_fast_atomic_uint_least8_t_add
    public static let fast_atomic_sub                          = catmc_fast_atomic_uint_least8_t_sub
    public static let fast_atomic_exchange                     = catmc_fast_atomic_uint_least8_t_exchange
    public static let fast_atomic_load                         = catmc_fast_atomic_uint_least8_t_load
    public static let fast_atomic_store                        = catmc_fast_atomic_uint_least8_t_store
}

extension Int16: FastAtomicPrimitive {
    public typealias AtomicWrapper = catmc_fast_atomic_int_least16_t
    public static let fast_atomic_create_with_existing_storage = catmc_fast_atomic_int_least16_t_create_with_existing_storage
    public static let fast_atomic_compare_and_exchange         = catmc_fast_atomic_int_least16_t_compare_and_exchange
    public static let fast_atomic_add                          = catmc_fast_atomic_int_least16_t_add
    public static let fast_atomic_sub                          = catmc_fast_atomic_int_least16_t_sub
    public static let fast_atomic_exchange                     = catmc_fast_atomic_int_least16_t_exchange
    public static let fast_atomic_load                         = catmc_fast_atomic_int_least16_t_load
    public static let fast_atomic_store                        = catmc_fast_atomic_int_least16_t_store
}

extension UInt16: FastAtomicPrimitive {
    public typealias AtomicWrapper = catmc_fast_atomic_uint_least16_t
    public static let fast_atomic_create_with_existing_storage = catmc_fast_atomic_uint_least16_t_create_with_existing_storage
    public static let fast_atomic_compare_and_exchange         = catmc_fast_atomic_uint_least16_t_compare_and_exchange
    public static let fast_atomic_add                          = catmc_fast_atomic_uint_least16_t_add
    public static let fast_atomic_sub                          = catmc_fast_atomic_uint_least16_t_sub
    public static let fast_atomic_exchange                     = catmc_fast_atomic_uint_least16_t_exchange
    public static let fast_atomic_load                         = catmc_fast_atomic_uint_least16_t_load
    public static let fast_atomic_store                        = catmc_fast_atomic_uint_least16_t_store
}

extension Int32: FastAtomicPrimitive {
    public typealias AtomicWrapper = catmc_fast_atomic_int_least32_t
    public static let fast_atomic_create_with_existing_storage = catmc_fast_atomic_int_least32_t_create_with_existing_storage
    public static let fast_atomic_compare_and_exchange         = catmc_fast_atomic_int_least32_t_compare_and_exchange
    public static let fast_atomic_add                          = catmc_fast_atomic_int_least32_t_add
    public static let fast_atomic_sub                          = catmc_fast_atomic_int_least32_t_sub
    public static let fast_atomic_exchange                     = catmc_fast_atomic_int_least32_t_exchange
    public static let fast_atomic_load                         = catmc_fast_atomic_int_least32_t_load
    public static let fast_atomic_store                        = catmc_fast_atomic_int_least32_t_store
}

extension UInt32: FastAtomicPrimitive {
    public typealias AtomicWrapper = catmc_fast_atomic_uint_least32_t
    public static let fast_atomic_create_with_existing_storage = catmc_fast_atomic_uint_least32_t_create_with_existing_storage
    public static let fast_atomic_compare_and_exchange         = catmc_fast_atomic_uint_least32_t_compare_and_exchange
    public static let fast_atomic_add                          = catmc_fast_atomic_uint_least32_t_add
    public static let fast_atomic_sub                          = catmc_fast_atomic_uint_least32_t_sub
    public static let fast_atomic_exchange                     = catmc_fast_atomic_uint_least32_t_exchange
    public static let fast_atomic_load                         = catmc_fast_atomic_uint_least32_t_load
    public static let fast_atomic_store                        = catmc_fast_atomic_uint_least32_t_store
}

extension Int64: FastAtomicPrimitive {
    public typealias AtomicWrapper = catmc_fast_atomic_long_long
    public static let fast_atomic_create_with_existing_storage = catmc_fast_atomic_long_long_create_with_existing_storage
    public static let fast_atomic_compare_and_exchange         = catmc_fast_atomic_long_long_compare_and_exchange
    public static let fast_atomic_add                          = catmc_fast_atomic_long_long_add
    public static let fast_atomic_sub                          = catmc_fast_atomic_long_long_sub
    public static let fast_atomic_exchange                     = catmc_fast_atomic_long_long_exchange
    public static let fast_atomic_load                         = catmc_fast_atomic_long_long_load
    public static let fast_atomic_store                        = catmc_fast_atomic_long_long_store
}

extension UInt64: FastAtomicPrimitive {
    public typealias AtomicWrapper = catmc_fast_atomic_unsigned_long_long
    public static let fast_atomic_create_with_existing_storage = catmc_fast_atomic_unsigned_long_long_create_with_existing_storage
    public static let fast_atomic_compare_and_exchange         = catmc_fast_atomic_unsigned_long_long_compare_and_exchange
    public static let fast_atomic_add                          = catmc_fast_atomic_unsigned_long_long_add
    public static let fast_atomic_sub                          = catmc_fast_atomic_unsigned_long_long_sub
    public static let fast_atomic_exchange                     = catmc_fast_atomic_unsigned_long_long_exchange
    public static let fast_atomic_load                         = catmc_fast_atomic_unsigned_long_long_load
    public static let fast_atomic_store                        = catmc_fast_atomic_unsigned_long_long_store
}

extension Int: FastAtomicPrimitive {
    public typealias AtomicWrapper = catmc_fast_atomic_long
    public static let fast_atomic_create_with_existing_storage = catmc_fast_atomic_long_create_with_existing_storage
    public static let fast_atomic_compare_and_exchange         = catmc_fast_atomic_long_compare_and_exchange
    public static let fast_atomic_add                          = catmc_fast_atomic_long_add
    public static let fast_atomic_sub                          = catmc_fast_atomic_long_sub
    public static let fast_atomic_exchange                     = catmc_fast_atomic_long_exchange
    public static let fast_atomic_load                         = catmc_fast_atomic_long_load
    public static let fast_atomic_store                        = catmc_fast_atomic_long_store
}

extension UInt: FastAtomicPrimitive {
    public typealias AtomicWrapper = catmc_fast_atomic_unsigned_long
    public static let fast_atomic_create_with_existing_storage = catmc_fast_atomic_unsigned_long_create_with_existing_storage
    public static let fast_atomic_compare_and_exchange         = catmc_fast_atomic_unsigned_long_compare_and_exchange
    public static let fast_atomic_add                          = catmc_fast_atomic_unsigned_long_add
    public static let fast_atomic_sub                          = catmc_fast_atomic_unsigned_long_sub
    public static let fast_atomic_exchange                     = catmc_fast_atomic_unsigned_long_exchange
    public static let fast_atomic_load                         = catmc_fast_atomic_unsigned_long_load
    public static let fast_atomic_store                        = catmc_fast_atomic_unsigned_long_store
}

public class FastAtomic<T: FastAtomicPrimitive> {
    @usableFromInline
    typealias Manager = ManagedBufferPointer<Void, T.AtomicWrapper>

    /// Create an atomic object with `value`
    @inlinable
    static func makeAtomic(value: T) -> FastAtomic {
        let manager = Manager(bufferClass: self, minimumCapacity: 1) { _, _ in }
        manager.withUnsafeMutablePointerToElements {
            T.fast_atomic_create_with_existing_storage($0, value)
        }
        return manager.buffer as! FastAtomic<T>
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
        return Manager(unsafeBufferObject: self).withUnsafeMutablePointerToElements {
            return T.fast_atomic_compare_and_exchange($0, expected, desired)
        }
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
        return Manager(unsafeBufferObject: self).withUnsafeMutablePointerToElements {
            return T.fast_atomic_add($0, rhs)
        }
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
        return Manager(unsafeBufferObject: self).withUnsafeMutablePointerToElements {
            return T.fast_atomic_sub($0, rhs)
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
    @inlinable
    public func exchange(with value: T) -> T {
        return Manager(unsafeBufferObject: self).withUnsafeMutablePointerToElements {
            return T.fast_atomic_exchange($0, value)
        }
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
        return Manager(unsafeBufferObject: self).withUnsafeMutablePointerToElements {
            return T.fast_atomic_load($0)
        }
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
        return Manager(unsafeBufferObject: self).withUnsafeMutablePointerToElements {
            return T.fast_atomic_store($0, value)
        }
    }

    deinit {
        Manager(unsafeBufferObject: self).withUnsafeMutablePointers { headerPtr, elementsPtr in
            elementsPtr.deinitialize(count: 1)
            headerPtr.deinitialize(count: 1)
        }
    }
}
