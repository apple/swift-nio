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

// MARK: _UInt24

/// A 24-bit unsigned integer value type.
@usableFromInline
struct _UInt24 {
    @usableFromInline var _backing: (UInt16, UInt8)

    @inlinable
    init(_ value: UInt32) {
        assert(value & 0xff_00_00_00 == 0, "value \(value) too large for _UInt24")
        self._backing = IntegerBitPacking.unpackUInt16UInt8(value)
    }

    static let bitWidth: Int = 24

    @usableFromInline
    static let max: _UInt24 = .init((UInt32(1) << 24) - 1)

    @usableFromInline
    static let min: _UInt24 = .init(0)
}

extension UInt32 {
    @inlinable
    init(_ value: _UInt24) {
        self = IntegerBitPacking.packUInt16UInt8(value._backing.0, value._backing.1)
    }
}

extension Int {
    @inlinable
    init(_ value: _UInt24) {
        self = Int(UInt32(value))
    }
}


extension _UInt24: Equatable {
    @inlinable
    public static func ==(lhs: _UInt24, rhs: _UInt24) -> Bool {
        return lhs._backing == rhs._backing
    }
}

extension _UInt24: CustomStringConvertible {
    @usableFromInline
    var description: String {
        return UInt32(self).description
    }
}

// MARK: _UInt56

/// A 56-bit unsigned integer value type.
struct _UInt56 {
    @usableFromInline var _backing: (UInt32, UInt16, UInt8)

    @inlinable init(_ value: UInt64) {
        self._backing = IntegerBitPacking.unpackUInt32UInt16UInt8(value)
    }

    static let bitWidth: Int = 56

    private static let initializeUInt64 : UInt64 = (1 << 56) - 1
    static let max: _UInt56 = .init(initializeUInt64)
    static let min: _UInt56 = .init(0)
}

extension _UInt56 {
    init(_ value: Int) {
        self.init(UInt64(value))
    }
}

extension UInt64 {
    init(_ value: _UInt56) {
        self = IntegerBitPacking.packUInt32UInt16UInt8(value._backing.0,
                                                       value._backing.1,
                                                       value._backing.2)
    }
}

extension Int {
    init(_ value: _UInt56) {
        self = Int(UInt64(value))
    }
}

extension _UInt56: Equatable {
    @inlinable
    public static func ==(lhs: _UInt56, rhs: _UInt56) -> Bool {
        return lhs._backing == rhs._backing
    }
}

extension _UInt56: CustomStringConvertible {
    var description: String {
        return UInt64(self).description
    }
}
