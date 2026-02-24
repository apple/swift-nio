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
import XCTest

@testable import NIOPosix

internal final class NIOPooledRecvBufferAllocatorTests: XCTestCase {
    func testPoolFillsToCapacity() {
        let allocator = ByteBufferAllocator()
        var pool = NIOPooledRecvBufferAllocator(
            capacity: 3,
            recvAllocator: FixedSizeRecvByteBufferAllocator(capacity: 1024)
        )
        XCTAssertEqual(pool.count, 0)
        XCTAssertEqual(pool.capacity, 3)

        // The pool recycles buffers which are unique. Store each buffer to ensure that's not the
        // case.
        let buffers: [ByteBuffer] = (1...pool.capacity).map { i in
            let (buffer, _) = pool.buffer(allocator: allocator) {
                XCTAssertEqual($0.readableBytes, 0)
                XCTAssertEqual($0.writableBytes, 1024)
            }
            return buffer
        }

        let bufferIDs = Set(buffers.map { $0.storagePointerIntegerValue() })
        XCTAssertEqual(buffers.count, bufferIDs.count)

        // Keep the buffers alive.
        withExtendedLifetime(buffers) {
            for _ in 1...pool.capacity {
                let (buffer, _) = pool.buffer(allocator: allocator) {
                    XCTAssertEqual($0.readableBytes, 0)
                    XCTAssertEqual($0.writableBytes, 1024)
                }
                XCTAssertEqual(pool.count, pool.capacity)
                XCTAssertFalse(bufferIDs.contains(buffer.storagePointerIntegerValue()))
            }
        }
    }

    func testBuffersAreRecycled() {
        let allocator = ByteBufferAllocator()
        var pool = NIOPooledRecvBufferAllocator(
            capacity: 5,
            recvAllocator: FixedSizeRecvByteBufferAllocator(capacity: 1024)
        )

        let (_, storageID) = pool.buffer(allocator: allocator) { buffer in
            buffer.storagePointerIntegerValue()
        }

        XCTAssertEqual(pool.count, 1)

        for _ in 0..<100 {
            _ = pool.buffer(allocator: allocator) { buffer in
                XCTAssertEqual(buffer.storagePointerIntegerValue(), storageID)
            }
            XCTAssertEqual(pool.count, 1)
        }
    }

    func testFirstAvailableBufferUsed() {
        let allocator = ByteBufferAllocator()
        var pool = NIOPooledRecvBufferAllocator(
            capacity: 3,
            recvAllocator: FixedSizeRecvByteBufferAllocator(capacity: 1024)
        )

        var buffers: [ByteBuffer] = (0..<pool.capacity).map { _ in
            let (buffer, _) = pool.buffer(allocator: allocator) { _ in }
            return buffer
        }

        let bufferIDs = Set(buffers.map { $0.storagePointerIntegerValue() })
        XCTAssertEqual(bufferIDs.count, pool.capacity)

        // Drop the ref to the middle buffer.
        buffers.remove(at: 1)

        _ = pool.buffer(allocator: allocator) { buffer in
            XCTAssert(bufferIDs.contains(buffer.storagePointerIntegerValue()))
        }
    }

    func testBuffersAreClearedBetweenCalls() {
        let allocator = ByteBufferAllocator()
        var pool = NIOPooledRecvBufferAllocator(
            capacity: 3,
            recvAllocator: FixedSizeRecvByteBufferAllocator(capacity: 1024)
        )

        // The pool recycles buffers which are unique. Store each buffer to ensure that's not the
        // case.
        var buffers: [ByteBuffer] = (1...pool.capacity).map { i in
            let (buffer, _) = pool.buffer(allocator: allocator) {
                $0.writeRepeatingByte(42, count: 1024)
            }
            return buffer
        }

        // Grab the storage pointers; check against them below.
        var storagePointers = Set(buffers.map { $0.storagePointerIntegerValue() })
        XCTAssertEqual(storagePointers.count, pool.capacity)

        // Drop the buffer storage refs so they can be reused.
        buffers.removeAll()

        // Loop of the pool again.
        var moreBuffers: [ByteBuffer] = storagePointers.map { pointerValue in
            let (buffer, _) = pool.buffer(allocator: allocator) {
                let storagePointer = $0.storagePointerIntegerValue()
                XCTAssertNotNil(storagePointers.remove(storagePointer))
                XCTAssertEqual($0.readerIndex, 0)
                XCTAssertEqual($0.writerIndex, 0)
            }
            return buffer
        }
        moreBuffers.removeAll()
    }

    func testPoolCapacityIncrease() {
        let allocator = ByteBufferAllocator()
        var pool = NIOPooledRecvBufferAllocator(
            capacity: 3,
            recvAllocator: FixedSizeRecvByteBufferAllocator(capacity: 1024)
        )

        // Fill the pool.
        let buffers: [ByteBuffer] = (0..<pool.capacity).map { _ in
            let (buffer, _) = pool.buffer(allocator: allocator) { _ in }
            return buffer
        }
        XCTAssertEqual(pool.capacity, 3)
        XCTAssertEqual(pool.count, 3)

        // Increase the capacity.
        pool.updateCapacity(to: 8)
        XCTAssertEqual(pool.capacity, 8)
        XCTAssertEqual(pool.count, 3)

        // Fill the pool.
        let moreBuffers: [ByteBuffer] = (pool.count..<pool.capacity).map { _ in
            let (buffer, _) = pool.buffer(allocator: allocator) { _ in }
            return buffer
        }

        XCTAssertEqual(pool.count, 8)
        XCTAssertEqual(pool.capacity, 8)

        var ids = Set(buffers.map { $0.storagePointerIntegerValue() })
        for buffer in moreBuffers {
            ids.insert(buffer.storagePointerIntegerValue())
        }
        XCTAssertEqual(ids.count, pool.count)
    }

    func testPoolCapacityDecrease() {
        let allocator = ByteBufferAllocator()
        var pool = NIOPooledRecvBufferAllocator(
            capacity: 5,
            recvAllocator: FixedSizeRecvByteBufferAllocator(capacity: 1024)
        )

        // Fill the pool.
        var buffers: [ByteBuffer] = []
        for _ in (0..<pool.capacity) {
            let (buffer, _) = pool.buffer(allocator: allocator) { _ in }
            buffers.append(buffer)
        }
        XCTAssertEqual(pool.count, 5)
        XCTAssertEqual(pool.capacity, 5)

        // Reduce the capacity.
        pool.updateCapacity(to: 3)
        XCTAssertEqual(pool.count, 3)
        XCTAssertEqual(pool.capacity, 3)
    }
}

extension Array where Element == ByteBuffer {
    fileprivate func allHaveUniqueStorage() -> Bool {
        self.count == Set(self.map { $0.storagePointerIntegerValue() }).count
    }
}
