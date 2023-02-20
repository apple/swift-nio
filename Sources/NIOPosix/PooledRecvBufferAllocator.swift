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

/// A receive buffer allocator which cycles through a pool of buffers.
internal struct PooledRecvBufferAllocator {
    // The pool will either use a single buffer (i.e. `buffer`) OR store multiple buffers
    // in `buffers`. If `buffers` is non-empty then `buffer` MUST be `nil`. If `buffer`
    // is non-nil then `buffers` MUST be empty.
    //
    // The backing storage is changed from `buffer` to `buffers` when a second buffer is
    // needed (and if capacity allows).
    private var buffer: Optional<ByteBuffer>
    private var buffers: [ByteBuffer]
    /// The index into `buffers` of the index which was last used.
    private var lastUsedIndex: Int

    /// Maximum number of buffers to store in the pool.
    internal private(set) var capacity: Int
    /// The receive allocator providing hints for the next buffer size to use.
    internal var recvAllocator: RecvByteBufferAllocator

    /// The return value from the last call to `recvAllocator.record(actualReadBytes:)`.
    private var mayGrow: Bool

    init(capacity: Int, recvAllocator: RecvByteBufferAllocator) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.buffer = nil
        self.buffers = []
        self.lastUsedIndex = 0
        self.recvAllocator = recvAllocator
        self.mayGrow = false
    }

    /// Returns the number of buffers in the pool.
    var count: Int {
        if self.buffer == nil {
            // Empty or switched to `buffers` for storage.
            return self.buffers.count
        } else {
            // `buffer` is non-nil; `buffers` must be empty and the count must be 1.
            assert(self.buffers.isEmpty)
            return 1
        }
    }

    /// Update the capacity of the underlying buffer pool.
    mutating func updateCapacity(to newCapacity: Int) {
        precondition(newCapacity > 0)

        if newCapacity > self.capacity {
            self.capacity = newCapacity
            if !self.buffers.isEmpty {
                self.buffers.reserveCapacity(newCapacity)
            }
        } else if newCapacity < self.capacity {
            self.capacity = newCapacity
            // Drop buffers if over capacity.
            while self.buffers.count > self.capacity {
                self.buffers.removeLast()
            }
            // Reset the last used index.
            if self.lastUsedIndex >= self.capacity {
                self.lastUsedIndex = 0
            }
        }
    }

    /// Record the number of bytes which were read.
    ///
    /// Returns whether the next buffer will be larger than the last.
    mutating func record(actualReadBytes: Int) {
        self.mayGrow = self.recvAllocator.record(actualReadBytes: actualReadBytes)
    }

    /// Provides a buffer with enough writable capacity as determined by the underlying
    /// receive allocator to the given closure.
    mutating func buffer<Result>(
        allocator: ByteBufferAllocator,
        _ body: (inout ByteBuffer) throws -> Result
    ) rethrows -> (ByteBuffer, Result) {
        // Reuse an existing buffer if we can do so without CoWing.
        if let bufferAndResult = try self.reuseExistingBuffer(body) {
            return bufferAndResult
        } else {
            // No available buffers or the allocator does not offer up buffer sizes; directly
            // allocate a new one.
            return try self.allocateNewBuffer(using: allocator, body)
        }
    }

    private mutating func reuseExistingBuffer<Result>(_ body: (inout ByteBuffer) throws -> Result) rethrows -> (ByteBuffer, Result)? {
        if let nextBufferSize = self.recvAllocator.nextBufferSize() {
            if let result = try self.buffer?.modifyIfUniquelyOwned(minimumCapacity: nextBufferSize, body) {
                // `result` can only be non-nil if `buffer` is non-nil.
                return (self.buffer!, result)
            } else {
                // Cycle through the buffers starting at the last used buffer.
                let resultAndIndex = try self.buffers.loopingFirstIndexWithResult(startingAt: self.lastUsedIndex) { buffer in
                    try buffer.modifyIfUniquelyOwned(minimumCapacity: nextBufferSize, body)
                }

                if let (result, index) = resultAndIndex {
                    self.lastUsedIndex = index
                    return (self.buffers[index], result)
                }
            }
        } else if self.buffer != nil, !self.mayGrow {
            // No hint about the buffer size (so pooling is not being used) and the allocator
            // indicated that the next buffer will not grow in size so reuse the existing stored
            // buffer.
            self.buffer!.clear()
            let result = try body(&self.buffer!)
            return (self.buffer!, result)
        }

        // Couldn't reuse an existing buffer.
        return nil
    }

    private mutating func allocateNewBuffer<Result>(using allocator: ByteBufferAllocator,
                                                    _ body: (inout ByteBuffer) throws -> Result) rethrows -> (ByteBuffer, Result) {
        // Couldn't reuse a buffer; create a new one and store it if there's capacity.
        var newBuffer = self.recvAllocator.buffer(allocator: allocator)

        if let buffer = self.buffer {
            assert(self.buffers.isEmpty)
            // We have a stored buffer, either:
            // 1. We have capacity to add more and use `buffers` for storage, or
            // 2. Our capacity is 1; we can't use `buffers` for storage.
            if self.capacity > 1 {
                self.buffer = nil
                self.buffers.reserveCapacity(self.capacity)
                self.buffers.append(buffer)
                self.buffers.append(newBuffer)
                self.lastUsedIndex = self.buffers.index(before: self.buffers.endIndex)
                return try self.modifyBuffer(atIndex: self.lastUsedIndex, body)
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
            if self.buffers.isEmpty {
                self.buffer = newBuffer
                let result = try body(&self.buffer!)
                return (self.buffer!, result)
            } else if self.buffers.count < self.capacity {
                self.buffers.append(newBuffer)
                self.lastUsedIndex = self.buffers.index(before: self.buffers.endIndex)
                return try self.modifyBuffer(atIndex: self.lastUsedIndex, body)
            } else {
                let result = try body(&newBuffer)
                return (newBuffer, result)
            }
        }
    }

    private mutating func modifyBuffer<Result>(atIndex index: Int,
                                               _ body: (inout ByteBuffer) throws -> Result) rethrows -> (ByteBuffer, Result) {
        let result = try body(&self.buffers[index])
        return (self.buffers[index], result)
    }
}

extension ByteBuffer {
    fileprivate mutating func modifyIfUniquelyOwned<Result>(minimumCapacity: Int,
                                                            _ body: (inout ByteBuffer) throws -> Result) rethrows -> Result? {
        return try self.modifyIfUniquelyOwned { buffer in
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
    fileprivate mutating func loopingFirstIndexWithResult<Result>(startingAt middleIndex: Index,
                                                                  whereNonNil body: (inout Element) throws -> Result?) rethrows -> (Result, Index)? {
        if let result = try self.firstIndexWithResult(in: middleIndex ..< self.endIndex, whereNonNil: body) {
            return result
        }

        return try self.firstIndexWithResult(in: self.startIndex ..< middleIndex, whereNonNil: body)
    }

    private mutating func firstIndexWithResult<Result>(in indices: Range<Index>,
                                                       whereNonNil body: (inout Element) throws -> Result?) rethrows -> (Result, Index)? {
        for index in indices {
            if let result = try body(&self[index]) {
                return (result, index)
            }
        }
        return nil
    }
}
