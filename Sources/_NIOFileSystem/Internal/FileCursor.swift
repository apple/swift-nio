//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Tracks where the next read or write through a file handle should happen, accounting for unseekable
/// files which can only be accessed sequentially.
///
/// Reading or writing at offset zero works for every kind of file, so the cursor only finds out whether
/// the file is seekable, by asking the handle for its type, when something needs a different offset. An
/// unseekable file (a pipe, FIFO or socket) is always accessed at offset zero, so a cursor which was
/// created with a different starting offset can't be used with one.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
internal struct FileCursor: Sendable {
    /// How the cursor addresses the bytes it reads or writes.
    private enum Positioning: Sendable {
        /// Not yet known. Accessing the file at offset zero works for every kind of file so there's no need
        /// to find out until a different offset is needed.
        case unknown
        /// The file is seekable: accesses are made at the cursor's offset.
        case positional
        /// The file is unseekable: it can only be accessed sequentially, so accesses are always made at
        /// offset zero.
        case sequential
    }

    /// The offset the cursor was created with.
    private let initialOffset: Int64

    /// The logical offset of the next read or write.
    ///
    /// For an unseekable file this counts the bytes which have been transferred, but isn't used for
    /// reading or writing.
    private var offset: Int64

    /// How the cursor addresses the file.
    private var positioning: Positioning = .unknown

    /// Creates a cursor.
    ///
    /// - Parameter initialOffset: The offset of the first read or write.
    init(initialOffset: Int64) {
        self.initialOffset = initialOffset
        self.offset = initialOffset
    }

    /// The offset to pass to the handle for the next read or write.
    ///
    /// - Parameter handle: The handle which is being read from or written to.
    /// - Returns: The offset to read from or write at. This is always zero for an unseekable file.
    /// - Throws: A ``FileSystemError`` with code ``FileSystemError/Code-swift.struct/unsupported`` if the
    ///   file is unseekable and the cursor didn't start at offset zero.
    mutating func nextOffset(for handle: some FileHandleProtocol) async throws -> Int64 {
        // Offset zero works for every kind of file, so only find out whether the file is seekable when
        // a different offset is needed.
        if self.offset != 0 {
            try await self.resolvePositioning(for: handle)
        }

        switch self.positioning {
        case .unknown, .positional:
            return self.offset
        case .sequential:
            try self.checkCanAccessSequentially()
            return 0
        }
    }

    /// Records that bytes were read or written.
    ///
    /// - Parameter count: The number of bytes which were transferred.
    mutating func advance(by count: Int64) {
        self.offset += count
    }

    /// Skips over bytes without reading or writing them, if the file can seek.
    ///
    /// - Parameters:
    ///   - count: The number of bytes to skip.
    ///   - handle: The handle which is being read from or written to.
    /// - Returns: `true` if the file is seekable, in which case the offset has been advanced by `count`.
    ///   `false` if the file is unseekable: the offset is unchanged and the bytes can only be skipped by
    ///   reading and discarding them, which the caller must do. The offset advances as they're transferred.
    /// - Throws: A ``FileSystemError`` with code ``FileSystemError/Code-swift.struct/unsupported`` if the
    ///   file is unseekable and the cursor didn't start at offset zero.
    mutating func skipIfSeekable(_ count: Int64, for handle: some FileHandleProtocol) async throws -> Bool {
        try await self.resolvePositioning(for: handle)

        switch self.positioning {
        case .unknown, .positional:
            self.advance(by: count)
            return true
        case .sequential:
            try self.checkCanAccessSequentially()
            return false
        }
    }

    /// Works out whether the file is seekable, if that isn't already known.
    private mutating func resolvePositioning(for handle: some FileHandleProtocol) async throws {
        guard self.positioning == .unknown else {
            return
        }

        let info = try await handle.info()
        self.positioning = info.type.isUnseekable ? .sequential : .positional
    }

    /// An unseekable file can only be accessed from the beginning.
    private func checkCanAccessSequentially() throws {
        guard self.initialOffset == 0 else {
            throw FileSystemError(
                code: .unsupported,
                message: "File is unseekable.",
                cause: nil,
                location: .here()
            )
        }
    }
}
