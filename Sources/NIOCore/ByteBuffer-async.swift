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

/// Async extensions for `ByteBuffer`.
///
/// These extensions provide safe access to `ByteBuffer` contents from
/// Swift Concurrency contexts by copying the readable bytes to a stable
/// temporary allocation before invoking the async closure, preventing
/// invalidation of the underlying storage across suspension points.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension ByteBuffer {

    /// Yields a buffer pointer containing this `ByteBuffer`'s readable bytes
    /// to an asynchronous closure.
    ///
    /// Unlike the synchronous ``withUnsafeReadableBytes(_:)-9hlep`` variant,
    /// this method copies the readable bytes into a temporary buffer before
    /// invoking `body`, ensuring the pointer remains valid across suspension
    /// points.  Calling the synchronous variant from an async context would
    /// be unsafe because `ByteBuffer` uses copy-on-write storage that could
    /// be invalidated by concurrent modification during suspension.
    ///
    /// - note: This method performs an O(n) copy of the readable bytes.  For
    ///   zero-copy access in synchronous contexts, prefer the non-async
    ///   ``withUnsafeReadableBytes(_:)-9hlep``.
    ///
    /// - warning: The pointer passed to `body` is valid only for the duration
    ///   of that closure.  Do not escape it for later use.
    ///
    /// - Parameters:
    ///   - body: An async closure that receives an `UnsafeRawBufferPointer`
    ///     covering the readable bytes.
    /// - Returns: The value returned by `body`.
    /// - Throws: Any error thrown by `body`.
    @inlinable
    public func withUnsafeReadableBytes<T>(
        _ body: (UnsafeRawBufferPointer) async throws -> T
    ) async rethrows -> T {
        let byteCount = self.readableBytes
        // Synchronously copy the readable bytes to a stable allocation.
        // This must happen outside the async closure to avoid a data race
        // on the ByteBuffer's underlying storage.
        let buffer = self.withUnsafeReadableBytes { source -> UnsafeMutableRawBufferPointer in
            let destination = UnsafeMutableRawBufferPointer.allocate(
                byteCount: byteCount,
                alignment: 1
            )
            if byteCount > 0 {
                destination.copyMemory(from: source)
            }
            return destination
        }
        defer { buffer.deallocate() }
        return try await body(.init(buffer))
    }
}
