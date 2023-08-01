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
    func hexDumpLong(offset: Int = 0, readableOnly: Bool = true) -> String {
        var result = ""
        let lastIndex = (readableOnly ? self.writerIndex : self.capacity)
        let length = lastIndex - offset

        // Grab the pointer to the whole buffer storage. We'll use offset and length when we index into it.
        let bytes = UnsafeRawBufferPointer(start: self._storage.bytes, count: Int(self.capacity))

        // hexdump -C dumps into lines of upto 16 bytes each
        // with a last line containing only the offset column.
        for line in 0 ... length/16 {
            // Line offset column
            result += "\(String(byte: line * 16, padding: 8))  "

            // The amount of bytes remaining in this dump
            let remainingBytes = length - line * 16

            // The amount of bytes in this dump line.
            let lineLength = min(16, remainingBytes)

            // The index range in the buffer storage for this line.
            let range = (offset + line*16)..<(offset + line*16 + lineLength)

            // Grab just the bytes for this particular line
            let lineBytes = bytes[range]

            // Make a hexdump of a single line of up to 16 bytes
            // Pad it with empty space if there were not enough bytes in the buffer dump range
            // And insert the separator space in the middle of the line
            var lineDump = bytes[range].map { String(byte: $0, padding: 2) }.joined(separator: " ")
            lineDump.append(String(repeating: " ", count: 49 - lineDump.count))
            lineDump.insert(" ", at: lineDump.index(lineDump.startIndex, offsetBy: 24))
            result += lineDump

            // ASCII column
            result += "|" + String(decoding: lineBytes, as: Unicode.UTF8.self).map {
                $0 >= " " && $0 < "~" ? $0 : "."
            } + "|\n"
        }

        // Add the last line with the last byte offset
        result += String(byte: length, padding: 8)
        return result
    }
}
