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
    /// Returns the longest possible subsequences of the sequence, in order, that
    /// don't contain elements satisfying the given predicate. Elements that are
    /// used to split the sequence are not returned as part of any subsequence.
    ///
    /// Similar to standard library's `String.split(maxSplits:omittingEmptySubsequences:whereSeparator:)`.
    ///
    /// Usage:
    /// ```swift
    /// let baseSequence = MyAsyncSequence<ByteBuffer>(...)
    /// let splitSequence = baseSequence.split(whereSeparator: { $0 == UInt8(ascii: " ") })
    ///
    /// for try await buffer in splitSequence {
    ///     print("Split by whitespaces!\n", buffer.hexDump(format: .detailed))
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - omittingEmptySubsequences: If `false`, an empty subsequence is
    ///     returned in the result for each pair of consecutive elements
    ///     satisfying the `isSeparator` predicate and for each element at the
    ///     start or end of the sequence satisfying the `isSeparator` predicate.
    ///     If `true`, only nonempty subsequences are returned. The default
    ///     value is `true`.
    ///   - isSeparator: A closure that returns `true` if its argument should be
    ///     used to split the file's bytes; otherwise, `false`.
    /// - Returns: An `AsyncSequence` of ``ByteBuffer``s, split from the this async sequence's bytes.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the file.
    @inlinable
    public func split(
        omittingEmptySubsequences: Bool = true,
        maximumBufferSize: Int? = nil,
        whereSeparator isSeparator: @escaping (UInt8) -> Bool
    ) -> NIODecodedAsyncSequence<Self, NIOSplitMessageDecoder> {
        self.decode(
            using: NIOSplitMessageDecoder(
                omittingEmptySubsequences: omittingEmptySubsequences,
                whereSeparator: isSeparator
            ),
            maximumBufferSize: maximumBufferSize
        )
    }

    /// Returns the longest possible subsequences of the sequence, in order,
    /// around elements equal to the given element.
    ///
    /// Similar to standard library's `String.split(separator:maxSplits:omittingEmptySubsequences:)`.
    ///
    /// Usage:
    /// ```swift
    /// let baseSequence = MyAsyncSequence<ByteBuffer>(...)
    /// let splitSequence = baseSequence.split(separator: UInt8(ascii: " "))
    ///
    /// for try await buffer in splitSequence {
    ///     print("Split by separator!\n", buffer.hexDump(format: .detailed))
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - separator: The element that should be split upon.
    ///   - omittingEmptySubsequences: If `false`, an empty subsequence is
    ///     returned in the result for each consecutive pair of `separator`
    ///     elements in the sequence and for each instance of `separator` at the
    ///     start or end of the sequence. If `true`, only nonempty subsequences
    ///     are returned. The default value is `true`.
    /// - Returns: An `AsyncSequence` of ``ByteBuffer``s, split from the this async sequence's bytes.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the file.
    @inlinable
    public func split(
        separator: UInt8,
        omittingEmptySubsequences: Bool = true,
        maximumBufferSize: Int? = nil
    ) -> NIODecodedAsyncSequence<Self, NIOSplitMessageDecoder> {
        self.split(
            omittingEmptySubsequences: omittingEmptySubsequences,
            maximumBufferSize: maximumBufferSize,
            whereSeparator: { $0 == separator }
        )
    }
}

/// A decoder which splits the data into subsequences that are separated by a given separator.
/// Similar to standard library's `String.split(separator:maxSplits:omittingEmptySubsequences:)`.
///
/// Use `AsyncSequence/split(omittingEmptySubsequences:maximumBufferSize:whereSeparator:)`
/// or `AsyncSequence/split(separator:omittingEmptySubsequences:maximumBufferSize:)` to create a
/// `NIODecodedAsyncSequence` that uses this decoder.
public struct NIOSplitMessageDecoder: NIOSingleStepByteToMessageDecoder {
    public typealias InboundOut = ByteBuffer

    @usableFromInline
    let omittingEmptySubsequences: Bool
    @usableFromInline
    let isSeparator: (UInt8) -> Bool
    @usableFromInline
    var ended: Bool

    @inlinable
    init(
        omittingEmptySubsequences: Bool = false,
        whereSeparator isSeparator: @escaping (UInt8) -> Bool
    ) {
        self.omittingEmptySubsequences = omittingEmptySubsequences
        self.isSeparator = isSeparator
        self.ended = false
    }

    /// Decode the next message from the given buffer.
    @inlinable
    mutating func decode(buffer: inout ByteBuffer, hasReceivedLastChunk: Bool) throws -> InboundOut? {
        if self.ended { return nil }

        while true {
            guard let separatorIndex = buffer.readableBytesView.firstIndex(where: self.isSeparator) else {
                guard hasReceivedLastChunk else {
                    // Need more data
                    return nil
                }

                self.ended = true

                if self.omittingEmptySubsequences,
                    buffer.readableBytes == 0
                {
                    return nil
                }

                // Just send the whole buffer if we're at the last chunk but we can find no separators
                return buffer.readSlice(length: buffer.readableBytes)
            }

            // Safe to force unwrap. We just found a separator somewhere in the buffer.
            let slice = buffer.readSlice(length: separatorIndex - buffer.readerIndex)!

            // Mark the separator itself as read
            buffer._moveReaderIndex(forwardBy: 1)

            if self.omittingEmptySubsequences,
                slice.readableBytes == 0
            {
                continue
            }

            return slice
        }
    }

    /// Decode the next message separated by the provided separator.
    /// To be used when we're still receiving data.
    @inlinable
    public mutating func decode(buffer: inout ByteBuffer) throws -> InboundOut? {
        try self.decode(buffer: &buffer, hasReceivedLastChunk: false)
    }

    /// Decode the next message separated by the provided separator.
    /// To be used when the last chunk of data has been received.
    @inlinable
    public mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> InboundOut? {
        try self.decode(buffer: &buffer, hasReceivedLastChunk: true)
    }
}

@available(*, unavailable)
extension NIOSplitMessageDecoder: Sendable {}
