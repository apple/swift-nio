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

        /// A detailed hex dump format compatible with `xxd`, clipped to `maxLength` bytes dumped.
        /// This format will dump first maxLength / 2 bytes, and the last maxLength / 2 bytes, replacing the rest with " ... ".
        public static func plain(maxBytes: Int) -> Self {
            Self(.plain(maxBytes: maxBytes))
        }

        /// A hex dump format compatible with `hexdump` command line tool.
        /// This format will dump first maxLength / 2 bytes, and the last maxLength / 2 bytes, with a placeholder in between.
        public static func detailed(maxBytes: Int) -> Self {
            Self(.detailed(maxBytes: maxBytes))
        }
    }

    /// Return a `String` of hexadecimal digits of bytes in the Buffer,
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

    /// Return a `String` of hexadecimal digits of bytes in the Buffer.,
    /// in a format that's compatible with `xxd -r -p`, but clips the output to the max length of `maxBytes` bytes.
    /// If the dump contains more than the `maxBytes` bytes, this function will return the first `maxBytes/2`
    /// and the last `maxBytes/2` of that, replacing the rest with `...`, i.e. `01 02 03 ... 09 11 12`.
    ///
    /// - parameters:
    ///     - maxBytes: The maximum amount of bytes presented in the dump.
    private func hexDumpPlain(maxBytes: Int) -> String {
        // If the buffer lenght fits in the max bytes limit in the hex dump, just dump the whole thing.
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

    // Dump hexdump -C compatible format without the last line containing the byte length of the buffer
    private func _hexDumpLines(offset: Int) -> String {
        var result = ""
        // Each hex dump line represents 16 bytes, and takes up to 79 characters including the \n in the end.
        // Plus the last line of the hex dump which is just 8 characters.
        result.reserveCapacity(self.readableBytes / 16 * 79 + 8)

        var buffer = self
        // We're going to move the lineOffset index forward, so copy it into a variable
        var lineOffset = offset

        while buffer.readableBytes > 0 {
            let slice = buffer.readSlice(length: min(16, buffer.readableBytes))! // Safe to force-unwrap because we're in a loop that guarantees there's at least one byte to read.
            let lineLength = slice.readableBytes

            // Left column of the hex dump signifies the offset from the beginning of the dumped buffer
            // and is separated from the next column with two spaces.
            result += String(lineOffset, radix: 16, padding: 8)
            result += "  "

            // Center column consists of:
            // - xxd-compatible dump of the first 8 bytes
            // - space
            // - xxd-compatible dump of the rest 8 bytes
            // If there are not enough bytes to dump, the column is padded with space.

            // Make another view into the slice to use readSlice.
            // Read up to 8 bytes into the left slice, and dump them. Safe to force-unwrap because there's at least one byte in `slice`.
            var plainSliceView = slice
            let left = plainSliceView.readSlice(length: min(8, slice.readableBytes))!.hexDumpPlain()
            // Read the remaining bytes, which is guaranteed to be up to 8, and dump them.
            let right = plainSliceView.hexDumpPlain()

            result += left
            result += String(repeating: " ", count: 25 - left.count)
            result += right
            result += String(repeating: " ", count: 25 - right.count)

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
    private func hexdumpDetailed() -> String {
        if self.readableBytes == 0 {
            return ""
        }

        var result = self._hexDumpLines(offset: 0)
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
        var result = ""

        var buffer = self
        // Safe to force-unwrap because we know the buffer has more readable bytes than maxBytes.
        let front = buffer.readSlice(length: maxBytes / 2)!
        buffer.moveReaderIndex(to: buffer.writerIndex - maxBytes / 2)
        let back = buffer.readSlice(length: buffer.readableBytes)!

        result += front._hexDumpLines(offset: 0)
        result += separator
        result += back._hexDumpLines(offset: self.readableBytes - maxBytes/2)
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
            if let maxBytes {
                return self.hexDumpPlain(maxBytes: maxBytes)
            } else {
                return self.hexDumpPlain()
            }

        case .detailed(let maxBytes):
            if let maxBytes {
                return self.hexDumpDetailed(maxBytes: maxBytes)
            } else {
                return self.hexdumpDetailed()
            }
        }
    }
}
