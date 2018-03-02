//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIO

public class AdaptiveRecvByteBufferAllocatorTest : XCTestCase {
    private let allocator = ByteBufferAllocator()
    private var adaptive = AdaptiveRecvByteBufferAllocator(minimum: 64, initial: 1024, maximum: 16 * 1024)
    private var fixed = FixedSizeRecvByteBufferAllocator(capacity: 1024)

    func testAdaptive() throws {
        let buffer = adaptive.buffer(allocator: allocator)
        XCTAssertEqual(1024, buffer.capacity)

        testActualReadBytes(mayGrow: false, actualReadBytes: 1024, expectedCapacity: 16384)
        testActualReadBytes(mayGrow: true, actualReadBytes: 16384, expectedCapacity: 16384)

        // Will never go over maximum
        testActualReadBytes(mayGrow: true, actualReadBytes: 32768, expectedCapacity: 16384)

        testActualReadBytes(mayGrow: false, actualReadBytes: 4096, expectedCapacity: 16384)
        testActualReadBytes(mayGrow: false, actualReadBytes: 8192, expectedCapacity: 16384)
        testActualReadBytes(mayGrow: false, actualReadBytes: 4096, expectedCapacity: 8192)
        testActualReadBytes(mayGrow: false, actualReadBytes: 4096, expectedCapacity: 8192)

        testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 8192)
        testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 4096)
        testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 4096)

        testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 2048)
        testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 2048)

        testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 1024)
        testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 1024)

        testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 512)
        testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 512)

        testActualReadBytes(mayGrow: false, actualReadBytes: 32, expectedCapacity: 512)
        testActualReadBytes(mayGrow: false, actualReadBytes: 32, expectedCapacity: 512)
    }

    private func testActualReadBytes(mayGrow: Bool, actualReadBytes: Int, expectedCapacity: Int) {
        XCTAssertEqual(mayGrow, adaptive.record(actualReadBytes: actualReadBytes))
        let buffer = adaptive.buffer(allocator: allocator)
        XCTAssertEqual(expectedCapacity, buffer.capacity)
    }

    func testFixed() throws {
        var buffer = fixed.buffer(allocator: allocator)
        XCTAssertEqual(fixed.capacity, buffer.capacity)
        XCTAssert(!fixed.record(actualReadBytes: 32768))
        buffer = fixed.buffer(allocator: allocator)
        XCTAssertEqual(fixed.capacity, buffer.capacity)
        XCTAssert(!fixed.record(actualReadBytes: 64))
        buffer = fixed.buffer(allocator: allocator)
        XCTAssertEqual(fixed.capacity, buffer.capacity)
    }
}
