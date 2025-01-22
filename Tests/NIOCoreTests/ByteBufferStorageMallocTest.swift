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

import XCTest

@testable import NIOCore

#if canImport(Darwin)
import Darwin

// Tests that ByteBuffer allocates memory in an optimal way depending on the host platform.

final class ByteBufferStorageMallocTest: XCTestCase {

    func testInitialAllocationUsesGoodSize() {
        let allocator = ByteBufferAllocator()
        let requestedCapacity = 1000
        let expectedCapacity = malloc_good_size(requestedCapacity)

        let buffer = allocator.buffer(capacity: requestedCapacity)
        XCTAssertEqual(Int(buffer._storage.capacity), expectedCapacity)
    }

    func testReallocationUsesGoodSize() {
        let allocator = ByteBufferAllocator()
        var buffer = allocator.buffer(capacity: 16)
        let initialCapacity = buffer.capacity

        // Write more bytes than the current capacity to trigger reallocation
        let newSize = initialCapacity + 100
        let expectedCapacity = malloc_good_size(Int(newSize))

        // This will trigger reallocation
        buffer.writeBytes(Array(repeating: UInt8(0), count: Int(newSize)))

        XCTAssertEqual(Int(buffer._storage.capacity), expectedCapacity)
    }

    func testZeroCapacity() {
        let allocator = ByteBufferAllocator()
        let buffer = allocator.buffer(capacity: 0)
        XCTAssertEqual(buffer.capacity, 0)
    }

}
#endif
