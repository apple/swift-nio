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

public final class Atomic<T: AtomicPrimitive> {
    private let value: OpaquePointer

    public init(value: T) {
        self.value = T.atomic_create(value)
    }

    public func compareAndExchange(expected: T, desired: T) -> Bool {
        return T.atomic_compare_and_exchange(self.value, expected, desired)
    }

    public func add(_ rhs: T) -> T {
        return T.atomic_add(self.value, rhs)
    }

    public func sub(_ rhs: T) -> T {
        return T.atomic_sub(self.value, rhs)
    }

    public func exchange(with value: T) -> T {
        return T.atomic_exchange(self.value, value)
    }

    public func load() -> T {
        return T.atomic_load(self.value)
    }

    public func store(_ value: T) -> Void {
        T.atomic_store(self.value, value)
    }

    deinit {
        T.atomic_destroy(self.value)
    }
}

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
