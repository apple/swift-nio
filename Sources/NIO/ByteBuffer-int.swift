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

extension ByteBuffer {
    private func toEndianness<T: FixedWidthInteger> (value: T, endianness: Endianness) -> T {
        switch endianness {
        case .little:
            return value.littleEndian
        case .big:
            return value.bigEndian
        }
    }

    public mutating func readInteger<T: FixedWidthInteger>(endianness: Endianness = .big) -> T? {
        guard self.readableBytes >= MemoryLayout<T>.size else {
            return nil
        }

        let value: T = self.integer(at: self.readerIndex, endianness: endianness)! /* must work as we have enough bytes */
        self.moveReaderIndex(forwardBy: MemoryLayout<T>.size)
        return value
    }

    public func integer<T: FixedWidthInteger>(at index: Int, endianness: Endianness = Endianness.big) -> T? {
        precondition(index >= 0, "index must not be negative")
        return self.withVeryUnsafeBytes { ptr in
            guard index <= ptr.count - MemoryLayout<T>.size else {
                return nil
            }
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { valuePtr in
                valuePtr.copyBytes(from: UnsafeRawBufferPointer(start: ptr.baseAddress!.advanced(by: index),
                                                                count: MemoryLayout<T>.size))
            }
            return toEndianness(value: value, endianness: endianness)
        }
    }

    @discardableResult
    public mutating func write<T: FixedWidthInteger>(integer: T, endianness: Endianness = .big) -> Int {
        let bytesWritten = self.set(integer: integer, at: self.writerIndex, endianness: endianness)
        self.moveWriterIndex(forwardBy: bytesWritten)
        return Int(bytesWritten)
    }

    @discardableResult
    public mutating func set<T: FixedWidthInteger>(integer: T, at index: Int, endianness: Endianness = .big) -> Int {
        var value = toEndianness(value: integer, endianness: endianness)
        return Swift.withUnsafeBytes(of: &value) { ptr in
            self.set(bytes: ptr, at: index)
        }
    }
}

extension UInt64 {
    public func nextPowerOf2() -> UInt64 {
        guard self > 0 else {
            return 1
        }

        var n = self

        n -= 1
        n |= n >> 1
        n |= n >> 2
        n |= n >> 4
        n |= n >> 8
        n |= n >> 16
        n |= n >> 32
        n += 1

        return n
    }
}

extension UInt32 {
    public func nextPowerOf2() -> UInt32 {
        guard self > 0 else {
            return 1
        }

        var n = self

        n -= 1
        n |= n >> 1
        n |= n >> 2
        n |= n >> 4
        n |= n >> 8
        n |= n >> 16
        n += 1

        return n
    }
}

public enum Endianness {
    public static let host: Endianness = hostEndianness0()

    private static func hostEndianness0() -> Endianness {
        let number: UInt32 = 0x12345678
        return number == number.bigEndian ? .big : .little
    }

    case big
    case little
}


