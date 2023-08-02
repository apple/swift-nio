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
        // If the length of the resulting hex dump is smaller than the maximum allowed dump length,
        // return the full dump. Otherwise, dump the first and last pieces of the buffer, then concatenate them.
        if readableBytes <= limit {
            return self.hexDumpShort()
        } else {
            var buffer = self
            let front = buffer.readSlice(length: limit / 2)!
            buffer.moveReaderIndex(forwardBy: buffer.readableBytes - limit / 2)
            let back = buffer.readSlice(length: buffer.readableBytes)!

            let startHex = front.hexDumpShort()
            let endHex = back.hexDumpShort()
            return startHex + " ... " + endHex
        }
    }

    /// Returns a `String` of hexadecimal digits of bytes in the Buffer,
    /// with formatting compatible with output of `hexdump -C`.
    func hexDumpLong() -> String {
        var result = ""

        var buffer = self
        var lineOffset = 0

        while buffer.readableBytes > 0 {
            let slice = buffer.readSlice(length: min(16, buffer.readableBytes))!
            let lineLength = slice.readableBytes

            result += "\(String(byte: lineOffset, padding: 8))  "

            // Start with a xxd-format hexdump that we already have, then pad it
            // and insert a space in the middle.
            var lineHex = slice.hexDumpShort()
            lineHex.append(String(repeating: " ", count: 49 - lineHex.count))
            lineHex.insert(" ", at: lineHex.index(lineHex.startIndex, offsetBy: 24))
            result += lineHex

            // ASCII column renders the line as ASCII characters, or "." if the character is not printable.
            let printableBytes = slice.readableBytesView.map {
                let printableRange = UInt8(ascii: " ") ..< UInt8(ascii: "~")
                return printableRange.contains($0) ? $0 : UInt8(ascii: ".")
            }
            result += "|\(String(decoding: printableBytes, as: UTF8.self))|\n"

            lineOffset += lineLength
        }

        // Add the last line with the last byte offset
        result += String(byte: lineOffset, padding: 8)
        return result
    }

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
                return self.hexDumpLong()
            } else {
                return self.hexDumpLong()
            }
        }
    }

}
