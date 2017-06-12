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
    private func toEndianess<T: EndianessInteger> (value: T, endianess: Endianess) -> T {
        switch endianess {
        case .little:
            return value.littleEndian
        case .big:
            return value.bigEndian
        }
    }

    public mutating func readInteger<T: EndianessInteger>(endianess: Endianess = .big) -> T? {
        guard self.readableBytes >= MemoryLayout<T>.size else {
            return nil
        }

        let value: T = self.integer(at: self.readerIndex, endianess: endianess)! /* must work as we have enough bytes */
        self.moveReaderIndex(forwardBy: MemoryLayout<T>.size)
        return value
    }

    public func integer<T: EndianessInteger>(at index: Int, endianess: Endianess = Endianess.big) -> T? {
        return self.withUnsafeBytes { ptr in
            if index + MemoryLayout<T>.size > ptr.count {
                return nil
            }
            return toEndianess(value: ptr.baseAddress!.advanced(by: index).bindMemory(to: T.self, capacity: 1).pointee,
                               endianess: endianess)
        }
    }

    @discardableResult
    public mutating func write<T: EndianessInteger>(integer: T, endianess: Endianess = .big) -> Int {
        let bytesWritten = self.set(integer: integer, at: self.writerIndex, endianess: endianess)
        self.moveWriterIndex(forwardBy: bytesWritten)
        return Int(bytesWritten)
    }

    @discardableResult
    public mutating func set<T: EndianessInteger>(integer: T, at index: Int, endianess: Endianess = .big) -> Int {
        var value = toEndianess(value: integer, endianess: endianess)
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

public enum Endianess {
    public static let host: Endianess = hostEndianess0()

    private static func hostEndianess0() -> Endianess {
        let number: UInt32 = 0x12345678
        let converted = number.bigEndian
        if number == converted {
            return .big
        } else {
            return .little
        }
    }

    case big
    case little
}


// Extensions to allow convert to different Endianess.

extension UInt8 : EndianessInteger {
    public var littleEndian: UInt8 {
        return self
    }

    public var bigEndian: UInt8 {
        return self
    }
}
extension UInt16 : EndianessInteger { }
extension UInt32 : EndianessInteger { }
extension UInt64 : EndianessInteger { }
extension Int8 : EndianessInteger {
    public var littleEndian: Int8 {
        return self
    }

    public var bigEndian: Int8 {
        return self
    }
}
extension Int16 : EndianessInteger { }
extension Int32 : EndianessInteger { }
extension Int64 : EndianessInteger { }

public protocol EndianessInteger: Numeric {

    /// Returns the big-endian representation of the integer, changing the
    /// byte order if necessary.
    var bigEndian: Self { get }

    /// Returns the little-endian representation of the integer, changing the
    /// byte order if necessary.
    var littleEndian: Self { get }
}
