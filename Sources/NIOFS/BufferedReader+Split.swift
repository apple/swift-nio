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

import NIOCore

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension BufferedReader {
    /// Returns the longest possible subsequences of the sequence, in order, that
    /// don't contain elements satisfying the given predicate. Elements that are
    /// used to split the sequence are not returned as part of any subsequence.
    ///
    /// Usage example:
    /// ```swift
    /// let myBufferedReader: BufferedReader = ...
    /// let whitespace = UInt8(ascii: " ")
    /// for try await buffer in myBufferedReader.split(whereSeparator: { $0 == whitespace }) {
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
    /// - Returns: An ``AsyncSequence`` of ``ByteBuffer``s, split from the ``BufferedReader``'s file.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the file.
    @inlinable
    public consuming func split(
        omittingEmptySubsequences: Bool = true,
        whereSeparator isSeparator: @Sendable @escaping (UInt8) -> Bool
    ) -> SplitSequence {
        SplitSequence(
            reader: self,
            omittingEmptySubsequences: omittingEmptySubsequences,
            isSeparator: isSeparator
        )
    }

    /// Returns the longest possible subsequences of the sequence, in order,
    /// around elements equal to the given element.
    ///
    /// Usage example:
    /// ```swift
    /// let myBufferedReader: BufferedReader = ...
    /// let whitespace = UInt8(ascii: " ")
    /// for try await buffer in myBufferedReader.split(separator: whitespace) {
    ///     print("Split by whitespaces!\n", buffer.hexDump(format: .detailed))
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
    /// - Returns: An ``AsyncSequence`` of ``ByteBuffer``s, split from the ``BufferedReader``'s file.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the file.
    @inlinable
    public consuming func split(
        separator: UInt8,
        omittingEmptySubsequences: Bool = true
    ) -> SplitSequence {
        self.split(
            omittingEmptySubsequences: omittingEmptySubsequences,
            whereSeparator: { $0 == separator }
        )
    }

    /// An ``AsyncSequence`` of ``ByteBuffer``s, split from the ``BufferedReader``'s file.
    ///
    /// Use ``BufferedReader/split(omittingEmptySubsequences:whereSeparator:)`` or ``BufferedReader/split(separator:omittingEmptySubsequences:)`` to create an instance of this sequence.
    public struct SplitSequence {
        var reader: BufferedReader<Handle>
        var omittingEmptySubsequences: Bool
        var isSeparator: @Sendable (UInt8) -> Bool

        @usableFromInline
        init(
            reader: BufferedReader<Handle>,
            omittingEmptySubsequences: Bool,
            isSeparator: @Sendable @escaping (UInt8) -> Bool
        ) {
            self.reader = reader
            self.omittingEmptySubsequences = omittingEmptySubsequences
            self.isSeparator = isSeparator
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension BufferedReader.SplitSequence: AsyncSequence {
    /// Returns an iterator over the elements of this sequence.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: self)
    }

    /// An iterator over the elements of this sequence.
    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: BufferedReader<Handle>.SplitSequence
        var ended = false

        /// Returns the next element in the sequence, or `nil` if the sequence has ended.
        public mutating func next() async throws -> ByteBuffer? {
            if self.ended { return nil }

            let (buffer, eof) = try await self.base.reader.read(while: {
                !self.base.isSeparator($0)
            })
            if eof {
                self.ended = true
            } else {
                try await self.base.reader.drop(1)
            }

            if self.base.omittingEmptySubsequences,
                buffer.readableBytes == 0
            {
                return try await self.next()
            }

            return buffer
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension BufferedReader.SplitSequence: Sendable where BufferedReader: Sendable {}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension BufferedReader.SplitSequence.AsyncIterator: Sendable where BufferedReader: Sendable {}
