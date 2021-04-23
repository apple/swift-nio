//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@usableFromInline
enum _IntegerBitPacking {}

extension _IntegerBitPacking {
    @inlinable
    static func packUU<Left: FixedWidthInteger & UnsignedInteger,
                       Right: FixedWidthInteger & UnsignedInteger,
                       Result: FixedWidthInteger & UnsignedInteger>(_ left: Left,
                                                                    _ right: Right,
                                                                    type: Result.Type = Result.self) -> Result {
        assert(MemoryLayout<Left>.size + MemoryLayout<Right>.size <= MemoryLayout<Result>.size)

        let resultLeft = Result(left)
        let resultRight = Result(right)
        let result = (resultLeft << Right.bitWidth) | resultRight
        assert(result.nonzeroBitCount == left.nonzeroBitCount + right.nonzeroBitCount)
        return result
    }

    @inlinable
    static func unpackUU<Input: FixedWidthInteger & UnsignedInteger,
                         Left: FixedWidthInteger & UnsignedInteger,
                         Right: FixedWidthInteger & UnsignedInteger>(_ input: Input,
                                                                     leftType: Left.Type = Left.self,
                                                                     rightType: Right.Type = Right.self) -> (Left, Right) {
        assert(MemoryLayout<Left>.size + MemoryLayout<Right>.size <= MemoryLayout<Input>.size)

        let leftMask = Input(Left.max)
        let rightMask = Input(Right.max)
        let right = input & rightMask
        let left = (input >> Right.bitWidth) & leftMask

        assert(input.nonzeroBitCount == left.nonzeroBitCount + right.nonzeroBitCount)
        return (Left(left), Right(right))
    }
}

@usableFromInline
enum IntegerBitPacking {}

extension IntegerBitPacking {
    @inlinable
    static func packUInt32UInt16UInt8(_ left: UInt32, _ middle: UInt16, _ right: UInt8) -> UInt64 {
        return _IntegerBitPacking.packUU(
            _IntegerBitPacking.packUU(right, middle, type: UInt32.self),
            left
        )
    }

    @inlinable
    static func unpackUInt32UInt16UInt8(_ value: UInt64) -> (UInt32, UInt16, UInt8) {
        let leftRight = _IntegerBitPacking.unpackUU(value, leftType: UInt32.self, rightType: UInt32.self)
        let left = _IntegerBitPacking.unpackUU(leftRight.0, leftType: UInt8.self, rightType: UInt16.self)
        return (leftRight.1, left.1, left.0)
    }

    @inlinable
    static func packUInt8UInt8(_ left: UInt8, _ right: UInt8) -> UInt16 {
        return _IntegerBitPacking.packUU(left, right)
    }

    @inlinable
    static func unpackUInt8UInt8(_ value: UInt16) -> (UInt8, UInt8) {
        return _IntegerBitPacking.unpackUU(value)
    }

    @inlinable
    static func packUInt16UInt8(_ left: UInt16, _ right: UInt8) -> UInt32 {
        return _IntegerBitPacking.packUU(left, right)
    }

    @inlinable
    static func unpackUInt16UInt8(_ value: UInt32) -> (UInt16, UInt8) {
        return _IntegerBitPacking.unpackUU(value)
    }

    @inlinable
    static func packUInt32CInt(_ left: UInt32, _ right: CInt) -> UInt64 {
        return _IntegerBitPacking.packUU(left, UInt32(truncatingIfNeeded: right))
    }

    @inlinable
    static func unpackUInt32CInt(_ value: UInt64) -> (UInt32, CInt) {
        let unpacked = _IntegerBitPacking.unpackUU(value, leftType: UInt32.self, rightType: UInt32.self)
        return (unpacked.0, CInt(truncatingIfNeeded: unpacked.1))
    }
}
