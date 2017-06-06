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
    var buf: ByteBuffer!
    
    override func setUp() {
        super.setUp()
        buf = try! allocator.buffer(capacity: 1024)
    }
    
    func testWrappedData() {
        let data = "Test".data(using: .utf8)!
        let buffer = allocator.buffer(wrapped: data)
        XCTAssertEqual(0, buffer.readerIndex)
        XCTAssertEqual(data.count, buffer.writerIndex)
    }
    
    func testSimpleReadTest() throws {
        buf.withReadPointer(body: { ptr, size in
            XCTAssertEqual(size, 0)
        })
        
        buf.write(string: "Hello world!")
        buf.withReadPointer(body: { ptr, size in XCTAssertEqual(12, size) })
    }

    func testWriteStringMovesWriterIndex() {
        var buf = try! allocator.buffer(capacity: 1024)
        buf.write(string: "hello")
        XCTAssertEqual(5, buf.writerIndex)
        let _ = buf.withMutableReadPointer { ptr, size in
            let s = String(bytesNoCopy: ptr, length: size, encoding: .utf8, freeWhenDone: false)
            XCTAssertEqual("hello", s)
            return 0
        }
    }

    func testMarkedReaderAndWriterIndicies0ByDefault() {
        XCTAssertEqual(0, buf.markedReaderIndex)
        XCTAssertEqual(0, buf.markedWriterIndex)
    }
    
    func testResetWriterIndex() {
        buf.write(string: "hello")
        XCTAssertEqual(5, buf.writerIndex)
        buf.markWriterIndex()
        buf.write(string: " world!")
        XCTAssertEqual(12, buf.writerIndex)
        buf.resetWriterIndex()
        XCTAssertEqual(5, buf.writerIndex)
    }
    
    func testResetReaderIndex() {
        buf.write(string: "hello")
        let bytesConsumed = buf.withMutableReadPointer { _,_ in return 5 }
        
        XCTAssertEqual(5, bytesConsumed)
        XCTAssertEqual(bytesConsumed, buf.readerIndex)
        buf.resetReaderIndex()
        XCTAssertEqual(0, buf.readerIndex)
    }
    
    func testWithMutableReadPointerMovesReaderIndexAndReturnsNumBytesConsumed() {
        XCTAssertEqual(0, buf.readerIndex)
        // We use mutable read pointers when we're consuming the data
        // so first we need some data there!
        buf.write(string: "hello again")
        
        let bytesConsumed = buf.withMutableReadPointer(body: { dst, size in
            // Pretend we did some operation which made use of entire 11 byte string
            return 11
        })
        XCTAssertEqual(11, bytesConsumed)
        XCTAssertEqual(11, buf.readerIndex)
    }

    func testWithMutableWritePointerMovesWriterIndexAndReturnsNumBytesWritten() {
        XCTAssertEqual(0, buf.writerIndex)
        
        let bytesWritten = buf.withMutableWritePointer { _, _ in return 5 }
        XCTAssertEqual(5, bytesWritten)
        XCTAssertEqual(5, buf.writerIndex)
    }
    
    func testEnsureWritableWithEnoughBytesDoesntExpand() {
        let result = buf.ensureWritable(bytesNeeded: buf.capacity - 1, expandIfRequired: true)
        XCTAssert(result.enoughSpace)
        XCTAssertFalse(result.capacityIncreased)
    }
    
    func testEnsureWritableWithNotEnoughBytesButNotAllowedToExpand() {
        let result = buf.ensureWritable(bytesNeeded: buf.capacity + 1, expandIfRequired: false)
        XCTAssertFalse(result.enoughSpace)
        XCTAssertFalse(result.capacityIncreased)
    }
    
    func testEnsureWritableWithNotEnoughBytesButAllowedToExpand() {
        let result = buf.ensureWritable(bytesNeeded: buf.capacity + 1, expandIfRequired: true)
        XCTAssertTrue(result.enoughSpace)
        XCTAssertTrue(result.capacityIncreased)
    }
    
    func testEnsureWritableWithNotEnoughBytesAndNotEnoughMaxCapacity() throws {
        buf = try! allocator.buffer(capacity: 10, maxCapacity: 10)
        let result = buf.ensureWritable(bytesNeeded: buf.capacity + 1, expandIfRequired: true)
        XCTAssertFalse(result.enoughSpace)
        XCTAssertFalse(result.capacityIncreased)
    }
    
    func testEnsureWritableThrowsWhenExpansionNotExplicitlyAllowed() {
        XCTAssertThrowsError(try buf.ensureWritable(bytesNeeded: buf.capacity + 1))
    }
    
    func testEnsureWritableDoesntThrowWhenEnoughSpaceEvenIfNotExplicitlyAllowingExpansion() {
        XCTAssertNoThrow(try buf.ensureWritable(bytesNeeded: buf.capacity - 1))
    }
    
    func testChangeCapacityWhenEnoughAvailable() throws {
        XCTAssertNoThrow(try buf.changeCapacity(to: buf.capacity - 1))
    }
    
    func testChangeCapacityWhenNotEnoughMaxCapacity() throws {
        buf = try! allocator.buffer(capacity: 10, maxCapacity: 10)
        XCTAssertThrowsError(try buf.changeCapacity(to: buf.capacity + 1))
    }
    
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
        
        XCTAssertEqual(MemoryLayout<T>.size, buffer.set(integer: v, at: index))
        XCTAssertEqual(v, buffer.get(at: index))
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
        XCTAssertEqual(MemoryLayout<T>.size, buffer.write(integer: v))
        XCTAssertEqual(MemoryLayout<T>.size, buffer.writerIndex)
        
        XCTAssertEqual(v, buffer.read())
        XCTAssertEqual(0, buffer.readableBytes)
    }
    
    func testSlice() throws {
        var buffer = try allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.write(integer: UInt64.max))
        var slice = buffer.slice()
        XCTAssertEqual(MemoryLayout<UInt64>.size, slice.readableBytes)
        XCTAssertEqual(UInt64.max, slice.read())
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.readableBytes)
        XCTAssertEqual(UInt64.max, buffer.read())
    }
    
    func testSliceWithParams() throws {
        var buffer = try allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.write(integer: UInt64.max))
        var slice = buffer.slice(from: 0, length: MemoryLayout<UInt64>.size)!
        XCTAssertEqual(MemoryLayout<UInt64>.size, slice.readableBytes)
        XCTAssertEqual(UInt64.max, slice.read())
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.readableBytes)
        XCTAssertEqual(UInt64.max, buffer.read())
    }
    
    func testReadSlice() throws {
        var buffer = try allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.write(integer: UInt64.max))
        var slice = buffer.readSlice(length: buffer.readableBytes)!
        XCTAssertEqual(MemoryLayout<UInt64>.size, slice.readableBytes)
        XCTAssertEqual(UInt64.max, slice.read())
        XCTAssertEqual(0, buffer.readableBytes)
        let value: UInt64? = buffer.read()
        XCTAssertTrue(value == nil)
    }
    
    func testSliceNoCopy() throws {
        var buffer = try allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.write(integer: UInt64.max))
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
        
        XCTAssertEqual(3, buffer.set(data: data, at: 0))
        XCTAssertEqual(0, buffer.readableBytes)
        XCTAssertEqual(data, buffer.get(at: 0, length: 3))
    }
    
    
    func testWriteReadData() throws {
        var buffer = try allocator.buffer(capacity: 32)
        let data = Data(bytes: [1, 2, 3])
        
        XCTAssertEqual(3, buffer.write(data: data))
        XCTAssertEqual(3, buffer.readableBytes)
        XCTAssertEqual(data, buffer.read(length: 3))
    }
    
    func testDiscardReadBytes() throws {
        var buffer = try allocator.buffer(capacity: 32)
        buffer.write(integer: UInt8(1))
        buffer.write(integer: UInt8(2))
        buffer.write(integer: UInt8(3))
        buffer.write(integer: UInt8(4))
        XCTAssertEqual(4, buffer.readableBytes)
        buffer.skipBytes(num: 2)
        XCTAssertEqual(2, buffer.readableBytes)
        XCTAssertEqual(2, buffer.readerIndex)
        XCTAssertEqual(4, buffer.writerIndex)
        XCTAssertTrue(buffer.discardReadBytes())
        XCTAssertEqual(2, buffer.readableBytes)
        XCTAssertEqual(0, buffer.readerIndex)
        XCTAssertEqual(2, buffer.writerIndex)
        XCTAssertEqual(UInt8(3), buffer.read())
        XCTAssertEqual(UInt8(4), buffer.read())
        XCTAssertEqual(0, buffer.readableBytes)
        XCTAssertTrue(buffer.discardReadBytes())
        XCTAssertFalse(buffer.discardReadBytes())
    }
    
    
    func testDiscardReadBytesSlice() throws {
        var buffer = try allocator.buffer(capacity: 32)
        buffer.write(integer: UInt8(1))
        buffer.write(integer: UInt8(2))
        buffer.write(integer: UInt8(3))
        buffer.write(integer: UInt8(4))
        XCTAssertEqual(4, buffer.readableBytes)
        var slice = buffer.slice(from: 1, length: 3)!
        XCTAssertEqual(3, slice.readableBytes)
        XCTAssertEqual(0, slice.readerIndex)

        slice.skipBytes(num: 1)
        XCTAssertEqual(2, slice.readableBytes)
        XCTAssertEqual(1, slice.readerIndex)
        XCTAssertEqual(3, slice.writerIndex)
        XCTAssertTrue(slice.discardReadBytes())
        XCTAssertEqual(2, slice.readableBytes)
        XCTAssertEqual(0, slice.readerIndex)
        XCTAssertEqual(2, slice.writerIndex)
        XCTAssertEqual(UInt8(3), slice.read())
        XCTAssertEqual(UInt8(4), slice.read())
        XCTAssertEqual(0,slice.readableBytes)
        XCTAssertTrue(slice.discardReadBytes())
        XCTAssertFalse(slice.discardReadBytes())
    }

    func testWithDataSlices() throws {
        let testStringPrefix = "0123456789"
        let testStringSuffix = "abcdef"
        let testString = "\(testStringPrefix)\(testStringSuffix)"

        var buffer = try allocator.buffer(capacity: testString.utf8.count)
        buffer.write(string: testStringPrefix)
        buffer.write(string: testStringSuffix)
        XCTAssertEqual(testString.utf8.count, buffer.capacity)

        func runTestForRemaining(string: String, buffer: ByteBuffer) {
            buffer.withReadPointer { (ptr, len) -> Void in
                XCTAssertEqual(string.utf8.count, len)

                for (idx, expected) in zip(0..<string.utf8.count, string.utf8) {
                    let actual = ptr.advanced(by: idx).pointee
                    XCTAssertEqual(expected, actual, "character at index \(idx) is \(actual) but should be \(expected)")
                }
            }

            buffer.withReadDataSlice { data -> Void in
                XCTAssertEqual(string.utf8.count, data.count)
                for (idx, expected) in zip(data.startIndex..<data.startIndex+string.utf8.count, string.utf8) {
                    XCTAssertEqual(expected, data[idx])
                }
            }

            buffer.withReadDataSlice { slice in
                XCTAssertEqual(string, String(bytes: slice, encoding: .utf8))
            }
        }

        runTestForRemaining(string: testString, buffer: buffer)
        let prefixBuffer = buffer.readSlice(length: testStringPrefix.utf8.count)
        XCTAssertNotNil(prefixBuffer)
        if let prefixBuffer = prefixBuffer {
            runTestForRemaining(string: testStringPrefix, buffer: prefixBuffer)
        }
        runTestForRemaining(string: testStringSuffix, buffer: buffer)
    }
}
