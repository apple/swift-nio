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

import NIO
import XCTest

final class AdaptiveRecvByteBufferAllocatorTest: XCTestCase {
    private let allocator = ByteBufferAllocator()
    private var adaptive: AdaptiveRecvByteBufferAllocator!
    private var fixed: FixedSizeRecvByteBufferAllocator!

    override func setUp() {
        self.adaptive = AdaptiveRecvByteBufferAllocator(minimum: 64, initial: 1024, maximum: 16 * 1024)
        self.fixed = FixedSizeRecvByteBufferAllocator(capacity: 1024)
    }

    override func tearDown() {
        self.adaptive = nil
        self.fixed = nil
    }

    func testAdaptive() throws {
        let buffer = self.adaptive.buffer(allocator: self.allocator)
        XCTAssertEqual(1024, buffer.capacity)

        // We double every time.
        self.testActualReadBytes(mayGrow: true, actualReadBytes: 1024, expectedCapacity: 2048)
        self.testActualReadBytes(mayGrow: true, actualReadBytes: 16_384, expectedCapacity: 4096)
        self.testActualReadBytes(mayGrow: true, actualReadBytes: 16_384, expectedCapacity: 8192)
        self.testActualReadBytes(mayGrow: true, actualReadBytes: 16_384, expectedCapacity: 16_384)

        // Will never go over maximum
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 32_768, expectedCapacity: 16_384)

        // Shrinks if two successive reads below half happen
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 4096, expectedCapacity: 16_384)
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 8192, expectedCapacity: 8192)

        self.testActualReadBytes(mayGrow: false, actualReadBytes: 4096, expectedCapacity: 8192)
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 4096, expectedCapacity: 4096)

        // But not if an intermediate read is above half.
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 2048, expectedCapacity: 4096)
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 2049, expectedCapacity: 4096)
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 2048, expectedCapacity: 4096)

        // Or if we grow in-between.
        self.testActualReadBytes(mayGrow: true, actualReadBytes: 4096, expectedCapacity: 8192)
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 4096, expectedCapacity: 8192)
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 4096, expectedCapacity: 4096)

        // Reads above half never shrink the capacity
        for _ in 0 ..< 10 {
            self.testActualReadBytes(mayGrow: false, actualReadBytes: 2049, expectedCapacity: 4096)
        }

        // Consistently reading below half does shrink all the way down.
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 4096)
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 2048)

        self.testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 2048)
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 1024)

        self.testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 1024)
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 512)

        self.testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 512)
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 256)

        self.testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 256)
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 128)

        self.testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 128)
        self.testActualReadBytes(mayGrow: false, actualReadBytes: 64, expectedCapacity: 64)

        // Until the bottom, where it stays forever.
        for _ in 0 ..< 10 {
            self.testActualReadBytes(mayGrow: false, actualReadBytes: 1, expectedCapacity: 64)
        }
    }

    private func testActualReadBytes(mayGrow: Bool, actualReadBytes: Int, expectedCapacity: Int, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(mayGrow, self.adaptive.record(actualReadBytes: actualReadBytes), "unexpected value for mayGrow", file: file, line: line)
        let buffer = self.adaptive.buffer(allocator: self.allocator)
        XCTAssertEqual(expectedCapacity, buffer.capacity, "unexpected capacity", file: file, line: line)
    }

    func testFixed() throws {
        var buffer = self.fixed.buffer(allocator: self.allocator)
        XCTAssertEqual(self.fixed.capacity, buffer.capacity)
        XCTAssert(!self.fixed.record(actualReadBytes: 32_768))
        buffer = self.fixed.buffer(allocator: self.allocator)
        XCTAssertEqual(self.fixed.capacity, buffer.capacity)
        XCTAssert(!self.fixed.record(actualReadBytes: 64))
        buffer = self.fixed.buffer(allocator: self.allocator)
        XCTAssertEqual(self.fixed.capacity, buffer.capacity)
    }

    func testMaxAllocSizeIsIntMax() {
        // To find the max alloc size, we're going to search for a fixed point in resizing. To do that we're just going to
        // keep saying we read max until we can't resize any longer.
        self.adaptive = AdaptiveRecvByteBufferAllocator(minimum: 0, initial: .max / 2, maximum: .max)
        var mayGrow = true
        while mayGrow {
            mayGrow = self.adaptive.record(actualReadBytes: .max)
        }

        let buffer = self.adaptive.buffer(allocator: self.allocator)
        XCTAssertEqual(buffer.capacity, 1 << 30)
        XCTAssertEqual(self.adaptive.maximum, 1 << 30)
        XCTAssertEqual(self.adaptive.minimum, 0)
    }

    func testAdaptiveRoundsValues() {
        let adaptive = AdaptiveRecvByteBufferAllocator(minimum: 9, initial: 677, maximum: 111_111)
        XCTAssertEqual(adaptive.minimum, 8)
        XCTAssertEqual(adaptive.maximum, 131_072)
        XCTAssertEqual(adaptive.initial, 512)
    }

    func testSettingMinimumAboveMaxAllowed() {
        guard let targetValue = Int(exactly: Int64.max / 2) else {
            // On a 32-bit word platform, this test cannot do anything sensible.
            return
        }

        let adaptive = AdaptiveRecvByteBufferAllocator(minimum: targetValue, initial: targetValue + 1, maximum: targetValue + 2)
        XCTAssertEqual(adaptive.minimum, 1 << 30)
        XCTAssertEqual(adaptive.maximum, 1 << 30)
        XCTAssertEqual(adaptive.initial, 1 << 30)
    }
}
