//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(Windows)
import ucrt
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Bionic)
import Bionic
#else
#error("The Byte Buffer module was unable to identify your C library.")
#endif

extension ByteBuffer {
    /// Read a QUIC variable-length integer, moving the `readerIndex` appropriately
    /// If there are not enough bytes, nil is returned
    ///
    /// [RFC 9000 § 16](https://www.rfc-editor.org/rfc/rfc9000.html#section-16)
    public mutating func readQUICVariableLengthInteger() -> Int? {
        guard let firstByte = self.getInteger(at: self.readerIndex, as: UInt8.self) else {
            return nil
        }

        // Look at the first two bits to work out the length, then read that, mask off the top two bits, and
        // extend to integer.
        switch firstByte & 0xC0 {
        case 0x00:
            // Easy case.
            self.moveReaderIndex(forwardBy: 1)
            return Int(firstByte & ~0xC0)
        case 0x40:
            // Length is two bytes long, read the next one.
            return self.readInteger(as: UInt16.self).map { Int($0 & ~(0xC0 << 8)) }
        case 0x80:
            // Length is 4 bytes long.
            return self.readInteger(as: UInt32.self).map { Int($0 & ~(0xC0 << 24)) }
        case 0xC0:
            // Length is 8 bytes long.
            return self.readInteger(as: UInt64.self).map { Int($0 & ~(0xC0 << 56)) }
        default:
            fatalError("Unreachable")
        }
    }

    /// Write a QUIC variable-length integer.
    ///
    /// [RFC 9000 § 16](https://www.rfc-editor.org/rfc/rfc9000.html#section-16)
    ///
    /// - Returns: The number of bytes written
    @discardableResult
    public mutating func writeQUICVariableLengthInteger<Integer: FixedWidthInteger>(_ value: Integer) -> Int {
        switch value {
        case 0..<63:
            // Easy, store the value. The top two bits are 0 so we don't need to do any masking.
            return self.writeInteger(UInt8(truncatingIfNeeded: value))
        case 0..<16383:
            // Set the top two bit mask, then write the value.
            let value = UInt16(truncatingIfNeeded: value) | (0x40 << 8)
            return self.writeInteger(value)
        case 0..<1_073_741_823:
            // Set the top two bit mask, then write the value.
            let value = UInt32(truncatingIfNeeded: value) | (0x80 << 24)
            return self.writeInteger(value)
        case 0..<4_611_686_018_427_387_903:
            // Set the top two bit mask, then write the value.
            let value = UInt64(truncatingIfNeeded: value) | (0xC0 << 56)
            return self.writeInteger(value)
        default:
            fatalError("Could not write QUIC variable-length integer: outside of valid range")
        }
    }

    /// Prefixes a message written by `writeMessage` with the number of bytes written as a QUIC variable-length integer
    /// - Parameters:
    ///     - writeMessage: A closure that takes a buffer, writes a message to it and returns the number of bytes written
    /// - Returns: Number of total bytes written
    /// - Note: Because the length of the message is not known upfront, 4 bytes will be used for encoding the length even if that may not be necessary. If you know the length of your message, prefer ``writeQUICLengthPrefixedBuffer(_:)`` instead
    @discardableResult
    @inlinable
    public mutating func writeQUICLengthPrefixed(
        writeMessage: (inout ByteBuffer) throws -> Int
    ) rethrows -> Int {
        var totalBytesWritten = 0

        let lengthPrefixIndex = self.writerIndex
        // Write 4 bytes as a placeholder
        // This is enough for upto 1gb of data
        // It is very unlikely someone is trying to write more than that, if they are then we will catch it later and do a memmove
        // Reserving 8 bytes now would require either wasting bytes for the majority of use cases, or doing a memmove for a majority of usecases
        // This way the majority only waste 0-3 bytes, and never incur a memmove, and the minority get a memmove
        totalBytesWritten += self.writeBytes([0, 0, 0, 0])

        let startWriterIndex = self.writerIndex
        let messageLength = try writeMessage(&self)
        let endWriterIndex = self.writerIndex

        totalBytesWritten += messageLength

        let actualBytesWritten = endWriterIndex - startWriterIndex
        precondition(
            actualBytesWritten == messageLength,
            "writeMessage returned \(messageLength) bytes, but actually \(actualBytesWritten) bytes were written, but they should be the same"
        )

        if messageLength >= 1_073_741_823 {
            // This message length cannot fit in the 4 bytes which we reserved. We need to make more space before the message
            self._createSpace(before: startWriterIndex, length: messageLength, requiredSpace: 4)
            totalBytesWritten += 4  // the 4 bytes we just reserved
            // We now have 8 bytes to use for the length
            let value = UInt64(truncatingIfNeeded: messageLength) | (0xC0 << 56)
            self.setInteger(value, at: lengthPrefixIndex)
        } else {
            // We must encode the length in a way that uses 4 bytes, even if not necessary, because we can't have leftover 0's after the length, before the data
            // The only way to use fewer bytes would be to do a memmove or similar
            // That is unlikely to be worthwhile to save, at most, 3 bytes
            // Set the top two bit mask, then write the value.
            let value = UInt32(truncatingIfNeeded: messageLength) | (0x80 << 24)
            self.setInteger(value, at: lengthPrefixIndex)
        }

        return totalBytesWritten
    }
}

// MARK: - Helpers for writing QUIC variable-length prefixed things

extension ByteBuffer {
    /// Write a QUIC variable-length integer prefixed buffer.
    ///
    /// [RFC 9000 § 16](https://www.rfc-editor.org/rfc/rfc9000.html#section-16)
    ///
    /// Write `buffer` prefixed with the length of buffer as a QUIC variable-length integer
    /// - Parameter buffer: The buffer to be written
    /// - Returns: The total bytes written. This is the bytes needed to write the length, plus the length of the buffer itself
    @discardableResult
    public mutating func writeQUICLengthPrefixedBuffer(_ buffer: ByteBuffer) -> Int {
        var written = 0
        written += self.writeQUICVariableLengthInteger(buffer.readableBytes)
        written += self.writeImmutableBuffer(buffer)
        return written
    }

    /// Write a QUIC variable-length integer prefixed string.
    ///
    /// [RFC 9000 § 16](https://www.rfc-editor.org/rfc/rfc9000.html#section-16)
    ///
    /// Write `string` prefixed with the length of string as a QUIC variable-length integer
    /// - Parameter string: The string to be written
    /// - Returns: The total bytes written. This is the bytes needed to write the length, plus the length of the string itself
    @discardableResult
    public mutating func writeQUICLengthPrefixedString(_ string: String) -> Int {
        var written = 0
        // writeString always writes the String as UTF8 bytes, without a null-terminator
        // So the length will be the utf8 count
        written += self.writeQUICVariableLengthInteger(string.utf8.count)
        written += self.writeString(string)
        return written
    }

    /// Write a QUIC variable-length integer prefixed collection of bytes.
    ///
    /// [RFC 9000 § 16](https://www.rfc-editor.org/rfc/rfc9000.html#section-16)
    ///
    /// Write `bytes` prefixed with the number of bytes as a QUIC variable-length integer
    /// - Parameter bytes: The bytes to be written
    /// - Returns: The total bytes written. This is the bytes needed to write the length, plus the length of the string itself
    @inlinable
    public mutating func writeQUICLengthPrefixedBytes<Bytes: Sequence>(_ bytes: Bytes) -> Int
    where Bytes.Element == UInt8 {
        let numberOfBytes = bytes.withContiguousStorageIfAvailable { b in
            UnsafeRawBufferPointer(b).count
        }
        if let numberOfBytes {
            var written = 0
            written += self.writeQUICVariableLengthInteger(numberOfBytes)
            written += self.writeBytes(bytes)
            return written
        } else {
            return self.writeQUICLengthPrefixed { buffer in
                buffer.writeBytes(bytes)
            }
        }
    }
}

extension ByteBuffer {
    /// Creates `requiredSpace` bytes of free space before `index` by moving the `length` bytes after `index` forward by `requiredSpace`
    /// e.g. given [a, b, c, d, e, f, g, h, i, j] and calling this function with (before: 4, length: 6, requiredSpace: 2) would result in
    /// [a, b, c, d, 0, 0, e, f, g, h, i, j]
    /// 2 extra bytes of space were created before index 4 (the letter e)
    /// The total bytes written will be equal to `requiredSpace`, and the writer index will be moved accordingly
    @usableFromInline
    mutating func _createSpace(before index: Int, length: Int, requiredSpace: Int) {
        // Add the required number of bytes to the end first
        self.writeBytes([UInt8](repeatElement(0, count: requiredSpace)))
        // Move the message forward by that many bytes, to make space at the front
        self.withUnsafeMutableReadableBytes { pointer in
            _ = memmove(
                // The new position is 4 forward from where the user written message currently begins
                pointer.baseAddress!.advanced(by: index + requiredSpace),
                // This is the position where the user written message currently begins
                pointer.baseAddress!.advanced(by: index),
                length
            )
        }
    }
}
