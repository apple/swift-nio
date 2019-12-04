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
    @usableFromInline
    typealias IntegerLiteralType = UInt16

    @usableFromInline var b12: UInt16
    @usableFromInline var b3: UInt8

    @inlinable
    init(_b12 b12: UInt16, b3: UInt8) {
        self.b12 = b12
        self.b3 = b3
    }

    @inlinable
    init(integerLiteral value: UInt16) {
        self.init(_b12: value, b3: 0)
    }

    static let bitWidth: Int = 24

    @inlinable
    static var max: _UInt24 {
        return .init(_b12: .max, b3: .max)
    }

    static let min: _UInt24 = .init(integerLiteral: 0)
}

extension UInt32 {
    @inlinable
    init(_ value: _UInt24) {
        var newValue: UInt32 = 0
        newValue  = UInt32(value.b12)
        newValue |= UInt32(value.b3) << 16
        self = newValue
    }
}

extension Int {
    @inlinable
    init(_ value: _UInt24) {
        var newValue: Int = 0
        newValue  = Int(value.b12)
        newValue |= Int(value.b3) << 16
        self = newValue
    }
}

extension _UInt24 {
    @inlinable
    init(_ value: UInt32) {
        assert(value & 0xff_00_00_00 == 0, "value \(value) too large for _UInt24")
        self.b12 = UInt16(truncatingIfNeeded: value & 0xff_ff)
        self.b3  =  UInt8(value >> 16)
    }
}

extension _UInt24: Equatable {
    @inlinable
    public static func ==(lhs: _UInt24, rhs: _UInt24) -> Bool {
        return lhs.b3 == rhs.b3 && lhs.b12 == rhs.b12
    }
}

extension _UInt24: CustomStringConvertible {
    @usableFromInline
    var description: String {
        return Int(self).description
    }
}

// MARK: _UInt56

/// A 56-bit unsigned integer value type.
struct _UInt56 {
    typealias IntegerLiteralType = UInt32

    @usableFromInline var b1234: UInt32
    @usableFromInline var b56: UInt16
    @usableFromInline var b7: UInt8

    @inlinable init(_b1234: UInt32, b56: UInt16, b7: UInt8) {
        self.b1234 = _b1234
        self.b56 = b56
        self.b7 = b7
    }

    @inlinable init(integerLiteral value: UInt32) {
        self.init(_b1234: value, b56: 0, b7: 0)
    }

    static let bitWidth: Int = 56

    static var max: _UInt56 {
        return .init(_b1234: .max, b56: .max, b7: .max)
    }

    static let min: _UInt56 = .init(integerLiteral: 0)
}

extension _UInt56 {
    init(_ value: UInt64) {
        assert(value & 0xff_00_00_00_00_00_00_00 == 0, "value \(value) too large for _UInt56")
        self.init(_b1234: UInt32(truncatingIfNeeded: (value &          0xff_ff_ff_ff) >> 0 ),
                  b56:    UInt16(truncatingIfNeeded: (value &    0xff_ff_00_00_00_00) >> 32),
                  b7:     UInt8(                     value                           >> 48))
    }

    init(_ value: Int) {
        self.init(UInt64(value))
    }
}

extension UInt64 {
    init(_ value: _UInt56) {
        var newValue: UInt64 = 0
        newValue  = UInt64(value.b1234)
        newValue |= UInt64(value.b56  ) << 32
        newValue |= UInt64(value.b7   ) << 48
        self = newValue
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
        return lhs.b1234 == rhs.b1234 && lhs.b56 == rhs.b56 && lhs.b7 == rhs.b7
    }
}

extension _UInt56: CustomStringConvertible {
    var description: String {
        return UInt64(self).description
    }
}
