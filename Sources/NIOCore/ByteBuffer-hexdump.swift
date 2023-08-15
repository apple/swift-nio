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
    public struct HexDumpFormat: Hashable, Sendable {

        enum Value: Hashable {
            case plain(maxBytes: Int? = nil)
            case detailed(maxBytes: Int? = nil)
        }

        let value: Value
        init(_ value: Value) { self.value = value }

        /// A plain hex dump format compatible with `xxd` CLI utility.
        public static let plain = Self(.plain(maxBytes: nil))

        /// A hex dump format compatible with `hexdump` command line utility.
        public static let detailed = Self(.detailed(maxBytes: nil))

        /// A detailed hex dump format compatible with `xxd`, clipped to `maxBytes` bytes dumped.
        /// This format will dump first `maxBytes / 2` bytes, and the last `maxBytes / 2` bytes, replacing the rest with " ... ".
        public static func plain(maxBytes: Int) -> Self {
            Self(.plain(maxBytes: maxBytes))
        }

        /// A hex dump format compatible with `hexdump` command line tool.
        /// This format will dump first `maxBytes / 2` bytes, and the last `maxBytes / 2` bytes, with a placeholder in between.
        public static func detailed(maxBytes: Int) -> Self {
            Self(.detailed(maxBytes: maxBytes))
        }
    }

    /// Return a `String` of space separated hexadecimal digits of the readable bytes in the buffer,
    /// in a format that's compatible with `xxd -r -p`.
    /// `hexDumpPlain()` always dumps all readable bytes, i.e. from `readerIndex` to `writerIndex`,
    /// so you should set those indices to desired location to get the offset and length that you need to dump.
    private func hexDumpPlain() -> String {
        var hexString = ""
        hexString.reserveCapacity(self.readableBytes * 3)

        for byte in self.readableBytesView {
            hexString += String(byte, radix: 16, padding: 2)
            hexString += " "
        }

        return String(hexString.dropLast())
    }

    /// Return a `String` of space delimited hexadecimal digits of the readable bytes in the buffer,
    /// in a format that's compatible with `xxd -r -p`, but clips the output to the max length of `maxBytes` bytes.
    /// If the dump contains more than the `maxBytes` bytes, this function will return the first `maxBytes/2`
    /// and the last `maxBytes/2` of that, replacing the rest with `...`, i.e. `01 02 03 ... 09 11 12`.
    ///
    /// - parameters:
    ///     - maxBytes: The maximum amount of bytes presented in the dump.
    private func hexDumpPlain(maxBytes: Int) -> String {
        // If the buffer length fits in the max bytes limit in the hex dump, just dump the whole thing.
        if self.readableBytes <= maxBytes {
            return self.hexDump(format: .plain)
        }

        var buffer = self

        // Safe to force-unwrap because we just checked readableBytes is > maxBytes above.
        let front = buffer.readSlice(length: maxBytes / 2)!
        buffer.moveReaderIndex(to: buffer.writerIndex - maxBytes / 2)
        let back = buffer.readSlice(length: buffer.readableBytes)!

        let startHex = front.hexDumpPlain()
        let endHex = back.hexDumpPlain()
        return startHex + " ... " + endHex
    }

    /// Returns a `String` containing a detailed hex dump of this buffer.
    /// Intended to be used internally in ``hexDump(format:)``
    /// - parameters:
    ///     - lineOffset: an offset from the beginning of the outer buffer that is being dumped. It's used to print the line offset in hexdump -C format.
    ///     - paddingBefore: the amount of space to pad before the first byte dumped on this line, used in center and right columns.
    ///     - paddingAfter: the amount of sapce to pad after the last byte on this line, used in center and right columns.
    private func _hexDumpLine(lineOffset: Int, paddingBefore: Int = 0, paddingAfter: Int = 0) -> String {
        // Each line takes 78 visible characters + \n
        var result = ""
        result.reserveCapacity(79)

        // Left column of the hex dump signifies the offset from the beginning of the dumped buffer
        // and is separated from the next column with two spaces.
        result += String(lineOffset, radix: 16, padding: 8)
        result += "  "

        // Center column consists of:
        // - xxd-compatible dump of the first 8 bytes
        // - space
        // - xxd-compatible dump of the rest 8 bytes
        // If there are not enough bytes to dump, the column is padded with space.

        // If there's any padding on the left, apply that first.
        result += String(repeating: " ", count: paddingBefore * 3)

        // Add the left side of the central column
        let bytesInLeftColumn = max(8 - paddingBefore, 0)
        for byte in self.readableBytesView.prefix(bytesInLeftColumn) {
            result += String(byte, radix: 16, padding: 2)
            result += " "
        }

        // Add an extra space for the centre column.
        result += " "

        // Add the right side of the central column.
        for byte in self.readableBytesView.dropFirst(bytesInLeftColumn) {
            result += String(byte, radix: 16, padding: 2)
            result += " "
        }

        // Pad the resulting center column line to 60 characters.
        result += String(repeating: " ", count: 60 - result.count)

        // Right column renders the 16 bytes line as ASCII characters, or "." if the character is not printable.
        let printableRange = UInt8(ascii: " ") ..< UInt8(ascii: "~")
        let printableBytes = self.readableBytesView.map {
            printableRange.contains($0) ? $0 : UInt8(ascii: ".")
        }

        result += "|"
        result += String(repeating: " ", count: paddingBefore)
        result += String(decoding: printableBytes, as: UTF8.self)
        result += String(repeating: " ", count: paddingAfter)
        result += "|\n"
        return result
    }

    /// Returns a `String` of hexadecimal digits of bytes in the Buffer,
    /// with formatting compatible with output of `hexdump -C`.
    private func hexdumpDetailed() -> String {
        if self.readableBytes == 0 {
            return ""
        }

        var result = ""
        result.reserveCapacity(self.readableBytes / 16 * 79 + 8)

        var buffer = self

        var lineOffset = 0
        while buffer.readableBytes > 0 {
            // Safe to force-unwrap because we're in a loop that guarantees there's at least one byte to read.
            let slice = buffer.readSlice(length: min(16, buffer.readableBytes))!
            result += slice._hexDumpLine(lineOffset: lineOffset)
            lineOffset += slice.readableBytes
        }

        result += String(self.readableBytes, radix: 16, padding: 8)
        return result
    }

    /// Returns a `String` of hexadecimal digits of bytes in this ByteBuffer
    /// with formatting sort of compatible with `hexdump -C`, but clipped on length.
    /// Dumps limit/2 first and limit/2 last bytes, with a separator line in between.
    ///
    /// - parameters:
    ///     - maxBytes: Max bytes to dump.
    private func hexDumpDetailed(maxBytes: Int) -> String {
        if self.readableBytes <= maxBytes {
            return self.hexdumpDetailed()
        }

        let separator = "........  .. .. .. .. .. .. .. ..  .. .. .. .. .. .. .. ..  ..................\n"

        // reserve capacity for the maxBytes dumped, plus the separator line, and buffer length line.
        var result = ""
        result.reserveCapacity(maxBytes/16 * 79 + 79 + 8)

        var buffer = self

        // Dump the front part of the buffer first, up to maxBytes/2 bytes.
        // Safe to force-unwrap because we know the buffer has more readable bytes than maxBytes.
        var front = buffer.readSlice(length: maxBytes / 2)!
        var bufferOffset = 0
        while front.readableBytes > 0 {
            // Safe to force-unwrap because buffer is guaranteed to have at least one byte in it.
            let slice = front.readSlice(length: min(16, front.readableBytes))!

            // This will only be non-zero on the last line of this loop
            let paddingAfter = 16 - slice.readableBytes
            result += slice._hexDumpLine(lineOffset: bufferOffset, paddingAfter: paddingAfter)
            bufferOffset += slice.readableBytes
        }

        result += separator

        // Dump the back maxBytes/2 bytes.
        bufferOffset = buffer.writerIndex - maxBytes / 2
        buffer.moveReaderIndex(to: bufferOffset)
        var back = buffer.readSlice(length: buffer.readableBytes)!

        // On the first line of the back part, we might want less than 16 bytes, with padding on the left.
        // But if this is also the last line, than take whatever is left.
        let lineLength = min(16 - bufferOffset % 16, back.readableBytes)

        // Line offset is the offset of the first byte of this line in a full buffer hex dump.
        // It may not match `bufferOffset` in the first line of the `back` part.
        let lineOffset = bufferOffset - bufferOffset % 16

        // Safe to force-unwrap because `back` is guaranteed to have at least one byte.
        let slice = back.readSlice(length: lineLength)!

        // paddingBefore is going to be applied both in the center column and the right column of the line.
        result += slice._hexDumpLine(lineOffset: lineOffset, paddingBefore: 16 - lineLength)
        bufferOffset += lineLength

        // Now dump the rest of the back part of the buffer.
        while back.readableBytes > 0 {
            let slice = back.readSlice(length: min(16, back.readableBytes))!
            result += slice._hexDumpLine(lineOffset: bufferOffset)
            bufferOffset += slice.readableBytes
        }

        // Last line of the dump, just the index of the last byte in the buffer.
        result += String(self.readableBytes, radix: 16, padding: 8)
        return result
    }

    /// Returns a hex dump of  this `ByteBuffer` in a preferred `HexDumpFormat`.
    ///
    /// `hexDump` provides four formats:
    ///     - `.plain` — plain hex dump format with hex bytes separated by spaces, i.e. `48 65 6c 6c 6f` for `Hello`. This format is compatible with `xxd -r`.
    ///     - `.plain(maxBytes: Int)` — like `.plain`, but clipped to maximum bytes dumped.
    ///     - `.detailed` — detailed hex dump format with both hex, and ASCII representation of the bytes. This format is compatible with what `hexdump -C` outputs.
    ///     - `.detailed(maxBytes: Int)` — like `.detailed`, but  clipped to maximum bytes dumped.
    ///
    /// - parameters:
    ///     - format: ``HexDumpFormat`` to use for the dump.
    public func hexDump(format: HexDumpFormat) -> String {
        switch(format.value) {
        case .plain(let maxBytes):
            if let maxBytes = maxBytes {
                return self.hexDumpPlain(maxBytes: maxBytes)
            } else {
                return self.hexDumpPlain()
            }

        case .detailed(let maxBytes):
            if let maxBytes = maxBytes {
                return self.hexDumpDetailed(maxBytes: maxBytes)
            } else {
                return self.hexdumpDetailed()
            }
        }
    }
}

