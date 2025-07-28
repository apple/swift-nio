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

/// A writer which buffers bytes in memory before writing them to the file system.
///
/// You can create a ``BufferedWriter`` by calling
/// ``WritableFileHandleProtocol/bufferedWriter(startingAtAbsoluteOffset:capacity:)`` on
/// ``WritableFileHandleProtocol`` and write bytes to it with one of the following methods:
/// - ``BufferedWriter/write(contentsOf:)-1rkf6``
/// - ``BufferedWriter/write(contentsOf:)-7cs3v``
/// - ``BufferedWriter/write(contentsOf:)-66cts``
///
/// If a call to one of the write functions reaches the buffers ``BufferedWriter/capacity`` the
/// buffer automatically writes its contents to the file.
///
/// - Remark: The writer reclaims the buffer's memory when it grows to more than twice the
///   configured size.
///
/// To write the bytes in the buffer to the file system before the buffer is full
/// use ``BufferedWriter/flush()``.
///
/// - Important: You should you call ``BufferedWriter/flush()`` when you have finished appending
///   to write any remaining data to the file system.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct BufferedWriter<Handle: WritableFileHandleProtocol> {
    private let handle: Handle
    /// Offset for the next write.
    private var offset: Int64
    /// A buffer of bytes to write.
    private var buffer: [UInt8] = []

    /// The maximum number of bytes to buffer before the buffer is automatically flushed.
    public let capacity: Int

    /// The number of bytes in the buffer.
    ///
    /// You can flush the buffer manually by calling ``flush()``.
    public var bufferedBytes: Int {
        self.buffer.count
    }

    /// The capacity of the buffer.
    @_spi(Testing)
    public var bufferCapacity: Int {
        self.buffer.capacity
    }

    internal init(wrapping writableHandle: Handle, initialOffset: Int64, capacity: Int) {
        precondition(
            initialOffset >= 0,
            "initialOffset (\(initialOffset)) must be greater than or equal to zero"
        )
        precondition(capacity > 0, "capacity (\(capacity)) must be greater than zero")
        self.handle = writableHandle
        self.offset = initialOffset
        self.capacity = capacity
    }

    /// Write the contents of the collection of bytes to the buffer.
    ///
    /// If the number of bytes in the buffer exceeds the size of the buffer then they're
    /// automatically written to the file system.
    ///
    /// - Remark: The writer reclaims the buffer's memory when it grows to more than twice the
    ///   configured size.
    ///
    /// To manually flush bytes use ``flush()``.
    ///
    /// - Parameter bytes: The bytes to write to the buffer.
    /// - Returns: The number of bytes written into the buffered writer.
    @discardableResult
    public mutating func write(contentsOf bytes: some Sequence<UInt8>) async throws -> Int64 {
        let bufferSize = Int64(self.buffer.count)
        self.buffer.append(contentsOf: bytes)
        let bytesWritten = Int64(self.buffer.count) &- bufferSize

        if self.buffer.count >= self.capacity {
            try await self.flush()
        }

        return bytesWritten
    }

    /// Write the contents of the `ByteBuffer` into the buffer.
    ///
    /// If the number of bytes in the buffer exceeds the size of the buffer then they're
    /// automatically written to the file system.
    ///
    /// - Remark: The writer reclaims the buffer's memory when it grows to more than twice the
    ///   configured size.
    ///
    /// To manually flush bytes use ``flush()``.
    ///
    /// - Parameter bytes: The bytes to write to the buffer.
    /// - Returns: The number of bytes written into the buffered writer.
    @discardableResult
    public mutating func write(contentsOf bytes: ByteBuffer) async throws -> Int64 {
        try await self.write(contentsOf: bytes.readableBytesView)
    }

    /// Write the contents of the `AsyncSequence` of byte chunks to the buffer.
    ///
    /// If appending a chunk to the buffer causes it to exceed the capacity of the buffer then the
    /// contents of the buffer are automatically written to the file system.
    ///
    /// - Remark: The writer reclaims the buffer's memory when it grows to more than twice the
    ///   configured size.
    ///
    /// To manually flush bytes use ``flush()``.
    ///
    /// - Parameter chunks: The `AsyncSequence` of byte chunks to write to the buffer.
    /// - Returns: The number of bytes written into the buffered writer.
    @discardableResult
    public mutating func write<Chunks: AsyncSequence>(
        contentsOf chunks: Chunks
    ) async throws -> Int64 where Chunks.Element: Sequence<UInt8> {
        var bytesWritten: Int64 = 0
        do {
            for try await chunk in chunks {
                bytesWritten += try await self.write(contentsOf: chunk)
            }
        } catch let error as FileSystemError {
            // From call to 'write'.
            throw error
        } catch let error {
            // From iterating the async sequence.
            throw FileSystemError(
                code: .unknown,
                message: "AsyncSequence of bytes threw error while writing to the buffered writer.",
                cause: error,
                location: .here()
            )
        }
        return bytesWritten
    }

    /// Write the contents of the `AsyncSequence` of `ByteBuffer`s into the buffer.
    ///
    /// If appending a chunk to the buffer causes it to exceed the capacity of the buffer then the
    /// contents of the buffer are automatically written to the file system.
    ///
    /// - Remark: The writer reclaims the buffer's memory when it grows to more than twice the
    ///   configured size.
    ///
    /// To manually flush bytes use ``flush()``.
    ///
    /// - Parameter chunks: The `AsyncSequence` of `ByteBuffer`s to write.
    /// - Returns: The number of bytes written into the buffered writer.
    @discardableResult
    public mutating func write<Chunks: AsyncSequence>(
        contentsOf chunks: Chunks
    ) async throws -> Int64 where Chunks.Element == ByteBuffer {
        try await self.write(contentsOf: chunks.map { $0.readableBytesView })
    }

    /// Write the contents of the `AsyncSequence` of bytes the buffer.
    ///
    /// If appending a byte to the buffer causes it to exceed the capacity of the buffer then the
    /// contents of the buffer are automatically written to the file system.
    ///
    /// - Remark: The writer reclaims the buffer's memory when it grows to more than twice the
    ///   configured size.
    ///
    /// To manually flush bytes use ``flush()``.
    ///
    /// - Parameter bytes: The `AsyncSequence` of bytes to write to the buffer.
    @discardableResult
    public mutating func write<Bytes: AsyncSequence>(
        contentsOf bytes: Bytes
    ) async throws -> Int64 where Bytes.Element == UInt8 {
        try await self.write(contentsOf: bytes.map { CollectionOfOne($0) })
    }

    /// Flush any buffered bytes to the file system.
    ///
    /// - Important: You should you call ``flush()`` when you have finished writing to ensure the
    ///   buffered writer writes any remaining data to the file system.
    public mutating func flush() async throws {
        if self.buffer.isEmpty { return }

        try await self.handle.write(contentsOf: self.buffer, toAbsoluteOffset: self.offset)
        self.offset += Int64(self.buffer.count)

        // The buffer may grow beyond the specified buffer size. Keep the capacity if it's less than
        // double the intended size, otherwise reclaim the memory.
        let keepCapacity = self.buffer.capacity <= (self.capacity * 2)
        self.buffer.removeAll(keepingCapacity: keepCapacity)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension WritableFileHandleProtocol {
    /// Creates a new ``BufferedWriter`` for this file handle.
    ///
    /// - Parameters:
    ///   - initialOffset: The offset to begin writing at, defaults to zero.
    ///   - capacity: The capacity of the buffer in bytes, as a ``ByteCount``. The writer writes the contents of its
    ///     buffer to the file system when it exceeds this capacity. Defaults to 512 KiB.
    /// - Returns: A ``BufferedWriter``.
    public func bufferedWriter(
        startingAtAbsoluteOffset initialOffset: Int64 = 0,
        capacity: ByteCount = .kibibytes(512)
    ) -> BufferedWriter<Self> {
        BufferedWriter(
            wrapping: self,
            initialOffset: initialOffset,
            capacity: Int(capacity.bytes)
        )
    }

    /// Convenience function that creates a buffered reader, executes
    /// the closure that writes the contents into the buffer and calls 'flush()'.
    ///
    /// - Parameters:
    ///   - initialOffset: The offset to begin writing at, defaults to zero.
    ///   - capacity: The capacity of the buffer in bytes, as a ``ByteCount``. The writer writes the contents of its
    ///     buffer to the file system when it exceeds this capacity. Defaults to 512 KiB.
    ///   - body: The closure that writes the contents to the buffer created in this method.
    /// - Returns: The result of the executed closure.
    public func withBufferedWriter<Result>(
        startingAtAbsoluteOffset initialOffset: Int64 = 0,
        capacity: ByteCount = .kibibytes(512),
        execute body: (inout BufferedWriter<Self>) async throws -> Result
    ) async throws -> Result {
        var bufferedWriter = self.bufferedWriter(startingAtAbsoluteOffset: initialOffset, capacity: capacity)
        return try await withUncancellableTearDown {
            try await body(&bufferedWriter)
        } tearDown: { _ in
            try await bufferedWriter.flush()
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension BufferedWriter: Sendable where Handle: Sendable {}
