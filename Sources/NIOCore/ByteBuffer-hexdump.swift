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
    ///
    /// - parameters:
    ///     - offset:  The offset from the beginning of the buffer, in bytes. Defaults to 0.
    ///     - readableOnly: Whether to only dump the `readableBytes` part (before the `writerIndex`), or to dump the full buffer, including empty bytes in the end of the allocated space. Defaults to true.
    func hexDumpShort(offset: Int = 0, readableOnly: Bool = true) -> String {
        let length = (readableOnly ? self.writerIndex : self.capacity) - offset
        return self._storage.dumpBytes(slice: self._storage.fullSlice,
                                       offset: offset,
                                       length: length)
    }

    /// Return a `String` of hexadecimal digits of bytes in the Buffer.,
    /// in a format that's compatible with `xxd -r -p`, but clips the output to the max length of `limit` bytes.
    /// If the dump contains more than the `limit` bytes, this function will return the first `limit/2`
    /// and the last `limit/2` of that, replacing the rest with `...`, i.e. `01 02 03 ... 09 11 12`.
    ///
    /// - parameters:
    ///     - offset:  The offset from the beginning of the buffer, in bytes. Defaults to 0.
    ///     - readableOnly: Whether to only dump the `readableBytes` part (before the `writerIndex`), or to dump the full buffer,
    ///         including empty bytes in the end of the allocated space. Defaults to true.
    ///     - limit: The maximum amount of bytes presented in the dump.
    func hexDumpShort(offset: Int = 0, readableOnly: Bool = true, limit: Int) -> String {
        let lastIndex = readableOnly ? self.writerIndex : self.capacity
        let length = lastIndex - offset

        // If the length of the resulting hex dump is smaller than the maximum allowed dump length,
        // return the full dump. Otherwise, dump the first and last pieces of the buffer, then concatenate them.
        if length <= limit {
            return self.hexDumpShort(offset: offset, readableOnly: readableOnly)
        } else {
            let clipLength = limit / 2
            let startHex = self._storage.dumpBytes(slice: self._storage.fullSlice,
                                                   offset: offset,
                                                   length: offset + clipLength)

            let endHex = self._storage.dumpBytes(slice: self._storage.fullSlice,
                                                 offset: lastIndex - clipLength,
                                                 length: clipLength)

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
