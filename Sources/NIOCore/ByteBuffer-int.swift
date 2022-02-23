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
    @inlinable
    func _toEndianness<T: FixedWidthInteger> (value: T, endianness: Endianness) -> T {
        switch endianness {
        case .little:
            return value.littleEndian
        case .big:
            return value.bigEndian
        }
    }

    /// Read an integer off this `ByteBuffer`, move the reader index forward by the integer's byte size and return the result.
    ///
    /// - parameters:
    ///     - endianness: The endianness of the integer in this `ByteBuffer` (defaults to big endian).
    ///     - as: the desired `FixedWidthInteger` type (optional parameter)
    /// - returns: An integer value deserialized from this `ByteBuffer` or `nil` if there aren't enough bytes readable.
    @inlinable
    public mutating func readInteger<T: FixedWidthInteger>(endianness: Endianness = .big, as: T.Type = T.self) -> T? {
        guard let result = self.getInteger(at: self.readerIndex, endianness: endianness, as: T.self) else {
            return nil
        }
        self._moveReaderIndex(forwardBy: MemoryLayout<T>.size)
        return result
    }

    /// Get the integer at `index` from this `ByteBuffer`. Does not move the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - parameters:
    ///     - index: The starting index of the bytes for the integer into the `ByteBuffer`.
    ///     - endianness: The endianness of the integer in this `ByteBuffer` (defaults to big endian).
    ///     - as: the desired `FixedWidthInteger` type (optional parameter)
    /// - returns: An integer value deserialized from this `ByteBuffer` or `nil` if the bytes of interest are not
    ///            readable.
    @inlinable
    public func getInteger<T: FixedWidthInteger>(at index: Int, endianness: Endianness = Endianness.big, as: T.Type = T.self) -> T? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: MemoryLayout<T>.size) else {
            return nil
        }

        if T.self == UInt8.self {
            assert(range.count == 1)
            return self.withUnsafeReadableBytes { ptr in
                ptr[range.startIndex] as! T
            }
        }

        return self.withUnsafeReadableBytes { ptr in
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { valuePtr in
                valuePtr.copyMemory(from: UnsafeRawBufferPointer(fastRebase: ptr[range]))
            }
            return _toEndianness(value: value, endianness: endianness)
        }
    }

    /// Write `integer` into this `ByteBuffer`, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - integer: The integer to serialize.
    ///     - endianness: The endianness to use, defaults to big endian.
    /// - returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func writeInteger<T: FixedWidthInteger>(_ integer: T,
                                                            endianness: Endianness = .big,
                                                            as: T.Type = T.self) -> Int {
        let bytesWritten = self.setInteger(integer, at: self.writerIndex, endianness: endianness)
        self._moveWriterIndex(forwardBy: bytesWritten)
        return Int(bytesWritten)
    }

    /// Write `integer` into this `ByteBuffer` starting at `index`. This does not alter the writer index.
    ///
    /// - parameters:
    ///     - integer: The integer to serialize.
    ///     - index: The index of the first byte to write.
    ///     - endianness: The endianness to use, defaults to big endian.
    /// - returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func setInteger<T: FixedWidthInteger>(_ integer: T, at index: Int, endianness: Endianness = .big, as: T.Type = T.self) -> Int {
        var value = _toEndianness(value: integer, endianness: endianness)
        return Swift.withUnsafeBytes(of: &value) { ptr in
            self.setBytes(ptr, at: index)
        }
    }
}

extension FixedWidthInteger {
    /// Returns the next power of two.
    @inlinable
    func nextPowerOf2() -> Self {
        guard self != 0 else {
            return 1
        }
        return 1 << (Self.bitWidth - (self - 1).leadingZeroBitCount)
    }

    /// Returns the previous power of 2, or self if it already is.
    @inlinable
    func previousPowerOf2() -> Self {
        guard self != 0 else {
            return 0
        }

        return 1 << ((Self.bitWidth - 1) - self.leadingZeroBitCount)
    }
}

extension UInt32 {
    /// Returns the next power of two unless that would overflow, in which case UInt32.max (on 64-bit systems) or
    /// Int32.max (on 32-bit systems) is returned. The returned value is always safe to be cast to Int and passed
    /// to malloc on all platforms.
    @inlinable
    func nextPowerOf2ClampedToMax() -> UInt32 {
        guard self > 0 else {
            return 1
        }

        var n = self

        #if arch(arm) || arch(i386)
        // on 32-bit platforms we can't make use of a whole UInt32.max (as it doesn't fit in an Int)
        let max = UInt32(Int.max)
        #else
        // on 64-bit platforms we're good
        let max = UInt32.max
        #endif

        n -= 1
        n |= n >> 1
        n |= n >> 2
        n |= n >> 4
        n |= n >> 8
        n |= n >> 16
        if n != max {
            n += 1
        }

        return n
    }
}

/// Endianness refers to the sequential order in which bytes are arranged into larger numerical values when stored in
/// memory or when transmitted over digital links.
public enum Endianness {
    /// The endianness of the machine running this program.
    public static let host: Endianness = hostEndianness0()

    private static func hostEndianness0() -> Endianness {
        let number: UInt32 = 0x12345678
        return number == number.bigEndian ? .big : .little
    }

    /// big endian, the most significant byte (MSB) is at the lowest address
    case big

    /// little endian, the least significant byte (LSB) is at the lowest address
    case little
}


