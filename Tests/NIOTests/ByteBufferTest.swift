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

import struct Foundation.Data
import XCTest
@testable import NIO

class ByteBufferTest: XCTestCase {
    private let allocator = ByteBufferAllocator()
    private var buf: ByteBuffer! = nil

    private func setGetInt<T: FixedWidthInteger>(index: Int, v: T) throws {
        var buffer = allocator.buffer(capacity: 32)

        XCTAssertEqual(MemoryLayout<T>.size, buffer.set(integer: v, at: index))
        XCTAssertEqual(v, buffer.getInteger(at: index))
    }

    private func writeReadInt<T: FixedWidthInteger>(v: T) throws {
        var buffer = allocator.buffer(capacity: 32)
        XCTAssertEqual(0, buffer.writerIndex)
        XCTAssertEqual(MemoryLayout<T>.size, buffer.write(integer: v))
        XCTAssertEqual(MemoryLayout<T>.size, buffer.writerIndex)

        XCTAssertEqual(v, buffer.readInteger())
        XCTAssertEqual(0, buffer.readableBytes)
    }
    
    override func setUp() {
        super.setUp()

        buf = allocator.buffer(capacity: 1024)
        buf = buf.getSlice(at: 256, length: 512)
        buf.clear()
    }

    override func tearDown() {
        buf = nil

        super.tearDown()
    }

    func testAllocateAndCount() {
        let b = allocator.buffer(capacity: 1024)
        XCTAssertEqual(1024, b.capacity)
    }

    func testEqualsComparesReadBuffersOnly() throws {
        // Only cares about the read buffer
        buf.write(integer: Int8.max)
        buf.write(string: "oh hi")
        let actual: Int8 = buf.readInteger()! // Just getting rid of it from the read buffer
        XCTAssertEqual(Int8.max, actual)

        var otherBuffer = allocator.buffer(capacity: 32)
        otherBuffer.write(string: "oh hi")
        XCTAssertEqual(otherBuffer, buf)
    }
    
    func testSimpleReadTest() throws {
        buf.withUnsafeReadableBytes { ptr in
            XCTAssertEqual(ptr.count, 0)
        }
        
        buf.write(string: "Hello world!")
        buf.withUnsafeReadableBytes { ptr in
            XCTAssertEqual(12, ptr.count)
        }
    }

    func testSimpleWrites() {
        var written = buf.write(string: "")
        XCTAssertEqual(0, written)
        XCTAssertEqual(0, buf.readableBytes)

        written = buf.write(string: "X")
        XCTAssertEqual(1, written)
        XCTAssertEqual(1, buf.readableBytes)

        written = buf.write(string: "XXXXX")
        XCTAssertEqual(5, written)
        XCTAssertEqual(6, buf.readableBytes)
    }

    func testReadWrite() {
        buf.write(string: "X")
        buf.write(string: "Y")
        let d = buf.readData(length: 1)
        XCTAssertNotNil(d)
        if let d = d {
            XCTAssertEqual(1, d.count)
            XCTAssertEqual("X".utf8.first!, d.first!)
        }
    }

    func testStaticStringReadTests() throws {
        var allBytes = 0
        for testString in ["", "Hello world!", "👍", "🇬🇧🇺🇸🇪🇺"] as [StaticString] {
            buf.withUnsafeReadableBytes { ptr in
                XCTAssertEqual(0, ptr.count)
            }
            XCTAssertEqual(0, buf.readableBytes)
            XCTAssertEqual(allBytes, buf.readerIndex)

            let bytes = buf.write(staticString: testString)
            XCTAssertEqual(testString.utf8CodeUnitCount, Int(bytes))
            allBytes += bytes
            XCTAssertEqual(allBytes - bytes, buf.readerIndex)

            let expected = testString.withUTF8Buffer { buf in
                String(decoding: buf, as: UTF8.self)
            }
            buf.withUnsafeReadableBytes { ptr in
                let actual = String(decoding: ptr, as: UTF8.self)
                XCTAssertEqual(expected, actual)
            }
            let d = buf.readData(length: testString.utf8CodeUnitCount)
            XCTAssertEqual(allBytes, buf.readerIndex)
            XCTAssertNotNil(d)
            XCTAssertEqual(d?.count, testString.utf8CodeUnitCount)
            XCTAssertEqual(expected, String(decoding: d!, as: UTF8.self))
        }
    }
    
    func testString() {
        let written = buf.write(string: "Hello")!
        let string = buf.string(at: 0, length: written)
        XCTAssertEqual("Hello", string)
    }
    
    func testSliceEasy() {
        buf.write(string: "0123456789abcdefg")
        for i in 0..<16 {
            let slice = buf.getSlice(at: i, length: 1)
            XCTAssertEqual(1, slice?.capacity)
            XCTAssertEqual(buf.getData(at: i, length: 1), slice?.getData(at: 0, length: 1))
        }
    }

    func testWriteStringMovesWriterIndex() throws {
        var buf = allocator.buffer(capacity: 1024)
        buf.write(string: "hello")
        XCTAssertEqual(5, buf.writerIndex)
        let _ = buf.withUnsafeReadableBytes { (ptr: UnsafeRawBufferPointer) -> Int in
            let s = String(decoding: ptr, as: UTF8.self)
            XCTAssertEqual("hello", s)
            return 0
        }
    }
    
    func testSetExpandsBufferOnUpperBoundsCheckFailure() {
        let initialCapacity = buf.capacity
        XCTAssertEqual(5, buf.set(string: "oh hi", at: buf.capacity))
        XCTAssert(initialCapacity < buf.capacity)
    }

    func testCoWWorks() {
        buf.write(string: "Hello")
        var a = buf!
        let b = buf!
        a.write(string: " World")
        XCTAssertEqual(buf, b)
        XCTAssertNotEqual(buf, a)
    }
    
    func testWithMutableReadPointerMovesReaderIndexAndReturnsNumBytesConsumed() {
        XCTAssertEqual(0, buf.readerIndex)
        // We use mutable read pointers when we're consuming the data
        // so first we need some data there!
        buf.write(string: "hello again")
        
        let bytesConsumed = buf.readWithUnsafeReadableBytes { dst in
            // Pretend we did some operation which made use of entire 11 byte string
            return 11
        }
        XCTAssertEqual(11, bytesConsumed)
        XCTAssertEqual(11, buf.readerIndex)
    }

    func testWithMutableWritePointerMovesWriterIndexAndReturnsNumBytesWritten() {
        XCTAssertEqual(0, buf.writerIndex)
        
        let bytesWritten = buf.writeWithUnsafeMutableBytes { _ in return 5 }
        XCTAssertEqual(5, bytesWritten)
        XCTAssertEqual(5, buf.writerIndex)
    }
    
    func testChangeCapacityWhenEnoughAvailable() throws {
        let oldCapacity = buf.capacity
        buf.changeCapacity(to: buf.capacity - 1)
        XCTAssertLessThanOrEqual(buf.capacity, oldCapacity)
    }
    
    func testChangeCapacityWhenNotEnoughMaxCapacity() throws {
        buf = allocator.buffer(capacity: 16)
        let oldCapacity = buf.capacity
        buf.changeCapacity(to: buf.capacity + 1)
        XCTAssertGreaterThan(buf.capacity, oldCapacity)
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
    
    func testSlice() throws {
        var buffer = allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.write(integer: UInt64.max))
        var slice = buffer.slice()
        XCTAssertEqual(MemoryLayout<UInt64>.size, slice.readableBytes)
        XCTAssertEqual(UInt64.max, slice.readInteger())
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.readableBytes)
        XCTAssertEqual(UInt64.max, buffer.readInteger())
    }
    
    func testSliceWithParams() throws {
        var buffer = allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.write(integer: UInt64.max))
        var slice = buffer.getSlice(at: 0, length: MemoryLayout<UInt64>.size)!
        XCTAssertEqual(MemoryLayout<UInt64>.size, slice.readableBytes)
        XCTAssertEqual(UInt64.max, slice.readInteger())
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.readableBytes)
        XCTAssertEqual(UInt64.max, buffer.readInteger())
    }
    
    func testReadSlice() throws {
        var buffer = allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.write(integer: UInt64.max))
        var slice = buffer.readSlice(length: buffer.readableBytes)!
        XCTAssertEqual(MemoryLayout<UInt64>.size, slice.readableBytes)
        XCTAssertEqual(UInt64.max, slice.readInteger())
        XCTAssertEqual(0, buffer.readableBytes)
        let value: UInt64? = buffer.readInteger()
        XCTAssertTrue(value == nil)
    }
    
    func testSliceNoCopy() throws {
        var buffer = allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.write(integer: UInt64.max))
        let slice = buffer.readSlice(length: buffer.readableBytes)!

        buffer.withVeryUnsafeBytes { ptr1 in
            slice.withVeryUnsafeBytes { ptr2 in
                XCTAssertEqual(ptr1.baseAddress, ptr2.baseAddress)
            }
        }
    }
    
    func testSetGetData() throws {
        var buffer = allocator.buffer(capacity: 32)
        let data = Data(bytes: [1, 2, 3])
        
        XCTAssertEqual(3, buffer.set(bytes: data, at: 0))
        XCTAssertEqual(0, buffer.readableBytes)
        XCTAssertEqual(data, buffer.getData(at: 0, length: 3))
    }
    
    func testWriteReadData() throws {
        var buffer = allocator.buffer(capacity: 32)
        let data = Data(bytes: [1, 2, 3])
        
        XCTAssertEqual(3, buffer.write(bytes: data))
        XCTAssertEqual(3, buffer.readableBytes)
        XCTAssertEqual(data, buffer.readData(length: 3))
    }
    
    func testDiscardReadBytes() throws {
        var buffer = allocator.buffer(capacity: 32)
        buffer.write(integer: UInt8(1))
        buffer.write(integer: UInt8(2))
        buffer.write(integer: UInt8(3))
        buffer.write(integer: UInt8(4))
        XCTAssertEqual(4, buffer.readableBytes)
        buffer.moveReaderIndex(forwardBy: 2)
        XCTAssertEqual(2, buffer.readableBytes)
        XCTAssertEqual(2, buffer.readerIndex)
        XCTAssertEqual(4, buffer.writerIndex)
        XCTAssertTrue(buffer.discardReadBytes())
        XCTAssertEqual(2, buffer.readableBytes)
        XCTAssertEqual(0, buffer.readerIndex)
        XCTAssertEqual(2, buffer.writerIndex)
        XCTAssertEqual(UInt8(3), buffer.readInteger())
        XCTAssertEqual(UInt8(4), buffer.readInteger())
        XCTAssertEqual(0, buffer.readableBytes)
        XCTAssertTrue(buffer.discardReadBytes())
        XCTAssertFalse(buffer.discardReadBytes())
    }
    
    func testDiscardReadBytesCoW() throws {
        var buffer = allocator.buffer(capacity: 32)
        let bytesWritten = buffer.write(bytes: "0123456789abcdef0123456789ABCDEF".data(using: .utf8)!)
        XCTAssertEqual(32, bytesWritten)

        func testAssumptionOriginalBuffer(_ buf: inout ByteBuffer) {
            XCTAssertEqual(32, buf.capacity)
            XCTAssertEqual(0, buf.readerIndex)
            XCTAssertEqual(32, buf.writerIndex)
            XCTAssertEqual("0123456789abcdef0123456789ABCDEF".data(using: .utf8)!, buf.getData(at: 0, length: 32)!)
        }
        testAssumptionOriginalBuffer(&buffer)

        var buffer10Missing = buffer
        let first10Bytes = buffer10Missing.readData(length: 10) /* make the first 10 bytes disappear */
        let otherBuffer10Missing = buffer10Missing
        XCTAssertEqual("0123456789".data(using: .utf8)!, first10Bytes)
        testAssumptionOriginalBuffer(&buffer)
        XCTAssertEqual(10, buffer10Missing.readerIndex)
        XCTAssertEqual(32, buffer10Missing.writerIndex)

        let nextBytes1 = buffer10Missing.getData(at: 10, length: 22)
        XCTAssertEqual("abcdef0123456789ABCDEF".data(using: .utf8)!, nextBytes1)

        buffer10Missing.discardReadBytes()
        XCTAssertEqual(0, buffer10Missing.readerIndex)
        XCTAssertEqual(22, buffer10Missing.writerIndex)
        testAssumptionOriginalBuffer(&buffer)

        XCTAssertEqual(10, otherBuffer10Missing.readerIndex)
        XCTAssertEqual(32, otherBuffer10Missing.writerIndex)

        let nextBytes2 = buffer10Missing.getData(at: 0, length: 22)
        XCTAssertEqual("abcdef0123456789ABCDEF".data(using: .utf8)!, nextBytes2)

        let nextBytes3 = otherBuffer10Missing.getData(at: 10, length: 22)
        XCTAssertEqual("abcdef0123456789ABCDEF".data(using: .utf8)!, nextBytes3)
        testAssumptionOriginalBuffer(&buffer)

    }
    
    func testDiscardReadBytesSlice() throws {
        var buffer = allocator.buffer(capacity: 32)
        buffer.write(integer: UInt8(1))
        buffer.write(integer: UInt8(2))
        buffer.write(integer: UInt8(3))
        buffer.write(integer: UInt8(4))
        XCTAssertEqual(4, buffer.readableBytes)
        var slice = buffer.getSlice(at: 1, length: 3)!
        XCTAssertEqual(3, slice.readableBytes)
        XCTAssertEqual(0, slice.readerIndex)

        slice.moveReaderIndex(forwardBy: 1)
        XCTAssertEqual(2, slice.readableBytes)
        XCTAssertEqual(1, slice.readerIndex)
        XCTAssertEqual(3, slice.writerIndex)
        XCTAssertTrue(slice.discardReadBytes())
        XCTAssertEqual(2, slice.readableBytes)
        XCTAssertEqual(0, slice.readerIndex)
        XCTAssertEqual(2, slice.writerIndex)
        XCTAssertEqual(UInt8(3), slice.readInteger())
        XCTAssertEqual(UInt8(4), slice.readInteger())
        XCTAssertEqual(0,slice.readableBytes)
        XCTAssertTrue(slice.discardReadBytes())
        XCTAssertFalse(slice.discardReadBytes())
    }

    func testWithDataSlices() throws {
        let testStringPrefix = "0123456789"
        let testStringSuffix = "abcdef"
        let testString = "\(testStringPrefix)\(testStringSuffix)"

        var buffer = allocator.buffer(capacity: testString.utf8.count)
        buffer.write(string: testStringPrefix)
        buffer.write(string: testStringSuffix)
        XCTAssertEqual(testString.utf8.count, buffer.capacity)

        func runTestForRemaining(string: String, buffer: ByteBuffer) {
            buffer.withUnsafeReadableBytes { ptr in
                XCTAssertEqual(string.utf8.count, ptr.count)

                for (idx, expected) in zip(0..<string.utf8.count, string.utf8) {
                    let actual = ptr.baseAddress!.advanced(by: idx).assumingMemoryBound(to: UInt8.self).pointee
                    XCTAssertEqual(expected, actual, "character at index \(idx) is \(actual) but should be \(expected)")
                }
            }

            buffer.withUnsafeReadableBytes { data -> Void in
                XCTAssertEqual(string.utf8.count, data.count)
                for (idx, expected) in zip(data.startIndex..<data.startIndex+string.utf8.count, string.utf8) {
                    XCTAssertEqual(expected, data[idx])
                }
            }

            buffer.withUnsafeReadableBytes { slice in
                XCTAssertEqual(string, String(decoding: slice, as: UTF8.self))
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

    func testEndianness() throws {
        let value: UInt32 = 0x12345678
        buf.write(integer: value)
        let actualRead: UInt32 = buf.readInteger()!
        XCTAssertEqual(value, actualRead)
        buf.write(integer: value, endianness: .big)
        buf.write(integer: value, endianness: .little)
        buf.write(integer: value)
        let actual = buf.getData(at: 4, length: 12)!
        let expected = Data(bytes: [0x12, 0x34, 0x56, 0x78, 0x78, 0x56, 0x34, 0x12, 0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(expected, actual)
        let actualA: UInt32 = buf.readInteger(endianness: .big)!
        let actualB: UInt32 = buf.readInteger(endianness: .little)!
        let actualC: UInt32 = buf.readInteger()!
        XCTAssertEqual(value, actualA)
        XCTAssertEqual(value, actualB)
        XCTAssertEqual(value, actualC)
    }

    func testExpansion() throws {
        var buf = allocator.buffer(capacity: 16)
        XCTAssertEqual(16, buf.capacity)
        buf.write(bytes: "0123456789abcdef".data(using: .utf8)!)
        XCTAssertEqual(16, buf.capacity)
        XCTAssertEqual(16, buf.writerIndex)
        XCTAssertEqual(0, buf.readerIndex)
        buf.write(bytes: "X".data(using: .utf8)!)
        XCTAssertEqual(32, buf.capacity)
        XCTAssertEqual(17, buf.writerIndex)
        XCTAssertEqual(0, buf.readerIndex)
        buf.withUnsafeReadableBytes { ptr in
            let bPtr = UnsafeBufferPointer(start: ptr.baseAddress!.bindMemory(to: UInt8.self, capacity: ptr.count),
                                           count: ptr.count)
            XCTAssertEqual("0123456789abcdefX".data(using: .utf8)!, Data(buffer: bPtr))
        }
    }
    
    func testExpansion2() throws {
        var buf = allocator.buffer(capacity: 2)
        XCTAssertEqual(2, buf.capacity)
        buf.write(bytes: "0123456789abcdef".data(using: .utf8)!)
        XCTAssertEqual(16, buf.capacity)
        XCTAssertEqual(16, buf.writerIndex)
        buf.withUnsafeReadableBytes { ptr in
            let bPtr = UnsafeBufferPointer(start: ptr.baseAddress!.bindMemory(to: UInt8.self, capacity: ptr.count),
                                           count: ptr.count)
            XCTAssertEqual("0123456789abcdef".data(using: .utf8)!, Data(buffer: bPtr))
        }
    }

    func testNotEnoughBytesToReadForIntegers() throws {
        let byteCount = 15
        func initBuffer() {
            let written = buf.write(bytes: Data(Array(repeating: 0, count: byteCount)))
            XCTAssertEqual(byteCount, written)
        }

        func tryWith<T: FixedWidthInteger>(_ type: T.Type) {
            initBuffer()

            let tooMany = (byteCount + 1)/MemoryLayout<T>.size
            for _ in 1..<tooMany {
                /* read just enough ones that we should be able to read in one go */
                XCTAssertNotNil(buf.getInteger(at: buf.readerIndex) as T?)
                let actual: T? = buf.readInteger()
                XCTAssertNotNil(actual)
                XCTAssertEqual(0, actual)
            }
            /* now see that trying to read one more fails */
            let actual: T? = buf.readInteger()
            XCTAssertNil(actual)

            buf.clear()
        }

        tryWith(UInt16.self)
        tryWith(UInt32.self)
        tryWith(UInt64.self)
    }

    func testNotEnoughBytesToReadForData() throws {
        let cap = buf.capacity
        let expected = Data(Array(repeating: 0, count: cap))
        let written = buf.write(bytes: expected)
        XCTAssertEqual(cap, written)
        XCTAssertEqual(cap, buf.capacity)

        XCTAssertNil(buf.readData(length: cap+1)) /* too many */
        XCTAssertEqual(expected, buf.readData(length: cap)) /* to make sure it can work */
    }

    func testChangeCapacityToSameCapacityRetainsCapacityAndPointers() throws {
        var buf = self.allocator.buffer(capacity: 1024)
        let cap = buf.capacity
        var firstBytes: UnsafeRawBufferPointer!
        var firstStorageRef: Unmanaged<AnyObject>!
        buf.withUnsafeReadableBytesWithStorageManagement { bytes, storageRef in
            firstBytes = bytes
            firstStorageRef = storageRef
            _ = storageRef.retain()
        }
        buf.changeCapacity(to: buf.capacity)
        XCTAssertEqual(cap, buf.capacity)
        buf.withUnsafeReadableBytesWithStorageManagement { bytes, storageRef in
            XCTAssertEqual(firstBytes.baseAddress!, bytes.baseAddress!)
            XCTAssertEqual(firstStorageRef.toOpaque(), storageRef.toOpaque())
        }
        firstStorageRef.release()
    }

    func testSlicesThatAreOutOfBands() throws {
        let goodSlice = buf.getSlice(at: 0, length: buf.capacity)
        XCTAssertNotNil(goodSlice)

        let badSlice1 = buf.getSlice(at: 0, length: buf.capacity+1)
        XCTAssertNil(badSlice1)

        let badSlice2 = buf.getSlice(at: buf.capacity-1, length: 2)
        XCTAssertNil(badSlice2)
    }

    func testMutableBytesCoW() throws {
        let cap = buf.capacity
        var otherBuf = buf
        XCTAssertEqual(otherBuf, buf)
        otherBuf?.writeWithUnsafeMutableBytes { ptr in
            XCTAssertEqual(cap, ptr.count)
            let intPtr = ptr.baseAddress!.bindMemory(to: UInt8.self, capacity: ptr.count)
            for i in 0..<ptr.count {
                intPtr[i] = UInt8(truncatingIfNeeded: i)
            }
            return ptr.count
        }
        XCTAssertEqual(cap, otherBuf?.capacity)
        XCTAssertNotEqual(buf, otherBuf)
        otherBuf?.withUnsafeReadableBytes { ptr in
            XCTAssertEqual(cap, ptr.count)
            for i in 0..<cap {
                XCTAssertEqual(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)[i], UInt8(truncatingIfNeeded: i))
            }
        }
    }

    func testWritableBytesTriggersCoW() throws {
        let cap = buf.capacity
        var otherBuf = buf
        XCTAssertEqual(otherBuf, buf)

        // Write to both buffers.
        let firstResult = buf!.withUnsafeMutableWritableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Bool in
            XCTAssertEqual(cap, ptr.count)
            memset(ptr.baseAddress!, 0, ptr.count)
            return false
        }
        let secondResult = otherBuf!.withUnsafeMutableWritableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Bool in
            XCTAssertEqual(cap, ptr.count)
            let intPtr = ptr.baseAddress!.bindMemory(to: UInt8.self, capacity: ptr.count)
            for i in 0..<ptr.count {
                intPtr[i] = UInt8(truncatingIfNeeded: i)
            }
            return true
        }
        XCTAssertFalse(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(cap, otherBuf!.capacity)
        XCTAssertEqual(buf!.readableBytes, 0)
        XCTAssertEqual(otherBuf!.readableBytes, 0)

        // Move both writer indices forwards by the amount of data we wrote.
        buf!.moveWriterIndex(forwardBy: cap)
        otherBuf!.moveWriterIndex(forwardBy: cap)

        // These should now be unequal. Check their bytes to be sure.
        XCTAssertNotEqual(buf, otherBuf)
        buf!.withUnsafeReadableBytes { ptr in
            XCTAssertEqual(cap, ptr.count)
            for i in 0..<cap {
                XCTAssertEqual(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)[i], 0)
            }
        }
        otherBuf!.withUnsafeReadableBytes { ptr in
            XCTAssertEqual(cap, ptr.count)
            for i in 0..<cap {
                XCTAssertEqual(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)[i], UInt8(truncatingIfNeeded: i))
            }
        }
    }

    func testBufferWithZeroBytes() throws {
        var buf = allocator.buffer(capacity: 0)
        XCTAssertEqual(0, buf.capacity)

        var otherBuf = buf

        otherBuf.set(bytes: Data(), at: 0)
        buf.set(bytes: Data(), at: 0)

        XCTAssertEqual(0, buf.capacity)
        XCTAssertEqual(0, otherBuf.capacity)

        XCTAssertNil(otherBuf.readData(length: 1))
        XCTAssertNil(buf.readData(length: 1))
    }

    func testPastEnd() throws {
        let buf = allocator.buffer(capacity: 4)
        XCTAssertEqual(4, buf.capacity)

        XCTAssertNil(buf.getInteger(at: 0) as UInt64?)
        XCTAssertNil(buf.getData(at: 0, length: 5))
    }

    func testReadDataNotEnoughAvailable() throws {
        /* write some bytes */
        buf.write(bytes: Data([0, 1, 2, 3]))

        /* make more available in the buffer that should not be readable */
        buf.set(bytes: Data([4, 5, 6, 7]), at: 4)

        let actualNil = buf.readData(length: 5)
        XCTAssertNil(actualNil)

        let actualGoodDirect = buf.getData(at: 0, length: 5)
        XCTAssertEqual(Data([0, 1, 2, 3, 4]), actualGoodDirect)

        let actualGood = buf.readData(length: 4)
        XCTAssertEqual(Data([0, 1, 2, 3]), actualGood)
    }

    func testReadSliceNotEnoughAvailable() throws {
        /* write some bytes */
        buf.write(bytes: Data([0, 1, 2, 3]))

        /* make more available in the buffer that should not be readable */
        buf.set(bytes: Data([4, 5, 6, 7]), at: 4)

        let actualNil = buf.readSlice(length: 5)
        XCTAssertNil(actualNil)


        let actualGoodDirect = buf.getSlice(at: 0, length: 5)
        XCTAssertEqual(Data([0, 1, 2, 3, 4]), actualGoodDirect?.getData(at: 0, length: 5))

        var actualGood = buf.readSlice(length: 4)
        XCTAssertEqual(Data([0, 1, 2, 3]), actualGood?.readData(length: 4))
    }
    
    func testSetBuffer() throws {
        var src = allocator.buffer(capacity: 4)
        src.write(bytes: Data([0, 1, 2, 3]))
        
        buf.set(buffer: src, at: 1)
        
        /* Should bit increase the writerIndex of the src buffer */
        XCTAssertEqual(4, src.readableBytes)
        XCTAssertEqual(0, buf.readableBytes)
 
        XCTAssertEqual(Data([0, 1, 2, 3]), buf.getData(at: 1, length: 4))
    }
    
    func testWriteBuffer() throws {
        var src = allocator.buffer(capacity: 4)
        src.write(bytes: Data([0, 1, 2, 3]))
        
        buf.write(buffer: &src)
        
        /* Should increase the writerIndex of the src buffer */
        XCTAssertEqual(0, src.readableBytes)
        XCTAssertEqual(4, buf.readableBytes)
        XCTAssertEqual(Data([0, 1, 2, 3]), buf.readData(length: 4))
    }

    func testMisalignedIntegerRead() throws {
        let value = UInt64(7)

        buf.write(bytes: Data([1]))
        buf.write(integer: value)
        let actual = buf.readData(length: 1)
        XCTAssertEqual(Data([1]), actual)

        buf.withUnsafeReadableBytes { ptr in
            /* make sure pointer is actually misaligned for an integer */
            let pointerBitPattern = UInt(bitPattern: ptr.baseAddress!)
            let lastBit = pointerBitPattern & 0x1
            XCTAssertEqual(1, lastBit) /* having a 1 as the last bit makes that pointer clearly misaligned for UInt64 */
        }

        XCTAssertEqual(value, buf.readInteger())
    }

    func testSetAndWriteBytes() throws {
        let str = "hello world!"
        let hwData = str.data(using: .utf8)!
        /* write once, ... */
        buf.write(string: str)
        var written1: Int = -1
        var written2: Int = -1
        hwData.withUnsafeBytes { (ptr: UnsafePointer<Int8>) -> Void in
            let ptr = UnsafeRawBufferPointer(start: ptr, count: hwData.count)
            /* ... write a second time and ...*/
            written1 = buf.set(bytes: ptr, at: buf.writerIndex)
            buf.moveWriterIndex(forwardBy: written1)
            /* ... a lucky third time! */
            written2 = buf.write(bytes: ptr)
        }
        XCTAssertEqual(written1, written2)
        XCTAssertEqual(str.utf8.count, written1)
        XCTAssertEqual(3 * str.utf8.count, buf.readableBytes)
        let actualData = buf.readData(length: 3 * str.utf8.count)!
        let actualString = String(decoding: actualData, as: UTF8.self)
        XCTAssertEqual(Array(repeating: str, count: 3).joined(), actualString)
    }

    func testWriteABunchOfCollections() throws {
        let overallData = "0123456789abcdef".data(using: .utf8)!
        buf.write(bytes: "0123".utf8)
        "4567".withCString { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 4) { ptr in
                _ = buf.write(bytes: UnsafeBufferPointer<UInt8>(start: ptr, count: 4))
            }
        }
        buf.write(bytes: Array("89ab".utf8))
        buf.write(bytes: "cdef".data(using: .utf8)!)
        let actual = buf.getData(at: 0, length: buf.readableBytes)
        XCTAssertEqual(overallData, actual)
    }

    func testSetABunchOfCollections() throws {
        let overallData = "0123456789abcdef".data(using: .utf8)!
        _ = buf.set(bytes: "0123".utf8, at: 0)
        "4567".withCString { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 4) { ptr in
                _ = buf.set(bytes: UnsafeBufferPointer<UInt8>(start: ptr, count: 4), at: 4)
            }
        }
        _ = buf.set(bytes: Array("89ab".utf8), at: 8)
        _ = buf.set(bytes: "cdef".data(using: .utf8)!, at: 12)
        let actual = buf.getData(at: 0, length: 16)
        XCTAssertEqual(overallData, actual)
    }

    func testTryStringTooLong() throws {
        let capacity = buf.capacity
        for i in 0..<buf.capacity {
            buf.set(string: "x", at: i)
        }
        XCTAssertEqual(capacity, buf.capacity, "buffer capacity needlessly changed from \(capacity) to \(buf.capacity)")
        XCTAssertNil(buf.string(at: 0, length: capacity+1))
    }

    func testSetGetBytesAllFine() throws {
        buf.set(bytes: [1, 2, 3, 4], at: 0)
        XCTAssertEqual([1, 2, 3, 4], buf.bytes(at: 0, length: 4) ?? [])

        let capacity = buf.capacity
        for i in 0..<buf.capacity {
            buf.set(bytes: [0xFF], at: i)
        }
        XCTAssertEqual(capacity, buf.capacity, "buffer capacity needlessly changed from \(capacity) to \(buf.capacity)")
        XCTAssertEqual(Array(repeating: 0xFF, count: capacity), buf.bytes(at: 0, length: capacity)!)

    }

    func testGetBytesTooLong() throws {
        XCTAssertNil(buf.bytes(at: 0, length: buf.capacity+1))
        XCTAssertNil(buf.bytes(at: buf.capacity, length: 1))
    }

    func testReadWriteBytesOkay() throws {
        buf.changeCapacity(to: 24)
        buf.clear()
        let capacity = buf.capacity
        for i in 0..<capacity {
            let expected = Array(repeating: UInt8(i % 255), count: i)
            buf.write(bytes: expected)
            let actual = buf.readBytes(length: i)!
            XCTAssertEqual(expected, actual)
            XCTAssertEqual(capacity, buf.capacity, "buffer capacity needlessly changed from \(capacity) to \(buf.capacity)")
            buf.clear()
        }
    }

    func testReadTooLong() throws {
        XCTAssertNotNil(buf.readBytes(length: buf.readableBytes))
        XCTAssertNil(buf.readBytes(length: buf.readableBytes+1))
    }

    func testReadWithUnsafeReadableBytesVariantsNothingToRead() throws {
        buf.changeCapacity(to: 1024)
        buf.clear()
        XCTAssertEqual(0, buf.readerIndex)
        XCTAssertEqual(0, buf.writerIndex)

        var rInt = buf.readWithUnsafeReadableBytes { ptr in
            XCTAssertEqual(0, ptr.count)
            return 0
        }
        XCTAssertEqual(0, rInt)

        rInt = buf.readWithUnsafeMutableReadableBytes { ptr in
            XCTAssertEqual(0, ptr.count)
            return 0
        }
        XCTAssertEqual(0, rInt)

        var rString = buf.readWithUnsafeReadableBytes { (ptr: UnsafeRawBufferPointer) -> (Int, String) in
            XCTAssertEqual(0, ptr.count)
            return (0, "blah")
        }
        XCTAssert(rString == "blah")

        rString = buf.readWithUnsafeMutableReadableBytes { (ptr: UnsafeMutableRawBufferPointer) -> (Int, String) in
            XCTAssertEqual(0, ptr.count)
            return (0, "blah")
        }
        XCTAssert(rString == "blah")
    }

    func testReadWithUnsafeReadableBytesVariantsSomethingToRead() throws {
        buf.changeCapacity(to: 1)
        buf.clear()
        buf.write(bytes: [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(0, buf.readerIndex)
        XCTAssertEqual(8, buf.writerIndex)

        var rInt = buf.readWithUnsafeReadableBytes { ptr in
            XCTAssertEqual(8, ptr.count)
            return 0
        }
        XCTAssertEqual(0, rInt)

        rInt = buf.readWithUnsafeMutableReadableBytes { ptr in
            XCTAssertEqual(8, ptr.count)
            return 1
        }
        XCTAssertEqual(1, rInt)

        var rString = buf.readWithUnsafeReadableBytes { (ptr: UnsafeRawBufferPointer) -> (Int, String) in
            XCTAssertEqual(7, ptr.count)
            return (2, "blah")
        }
        XCTAssert(rString == "blah")

        rString = buf.readWithUnsafeMutableReadableBytes { (ptr: UnsafeMutableRawBufferPointer) -> (Int, String) in
            XCTAssertEqual(5, ptr.count)
            return (3, "blah")
        }
        XCTAssert(rString == "blah")

        XCTAssertEqual(6, buf.readerIndex)
        XCTAssertEqual(8, buf.writerIndex)
    }

    func testSomePotentialIntegerUnderOrOverflows() throws {
        buf.changeCapacity(to: 1024)
        buf.write(staticString: "hello world, just some trap bytes here")

        func testIndexAndLengthFunc<T>(_ fn: (Int, Int) -> T?, file: StaticString = #file, line: UInt = #line) {
            XCTAssertNil(fn(Int.max, 1), file: file, line: line)
            XCTAssertNil(fn(Int.max - 1, 2), file: file, line: line)
            XCTAssertNil(fn(1, Int.max), file: file, line: line)
            XCTAssertNil(fn(2, Int.max - 1), file: file, line: line)
        }

        func testIndexOrLengthFunc<T>(_ fn: (Int) -> T?, file: StaticString = #file, line: UInt = #line) {
            XCTAssertNil(fn(Int.max))
            XCTAssertNil(fn(Int.max - 1))
        }

        testIndexOrLengthFunc({ x in buf.getInteger(at: x) as UInt16? })
        testIndexOrLengthFunc({ buf.readSlice(length: $0) })
        testIndexOrLengthFunc({ buf.readBytes(length: $0) })
        testIndexOrLengthFunc({ buf.readData(length: $0) })

        testIndexAndLengthFunc(buf.bytes)
        testIndexAndLengthFunc(buf.getData)
        testIndexAndLengthFunc(buf.getSlice)
        testIndexAndLengthFunc(buf.string)
    }

    func testWriteForContiguousCollections() throws {
        buf.clear()
        var written = buf.write(bytes: [1, 2, 3, 4])
        XCTAssertEqual(4, written)
        written += [5 as UInt8, 6, 7, 8].withUnsafeBytes { ptr in
            buf.write(bytes: ptr)
        }
        XCTAssertEqual(8, written)
        written += [9 as UInt8, 10, 11, 12].withUnsafeBufferPointer { ptr in
            buf.write(bytes: ptr)
        }
        XCTAssertEqual(12, written)
        written += buf.write(bytes: ContiguousArray<UInt8>([13, 14, 15, 16]))
        XCTAssertEqual(16, written)
        written += buf.write(bytes: "ABCD" as StaticString)
        XCTAssertEqual(20, written)
        written += buf.write(bytes: "EFGH".data(using: .utf8)!)
        XCTAssertEqual(24, written)

        let expected = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, "A".utf8.first!, "B".utf8.first!, "C".utf8.first!, "D".utf8.first!, "E".utf8.first!, "F".utf8.first!, "G".utf8.first!, "H".utf8.first!]

        XCTAssertEqual(expected, buf.readBytes(length: written)!)
    }

    func testWriteForNonContiguousCollections() throws {
        buf.clear()
        let written = buf.write(bytes: "ABCD".utf8)
        XCTAssertEqual(4, written)

        let expected = ["A".utf8.first!, "B".utf8.first!, "C".utf8.first!, "D".utf8.first!]

        XCTAssertEqual(expected, buf.readBytes(length: written)!)
    }

    func testReadStringOkay() throws {
        buf.clear()
        let expected = "hello"
        buf.write(string: expected)
        let actual = buf.readString(length: expected.utf8.count)
        XCTAssertEqual(expected, actual)
        XCTAssertEqual("", buf.readString(length: 0))
        XCTAssertNil(buf.readString(length: 1))
    }

    func testReadStringTooMuch() throws {
        buf.clear()
        XCTAssertNil(buf.readString(length: 1))

        buf.write(string: "a")
        XCTAssertNil(buf.readString(length: 2))

        XCTAssertEqual("a", buf.readString(length: 1))
    }

    func testSetIntegerBeyondCapacity() throws {
        buf.clear()
        buf.changeCapacity(to: 32)
        XCTAssertLessThan(buf.capacity, 200)

        buf.set(integer: 17, at: 201)
        let i: Int = buf.getInteger(at: 201)!
        XCTAssertEqual(17, i)
        XCTAssertGreaterThanOrEqual(buf.capacity, 200 + MemoryLayout.size(ofValue: i))
    }

    func testGetIntegerBeyondCapacity() throws {
        buf.clear()
        buf.changeCapacity(to: 32)
        XCTAssertLessThan(buf.capacity, 200)

        let i: Int? = buf.getInteger(at: 201)
        XCTAssertNil(i)
    }

    func testSetStringBeyondCapacity() throws {
        buf.clear()
        buf.changeCapacity(to: 32)
        XCTAssertLessThan(buf.capacity, 200)

        buf.set(string: "HW", at: 201)
        let s = buf.string(at: 201, length: 2)!
        XCTAssertEqual("HW", s)
        XCTAssertGreaterThanOrEqual(buf.capacity, 202)
    }

    func testGetStringBeyondCapacity() throws {
        buf.clear()
        buf.changeCapacity(to: 32)
        XCTAssertLessThan(buf.capacity, 200)

        let i: String? = buf.string(at: 201, length: 1)
        XCTAssertNil(i)
    }

    func testAllocationOfReallyBigByteBuffer() throws {
        let alloc = ByteBufferAllocator(hookedMalloc: { testAllocationOfReallyBigByteBuffer_mallocHook($0) },
                                        hookedRealloc: { testAllocationOfReallyBigByteBuffer_reallocHook($0, $1) },
                                        hookedFree: { testAllocationOfReallyBigByteBuffer_freeHook($0) },
                                        hookedMemcpy: { testAllocationOfReallyBigByteBuffer_memcpyHook($0, $1, $2) })

        XCTAssertEqual(AllocationExpectationState.begin, testAllocationOfReallyBigByteBuffer_state)
        var buf = alloc.buffer(capacity: Int(Int32.max))
        XCTAssertEqual(AllocationExpectationState.mallocDone, testAllocationOfReallyBigByteBuffer_state)
        XCTAssertGreaterThanOrEqual(buf.capacity, Int(Int32.max))

        buf.set(bytes: [1], at: 0)
        /* now make it expand (will trigger realloc) */
        buf.set(bytes: [1], at: buf.capacity)

        XCTAssertEqual(AllocationExpectationState.reallocDone, testAllocationOfReallyBigByteBuffer_state)
        XCTAssertEqual(buf.capacity, Int(UInt32.max))
    }

    func testWritableBytesAccountsForSlicing() throws {
        buf.clear()
        buf.changeCapacity(to: 32)
        XCTAssertEqual(buf.capacity, 32)
        XCTAssertEqual(buf.writableBytes, 32)

        let newBuf = buf.getSlice(at: buf.writerIndex, length: 8)!
        XCTAssertEqual(newBuf.capacity, 8)
        XCTAssertEqual(newBuf.writableBytes, 0)
    }

    func testClearDupesStorageIfTheresTwoBuffersSharingStorage() throws {
        let alloc = ByteBufferAllocator()
        var buf1 = alloc.buffer(capacity: 16)
        let buf2 = buf1

        var buf1PtrVal: UInt = 1
        var buf2PtrVal: UInt = 2

        buf1.withUnsafeReadableBytes { ptr in
            buf1PtrVal = UInt(bitPattern: ptr.baseAddress!)
        }
        buf2.withUnsafeReadableBytes { ptr in
            buf2PtrVal = UInt(bitPattern: ptr.baseAddress!)
        }
        XCTAssertEqual(buf1PtrVal, buf2PtrVal)

        buf1.clear()

        buf1.withUnsafeReadableBytes { ptr in
            buf1PtrVal = UInt(bitPattern: ptr.baseAddress!)
        }
        buf2.withUnsafeReadableBytes { ptr in
            buf2PtrVal = UInt(bitPattern: ptr.baseAddress!)
        }
        XCTAssertNotEqual(buf1PtrVal, buf2PtrVal)
    }

    func testClearDoesNotDupeStorageIfTheresOnlyOneBuffer() throws {
        let alloc = ByteBufferAllocator()
        var buf = alloc.buffer(capacity: 16)

        var bufPtrValPre: UInt = 1
        var bufPtrValPost: UInt = 2

        buf.withUnsafeReadableBytes { ptr in
            bufPtrValPre = UInt(bitPattern: ptr.baseAddress!)
        }

        buf.clear()

        buf.withUnsafeReadableBytes { ptr in
            bufPtrValPost = UInt(bitPattern: ptr.baseAddress!)
        }
        XCTAssertEqual(bufPtrValPre, bufPtrValPost)
    }
}

private enum AllocationExpectationState: Int {
    case begin
    case mallocDone
    case reallocDone
    case freeDone
}

private var testAllocationOfReallyBigByteBuffer_state = AllocationExpectationState.begin
private func testAllocationOfReallyBigByteBuffer_freeHook(_ ptr: UnsafeMutableRawPointer) -> Void {
    precondition(AllocationExpectationState.reallocDone == testAllocationOfReallyBigByteBuffer_state)
    testAllocationOfReallyBigByteBuffer_state = .freeDone
    /* free the pointer initially produced by malloc and then rebased by realloc offsetting it back */
    free(ptr.advanced(by: Int(Int32.max)))
}

private func testAllocationOfReallyBigByteBuffer_mallocHook(_ size: Int) -> UnsafeMutableRawPointer! {
    precondition(AllocationExpectationState.begin == testAllocationOfReallyBigByteBuffer_state)
    testAllocationOfReallyBigByteBuffer_state = .mallocDone
    /* return a 16 byte pointer here, good enough to write an integer in there */
    return malloc(16)
}

private func testAllocationOfReallyBigByteBuffer_reallocHook(_ ptr: UnsafeMutableRawPointer, _ count: Int) -> UnsafeMutableRawPointer! {
    precondition(AllocationExpectationState.mallocDone == testAllocationOfReallyBigByteBuffer_state)
    testAllocationOfReallyBigByteBuffer_state = .reallocDone
    /* rebase this pointer by -Int32.max so that the byte copy extending the ByteBuffer below will land at actual index 0 into this buffer ;) */
    return ptr.advanced(by: -Int(Int32.max))
}

private func testAllocationOfReallyBigByteBuffer_memcpyHook(_ dst: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ count: Int) -> Void {
    /* not actually doing any copies */
}
