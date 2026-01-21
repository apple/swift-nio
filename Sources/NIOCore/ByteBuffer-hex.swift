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

    /// Create a fresh `ByteBuffer` containing the `bytes` decoded from the string representation of `plainHexEncodedBytes`.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit the hex decoded `bytes` and potentially some extra space
    /// using the default allocator.
    ///
    /// - info: If you have access to a `Channel`, `ChannelHandlerContext`, or `ByteBufferAllocator` we
    ///         recommend using `channel.allocator.buffer(integer:)`. Or if you want to write multiple items into the
    ///         buffer use `channel.allocator.buffer(capacity: ...)` to allocate a `ByteBuffer` of the right
    ///         size followed by a `writeHexEncodedBytes` instead of using this method. This allows SwiftNIO to do
    ///         accounting and optimisations of resources acquired for operations on a given `Channel` in the future.
    public init(plainHexEncodedBytes string: String) throws {
        self = try ByteBufferAllocator().buffer(plainHexEncodedBytes: string)
    }

    /// Describes a ByteBuffer hexDump format.
    /// Can be either xxd output compatible, or hexdump compatible.
    public struct HexDumpFormat: Hashable, Sendable {

        @usableFromInline
        enum Value: Hashable, Sendable {
            case plain(maxBytes: Int? = nil)
            case detailed(maxBytes: Int? = nil)
            case compact(maxBytes: Int? = nil)
        }

        @usableFromInline
        let value: Value

        @inlinable
        init(_ value: Value) { self.value = value }

        /// A plain hex dump format compatible with `xxd` CLI utility.
        @inlinable
        public static var plain: HexDumpFormat { Self(.plain(maxBytes: nil)) }

        /// A hex dump format compatible with `hexdump` command line utility.
        @inlinable
        public static var detailed: HexDumpFormat { Self(.detailed(maxBytes: nil)) }

        /// A hex dump analog to `plain` format  but without whitespaces.
        public static var compact: HexDumpFormat { Self(.compact(maxBytes: nil)) }

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

        /// A hex dump analog to `plain`format  but without whitespaces.
        /// This format will dump first `maxBytes / 2` bytes, and the last `maxBytes / 2` bytes, with a placeholder in between.
        public static func compact(maxBytes: Int) -> Self {
            Self(.compact(maxBytes: maxBytes))
        }
    }

    /// Shared logic for `hexDumpPlain` and `hexDumpCompact`.
    /// Returns a `String` of hexadecimals digits of the readable bytes in the buffer.
    /// - Parameter
    ///   - separateWithWhitespace: Controls whether the hex deump will be separated by whitespaces.
    private func _hexDump(separateWithWhitespace: Bool) -> String {
        var hexString = ""
        var capacity: Int

        if separateWithWhitespace {
            capacity = self.readableBytes * 3
        } else {
            capacity = self.readableBytes * 2
        }

        hexString.reserveCapacity(capacity)

        for byte in self.readableBytesView {
            hexString += String(byte, radix: 16, padding: 2)
            if separateWithWhitespace {
                hexString += " "
            }
        }

        if separateWithWhitespace {
            return String(hexString.dropLast())
        }

        return hexString
    }

    /// Shared logic for `hexDumpPlain(maxBytes: Int)` and `hexDumpCompact(maxBytes: Int)`.
    ///
    /// - Parameters:
    ///   - maxBytes: The maximum amount of bytes presented in the dump.
    ///   - separateWithWhitespace: Controls whether the dump will be separated by whitespaces.
    private func _hexDump(maxBytes: Int, separateWithWhitespace: Bool) -> String {
        // If the buffer length fits in the max bytes limit in the hex dump, just dump the whole thing.
        if self.readableBytes <= maxBytes {
            return self._hexDump(separateWithWhitespace: separateWithWhitespace)
        }

        var buffer = self

        // Safe to force-unwrap because we just checked readableBytes is > maxBytes above.
        let front = buffer.readSlice(length: maxBytes / 2)!
        buffer.moveReaderIndex(to: buffer.writerIndex - maxBytes / 2)
        let back = buffer.readSlice(length: buffer.readableBytes)!

        let startHex = front._hexDump(separateWithWhitespace: separateWithWhitespace)
        let endHex = back._hexDump(separateWithWhitespace: separateWithWhitespace)

        var dots: String
        if separateWithWhitespace {
            dots = " ... "
        } else {
            dots = "..."
        }

        return startHex + dots + endHex
    }

    /// Return a `String` of space separated hexadecimal digits of the readable bytes in the buffer,
    /// in a format that's compatible with `xxd -r -p`.
    /// `hexDumpPlain()` always dumps all readable bytes, i.e. from `readerIndex` to `writerIndex`,
    /// so you should set those indices to desired location to get the offset and length that you need to dump.
    private func hexDumpPlain() -> String {
        self._hexDump(separateWithWhitespace: true)
    }

    /// Return a `String` of space delimited hexadecimal digits of the readable bytes in the buffer,
    /// in a format that's compatible with `xxd -r -p`, but clips the output to the max length of `maxBytes` bytes.
    /// If the dump contains more than the `maxBytes` bytes, this function will return the first `maxBytes/2`
    /// and the last `maxBytes/2` of that, replacing the rest with `...`, i.e. `01 02 03 ... 09 11 12`.
    ///
    /// - Parameters:
    ///   - maxBytes: The maximum amount of bytes presented in the dump.
    private func hexDumpPlain(maxBytes: Int) -> String {
        self._hexDump(maxBytes: maxBytes, separateWithWhitespace: true)
    }

    /// Return a `String` of  hexadecimal digits of the readable bytes in the buffer,
    /// analog to `.plain` format but without whitespaces. This format guarantees not to emit whitespaces.
    /// `hexDumpCompact()` always dumps all readable bytes, i.e. from `readerIndex` to `writerIndex`,
    /// so you should set those indices to desired location to get the offset and length that you need to dump.
    private func hexDumpCompact() -> String {
        self._hexDump(separateWithWhitespace: false)
    }

    /// Return a `String` of  hexadecimal digits of the readable bytes in the buffer,
    /// analog to `.plain` format but without whitespaces and clips the output to the max length of `maxBytes` bytes.
    /// This format guarantees not to emmit whitespaces.
    /// If the dump contains more than the `maxBytes` bytes, this function will return the first `maxBytes/2`
    /// and the last `maxBytes/2` of that, replacing the rest with `...`, i.e. `010203...091112`.
    ///
    /// - Parameters:
    ///   - maxBytes: The maximum amount of bytes presented in the dump.
    private func hexDumpCompact(maxBytes: Int) -> String {
        self._hexDump(maxBytes: maxBytes, separateWithWhitespace: false)
    }

    /// Returns a `String` containing a detailed hex dump of this buffer.
    /// Intended to be used internally in ``hexDump(format:)``
    /// - Parameters:
    ///   - lineOffset: an offset from the beginning of the outer buffer that is being dumped. It's used to print the line offset in hexdump -C format.
    ///   - paddingBefore: the amount of space to pad before the first byte dumped on this line, used in center and right columns.
    ///   - paddingAfter: the amount of sapce to pad after the last byte on this line, used in center and right columns.
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
        let printableRange = UInt8(ascii: " ")..<UInt8(ascii: "~")
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
    /// - Parameters:
    ///   - maxBytes: Max bytes to dump.
    private func hexDumpDetailed(maxBytes: Int) -> String {
        if self.readableBytes <= maxBytes {
            return self.hexdumpDetailed()
        }

        let separator = "........  .. .. .. .. .. .. .. ..  .. .. .. .. .. .. .. ..  ..................\n"

        // reserve capacity for the maxBytes dumped, plus the separator line, and buffer length line.
        var result = ""
        result.reserveCapacity(maxBytes / 16 * 79 + 79 + 8)

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
    /// `hexDump` provides several formats:
    ///   - `.plain` — plain hex dump format with hex bytes separated by spaces, i.e. `48 65 6c 6c 6f` for `Hello`. This format is compatible with `xxd -r`.
    ///   - `.plain(maxBytes: Int)` — like `.plain`, but clipped to maximum bytes dumped.
    ///   - `.compact` — plain hexd dump without whitespaces.
    ///   - `.compact(maxBytes: Int)` — like `.compact`, but  clipped to maximum bytes dumped.
    ///   - `.detailed` — detailed hex dump format with both hex, and ASCII representation of the bytes. This format is compatible with what `hexdump -C` outputs.
    ///   - `.detailed(maxBytes: Int)` — like `.detailed`, but  clipped to maximum bytes dumped.
    ///
    /// - Parameters:
    ///   - format: ``HexDumpFormat`` to use for the dump.
    public func hexDump(format: HexDumpFormat) -> String {
        switch format.value {
        case .plain(let maxBytes):
            if let maxBytes = maxBytes {
                return self.hexDumpPlain(maxBytes: maxBytes)
            } else {
                return self.hexDumpPlain()
            }

        case .compact(let maxBytes):
            if let maxBytes = maxBytes {
                return self.hexDumpCompact(maxBytes: maxBytes)
            } else {
                return self.hexDumpCompact()
            }

        case .detailed(let maxBytes):
            if let maxBytes = maxBytes {
                return self.hexDumpDetailed(maxBytes: maxBytes)
            } else {
                return self.hexdumpDetailed()
            }
        }
    }

    /// An error that is thrown when an invalid hex encoded string was attempted to be written to a ByteBuffer.
    public struct HexDecodingError: Error, Equatable {
        private let kind: HexDecodingErrorKind

        private enum HexDecodingErrorKind {
            /// The hex encoded string was not of the expected even length.
            case invalidHexLength
            /// An invalid hex character was found in the hex encoded string.
            case invalidCharacter
        }

        public static let invalidHexLength = HexDecodingError(kind: .invalidHexLength)
        public static let invalidCharacter = HexDecodingError(kind: .invalidCharacter)
    }
}

extension UInt8 {
    fileprivate var isASCIIWhitespace: Bool {
        [UInt8(ascii: "\n"), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: " ")].contains(
            self
        )
    }

    fileprivate var asciiHexNibble: UInt8 {
        get throws {
            switch self {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                return self - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"):
                return self - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"):
                return self - UInt8(ascii: "A") + 10
            default:
                throw ByteBuffer.HexDecodingError.invalidCharacter
            }
        }
    }
}

extension Substring.UTF8View {
    @usableFromInline
    mutating func popNextHexByte() throws -> UInt8? {
        while let nextByte = self.first, nextByte.isASCIIWhitespace {
            self = self.dropFirst()
        }

        guard let firstHex = try self.popFirst()?.asciiHexNibble else {
            return nil  // No next byte to pop
        }

        guard let secondHex = try self.popFirst()?.asciiHexNibble else {
            throw ByteBuffer.HexDecodingError.invalidHexLength
        }

        return (firstHex << 4) | secondHex
    }
}
