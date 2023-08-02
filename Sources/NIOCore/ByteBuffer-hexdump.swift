//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension ByteBuffer {

    /// Describes a ByteBuffer hexDump format.
    /// Can be either xxd output compatible, or hexdump compatible.
    public struct HexDumpFormat {
        enum Value {
            case xxdCompatible(maxLength: Int? = nil)
            case hexDumpCompatible(maxLength: Int? = nil)
        }

        var value: Value
        init(_ value: Value) { self.value = value }

        /// A hex dump format compatible with `xxd` CLI utility.
        public static let xxdCompatible = Self(.xxdCompatible(maxLength: nil))

        /// A hex dump format compatible with `hexdump` command line utility.
        public static let hexDumpCompatible = Self(.hexDumpCompatible(maxLength: nil))

        /// A hex dump format compatible with `xxd`, clipped to `maxLength` bytes dumped.
        /// This format will dump first maxLength / 2 bytes, and the last maxLength / 2 bytes, replacing the rest with " ... ".
        public static func xxdCompatible(maxLength: Int) -> Self {
            Self(.xxdCompatible(maxLength: maxLength))
        }

        /// A hex dump format compatible with `hexdump` command line tool.
        /// This format will dump first maxLength / 2 bytes, and the last maxLength / 2 bytes, with a placeholder in between.
        public static func hexDumpCompatible(maxLength: Int) -> Self {
            Self(.hexDumpCompatible(maxLength: maxLength))
        }
    }

    /// Return a `String` of hexadecimal digits of bytes in the Buffer,
    /// in a format that's compatible with `xxd -r -p`.
    /// `hexDumpShort()` always dumps all readable bytes, i.e. from `readerIndex` to `writerIndex`,
    /// so you should set those indices to desired location to get the offset and length that you need to dump.
    func hexDumpShort() -> String {
        var hexString = ""
        hexString.reserveCapacity(self.readableBytes * 3)

        for byte in self.readableBytesView {
            hexString += String(byte: byte, padding: 2)
            hexString += " "
        }

        return String(hexString.dropLast())
    }

    /// Return a `String` of hexadecimal digits of bytes in the Buffer.,
    /// in a format that's compatible with `xxd -r -p`, but clips the output to the max length of `limit` bytes.
    /// If the dump contains more than the `limit` bytes, this function will return the first `limit/2`
    /// and the last `limit/2` of that, replacing the rest with `...`, i.e. `01 02 03 ... 09 11 12`.
    ///
    /// - parameters:
    ///     - limit: The maximum amount of bytes presented in the dump.
    func hexDumpShort(limit: Int) -> String {
        guard self.readableBytes > limit else {
            return self.hexDumpShort()
        }

        var buffer = self
        let front = buffer.readSlice(length: limit / 2)!
        buffer.moveReaderIndex(forwardBy: buffer.readableBytes - limit / 2)
        let back = buffer.readSlice(length: buffer.readableBytes)!

        let startHex = front.hexDumpShort()
        let endHex = back.hexDumpShort()
        return startHex + " ... " + endHex
    }

    // Dump hexdump -C compatible format without the last line containing the byte length of the buffer
    func _hexDumpLines(offset: Int) -> String {
        var result = ""
        var buffer = self
        // We're going to move the lineOffset index forward, so copy it into a variable
        var lineOffset = offset

        while buffer.readableBytes > 0 {
            let slice = buffer.readSlice(length: min(16, buffer.readableBytes))!
            let lineLength = slice.readableBytes

            // Left column of the hex dump signifies the offset from the beginning of the dumped buffer
            // and is separated from the next column with two spaces.
            result += String(byte: lineOffset, padding: 8)
            result += "  "

            // Center column consists of:
            // - xxd-compatible dump of the first 8 bytes
            // - space
            // - xxd-compatible dump of the rest 8 bytes
            // If there are not enough bytes to dump, the column is padded with space.
            let left = slice.getSlice(at: 0, length: min( 8, slice.readableBytes ))!
            let right = slice.getSlice(at: 8, length: min( 8, slice.readableBytes - 8)) ?? ByteBuffer()
            let leftHex = left.hexDumpShort()
            let rightHex = right.hexDumpShort()

            result += leftHex
            result += String(repeating: " ", count: 25 - leftHex.count)
            result += rightHex
            result += String(repeating: " ", count: 25 - rightHex.count)

            // Right column renders the 16 bytes line as ASCII characters, or "." if the character is not printable.
            let printableBytes = slice.readableBytesView.map {
                let printableRange = UInt8(ascii: " ") ..< UInt8(ascii: "~")
                return printableRange.contains($0) ? $0 : UInt8(ascii: ".")
            }
            result += "|\(String(decoding: printableBytes, as: UTF8.self))|\n"

            lineOffset += lineLength
        }
        return result
    }

    /// Returns a `String` of hexadecimal digits of bytes in the Buffer,
    /// with formatting compatible with output of `hexdump -C`.
    func hexDumpLong() -> String {
        var result = ""
        // Each hex dump line represents 16 bytes, and takes up to 79 characters including the \n in the end.
        // Plus the last line of the hex dump which is just 8 characters.
        result.reserveCapacity(self.readableBytes / 16 * 79 + 8)

        result += self._hexDumpLines(offset: 0)
        result += String(byte: self.readableBytes, padding: 8)
        return result
    }

    /// Returns a `String` of hexadecimal digits of bytes in this ByteBuffer
    /// with formatting sort of compatible with `hexdump -C`, but clipped on length.
    /// Dumps limit/2 first and limit/2 last bytes, with a separator line in between.
    ///
    /// - parameters:
    ///     - limit: Max bytes to dump.
    func hexDumpLong(limit: Int) -> String {
        guard readableBytes > limit else {
            return self.hexDumpLong()
        }

        let separator = "                                     ...                                      \n"
        var result = ""
        // TODO: .reserveCapacity on the result string.

        var buffer = self
        let front = buffer.readSlice(length: limit / 2)!
        buffer.moveReaderIndex(forwardBy: buffer.readableBytes - limit / 2)
        let back = buffer.readSlice(length: buffer.readableBytes)!

        result += front._hexDumpLines(offset: 0)
        result += separator
        result += back._hexDumpLines(offset: self.readableBytes - limit/2)
        result += String(byte: self.readableBytes, padding: 8)
        return result
    }

    /// hexDump this `ByteBuffer` in a preferred `HexDumpFormat`.
    /// hexDump will dump only the readable bytes, from `readerIndex` to `writerIndex`. You're responsible for setting those indices or slicing into the part that you want to be dumped.
    ///
    /// - parameters:
    ///     - format: ``HexDumpFormat`` to use for the dump.
    public func hexDump(format: HexDumpFormat) -> String {
        switch(format.value) {
        case .xxdCompatible(let maxLength):
            if let maxLength {
                return self.hexDumpShort(limit: maxLength)
            } else {
                return self.hexDumpShort()
            }

        case .hexDumpCompatible(let maxLength):
            if let maxLength {
                return self.hexDumpLong(limit: maxLength)
            } else {
                return self.hexDumpLong()
            }
        }
    }
}
