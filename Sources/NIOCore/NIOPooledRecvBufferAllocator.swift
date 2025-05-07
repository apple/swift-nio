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

/// A receive buffer allocator which cycles through a pool of buffers.
///
/// Channels can read multiple times per cycle (based on `ChannelOptions.maxMessagesPerRead`), and they reuse
/// the inbound buffer for each read. If a `ChannelHandler` holds onto this buffer, then CoWing will be needed.
/// A `NIOPooledRecvBufferAllocator` cycles through preallocated buffers to avoid CoWs during the same read cycle.
public struct NIOPooledRecvBufferAllocator: Sendable {
    // The pool will either use a single buffer (i.e. `buffer`) OR store multiple buffers
    // in `buffers`. If `buffers` is non-empty then `buffer` MUST be `nil`. If `buffer`
    // is non-nil then `buffers` MUST be empty.
    //
    // The backing storage is changed from `buffer` to `buffers` when a second buffer is
    // needed (and if capacity allows).
    @usableFromInline
    internal var _buffer: Optional<ByteBuffer>
    @usableFromInline
    internal var _buffers: [ByteBuffer]
    /// The index into `buffers` of the index which was last used.
    @usableFromInline
    internal var _lastUsedIndex: Int

    /// Maximum number of buffers to store in the pool.
    public private(set) var capacity: Int
    /// The receive allocator providing hints for the next buffer size to use.
    public var recvAllocator: RecvByteBufferAllocator

    /// The return value from the last call to `recvAllocator.record(actualReadBytes:)`.
    @usableFromInline
    internal var _mayGrow: Bool

    /// Builds a new instance of `NIOPooledRecvBufferAllocator`
    ///
    /// - Parameters:
    ///   - capacity: Maximum number of buffers to store in the pool.
    ///   - recvAllocator: The receive allocator providing hints for the next buffer size to use.
    public init(capacity: Int, recvAllocator: RecvByteBufferAllocator) {
        precondition(capacity > 0)
        self.capacity = capacity
        self._buffer = nil
        self._buffers = []
        self._lastUsedIndex = 0
        self.recvAllocator = recvAllocator
        self._mayGrow = false
    }

    /// Returns the number of buffers in the pool.
    public var count: Int {
        if self._buffer == nil {
            // Empty or switched to `buffers` for storage.
            return self._buffers.count
        } else {
            // `buffer` is non-nil; `buffers` must be empty and the count must be 1.
            assert(self._buffers.isEmpty)
            return 1
        }
    }

    /// Update the capacity of the underlying buffer pool.
    ///
    /// - Parameters:
    ///   - newCapacity: The new capacity for the underlying buffer pool.
    public mutating func updateCapacity(to newCapacity: Int) {
        precondition(newCapacity > 0)

        if newCapacity > self.capacity {
            self.capacity = newCapacity
            if !self._buffers.isEmpty {
                self._buffers.reserveCapacity(newCapacity)
            }
        } else if newCapacity < self.capacity {
            self.capacity = newCapacity
            // Drop buffers if over capacity.
            while self._buffers.count > self.capacity {
                self._buffers.removeLast()
            }
            // Reset the last used index.
            if self._lastUsedIndex >= self.capacity {
                self._lastUsedIndex = 0
            }
        }
    }

    /// Record the number of bytes which were read.
    ///
    /// - Parameters:
    ///   - actualReadBytes: Number of bytes being recorded
    public mutating func record(actualReadBytes: Int) {
        self._mayGrow = self.recvAllocator.record(actualReadBytes: actualReadBytes)
    }

    /// Provides a buffer with enough writable capacity as determined by the underlying
    /// receive allocator to the given closure.
    ///
    /// - Parameters:
    ///    - allocator: `ByteBufferAllocator` used to construct a new buffer if needed
    ///    - body: Closure where the caller can use the new or existing buffer
    /// - Returns: A tuple containing the `ByteBuffer` used and the `Result` yielded by the closure provided.
    @inlinable
    public mutating func buffer<Result>(
        allocator: ByteBufferAllocator,
        _ body: (inout ByteBuffer) throws -> Result
    ) rethrows -> (ByteBuffer, Result) {
        // Reuse an existing buffer if we can do so without CoWing.
        if let bufferAndResult = try self._reuseExistingBuffer(body) {
            return bufferAndResult
        } else {
            // No available buffers or the allocator does not offer up buffer sizes; directly
            // allocate a new one.
            return try self._allocateNewBuffer(using: allocator, body)
        }
    }

    @inlinable
    internal mutating func _reuseExistingBuffer<Result>(
        _ body: (inout ByteBuffer) throws -> Result
    ) rethrows -> (ByteBuffer, Result)? {
        if let nextBufferSize = self.recvAllocator.nextBufferSize() {
            if let result = try self._buffer?._modifyIfUniquelyOwned(minimumCapacity: nextBufferSize, body) {
                // `result` can only be non-nil if `buffer` is non-nil.
                return (self._buffer!, result)
            } else {
                // Cycle through the buffers starting at the last used buffer.
                let resultAndIndex = try self._buffers._loopingFirstIndexWithResult(startingAt: self._lastUsedIndex) {
                    buffer in
                    try buffer._modifyIfUniquelyOwned(minimumCapacity: nextBufferSize, body)
                }

                if let (result, index) = resultAndIndex {
                    self._lastUsedIndex = index
                    return (self._buffers[index], result)
                }
            }
        } else if self._buffer != nil, !self._mayGrow {
            // No hint about the buffer size (so pooling is not being used) and the allocator
            // indicated that the next buffer will not grow in size so reuse the existing stored
            // buffer.
            self._buffer!.clear()
            let result = try body(&self._buffer!)
            return (self._buffer!, result)
        }

        // Couldn't reuse an existing buffer.
        return nil
    }

    @inlinable
    internal mutating func _allocateNewBuffer<Result>(
        using allocator: ByteBufferAllocator,
        _ body: (inout ByteBuffer) throws -> Result
    ) rethrows -> (ByteBuffer, Result) {
        // Couldn't reuse a buffer; create a new one and store it if there's capacity.
        var newBuffer = self.recvAllocator.buffer(allocator: allocator)

        if let buffer = self._buffer {
            assert(self._buffers.isEmpty)
            // We have a stored buffer, either:
            // 1. We have capacity to add more and use `buffers` for storage, or
            // 2. Our capacity is 1; we can't use `buffers` for storage.
            if self.capacity > 1 {
                self._buffer = nil
                self._buffers.reserveCapacity(self.capacity)
                self._buffers.append(buffer)
                self._buffers.append(newBuffer)
                self._lastUsedIndex = self._buffers.index(before: self._buffers.endIndex)
                return try self._modifyBuffer(atIndex: self._lastUsedIndex, body)
            } else {
                let result = try body(&newBuffer)
                return (newBuffer, result)
            }
        } else {
            // There's no stored buffer which could be due to:
            // 1. this is the first buffer we allocate (i.e. buffers is empty, we already know
            //    buffer is nil), or
            // 2. we've already switched to using buffers for storage and it's not yet full, or
            // 3. we've already switched to using buffers for storage and it's full.
            if self._buffers.isEmpty {
                self._buffer = newBuffer
                let result = try body(&self._buffer!)
                return (self._buffer!, result)
            } else if self._buffers.count < self.capacity {
                self._buffers.append(newBuffer)
                self._lastUsedIndex = self._buffers.index(before: self._buffers.endIndex)
                return try self._modifyBuffer(atIndex: self._lastUsedIndex, body)
            } else {
                let result = try body(&newBuffer)
                return (newBuffer, result)
            }
        }
    }

    @inlinable
    internal mutating func _modifyBuffer<Result>(
        atIndex index: Int,
        _ body: (inout ByteBuffer) throws -> Result
    ) rethrows -> (ByteBuffer, Result) {
        let result = try body(&self._buffers[index])
        return (self._buffers[index], result)
    }
}

extension ByteBuffer {
    @inlinable
    internal mutating func _modifyIfUniquelyOwned<Result>(
        minimumCapacity: Int,
        _ body: (inout ByteBuffer) throws -> Result
    ) rethrows -> Result? {
        try self.modifyIfUniquelyOwned { buffer in
            buffer.clear(minimumCapacity: minimumCapacity)
            return try body(&buffer)
        }
    }
}

extension Array {
    /// Iterate over all elements in the array starting at the given index and looping back to the start
    /// if the end is reached. The `body` is applied to each element and iteration is stopped when
    /// `body` returns a non-nil value or all elements have been iterated.
    ///
    /// - Returns: The result and index of the first element passed to `body` which returned
    ///   non-nil, or `nil` if no such element exists.
    @inlinable
    internal mutating func _loopingFirstIndexWithResult<Result>(
        startingAt middleIndex: Index,
        whereNonNil body: (inout Element) throws -> Result?
    ) rethrows -> (Result, Index)? {
        if let result = try self._firstIndexWithResult(in: middleIndex..<self.endIndex, whereNonNil: body) {
            return result
        }

        return try self._firstIndexWithResult(in: self.startIndex..<middleIndex, whereNonNil: body)
    }

    @inlinable
    internal mutating func _firstIndexWithResult<Result>(
        in indices: Range<Index>,
        whereNonNil body: (inout Element) throws -> Result?
    ) rethrows -> (Result, Index)? {
        for index in indices {
            if let result = try body(&self[index]) {
                return (result, index)
            }
        }
        return nil
    }
}
