//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncSequence where Element == ByteBuffer {
    /// Returns the longest possible subsequences of the sequence, in order,
    /// that are separated by line breaks.
    ///
    /// The following Characters are considered line breaks, similar to
    /// standard library's `String.split(whereSeparator: \.isNewline)`:
    /// - "\n" (U+000A): LINE FEED (LF)
    /// - U+000B: LINE TABULATION (VT)
    /// - U+000C: FORM FEED (FF)
    /// - "\r" (U+000D): CARRIAGE RETURN (CR)
    /// - "\r\n" (U+000D U+000A): CR-LF
    ///
    /// The following Characters are NOT considered line breaks, unlike in
    /// standard library's `String.split(whereSeparator: \.isNewline)`:
    /// - U+0085: NEXT LINE (NEL)
    /// - U+2028: LINE SEPARATOR
    /// - U+2029: PARAGRAPH SEPARATOR
    ///
    /// This is because these characters would require unicode and data-encoding awareness, which
    /// are outside swift-nio's scope.
    ///
    /// Usage:
    /// ```swift
    /// let baseSequence = MyAsyncSequence<ByteBuffer>(...)
    /// let splitLinesSequence = baseSequence.splitLines()
    ///
    /// for try await buffer in splitLinesSequence {
    ///     print("Split by line breaks!\n", buffer.hexDump(format: .detailed))
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - omittingEmptySubsequences: If `false`, an empty subsequence is
    ///     returned in the result for each consecutive line break in the sequence.
    ///     If `true`, only nonempty subsequences are returned. The default value is `true`.
    ///   - maximumBufferSize: The maximum number of bytes to aggregate in-memory.
    ///     An error will be thrown if after decoding an element there is more aggregated data than this amount.
    /// - Returns: An `AsyncSequence` of ``ByteBuffer``s, split from the this async sequence's bytes.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the file.
    @inlinable
    public func splitLines(
        omittingEmptySubsequences: Bool = true,
        maximumBufferSize: Int? = nil
    ) -> NIODecodedAsyncSequence<Self, NIOSplitLinesMessageDecoder> {
        self.decode(
            using: NIOSplitLinesMessageDecoder(
                omittingEmptySubsequences: omittingEmptySubsequences
            ),
            maximumBufferSize: maximumBufferSize
        )
    }

    /// Returns the longest possible `String`s of the sequence, in order,
    /// that are separated by line breaks.
    ///
    /// The following Characters are considered line breaks, similar to
    /// standard library's `String.split(whereSeparator: \.isNewline)`:
    /// - "\n" (U+000A): LINE FEED (LF)
    /// - U+000B: LINE TABULATION (VT)
    /// - U+000C: FORM FEED (FF)
    /// - "\r" (U+000D): CARRIAGE RETURN (CR)
    /// - "\r\n" (U+000D U+000A): CR-LF
    ///
    /// The following Characters are NOT considered line breaks, unlike in
    /// standard library's `String.split(whereSeparator: \.isNewline)`:
    /// - U+0085: NEXT LINE (NEL)
    /// - U+2028: LINE SEPARATOR
    /// - U+2029: PARAGRAPH SEPARATOR
    ///
    /// This is because these characters would require unicode and data-encoding awareness, which
    /// are outside swift-nio's scope.
    ///
    /// Usage:
    /// ```swift
    /// let baseSequence = MyAsyncSequence<ByteBuffer>(...)
    /// let splitLinesSequence = baseSequence.splitUTF8Lines()
    ///
    /// for try await string in splitLinesSequence {
    ///     print("Split by line breaks!\n", string)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - omittingEmptySubsequences: If `false`, an empty subsequence is
    ///     returned in the result for each consecutive line break in the sequence.
    ///     If `true`, only nonempty subsequences are returned. The default value is `true`.
    ///   - maximumBufferSize: The maximum number of bytes to aggregate in-memory.
    ///     An error will be thrown if after decoding an element there is more aggregated data than this amount.
    /// - Returns: An `AsyncSequence` of `String`s, split from the this async sequence's bytes.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the file.
    @inlinable
    public func splitUTF8Lines(
        omittingEmptySubsequences: Bool = true,
        maximumBufferSize: Int? = nil
    ) -> NIODecodedAsyncSequence<Self, NIOSplitUTF8LinesMessageDecoder> {
        self.decode(
            using: NIOSplitUTF8LinesMessageDecoder(
                omittingEmptySubsequences: omittingEmptySubsequences
            ),
            maximumBufferSize: maximumBufferSize
        )
    }
}

// MARK: - SplitMessageDecoder

/// A decoder which splits the data into subsequences that are separated by a given separator.
/// Similar to standard library's `String.split(separator:maxSplits:omittingEmptySubsequences:)`.
///
/// This decoder can be used to introduce a `AsyncSequence/split(omittingEmptySubsequences:maximumBufferSize:whereSeparator:)`
/// function. We could not come up with valid use-cases for such a function so we held off on introducing it.
/// See https://github.com/apple/swift-nio/pull/3411 for more info if you need such a function.
@usableFromInline
struct SplitMessageDecoder: NIOSingleStepByteToMessageDecoder {
    @usableFromInline
    typealias InboundOut = ByteBuffer

    @usableFromInline
    let omittingEmptySubsequences: Bool
    @usableFromInline
    let isSeparator: (UInt8) -> Bool
    @usableFromInline
    var ended: Bool
    @usableFromInline
    var bytesWithNoSeparatorsCount: Int

    @inlinable
    init(
        omittingEmptySubsequences: Bool = true,
        whereSeparator isSeparator: @escaping (UInt8) -> Bool
    ) {
        self.omittingEmptySubsequences = omittingEmptySubsequences
        self.isSeparator = isSeparator
        self.ended = false
        self.bytesWithNoSeparatorsCount = 0
    }

    /// Decode the next message from the given buffer.
    @inlinable
    mutating func decode(
        buffer: inout ByteBuffer,
        hasReceivedLastChunk: Bool
    ) throws -> (buffer: InboundOut, separator: UInt8?)? {
        if self.ended { return nil }

        while true {
            let startIndex = buffer.readerIndex + self.bytesWithNoSeparatorsCount
            if let separatorIndex = buffer.readableBytesView[startIndex...].firstIndex(where: self.isSeparator) {
                // Safe to force unwrap. We just found a separator somewhere in the buffer.
                let slice = buffer.readSlice(length: separatorIndex - buffer.readerIndex)!
                // Reset for the next search since we found a separator.
                self.bytesWithNoSeparatorsCount = 0

                if self.omittingEmptySubsequences,
                    slice.readableBytes == 0
                {
                    // Mark the separator itself as read
                    buffer._moveReaderIndex(forwardBy: 1)
                    continue
                }

                // Read the separator itself
                // Safe to force unwrap. We just found a separator somewhere in the buffer.
                let separator = buffer.readInteger(as: UInt8.self)!

                return (slice, separator)
            } else {
                guard hasReceivedLastChunk else {
                    // Make sure we don't double-check these no-separator bytes again.
                    self.bytesWithNoSeparatorsCount = buffer.readableBytes
                    // Need more data
                    return nil
                }

                // At this point, we're ending the decoding process.
                self.ended = true

                if self.omittingEmptySubsequences,
                    buffer.readableBytes == 0
                {
                    return nil
                }

                // Just send the whole buffer if we're at the last chunk but we can find no separators
                // Safe to force unwrap. `buffer.readableBytes` is `0` in the worst case.
                let slice = buffer.readSlice(length: buffer.readableBytes)!

                return (slice, nil)
            }
        }
    }

    /// Decode the next message separated by the provided separator.
    /// To be used when we're still receiving data.
    @inlinable
    mutating func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
        try self.decode(buffer: &buffer, hasReceivedLastChunk: false)?.buffer
    }

    /// Decode the next message separated by the provided separator.
    /// To be used when the last chunk of data has been received.
    @inlinable
    mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
        try self.decode(buffer: &buffer, hasReceivedLastChunk: true)?.buffer
    }
}

@available(*, unavailable)
extension SplitMessageDecoder: Sendable {}

// MARK: - NIOSplitLinesMessageDecoder

/// A decoder which splits the data into subsequences that are separated by line breaks.
///
/// You can initialize this type directly, or use
/// `AsyncSequence/splitLines(omittingEmptySubsequences:maximumBufferSize:)` to create a
/// `NIODecodedAsyncSequence` that uses this decoder.
///
/// The following Characters are considered line breaks, similar to
/// standard library's `String.split(whereSeparator: \.isNewline)`:
/// - "\n" (U+000A): LINE FEED (LF)
/// - U+000B: LINE TABULATION (VT)
/// - U+000C: FORM FEED (FF)
/// - "\r" (U+000D): CARRIAGE RETURN (CR)
/// - "\r\n" (U+000D U+000A): CR-LF
///
/// The following Characters are NOT considered line breaks, unlike in
/// standard library's `String.split(whereSeparator: \.isNewline)`:
/// - U+0085: NEXT LINE (NEL)
/// - U+2028: LINE SEPARATOR
/// - U+2029: PARAGRAPH SEPARATOR
///
/// This is because these characters would require unicode and data-encoding awareness, which
/// are outside swift-nio's scope.
///
/// Usage:
/// ```swift
/// let baseSequence = MyAsyncSequence<ByteBuffer>(...)
/// let splitLinesSequence = baseSequence.splitLines()
///
/// for try await buffer in splitLinesSequence {
///     print("Split by line breaks!\n", buffer.hexDump(format: .detailed))
/// }
/// ```
public struct NIOSplitLinesMessageDecoder: NIOSingleStepByteToMessageDecoder {
    public typealias InboundOut = ByteBuffer

    @usableFromInline
    var splitDecoder: SplitMessageDecoder
    @usableFromInline
    var previousSeparatorWasCR: Bool

    @inlinable
    public init(omittingEmptySubsequences: Bool) {
        self.splitDecoder = SplitMessageDecoder(
            omittingEmptySubsequences: omittingEmptySubsequences,
            whereSeparator: Self.isLineBreak
        )
        self.previousSeparatorWasCR = false
    }

    /// - ASCII 10 - "\n" (U+000A): LINE FEED (LF)
    /// - ASCII 11 - U+000B: LINE TABULATION (VT)
    /// - ASCII 12 - U+000C: FORM FEED (FF)
    /// - ASCII 13 - "\r" (U+000D): CARRIAGE RETURN (CR)
    ///
    /// "\r\n" is manually accounted for during the decoding.
    @inlinable
    static func isLineBreak(_ byte: UInt8) -> Bool {
        /// All the 4 ASCII bytes are in range of \n to \r.
        (UInt8(ascii: "\n")...UInt8(ascii: "\r")).contains(byte)
    }

    /// Decode the next message from the given buffer.
    @inlinable
    mutating func decode(buffer: inout ByteBuffer, hasReceivedLastChunk: Bool) throws -> InboundOut? {
        while true {
            guard
                let (slice, separator) = try self.splitDecoder.decode(
                    buffer: &buffer,
                    hasReceivedLastChunk: hasReceivedLastChunk
                )
            else {
                return nil
            }

            // If we are getting rid of empty subsequences then it doesn't matter if we detect
            // \r\n as a CR-LF, or as a CR + a LF. The backing decoder gets rid of the empty subsequence
            // anyway. Therefore, we can return early right here and skip the rest of the logic.
            if self.splitDecoder.omittingEmptySubsequences {
                return slice
            }

            // "\r\n" is 2 bytes long, so we need to manually account for it.
            switch separator {
            case UInt8(ascii: "\n") where slice.readableBytes == 0:
                let isCRLF = self.previousSeparatorWasCR
                self.previousSeparatorWasCR = false
                if isCRLF {
                    continue
                }
            case UInt8(ascii: "\r"):
                self.previousSeparatorWasCR = true
            default:
                self.previousSeparatorWasCR = false
            }

            return slice
        }
    }

    /// Decode the next message separated by one of the ASCII line breaks.
    /// To be used when we're still receiving data.
    @inlinable
    public mutating func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
        try self.decode(buffer: &buffer, hasReceivedLastChunk: false)
    }

    /// Decode the next message separated by one of the ASCII line breaks.
    /// To be used when the last chunk of data has been received.
    @inlinable
    public mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
        try self.decode(buffer: &buffer, hasReceivedLastChunk: true)
    }
}

@available(*, unavailable)
extension NIOSplitLinesMessageDecoder: Sendable {}

// MARK: - NIOSplitUTF8LinesMessageDecoder

/// A decoder which splits the data into subsequences that are separated by line breaks.
///
/// You can initialize this type directly, or use
/// `AsyncSequence/splitUTF8Lines(omittingEmptySubsequences:maximumBufferSize:)` to create a
/// `NIODecodedAsyncSequence` that uses this decoder.
///
/// The following Characters are considered line breaks, similar to
/// standard library's `String.split(whereSeparator: \.isNewline)`:
/// - "\n" (U+000A): LINE FEED (LF)
/// - U+000B: LINE TABULATION (VT)
/// - U+000C: FORM FEED (FF)
/// - "\r" (U+000D): CARRIAGE RETURN (CR)
/// - "\r\n" (U+000D U+000A): CR-LF
///
/// The following Characters are NOT considered line breaks, unlike in
/// standard library's `String.split(whereSeparator: \.isNewline)`:
/// - U+0085: NEXT LINE (NEL)
/// - U+2028: LINE SEPARATOR
/// - U+2029: PARAGRAPH SEPARATOR
///
/// This is because these characters would require unicode and data-encoding awareness, which
/// are outside swift-nio's scope.
///
/// Usage:
/// ```swift
/// let baseSequence = MyAsyncSequence<ByteBuffer>(...)
/// let splitLinesSequence = baseSequence.splitUTF8Lines()
///
/// for try await string in splitLinesSequence {
///     print("Split by line breaks!\n", string)
/// }
/// ```
public struct NIOSplitUTF8LinesMessageDecoder: NIOSingleStepByteToMessageDecoder {
    public typealias InboundOut = String

    @usableFromInline
    var splitLinesDecoder: NIOSplitLinesMessageDecoder

    @inlinable
    public init(omittingEmptySubsequences: Bool) {
        self.splitLinesDecoder = NIOSplitLinesMessageDecoder(
            omittingEmptySubsequences: omittingEmptySubsequences
        )
    }

    /// Decode the next message separated by one of the ASCII line breaks.
    /// To be used when we're still receiving data.
    @inlinable
    public mutating func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
        try self.splitLinesDecoder.decode(buffer: &buffer, hasReceivedLastChunk: false).map {
            String(buffer: $0)
        }
    }

    /// Decode the next message separated by one of the ASCII line breaks.
    /// To be used when the last chunk of data has been received.
    @inlinable
    public mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
        try self.splitLinesDecoder.decode(buffer: &buffer, hasReceivedLastChunk: true).map {
            String(buffer: $0)
        }
    }
}

@available(*, unavailable)
extension NIOSplitUTF8LinesMessageDecoder: Sendable {}
