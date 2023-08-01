//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2023 Apple Inc. and the SwiftNIO project authors
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
        hexString.reserveCapacity(self.readableBytes*3)

        for byte in self.readableBytesView {
            hexString += "\(String(byte: byte, padding: 2)) "
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
            let startHex = self.getSlice(at: 0, length: limit/2)!.hexDumpShort()
            let endHex  = self.getSlice(at: self.readableBytes - limit/2, length: limit/2)!.hexDumpShort()
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
            result += "|" + String(decoding: slice.getBytes(at: 0, length: slice.readableBytes)!, as: Unicode.UTF8.self).map {
                $0 >= " " && $0 < "~" ? $0 : "."
            } + "|\n"

            lineOffset += lineLength
        }

        // Add the last line with the last byte offset
        result += String(byte: lineOffset, padding: 8)
        return result
    }

//    func hexDumpLong(limit: Int) -> String {
//        var result = ""
//
//        // Start with long-format dump of limit/2 bytes
//        // then insert an empty line with "..." in the middle
//        // Add a dump of the last limit/2 bytes
//        // The last line should be the final lineOffset
//
//        
//
//        return result
//    }

    /// Describes a ByteBuffer hexDump format. Can be either xxd output compatible, or hexdump compatible.
    /// You can provide a `maxLength` argument to both formats that will limit the maximum length of the buffer to dump before clipping the dump for readability.
    public enum HexDumpFormat {
        /// A hexdump format compatible with the xxd utility.
        /// - parameters:
        ///     - maxLength: The maximum amount of bytes to dump before clipping for readability.
        case xxdCompatible(maxLength: Int? = nil)

        /// A hexdump format compatible with hexdump utility.
        /// - parameters:
        ///     - maxLength: The maximum amount of bytes to dump before clipping for readability.
        case hexDumpCompatible(maxLength: Int? = nil)
    }


    public func hexDump(format: HexDumpFormat) -> String {
        switch(format) {
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
