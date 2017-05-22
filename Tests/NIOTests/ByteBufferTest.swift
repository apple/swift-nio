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
@testable import NIO

class ByteBufferTest: XCTestCase {
    let allocator = ByteBufferAllocator()

    func testSetGetInt8() throws {
        try setGetInt(index: 0, v: Int8.max)
    }
    
    func testSetGetInt16() throws {
        try setGetInt(index: 1, v: Int16.max)
    }
    
    func testSetGetInt32() throws {
        try setGetInt(index: 2, v: Int32.max)
    }
    
    func testSetGetInt64() throws {
        try setGetInt(index: 3, v: Int64.max)
    }
    
    func testSetGetUInt8() throws {
        try setGetInt(index: 4, v: UInt8.max)
    }
    
    func testSetGetUInt16() throws {
        try setGetInt(index: 5, v: UInt16.max)
    }
    
    func testSetGetUInt32() throws {
        try setGetInt(index: 6, v: UInt32.max)
    }
    
    func testSetGetUInt64() throws {
        try setGetInt(index: 7, v: UInt64.max)
    }
    
    private func setGetInt<T: EndianessInteger>(index: Int, v: T) throws {
        var buffer = try allocator.buffer(capacity: 32)
        
        XCTAssertEqual(MemoryLayout<T>.size, buffer.setInteger(index: index, value: v))
        XCTAssertEqual(v, buffer.getInteger(index: index))
    }
    
    func testWriteReadInt8() throws {
        try writeReadInt(v: Int8.max)
    }

    func testWriteReadInt16() throws {
        try writeReadInt(v: Int16.max)
    }
    
    func testWriteReadInt32() throws {
        try writeReadInt(v: Int32.max)
    }
    
    func testWriteReadInt64() throws {
        try writeReadInt(v: Int32.max)
    }
    
    func testWriteReadUInt8() throws {
        try writeReadInt(v: UInt8.max)
    }
    
    func testWriteReadUInt16() throws {
        try writeReadInt(v: UInt16.max)
    }
    
    func testWriteReadUInt32() throws {
        try writeReadInt(v: UInt32.max)
    }
    
    func testWriteReadUInt64() throws {
        try writeReadInt(v: UInt32.max)
    }
    
    private func writeReadInt<T: EndianessInteger>(v: T) throws {
        var buffer = try allocator.buffer(capacity: 32)
        XCTAssertEqual(0, buffer.writerIndex)
        XCTAssertEqual(MemoryLayout<T>.size, buffer.writeInteger(value: v))
        XCTAssertEqual(MemoryLayout<T>.size, buffer.writerIndex)
        
        XCTAssertEqual(v, buffer.readInteger())
        XCTAssertEqual(0, buffer.readableBytes)
    }
    
    func testSlice() throws {
        var buffer = try allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.writeInteger(value: UInt64.max))
        var slice = buffer.slice()
        XCTAssertEqual(MemoryLayout<UInt64>.size, slice.readableBytes)
        XCTAssertEqual(UInt64.max, slice.readInteger())
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.readableBytes)
        XCTAssertEqual(UInt64.max, buffer.readInteger())
    }
    
    func testSliceWithParams() throws {
        var buffer = try allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.writeInteger(value: UInt64.max))
        var slice = buffer.slice(from: 0, length: MemoryLayout<UInt64>.size)!
        XCTAssertEqual(MemoryLayout<UInt64>.size, slice.readableBytes)
        XCTAssertEqual(UInt64.max, slice.readInteger())
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.readableBytes)
        XCTAssertEqual(UInt64.max, buffer.readInteger())
    }
    
    func testReadSlice() throws {
        var buffer = try allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.writeInteger(value: UInt64.max))
        var slice = buffer.readSlice(length: buffer.readableBytes)!
        XCTAssertEqual(MemoryLayout<UInt64>.size, slice.readableBytes)
        XCTAssertEqual(UInt64.max, slice.readInteger())
        XCTAssertEqual(0, buffer.readableBytes)
        let value: UInt64? = buffer.readInteger()
        XCTAssertTrue(value == nil)
    }
    
    func testSliceNoCopy() throws {
        var buffer = try allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.writeInteger(value: UInt64.max))
        let slice = buffer.readSlice(length: buffer.readableBytes)!
    
        buffer.data.withUnsafeBytes { (ptr1: UnsafePointer<UInt8>) -> Void in
            slice.data.withUnsafeBytes({ (ptr2: UnsafePointer<UInt8>) -> Void in
                XCTAssertEqual(ptr1, ptr2)
            })
        }
    }
    
    func testSetGetData() throws {
        var buffer = try allocator.buffer(capacity: 32)
        let data = Data(bytes: [1, 2, 3])
        
        XCTAssertEqual(3, buffer.setData(index: 0, value: data))
        XCTAssertEqual(0, buffer.readableBytes)
        XCTAssertEqual(data, buffer.getData(index: 0, length: 3))
    }
    
    
    func testWriteReadData() throws {
        var buffer = try allocator.buffer(capacity: 32)
        let data = Data(bytes: [1, 2, 3])
        
        XCTAssertEqual(3, buffer.writeData(value: data))
        XCTAssertEqual(3, buffer.readableBytes)
        XCTAssertEqual(data, buffer.readData(length: 3))
    }
}
