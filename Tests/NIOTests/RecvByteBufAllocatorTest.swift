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

import Foundation
import XCTest
import NIO

public class AdaptiveRecvByteBufferAllocatorTest : XCTestCase {
    private let allocator = ByteBufferAllocator()
    private var adaptive = AdaptiveRecvByteBufferAllocator(minimum: 64, initial: 1024, maximum: 16 * 1024)
    private var fixed = FixedSizeRecvByteBufferAllocator(capacity: 1024)

    func testAdaptive() throws {
        let buffer = try adaptive.buffer(allocator: allocator)
        XCTAssertEqual(1024, buffer.capacity)
        
        try testActualReadBytes(actualReadBytes: 1024, expectedCapacity: 16384)
        try testActualReadBytes(actualReadBytes: 16384, expectedCapacity: 16384)
        
        // Will never go over maximum
        try testActualReadBytes(actualReadBytes: 32768, expectedCapacity: 16384)

        try testActualReadBytes(actualReadBytes: 4096, expectedCapacity: 16384)
        try testActualReadBytes(actualReadBytes: 8192, expectedCapacity: 16384)
        try testActualReadBytes(actualReadBytes: 4096, expectedCapacity: 8192)
        try testActualReadBytes(actualReadBytes: 4096, expectedCapacity: 8192)

        try testActualReadBytes(actualReadBytes: 64, expectedCapacity: 8192)
        try testActualReadBytes(actualReadBytes: 64, expectedCapacity: 4096)
        try testActualReadBytes(actualReadBytes: 64, expectedCapacity: 4096)

        try testActualReadBytes(actualReadBytes: 64, expectedCapacity: 2048)
        try testActualReadBytes(actualReadBytes: 64, expectedCapacity: 2048)

        try testActualReadBytes(actualReadBytes: 64, expectedCapacity: 1024)
        try testActualReadBytes(actualReadBytes: 64, expectedCapacity: 1024)
        
        try testActualReadBytes(actualReadBytes: 64, expectedCapacity: 512)
        try testActualReadBytes(actualReadBytes: 64, expectedCapacity: 512)

        try testActualReadBytes(actualReadBytes: 32, expectedCapacity: 512)
        try testActualReadBytes(actualReadBytes: 32, expectedCapacity: 512)
    }
    
    private func testActualReadBytes(actualReadBytes: Int, expectedCapacity: Int) throws {
        adaptive.record(actualReadBytes: actualReadBytes)
        let buffer = try adaptive.buffer(allocator: allocator)
        XCTAssertEqual(expectedCapacity, buffer.capacity)
    }
    
    func testFixed() throws {
        var buffer = try fixed.buffer(allocator: allocator)
        XCTAssertEqual(fixed.capacity, buffer.capacity)
        fixed.record(actualReadBytes: 32768)
        buffer = try fixed.buffer(allocator: allocator)
        XCTAssertEqual(fixed.capacity, buffer.capacity)
        fixed.record(actualReadBytes: 64)
        buffer = try fixed.buffer(allocator: allocator)
        XCTAssertEqual(fixed.capacity, buffer.capacity)
    }
}
