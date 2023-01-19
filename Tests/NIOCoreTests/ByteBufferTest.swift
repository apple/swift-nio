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
@testable import NIOCore
import NIOFoundationCompat

class ByteBufferTest: XCTestCase {
    private let allocator = ByteBufferAllocator()
    private var buf: ByteBuffer! = nil

    private func setGetInt<T: FixedWidthInteger>(index: Int, v: T) throws {
        var buffer = allocator.buffer(capacity: 32)

        XCTAssertEqual(MemoryLayout<T>.size, buffer.setInteger(v, at: index))
        buffer.moveWriterIndex(to: index + MemoryLayout<T>.size)
        buffer.moveReaderIndex(to: index)
        XCTAssertEqual(v, buffer.getInteger(at: index))
    }

    private func writeReadInt<T: FixedWidthInteger>(v: T) throws {
        var buffer = allocator.buffer(capacity: 32)
        XCTAssertEqual(0, buffer.writerIndex)
        XCTAssertEqual(MemoryLayout<T>.size, buffer.writeInteger(v))
        XCTAssertEqual(MemoryLayout<T>.size, buffer.writerIndex)

        XCTAssertEqual(v, buffer.readInteger())
        XCTAssertEqual(0, buffer.readableBytes)
    }

    override func setUp() {
        super.setUp()

        self.buf = allocator.buffer(capacity: 1024)
        self.buf.writeBytes(Array(repeating: UInt8(0xff), count: 1024))
        self.buf = self.buf.getSlice(at: 256, length: 512)
        self.buf.clear()
    }

    override func tearDown() {
        self.buf = nil

        super.tearDown()
    }

    func testAllocateAndCount() {
        let b = allocator.buffer(capacity: 1024)
        XCTAssertEqual(1024, b.capacity)
    }

    func testEqualsComparesReadBuffersOnly() throws {
        // Only cares about the read buffer
        self.buf.writeInteger(Int8.max)
        self.buf.writeString("oh hi")
        let actual: Int8 = buf.readInteger()! // Just getting rid of it from the read buffer
        XCTAssertEqual(Int8.max, actual)

        var otherBuffer = allocator.buffer(capacity: 32)
        otherBuffer.writeString("oh hi")
        XCTAssertEqual(otherBuffer, buf)
    }
    
    func testHasherUsesReadBuffersOnly() {
        // Only cares about the read buffer
        self.buf.clear()
        self.buf.writeString("oh hi")

        var hasher = Hasher()
        // We need to force unwrap the implicitly unwrapped optional here in order to
        // mark it as unwrapped for the compiler *before* the function call. Otherwise
        // the implementation of the optional's conditional conformance is triggered,
        // that will change the hash. For more information please see:
        // https://github.com/apple/swift-nio/pull/1326
        // https://bugs.swift.org/browse/SR-11975
        hasher.combine(self.buf!)
        let hash = hasher.finalize()
        
        var otherBuffer = allocator.buffer(capacity: 6)
        otherBuffer.writeString("oh hi")

        var otherHasher = Hasher()
        otherHasher.combine(otherBuffer)
        let otherHash = otherHasher.finalize()
        
        XCTAssertEqual(hash, otherHash)
    }

    func testSimpleReadTest() throws {
        buf.withUnsafeReadableBytes { ptr in
            XCTAssertEqual(ptr.count, 0)
        }

        buf.writeString("Hello world!")
        buf.withUnsafeReadableBytes { ptr in
            XCTAssertEqual(12, ptr.count)
        }
    }

    func testSimpleWrites() {
        var written = buf.writeString("")
        XCTAssertEqual(0, written)
        XCTAssertEqual(0, buf.readableBytes)

        written = buf.writeString("X")
        XCTAssertEqual(1, written)
        XCTAssertEqual(1, buf.readableBytes)

        written = buf.writeString("XXXXX")
        XCTAssertEqual(5, written)
        XCTAssertEqual(6, buf.readableBytes)
    }

    func makeSliceToBufferWhichIsDeallocated() -> ByteBuffer {
        var buf = self.allocator.buffer(capacity: 16)
        let oldCapacity = buf.capacity
        buf.writeBytes(0..<16)
        XCTAssertEqual(oldCapacity, buf.capacity)
        return buf.getSlice(at: 15, length: 1)!
    }

    func testMakeSureUniquelyOwnedSliceDoesNotGetReallocatedOnWrite() {
        var slice = self.makeSliceToBufferWhichIsDeallocated()
        XCTAssertEqual(1, slice.capacity)
        XCTAssertEqual(16, slice.storageCapacity)
        let oldStorageBegin = slice.withUnsafeReadableBytes { ptr in
            return UInt(bitPattern: ptr.baseAddress!)
        }
        slice.setInteger(1, at: 0, as: UInt8.self)
        let newStorageBegin = slice.withUnsafeReadableBytes { ptr in
            return UInt(bitPattern: ptr.baseAddress!)
        }
        XCTAssertEqual(oldStorageBegin, newStorageBegin)
    }

    func testWriteToUniquelyOwnedSliceWhichTriggersAReallocation() {
        var slice = self.makeSliceToBufferWhichIsDeallocated()
        XCTAssertEqual(1, slice.capacity)
        XCTAssertEqual(16, slice.storageCapacity)
        // this will cause a re-allocation, the whole buffer should be 32 bytes then, the slice having 17 of that.
        // this fills 16 bytes so will still fit
        slice.writeBytes(Array(16..<32))
        XCTAssertEqual(Array(15..<32), slice.readBytes(length: slice.readableBytes)!)

        // and this will need another re-allocation
        slice.writeBytes(Array(32..<47))
    }


    func testReadWrite() {
        buf.writeString("X")
        buf.writeString("Y")
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

            let bytes = buf.writeStaticString(testString)
            XCTAssertEqual(testString.utf8CodeUnitCount, Int(bytes))
            allBytes += bytes
            XCTAssertEqual(allBytes - bytes, buf.readerIndex)

            let expected = testString.withUTF8Buffer { buf in
                String(decoding: buf, as: Unicode.UTF8.self)
            }
            buf.withUnsafeReadableBytes { ptr in
                let actual = String(decoding: ptr, as: Unicode.UTF8.self)
                XCTAssertEqual(expected, actual)
            }
            let d = buf.readData(length: testString.utf8CodeUnitCount)
            XCTAssertEqual(allBytes, buf.readerIndex)
            XCTAssertNotNil(d)
            XCTAssertEqual(d?.count, testString.utf8CodeUnitCount)
            XCTAssertEqual(expected, String(decoding: d!, as: Unicode.UTF8.self))
        }
    }

    func testString() {
        let written = buf.writeString("Hello")
        let string = buf.getString(at: 0, length: written)
        XCTAssertEqual("Hello", string)
    }
    
    func testNullTerminatedString() {
        let writtenHello = buf.writeNullTerminatedString("Hello")
        XCTAssertEqual(writtenHello, 6)
        XCTAssertEqual(buf.readableBytes, 6)
        
        let writtenEmpty = buf.writeNullTerminatedString("")
        XCTAssertEqual(writtenEmpty, 1)
        XCTAssertEqual(buf.readableBytes, 7)
        
        let writtenFoo = buf.writeNullTerminatedString("foo")
        XCTAssertEqual(writtenFoo, 4)
        XCTAssertEqual(buf.readableBytes, 11)
        
        XCTAssertEqual(buf.getNullTerminatedString(at: 0), "Hello")
        XCTAssertEqual(buf.getNullTerminatedString(at: 6), "")
        XCTAssertEqual(buf.getNullTerminatedString(at: 7), "foo")
        
        XCTAssertEqual(buf.readNullTerminatedString(), "Hello")
        XCTAssertEqual(buf.readerIndex, 6)
        
        XCTAssertEqual(buf.readNullTerminatedString(), "")
        XCTAssertEqual(buf.readerIndex, 7)
        
        XCTAssertEqual(buf.readNullTerminatedString(), "foo")
        XCTAssertEqual(buf.readerIndex, 11)
    }
    
    func testReadNullTerminatedStringWithoutNullTermination() {
        buf.writeString("Hello")
        XCTAssertNil(buf.readNullTerminatedString())
    }
    
    func testGetNullTerminatedStringOutOfRangeTests() {
        buf.writeNullTerminatedString("Hello")
        XCTAssertNil(buf.getNullTerminatedString(at: 100))
        buf.moveReaderIndex(forwardBy: 6)
        XCTAssertNil(buf.readNullTerminatedString())
        XCTAssertNil(buf.getNullTerminatedString(at: 0))
        buf.writeInteger(UInt8(0))
        XCTAssertEqual(buf.readNullTerminatedString(), "")
    }
    
    func testWriteSubstring() {
        var text = "Hello"
        let written = buf.writeSubstring(text[...])
        var string = buf.getString(at: 0, length: written)
        XCTAssertEqual(text, string)
        
        text = ""
        buf.writeSubstring(text[...])
        string = buf.getString(at: 0, length: written)
        XCTAssertEqual("Hello", string)
    }
    
    func testSetSubstring() {
        let text = "Hello"
        buf.writeSubstring(text[...])
        
        var written = buf.setSubstring(text[...], at: 0)
        var string = buf.getString(at: 0, length: written)
        XCTAssertEqual(text, string)
        
        written = buf.setSubstring(text[text.index(after: text.startIndex)...], at: 1)
        string = buf.getString(at: 0, length: written + 1)
        XCTAssertEqual(text, string)
        
        written = buf.setSubstring(text[text.index(after: text.startIndex)...], at: 0)
        string = buf.getString(at: 0, length: written)
        XCTAssertEqual("ello", string)
    }

    func testSliceEasy() {
        buf.writeString("0123456789abcdefg")
        for i in 0..<16 {
            let slice = buf.getSlice(at: i, length: 1)
            XCTAssertEqual(1, slice?.capacity)
            XCTAssertEqual(buf.getData(at: i, length: 1), slice?.getData(at: 0, length: 1))
        }
    }

    func testWriteStringMovesWriterIndex() throws {
        var buf = allocator.buffer(capacity: 1024)
        buf.writeString("hello")
        XCTAssertEqual(5, buf.writerIndex)
        buf.withUnsafeReadableBytes { (ptr: UnsafeRawBufferPointer) -> Void in
            let s = String(decoding: ptr, as: Unicode.UTF8.self)
            XCTAssertEqual("hello", s)
        }
    }

    func testSetExpandsBufferOnUpperBoundsCheckFailure() {
        let initialCapacity = buf.capacity
        XCTAssertEqual(5, buf.setString("oh hi", at: buf.capacity))
        XCTAssert(initialCapacity < buf.capacity)
    }

    func testCoWWorks() {
        buf.writeString("Hello")
        var a = buf!
        let b = buf!
        a.writeString(" World")
        XCTAssertEqual(buf, b)
        XCTAssertNotEqual(buf, a)
    }

    func testWithMutableReadPointerMovesReaderIndexAndReturnsNumBytesConsumed() {
        XCTAssertEqual(0, buf.readerIndex)
        // We use mutable read pointers when we're consuming the data
        // so first we need some data there!
        buf.writeString("hello again")

        let bytesConsumed = buf.readWithUnsafeReadableBytes { dst in
            // Pretend we did some operation which made use of entire 11 byte string
            return 11
        }
        XCTAssertEqual(11, bytesConsumed)
        XCTAssertEqual(11, buf.readerIndex)
    }

    func testWithMutableWritePointerMovesWriterIndexAndReturnsNumBytesWritten() {
        XCTAssertEqual(0, buf.writerIndex)

        let bytesWritten = buf.writeWithUnsafeMutableBytes(minimumWritableBytes: 5) {
            XCTAssertTrue($0.count >= 5)
            return 5
        }
        XCTAssertEqual(5, bytesWritten)
        XCTAssertEqual(5, buf.writerIndex)
    }

    func testWithMutableWritePointerWithMinimumSpecifiedAdjustsCapacity() {
        XCTAssertEqual(0, buf.writerIndex)
        XCTAssertEqual(1024, buf.capacity)

        var bytesWritten = buf.writeWithUnsafeMutableBytes(minimumWritableBytes: 256) {
            XCTAssertTrue($0.count >= 256)
            return 256
        }
        XCTAssertEqual(256, bytesWritten)
        XCTAssertEqual(256, buf.writerIndex)
        XCTAssertEqual(1024, buf.capacity)

        bytesWritten += buf.writeWithUnsafeMutableBytes(minimumWritableBytes: 1024) {
            XCTAssertTrue($0.count >= 1024)
            return 1024
        }
        let expectedBytesWritten = 256 + 1024
        XCTAssertEqual(expectedBytesWritten, bytesWritten)
        XCTAssertEqual(expectedBytesWritten, buf.writerIndex)
        XCTAssertTrue(buf.capacity >= expectedBytesWritten)
    }

    func testWithMutableWritePointerWithMinimumSpecifiedWhileAtMaxCapacity() {
        XCTAssertEqual(0, buf.writerIndex)
        XCTAssertEqual(1024, buf.capacity)

        var bytesWritten = buf.writeWithUnsafeMutableBytes(minimumWritableBytes: 512) {
            XCTAssertTrue($0.count >= 512)
            return 512
        }
        XCTAssertEqual(512, bytesWritten)
        XCTAssertEqual(512, buf.writerIndex)
        XCTAssertEqual(1024, buf.capacity)

        bytesWritten += buf.writeWithUnsafeMutableBytes(minimumWritableBytes: 1) {
            XCTAssertTrue($0.count >= 1)
            return 1
        }
        let expectedBytesWritten = 512 + 1
        XCTAssertEqual(expectedBytesWritten, bytesWritten)
        XCTAssertEqual(expectedBytesWritten, buf.writerIndex)
        XCTAssertTrue(buf.capacity >= expectedBytesWritten)
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
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.writeInteger(UInt64.max))
        var slice = buffer.slice()
        XCTAssertEqual(MemoryLayout<UInt64>.size, slice.readableBytes)
        XCTAssertEqual(UInt64.max, slice.readInteger())
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.readableBytes)
        XCTAssertEqual(UInt64.max, buffer.readInteger())
    }

    func testSliceWithParams() throws {
        var buffer = allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.writeInteger(UInt64.max))
        var slice = buffer.getSlice(at: 0, length: MemoryLayout<UInt64>.size)!
        XCTAssertEqual(MemoryLayout<UInt64>.size, slice.readableBytes)
        XCTAssertEqual(UInt64.max, slice.readInteger())
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.readableBytes)
        XCTAssertEqual(UInt64.max, buffer.readInteger())
    }

    func testReadSlice() throws {
        var buffer = allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.writeInteger(UInt64.max))
        var slice = buffer.readSlice(length: buffer.readableBytes)!
        XCTAssertEqual(MemoryLayout<UInt64>.size, slice.readableBytes)
        XCTAssertEqual(UInt64.max, slice.readInteger())
        XCTAssertEqual(0, buffer.readableBytes)
        let value: UInt64? = buffer.readInteger()
        XCTAssertTrue(value == nil)
    }

    func testSliceNoCopy() throws {
        var buffer = allocator.buffer(capacity: 32)
        XCTAssertEqual(MemoryLayout<UInt64>.size, buffer.writeInteger(UInt64.max))
        let slice = buffer.readSlice(length: buffer.readableBytes)!

        buffer.withVeryUnsafeBytes { ptr1 in
            slice.withVeryUnsafeBytes { ptr2 in
                XCTAssertEqual(ptr1.baseAddress, ptr2.baseAddress)
            }
        }
    }

    func testSetGetData() throws {
        var buffer = allocator.buffer(capacity: 32)
        let data = Data([1, 2, 3])

        XCTAssertEqual(3, buffer.setBytes(data, at: 0))
        XCTAssertEqual(0, buffer.readableBytes)
        buffer.moveReaderIndex(to: 0)
        buffer.moveWriterIndex(to: 3)
        XCTAssertEqual(data, buffer.getData(at: 0, length: 3))
    }

    func testWriteReadData() throws {
        var buffer = allocator.buffer(capacity: 32)
        let data = Data([1, 2, 3])

        XCTAssertEqual(3, buffer.writeBytes(data))
        XCTAssertEqual(3, buffer.readableBytes)
        XCTAssertEqual(data, buffer.readData(length: 3))
    }

    func testDiscardReadBytes() throws {
        var buffer = allocator.buffer(capacity: 32)
        buffer.writeInteger(1, as: UInt8.self)
        buffer.writeInteger(UInt8(2))
        buffer.writeInteger(3 as UInt8)
        buffer.writeInteger(4, as: UInt8.self)
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
        let bytesWritten = buffer.writeBytes("0123456789abcdef0123456789ABCDEF".data(using: .utf8)!)
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
        buffer.writeInteger(UInt8(1))
        buffer.writeInteger(UInt8(2))
        buffer.writeInteger(UInt8(3))
        buffer.writeInteger(UInt8(4))
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
        buffer.writeString(testStringPrefix)
        buffer.writeString(testStringSuffix)
        XCTAssertEqual(testString.utf8.count, buffer.capacity)

        func runTestForRemaining(string: String, buffer: ByteBuffer) {
            buffer.withUnsafeReadableBytes { ptr in
                XCTAssertEqual(string.utf8.count, ptr.count)

                for (idx, expected) in zip(0..<string.utf8.count, string.utf8) {
                    let actual = ptr[idx]
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
                XCTAssertEqual(string, String(decoding: slice, as: Unicode.UTF8.self))
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
        buf.writeInteger(value)
        let actualRead: UInt32 = buf.readInteger()!
        XCTAssertEqual(value, actualRead)
        buf.writeInteger(value, endianness: .big)
        buf.writeInteger(value, endianness: .little)
        buf.writeInteger(value)
        let actual = buf.getData(at: 4, length: 12)!
        let expected = Data([0x12, 0x34, 0x56, 0x78, 0x78, 0x56, 0x34, 0x12, 0x12, 0x34, 0x56, 0x78])
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
        buf.writeBytes("0123456789abcdef".data(using: .utf8)!)
        XCTAssertEqual(16, buf.capacity)
        XCTAssertEqual(16, buf.writerIndex)
        XCTAssertEqual(0, buf.readerIndex)
        buf.writeBytes("X".data(using: .utf8)!)
        XCTAssertGreaterThan(buf.capacity, 16)
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
        buf.writeBytes("0123456789abcdef".data(using: .utf8)!)
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
            let written = buf.writeBytes(Data(Array(repeating: 0, count: byteCount)))
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
        let written = buf.writeBytes(expected)
        XCTAssertEqual(cap, written)
        XCTAssertEqual(cap, buf.capacity)

        XCTAssertNil(buf.readData(length: cap+1)) /* too many */
        XCTAssertEqual(expected, buf.readData(length: cap)) /* to make sure it can work */
    }

    func testSlicesThatAreOutOfBands() throws {
        self.buf.moveReaderIndex(to: 0)
        self.buf.moveWriterIndex(to: self.buf.capacity)
        let goodSlice = self.buf.getSlice(at: 0, length: self.buf.capacity)
        XCTAssertNotNil(goodSlice)

        let badSlice1 = self.buf.getSlice(at: 0, length: self.buf.capacity+1)
        XCTAssertNil(badSlice1)

        let badSlice2 = self.buf.getSlice(at: self.buf.capacity-1, length: 2)
        XCTAssertNil(badSlice2)
    }

    func testMutableBytesCoW() throws {
        let cap = buf.capacity
        var otherBuf = buf
        XCTAssertEqual(otherBuf, buf)
        otherBuf?.writeWithUnsafeMutableBytes(minimumWritableBytes: 0) { ptr in
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
                XCTAssertEqual(ptr[i], UInt8(truncatingIfNeeded: i))
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
                XCTAssertEqual(ptr[i], 0)
            }
        }
        otherBuf!.withUnsafeReadableBytes { ptr in
            XCTAssertEqual(cap, ptr.count)
            for i in 0..<cap {
                XCTAssertEqual(ptr[i], UInt8(truncatingIfNeeded: i))
            }
        }
    }

    func testBufferWithZeroBytes() throws {
        var buf = allocator.buffer(capacity: 0)
        XCTAssertEqual(0, buf.capacity)

        var otherBuf = buf

        otherBuf.setBytes(Data(), at: 0)
        buf.setBytes(Data(), at: 0)

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
        self.buf.writeBytes(Data([0, 1, 2, 3]))

        /* make more available in the buffer that should not be readable */
        self.buf.setBytes(Data([4, 5, 6, 7]), at: 4)

        let actualNil = buf.readData(length: 5)
        XCTAssertNil(actualNil)

        self.buf.moveReaderIndex(to: 0)
        self.buf.moveWriterIndex(to: 5)
        let actualGoodDirect = buf.getData(at: 0, length: 5)
        XCTAssertEqual(Data([0, 1, 2, 3, 4]), actualGoodDirect)

        let actualGood = self.buf.readData(length: 4)
        XCTAssertEqual(Data([0, 1, 2, 3]), actualGood)
    }

    func testReadSliceNotEnoughAvailable() throws {
        /* write some bytes */
        self.buf.writeBytes(Data([0, 1, 2, 3]))

        /* make more available in the buffer that should not be readable */
        self.buf.setBytes(Data([4, 5, 6, 7]), at: 4)

        let actualNil = self.buf.readSlice(length: 5)
        XCTAssertNil(actualNil)

        self.buf.moveWriterIndex(forwardBy: 1)
        let actualGoodDirect = self.buf.getSlice(at: 0, length: 5)
        XCTAssertEqual(Data([0, 1, 2, 3, 4]), actualGoodDirect?.getData(at: 0, length: 5))

        var actualGood = self.buf.readSlice(length: 4)
        XCTAssertEqual(Data([0, 1, 2, 3]), actualGood?.readData(length: 4))
    }

    func testSetBuffer() throws {
        var src = self.allocator.buffer(capacity: 4)
        src.writeBytes(Data([0, 1, 2, 3]))

        self.buf.setBuffer(src, at: 1)

        /* Should bit increase the writerIndex of the src buffer */
        XCTAssertEqual(4, src.readableBytes)
        XCTAssertEqual(0, self.buf.readableBytes)

        self.buf.moveWriterIndex(to: 5)
        self.buf.moveReaderIndex(to: 1)
        XCTAssertEqual(Data([0, 1, 2, 3]), self.buf.getData(at: 1, length: 4))
    }

    func testWriteBuffer() throws {
        var src = allocator.buffer(capacity: 4)
        src.writeBytes(Data([0, 1, 2, 3]))

        buf.writeBuffer(&src)

        /* Should increase the writerIndex of the src buffer */
        XCTAssertEqual(0, src.readableBytes)
        XCTAssertEqual(4, buf.readableBytes)
        XCTAssertEqual(Data([0, 1, 2, 3]), buf.readData(length: 4))
    }

    func testMisalignedIntegerRead() throws {
        let value = UInt64(7)

        buf.writeBytes(Data([1]))
        buf.writeInteger(value)
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
        buf.writeString(str)
        var written1: Int = -1
        var written2: Int = -1
        hwData.withUnsafeBytes { ptr in
            /* ... write a second time and ...*/
            written1 = buf.setBytes(ptr, at: buf.writerIndex)
            buf.moveWriterIndex(forwardBy: written1)
            /* ... a lucky third time! */
            written2 = buf.writeBytes(ptr)
        }
        XCTAssertEqual(written1, written2)
        XCTAssertEqual(str.utf8.count, written1)
        XCTAssertEqual(3 * str.utf8.count, buf.readableBytes)
        let actualData = buf.readData(length: 3 * str.utf8.count)!
        let actualString = String(decoding: actualData, as: Unicode.UTF8.self)
        XCTAssertEqual(Array(repeating: str, count: 3).joined(), actualString)
    }

    func testCopyBytesWithNegativeLength() {
        self.buf.writeBytes([0x0, 0x1])
        XCTAssertThrowsError(try self.buf.copyBytes(at: self.buf.readerIndex, to: self.buf.readerIndex + 1, length: -1)) {
            XCTAssertEqual($0 as? ByteBuffer.CopyBytesError, .negativeLength)
        }
    }

    func testCopyBytesNonReadable() {
        let oldReaderIndex = self.buf.readerIndex
        self.buf.writeBytes([0x0, 0x1, 0x2])
        // Partially consume the bytes.
        self.buf.moveReaderIndex(forwardBy: 2)

        // Copy two read bytes.
        XCTAssertThrowsError(try self.buf.copyBytes(at: oldReaderIndex, to: self.buf.writerIndex, length: 2)) {
            XCTAssertEqual($0 as? ByteBuffer.CopyBytesError, .unreadableSourceBytes)
        }

        // Copy one read byte and one readable byte.
        XCTAssertThrowsError(try self.buf.copyBytes(at: oldReaderIndex + 1, to: self.buf.writerIndex, length: 2)) {
            XCTAssertEqual($0 as? ByteBuffer.CopyBytesError, .unreadableSourceBytes)
        }

        // Copy one readable byte and one uninitialized byte.
        XCTAssertThrowsError(try self.buf.copyBytes(at: oldReaderIndex + 3, to: self.buf.writerIndex, length: 2)) {
            XCTAssertEqual($0 as? ByteBuffer.CopyBytesError, .unreadableSourceBytes)
        }

        // Copy two uninitialized bytes.
        XCTAssertThrowsError(try self.buf.copyBytes(at: self.buf.writerIndex, to: oldReaderIndex, length: 2)) {
            XCTAssertEqual($0 as? ByteBuffer.CopyBytesError, .unreadableSourceBytes)
        }
    }

    func testCopyBytes() throws {
        self.buf.writeBytes([0, 1, 2, 3])
        XCTAssertNoThrow(try self.buf.copyBytes(at: self.buf.readerIndex, to: self.buf.readerIndex + 2, length: 2))
        XCTAssertEqual(self.buf.readableBytes, 4)
        XCTAssertEqual(self.buf.readBytes(length: self.buf.readableBytes), [0, 1, 0, 1])
    }

    func testCopyZeroBytesOutOfBoundsIsOk() throws {
        XCTAssertEqual(try self.buf.copyBytes(at: self.buf.writerIndex, to: self.buf.writerIndex + 42, length: 0), 0)
    }

    func testCopyBytesBeyondWriterIndex() throws {
        self.buf.writeBytes([0, 1, 2, 3])
        // Write beyond the writerIndex
        XCTAssertNoThrow(try self.buf.copyBytes(at: self.buf.readerIndex, to: self.buf.readerIndex + 4, length: 2))
        XCTAssertEqual(self.buf.readableBytes, 4)
        XCTAssertEqual(self.buf.readBytes(length: 2), [0, 1])
        XCTAssertNotNil(self.buf.readBytes(length: 2))  // could be anything!
        self.buf.moveWriterIndex(forwardBy: 2)  // We know these have been written.
        XCTAssertEqual(self.buf.readBytes(length: 2), [0, 1])
    }

    func testCopyBytesOverSelf() throws {
        self.buf.writeBytes([0, 1, 2, 3])
        XCTAssertNoThrow(try self.buf.copyBytes(at: self.buf.readerIndex, to: self.buf.readerIndex + 1, length: 3))
        XCTAssertEqual(self.buf.readableBytes, 4)
        XCTAssertEqual(self.buf.readBytes(length: self.buf.readableBytes), [0, 0, 1, 2])

        self.buf.writeBytes([0, 1, 2, 3])
        XCTAssertNoThrow(try self.buf.copyBytes(at: self.buf.readerIndex + 1, to: self.buf.readerIndex, length: 3))
        XCTAssertEqual(self.buf.readableBytes, 4)
        XCTAssertEqual(self.buf.readBytes(length: self.buf.readableBytes), [1, 2, 3, 3])
    }

    func testCopyBytesCoWs() throws {
        let bytes: [UInt8] = (0..<self.buf.writableBytes).map { UInt8($0 % Int(UInt8.max)) }
        self.buf.writeBytes(bytes)
        var otherBuf = self.buf!

        XCTAssertEqual(self.buf.writableBytes, 0)

        XCTAssertNoThrow(try self.buf.copyBytes(at: self.buf.readerIndex, to: self.buf.readerIndex + 2, length: 1))
        XCTAssertNotEqual(self.buf.readBytes(length: self.buf.readableBytes),
                          otherBuf.readBytes(length: otherBuf.readableBytes))
    }

    func testWriteABunchOfCollections() throws {
        let overallData = "0123456789abcdef".data(using: .utf8)!
        buf.writeBytes("0123".utf8)
        "4567".withCString { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 4) { ptr in
                _ = buf.writeBytes(UnsafeBufferPointer<UInt8>(start: ptr, count: 4))
            }
        }
        buf.writeBytes(Array("89ab".utf8))
        buf.writeBytes("cdef".data(using: .utf8)!)
        let actual = buf.getData(at: 0, length: buf.readableBytes)
        XCTAssertEqual(overallData, actual)
    }

    func testSetABunchOfCollections() throws {
        let overallData = "0123456789abcdef".data(using: .utf8)!
        self.buf.setBytes("0123".utf8, at: 0)
        _ = "4567".withCString { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 4) { ptr in
                self.buf.setBytes(UnsafeBufferPointer<UInt8>(start: ptr, count: 4), at: 4)
            }
        }
        self.buf.setBytes(Array("89ab".utf8), at: 8)
        self.buf.setBytes("cdef".data(using: .utf8)!, at: 12)
        self.buf.moveReaderIndex(to: 0)
        self.buf.moveWriterIndex(to: 16)
        let actual = self.buf.getData(at: 0, length: 16)
        XCTAssertEqual(overallData, actual)
    }

    func testTryStringTooLong() throws {
        let capacity = self.buf.capacity
        for i in 0..<self.buf.capacity {
            self.buf.setString("x", at: i)
        }
        XCTAssertEqual(capacity, self.buf.capacity,
                       "buffer capacity needlessly changed from \(capacity) to \(self.buf.capacity)")
        XCTAssertNil(self.buf.getString(at: 0, length: capacity+1))
    }

    func testSetGetBytesAllFine() throws {
        self.buf.moveReaderIndex(to: 0)
        self.buf.setBytes([1, 2, 3, 4], at: 0)
        self.buf.moveWriterIndex(to: 4)
        XCTAssertEqual([1, 2, 3, 4], self.buf.getBytes(at: 0, length: 4) ?? [])

        let capacity = self.buf.capacity
        for i in 0..<self.buf.capacity {
            self.buf.setBytes([0xFF], at: i)
        }
        self.buf.moveWriterIndex(to: self.buf.capacity)
        XCTAssertEqual(capacity, buf.capacity, "buffer capacity needlessly changed from \(capacity) to \(buf.capacity)")
        XCTAssertEqual(Array(repeating: 0xFF, count: capacity), self.buf.getBytes(at: 0, length: capacity))

    }

    func testGetBytesTooLong() throws {
        XCTAssertNil(buf.getBytes(at: 0, length: buf.capacity+1))
        XCTAssertNil(buf.getBytes(at: buf.capacity, length: 1))
    }

    func testReadWriteBytesOkay() throws {
        buf.reserveCapacity(24)
        buf.clear()
        let capacity = buf.capacity
        for i in 0..<capacity {
            let expected = Array(repeating: UInt8(i % 255), count: i)
            buf.writeBytes(expected)
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
        buf.reserveCapacity(1024)
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
        var buf = ByteBufferAllocator().buffer(capacity: 1)
        buf.clear()
        buf.writeBytes([1, 2, 3, 4, 5, 6, 7, 8])
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
        buf.reserveCapacity(1024)
        buf.writeStaticString("hello world, just some trap bytes here")

        func testIndexAndLengthFunc<T>(_ body: (Int, Int) -> T?, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNil(body(Int.max, 1), file: (file), line: line)
            XCTAssertNil(body(Int.max - 1, 2), file: (file), line: line)
            XCTAssertNil(body(1, Int.max), file: (file), line: line)
            XCTAssertNil(body(2, Int.max - 1), file: (file), line: line)
            XCTAssertNil(body(Int.max, Int.max), file: (file), line: line)
            XCTAssertNil(body(Int.min, Int.min), file: (file), line: line)
            XCTAssertNil(body(Int.max, Int.min), file: (file), line: line)
            XCTAssertNil(body(Int.min, Int.max), file: (file), line: line)
        }

        func testIndexOrLengthFunc<T>(_ body: (Int) -> T?, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNil(body(Int.max))
            XCTAssertNil(body(Int.max - 1))
            XCTAssertNil(body(Int.min))
        }

        testIndexOrLengthFunc({ buf.readBytes(length: $0) })
        testIndexOrLengthFunc({ buf.readData(length: $0) })
        testIndexOrLengthFunc({ buf.readSlice(length: $0) })
        testIndexOrLengthFunc({ buf.readString(length: $0) })
        testIndexOrLengthFunc({ buf.readDispatchData(length: $0) })

        testIndexOrLengthFunc({ buf.getInteger(at: $0, as: UInt8.self) })
        testIndexOrLengthFunc({ buf.getInteger(at: $0, as: UInt16.self) })
        testIndexOrLengthFunc({ buf.getInteger(at: $0, as: UInt32.self) })
        testIndexOrLengthFunc({ buf.getInteger(at: $0, as: UInt64.self) })
        testIndexAndLengthFunc(buf.getBytes)
        testIndexAndLengthFunc(buf.getData)
        testIndexAndLengthFunc(buf.getSlice)
        testIndexAndLengthFunc(buf.getString)
        testIndexAndLengthFunc(buf.getDispatchData)
        testIndexAndLengthFunc(buf.viewBytes(at:length:))
    }

    func testWriteForContiguousCollections() throws {
        buf.clear()
        var written = buf.writeBytes([1, 2, 3, 4])
        XCTAssertEqual(4, written)
        // UnsafeRawBufferPointer
        written += [5 as UInt8, 6, 7, 8].withUnsafeBytes { ptr in
            buf.writeBytes(ptr)
        }
        XCTAssertEqual(8, written)
        // UnsafeBufferPointer<UInt8>
        written += [9 as UInt8, 10, 11, 12].withUnsafeBufferPointer { ptr in
            buf.writeBytes(ptr)
        }
        XCTAssertEqual(12, written)
        // ContiguousArray
        written += buf.writeBytes(ContiguousArray<UInt8>([13, 14, 15, 16]))
        XCTAssertEqual(16, written)

        // Data
        written += buf.writeBytes("EFGH".data(using: .utf8)!)
        XCTAssertEqual(20, written)
        var more = Array("IJKL".utf8)

        // UnsafeMutableRawBufferPointer
        written += more.withUnsafeMutableBytes { ptr in
            buf.writeBytes(ptr)
        }
        more = Array("MNOP".utf8)
        // UnsafeMutableBufferPointer<UInt8>
        written += more.withUnsafeMutableBufferPointer { ptr in
            buf.writeBytes(ptr)
        }
        more = Array("mnopQRSTuvwx".utf8)

        // ArraySlice
        written += buf.writeBytes(more.dropFirst(4).dropLast(4))

        let moreCA = ContiguousArray("qrstUVWXyz01".utf8)
        // ContiguousArray's slice (== ArraySlice)
        written += buf.writeBytes(moreCA.dropFirst(4).dropLast(4))

        // Slice<UnsafeRawBufferPointer>
        written += Array("uvwxYZ01abcd".utf8).withUnsafeBytes { ptr in
            buf.writeBytes(ptr.dropFirst(4).dropLast(4) as UnsafeRawBufferPointer.SubSequence)
        }
        more = Array("2345".utf8)
        written += more.withUnsafeMutableBytes { ptr in
            buf.writeBytes(ptr.dropFirst(0)) + buf.writeBytes(ptr.dropFirst(4 /* drop all of them */))
        }

        let expected = Array(1...16) + Array("EFGHIJKLMNOPQRSTUVWXYZ012345".utf8)

        XCTAssertEqual(expected, buf.readBytes(length: written)!)
    }

    func testWriteForNonContiguousCollections() throws {
        buf.clear()
        let written = buf.writeBytes("ABCD".utf8)
        XCTAssertEqual(4, written)

        let expected = ["A".utf8.first!, "B".utf8.first!, "C".utf8.first!, "D".utf8.first!]

        XCTAssertEqual(expected, buf.readBytes(length: written)!)
    }

    func testReadStringOkay() throws {
        buf.clear()
        let expected = "hello"
        buf.writeString(expected)
        let actual = buf.readString(length: expected.utf8.count)
        XCTAssertEqual(expected, actual)
        XCTAssertEqual("", buf.readString(length: 0))
        XCTAssertNil(buf.readString(length: 1))
    }

    func testReadStringTooMuch() throws {
        buf.clear()
        XCTAssertNil(buf.readString(length: 1))

        buf.writeString("a")
        XCTAssertNil(buf.readString(length: 2))

        XCTAssertEqual("a", buf.readString(length: 1))
    }

    func testSetIntegerBeyondCapacity() throws {
        var buf = ByteBufferAllocator().buffer(capacity: 32)
        XCTAssertLessThan(buf.capacity, 200)

        buf.setInteger(17, at: 201)
        buf.moveWriterIndex(to: 201 + MemoryLayout<Int>.size)
        buf.moveReaderIndex(to: 201)
        let i: Int = buf.getInteger(at: 201)!
        XCTAssertEqual(17, i)
        XCTAssertGreaterThanOrEqual(buf.capacity, 200 + MemoryLayout.size(ofValue: i))
    }

    func testGetIntegerBeyondCapacity() throws {
        let buf = ByteBufferAllocator().buffer(capacity: 32)
        XCTAssertLessThan(buf.capacity, 200)

        let i: Int? = buf.getInteger(at: 201)
        XCTAssertNil(i)
    }

    func testSetStringBeyondCapacity() throws {
        var buf = ByteBufferAllocator().buffer(capacity: 32)
        XCTAssertLessThan(buf.capacity, 200)

        buf.setString("HW", at: 201)
        buf.moveWriterIndex(to: 201 + 2)
        buf.moveReaderIndex(to: 201)
        let s = buf.getString(at: 201, length: 2)!
        XCTAssertEqual("HW", s)
        XCTAssertGreaterThanOrEqual(buf.capacity, 202)
    }

    func testGetStringBeyondCapacity() throws {
        let buf = ByteBufferAllocator().buffer(capacity: 32)
        XCTAssertLessThan(buf.capacity, 200)

        let i: String? = buf.getString(at: 201, length: 1)
        XCTAssertNil(i)
    }

    func testAllocationOfReallyBigByteBuffer() throws {
        #if arch(arm) || arch(i386)
        // this test doesn't work on 32-bit platforms because the address space is only 4GB large and we're trying
        // to make a 4GB ByteBuffer which just won't fit. Even going down to 2GB won't make it better.
        return
        #endif
        let alloc = ByteBufferAllocator(hookedMalloc: { testAllocationOfReallyBigByteBuffer_mallocHook($0) },
                                        hookedRealloc: { testAllocationOfReallyBigByteBuffer_reallocHook($0, $1) },
                                        hookedFree: { testAllocationOfReallyBigByteBuffer_freeHook($0) },
                                        hookedMemcpy: { testAllocationOfReallyBigByteBuffer_memcpyHook($0, $1, $2) })

        let reallyBigSize = Int(Int32.max)
        XCTAssertEqual(AllocationExpectationState.begin, testAllocationOfReallyBigByteBuffer_state)
        var buf = alloc.buffer(capacity: reallyBigSize)
        XCTAssertEqual(AllocationExpectationState.mallocDone, testAllocationOfReallyBigByteBuffer_state)
        XCTAssertGreaterThanOrEqual(buf.capacity, reallyBigSize)

        buf.setBytes([1], at: 0)
        /* now make it expand (will trigger realloc) */
        buf.setBytes([1], at: buf.capacity)

        XCTAssertEqual(AllocationExpectationState.reallocDone, testAllocationOfReallyBigByteBuffer_state)
        XCTAssertEqual(buf.capacity, Int(UInt32.max))
    }

    func testWritableBytesAccountsForSlicing() throws {
        var buf = ByteBufferAllocator().buffer(capacity: 32)
        XCTAssertEqual(buf.capacity, 32)
        XCTAssertEqual(buf.writableBytes, 32)
        let oldWriterIndex = buf.writerIndex
        buf.writeStaticString("01234567")
        let newBuf = buf.getSlice(at: oldWriterIndex, length: 8)!
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
    
    func testClearWithBiggerMinimumCapacityDupesStorageIfTheresTwoBuffersSharingStorage() throws {
        let alloc = ByteBufferAllocator()
        let buf1 = alloc.buffer(capacity: 16)
        var buf2 = buf1

        var buf1PtrVal: UInt = 1
        var buf2PtrVal: UInt = 2
        
        buf1PtrVal = buf1.storagePointerIntegerValue()
        buf2PtrVal = buf2.storagePointerIntegerValue()
        
        XCTAssertEqual(buf1PtrVal, buf2PtrVal)

        buf2.clear(minimumCapacity: 32)

        buf1PtrVal = buf1.storagePointerIntegerValue()
        buf2PtrVal = buf2.storagePointerIntegerValue()

        XCTAssertNotEqual(buf1PtrVal, buf2PtrVal)
        XCTAssertLessThan(buf1.capacity, 32)
        XCTAssertGreaterThanOrEqual(buf2.capacity, 32)
    }
    
    func testClearWithSmallerMinimumCapacityDupesStorageIfTheresTwoBuffersSharingStorage() throws {
        let alloc = ByteBufferAllocator()
        let buf1 = alloc.buffer(capacity: 16)
        var buf2 = buf1

        var buf1PtrVal: UInt = 1
        var buf2PtrVal: UInt = 2
        
        buf1PtrVal = buf1.storagePointerIntegerValue()
        buf2PtrVal = buf2.storagePointerIntegerValue()

        XCTAssertEqual(buf1PtrVal, buf2PtrVal)

        buf2.clear(minimumCapacity: 4)

        buf1PtrVal = buf1.storagePointerIntegerValue()
        buf2PtrVal = buf2.storagePointerIntegerValue()

        XCTAssertNotEqual(buf1PtrVal, buf2PtrVal)
        XCTAssertGreaterThanOrEqual(buf1.capacity, 16)
        XCTAssertLessThan(buf2.capacity, 16)
    }

    func testClearWithBiggerMinimumCapacityDoesNotDupeStorageIfTheresOnlyOneBuffer() throws {
        let alloc = ByteBufferAllocator()
        var buf = alloc.buffer(capacity: 16)

        XCTAssertLessThan(buf.capacity, 32)
        let preCapacity = buf.capacity

        buf.clear(minimumCapacity: 32)
        let postCapacity = buf.capacity

        XCTAssertGreaterThanOrEqual(buf.capacity, 32)
        XCTAssertNotEqual(preCapacity, postCapacity)
    }
    
    func testClearWithSmallerMinimumCapacityDoesNotDupeStorageIfTheresOnlyOneBuffer() throws {
        let alloc = ByteBufferAllocator()
        var buf = alloc.buffer(capacity: 16)

        var bufPtrValPre: UInt = 1
        var bufPtrValPost: UInt = 2

        let preCapacity = buf.capacity
        XCTAssertGreaterThanOrEqual(buf.capacity, 16)
        
        bufPtrValPre = buf.storagePointerIntegerValue()
        buf.clear(minimumCapacity: 8)
        bufPtrValPost = buf.storagePointerIntegerValue()
        let postCapacity = buf.capacity

        XCTAssertEqual(bufPtrValPre, bufPtrValPost)
        XCTAssertEqual(preCapacity, postCapacity)
    }

    func testClearWithBiggerCapacityDoesReallocateStorageCorrectlyIfTheresOnlyOneBuffer() throws {
        let alloc = ByteBufferAllocator()
        var buf = alloc.buffer(capacity: 16)

        buf.clear(minimumCapacity: 32)

        XCTAssertEqual(buf._storage.capacity, 32)
    }

    func testClearWithSmallerCapacityDoesReallocateStorageCorrectlyIfTheresOnlyOneBuffer() throws {
        let alloc = ByteBufferAllocator()
        var buf = alloc.buffer(capacity: 16)

        buf.clear(minimumCapacity: 8)

        XCTAssertEqual(buf._storage.capacity, 16)
    }

    func testClearDoesAllocateStorageCorrectlyIfTheresTwoBuffersSharingStorage() throws {
        let alloc = ByteBufferAllocator()
        var buf1 = alloc.buffer(capacity: 16)
        let buf2 = buf1

        buf1.clear(minimumCapacity: 8)

        XCTAssertEqual(buf1._storage.capacity, 8)
        XCTAssertEqual(buf2._storage.capacity, 16)
    }

    func testClearResetsTheSliceCapacityIfTheresOnlyOneBuffer() {
        let alloc = ByteBufferAllocator()
        var buf = alloc.buffer(capacity: 16)
        buf.writeString("qwertyuiop")
        XCTAssertEqual(buf.capacity, 16)

        var slice = buf.getSlice(at: 3, length: 4)!
        XCTAssertEqual(slice.capacity, 4)

        slice.clear()
        XCTAssertEqual(slice.capacity, 16)
    }

    func testClearResetsTheSliceCapacityIfTheresTwoSlicesSharingStorage() {
        let alloc = ByteBufferAllocator()
        var buf = alloc.buffer(capacity: 16)
        buf.writeString("qwertyuiop")

        var slice1 = buf.getSlice(at: 3, length: 4)!
        let slice2 = slice1

        slice1.clear()
        XCTAssertEqual(slice1.capacity, 16)
        XCTAssertEqual(slice2.capacity, 4)
    }

    func testWeUseFastWriteForContiguousCollections() throws {
        struct WrongCollection: Collection {
            let storage: [UInt8] = [1, 2, 3]
            typealias Element = UInt8
            typealias Index = Array<UInt8>.Index
            typealias SubSequence = Array<UInt8>.SubSequence
            typealias Indices = Array<UInt8>.Indices
            public var indices: Indices {
                return self.storage.indices
            }
            public subscript(bounds: Range<Index>) -> SubSequence {
                return self.storage[bounds]
            }

            public subscript(position: Index) -> Element {
                /* this is wrong but we need to check that we don't access this */
                XCTFail("shouldn't have been called")
                return 0xff
            }

            public var startIndex: Index {
                return self.storage.startIndex
            }

            public var endIndex: Index {
                return self.storage.endIndex
            }

            func index(after i: Index) -> Index {
                return self.storage.index(after: i)
            }

            func withContiguousStorageIfAvailable<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R? {
                return try self.storage.withUnsafeBufferPointer(body)
            }
        }
        buf.clear()
        buf.writeBytes(WrongCollection())
        XCTAssertEqual(3, buf.readableBytes)
        XCTAssertEqual(1, buf.readInteger()! as UInt8)
        XCTAssertEqual(2, buf.readInteger()! as UInt8)
        XCTAssertEqual(3, buf.readInteger()! as UInt8)
        buf.setBytes(WrongCollection(), at: 0)
        XCTAssertEqual(0, buf.readableBytes)
        buf.moveWriterIndex(to: 3)
        buf.moveReaderIndex(to: 0)
        XCTAssertEqual(1, buf.getInteger(at: 0, as: UInt8.self))
        XCTAssertEqual(2, buf.getInteger(at: 1, as: UInt8.self))
        XCTAssertEqual(3, buf.getInteger(at: 2, as: UInt8.self))
    }

    func testUnderestimatingSequenceWorks() throws {
        struct UnderestimatingSequence: Sequence {
            let storage: [UInt8] = Array(0...255)
            typealias Element = UInt8

            public var indices: CountableRange<Int> {
                return self.storage.indices
            }

            public subscript(position: Int) -> Element {
                return self.storage[position]
            }

            public var underestimatedCount: Int {
                return 8
            }

            func makeIterator() -> Array<UInt8>.Iterator {
                return self.storage.makeIterator()
            }
        }
        buf = self.allocator.buffer(capacity: 4)
        buf.clear()
        buf.writeBytes(UnderestimatingSequence())
        XCTAssertEqual(256, buf.readableBytes)
        for i in 0..<256 {
            let actual = Int(buf.readInteger()! as UInt8)
            XCTAssertEqual(i, actual)
        }
        buf = self.allocator.buffer(capacity: 4)
        buf.setBytes(UnderestimatingSequence(), at: 0)
        XCTAssertEqual(0, buf.readableBytes)
        buf.moveWriterIndex(to: 256)
        buf.moveReaderIndex(to: 0)
        for i in 0..<256 {
            XCTAssertEqual(i, buf.getInteger(at: i, as: UInt8.self).map(Int.init))
        }
    }

    func testZeroSizeByteBufferResizes() {
        var buf = ByteBuffer()
        buf.writeStaticString("x")
        XCTAssertEqual(buf.writerIndex, 1)
    }

    func testSpecifyTypesAndEndiannessForIntegerMethods() {
        self.buf.clear()
        self.buf.writeInteger(-1, endianness: .big, as: Int64.self)
        XCTAssertEqual(-1, self.buf.readInteger(endianness: .big, as: Int64.self))
        self.buf.setInteger(0xdeadbeef, at: 0, endianness: .little, as: UInt64.self)
        self.buf.moveWriterIndex(to: 8)
        self.buf.moveReaderIndex(to: 0)
        XCTAssertEqual(0xdeadbeef, self.buf.getInteger(at: 0, endianness: .little, as: UInt64.self))
    }

    func testByteBufferFitsInACoupleOfEnums() throws {
        enum Level4 {
            case case1(ByteBuffer)
            case case2(ByteBuffer)
            case case3(ByteBuffer)
            case case4(ByteBuffer)
        }
        enum Level3 {
            case case1(Level4)
            case case2(Level4)
            case case3(Level4)
            case case4(Level4)
        }
        enum Level2 {
            case case1(Level3)
            case case2(Level3)
            case case3(Level3)
            case case4(Level3)
        }
        enum Level1 {
            case case1(Level2)
            case case2(Level2)
            case case3(Level2)
            case case4(Level2)
        }

        XCTAssertLessThanOrEqual(MemoryLayout<ByteBuffer>.size, 23)
        XCTAssertLessThanOrEqual(MemoryLayout<Level1>.size, 24)

        XCTAssertLessThanOrEqual(MemoryLayout.size(ofValue: Level1.case1(.case2(.case3(.case4(self.buf))))), 24)
        XCTAssertLessThanOrEqual(MemoryLayout.size(ofValue: Level1.case1(.case3(.case4(.case1(self.buf))))), 24)
    }

    func testLargeSliceBegin16MBIsOkayAndDoesNotCopy() throws {
        var fourMBBuf = self.allocator.buffer(capacity: 4 * 1024 * 1024)
        fourMBBuf.writeBytes(Array<UInt8>(repeating: 0xff, count: fourMBBuf.capacity))
        let totalBufferSize = 5 * fourMBBuf.readableBytes
        XCTAssertEqual(4 * 1024 * 1024, fourMBBuf.readableBytes)
        var buf = self.allocator.buffer(capacity: totalBufferSize)
        for _ in 0..<5 {
            var fresh = fourMBBuf
            buf.writeBuffer(&fresh)
        }

        let offset = Int(_UInt24.max)

        // mark some special bytes
        buf.setInteger(0xaa, at: 0, as: UInt8.self)
        buf.setInteger(0xbb, at: offset - 1, as: UInt8.self)
        buf.setInteger(0xcc, at: offset, as: UInt8.self)
        buf.setInteger(0xdd, at: buf.writerIndex - 1, as: UInt8.self)

        XCTAssertEqual(totalBufferSize, buf.readableBytes)

        let oldPtrVal = buf.withUnsafeReadableBytes {
            UInt(bitPattern: $0.baseAddress!.advanced(by: offset))
        }

        let expectedReadableBytes = totalBufferSize - offset
        let slice = buf.getSlice(at: offset, length: expectedReadableBytes)!
        XCTAssertEqual(expectedReadableBytes, slice.readableBytes)
        let newPtrVal = slice.withUnsafeReadableBytes {
            UInt(bitPattern: $0.baseAddress!)
        }
        XCTAssertEqual(oldPtrVal, newPtrVal)

        XCTAssertEqual(0xcc, slice.getInteger(at: 0, as: UInt8.self))
        XCTAssertEqual(0xdd, slice.getInteger(at: slice.writerIndex - 1, as: UInt8.self))
    }

    func testLargeSliceBeginMoreThan16MBIsOkay() throws {
        var fourMBBuf = self.allocator.buffer(capacity: 4 * 1024 * 1024)
        fourMBBuf.writeBytes(Array<UInt8>(repeating: 0xff, count: fourMBBuf.capacity))
        let totalBufferSize = 5 * fourMBBuf.readableBytes + 1
        XCTAssertEqual(4 * 1024 * 1024, fourMBBuf.readableBytes)
        var buf = self.allocator.buffer(capacity: totalBufferSize)
        for _ in 0..<5 {
            var fresh = fourMBBuf
            buf.writeBuffer(&fresh)
        }

        let offset = Int(_UInt24.max) + 1

        // mark some special bytes
        buf.setInteger(0xaa, at: 0, as: UInt8.self)
        buf.setInteger(0xbb, at: offset - 1, as: UInt8.self)
        buf.setInteger(0xcc, at: offset, as: UInt8.self)
        buf.writeInteger(0xdd, as: UInt8.self) // write extra byte so the slice is the same length as above
        XCTAssertEqual(totalBufferSize, buf.readableBytes)

        let expectedReadableBytes = totalBufferSize - offset
        let slice = buf.getSlice(at: offset, length: expectedReadableBytes)!
        XCTAssertEqual(expectedReadableBytes, slice.readableBytes)
        XCTAssertEqual(0, slice.readerIndex)
        XCTAssertEqual(expectedReadableBytes, slice.writerIndex)
        XCTAssertEqual(Int(UInt32(expectedReadableBytes).nextPowerOf2()), slice.capacity)

        XCTAssertEqual(0xcc, slice.getInteger(at: 0, as: UInt8.self))
        XCTAssertEqual(0xdd, slice.getInteger(at: slice.writerIndex - 1, as: UInt8.self))
    }

    func testSliceOfMassiveBufferWithAdvancedReaderIndexIsOk() throws {
        // We only want to run this test on 64-bit systems: 32-bit systems can't allocate buffers
        // large enough to run this test safely.
        guard MemoryLayout<Int>.size >= 8 else {
            throw XCTSkip("This test is only supported on 64-bit systems.")
        }

        // This allocator assumes that we'll never call realloc.
        let fakeAllocator = ByteBufferAllocator(
            hookedMalloc: { _ in .init(bitPattern: 0xdedbeef) },
            hookedRealloc: { _, _ in fatalError() },
            hookedFree: { precondition($0 == .init(bitPattern: 0xdedbeef)!) },
            hookedMemcpy: {_, _, _ in }
        )

        let targetSize = Int(UInt32.max)
        var buffer = fakeAllocator.buffer(capacity: targetSize)

        // Move the reader index forward such that we hit the slow path.
        let offset = Int(_UInt24.max) + 1
        buffer.moveWriterIndex(to: offset)
        buffer.moveReaderIndex(to: offset)

        // Pretend we wrote a UInt32.
        buffer.moveWriterIndex(forwardBy: 4)

        // We're going to move the readerIndex forward by 1, and then slice.
        buffer.moveReaderIndex(forwardBy: 1)
        let slice = buffer.getSlice(at: buffer.readerIndex, length: 3)!
        XCTAssertEqual(slice.readableBytes, 3)
        XCTAssertEqual(slice.readerIndex, 0)
        XCTAssertEqual(Int(UInt32(3).nextPowerOf2()), slice.capacity)
    }
    
    func testSliceOnSliceAfterHitting16MBMark() {
        // This test ensures that a slice will get a new backing storage if its start is more than
        // 16MiB after the originating backing storage.
        
        // create a buffer with 16MiB + 1 byte
        let inputBufferLength = 16 * 1024 * 1024 + 1
        var inputBuffer = ByteBufferAllocator().buffer(capacity: inputBufferLength)
        inputBuffer.writeRepeatingByte(1, count: 8)
        inputBuffer.writeRepeatingByte(2, count: inputBufferLength - 9)
        inputBuffer.writeRepeatingByte(3, count: 1)
        // read a small slice from the inputBuffer, to create an offset of eight bytes
        XCTAssertEqual(inputBuffer.readInteger(as: UInt64.self), 0x0101010101010101)
        
        // read the remaining bytes into a new slice (this will have a length of 16MiB - 7Bbytes)
        let remainingSliceLength = inputBufferLength - 8
        XCTAssertEqual(inputBuffer.readableBytes, remainingSliceLength)
        var remainingSlice = inputBuffer.readSlice(length: remainingSliceLength)!
        
        let finalSliceLength = 1
        // let's create a new buffer that uses all but one byte
        XCTAssertEqual(remainingSlice.readBytes(length: remainingSliceLength - finalSliceLength),
                       Array<UInt8>(repeating: 2, count: remainingSliceLength - finalSliceLength))
        
        // there should only be one byte left.
        XCTAssertEqual(remainingSlice.readableBytes, finalSliceLength)
        
        // with just one byte left, the last byte is exactly one byte above the 16MiB threshold.
        // For this reason a slice of the last byte, will need to get a new backing storage.
        let finalSlice = remainingSlice.readSlice(length: finalSliceLength)
        XCTAssertNotEqual(finalSlice?.storagePointerIntegerValue(), remainingSlice.storagePointerIntegerValue())
        XCTAssertEqual(finalSlice?.storageCapacity, 1)
        XCTAssertEqual(finalSlice, ByteBuffer(integer: 3, as: UInt8.self))
        
        XCTAssertEqual(remainingSlice.readableBytes, 0)
    }

    func testDiscardReadBytesOnConsumedBuffer() {
        var buffer = self.allocator.buffer(capacity: 8)
        buffer.writeInteger(0xaa, as: UInt8.self)
        XCTAssertEqual(1, buffer.readableBytes)
        XCTAssertEqual(0xaa, buffer.readInteger(as: UInt8.self))
        XCTAssertEqual(0, buffer.readableBytes)

        let buffer2 = buffer
        XCTAssertTrue(buffer.discardReadBytes())
        XCTAssertEqual(0, buffer.readerIndex)
        XCTAssertEqual(0, buffer.writerIndex)
        // As we fully consumed the buffer we should only have adjusted the indices but not triggered a copy as result of CoW semantics.
        // So we should still be able to also read the old data.
        buffer.moveWriterIndex(to: 1)
        buffer.moveReaderIndex(to: 0)
        XCTAssertEqual(0xaa, buffer.getInteger(at: 0, as: UInt8.self))
        XCTAssertEqual(0, buffer2.readableBytes)
    }

    func testDumpBytesFormat() throws {
        self.buf.clear()
        for f in UInt8.min...UInt8.max {
            self.buf.writeInteger(f)
        }
        let actual = self.buf._storage.dumpBytes(slice: self.buf._slice, offset: 0, length: self.buf.readableBytes)
        let expected = """
        [ \
        00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f \
        20 21 22 23 24 25 26 27 28 29 2a 2b 2c 2d 2e 2f 30 31 32 33 34 35 36 37 38 39 3a 3b 3c 3d 3e 3f \
        40 41 42 43 44 45 46 47 48 49 4a 4b 4c 4d 4e 4f 50 51 52 53 54 55 56 57 58 59 5a 5b 5c 5d 5e 5f \
        60 61 62 63 64 65 66 67 68 69 6a 6b 6c 6d 6e 6f 70 71 72 73 74 75 76 77 78 79 7a 7b 7c 7d 7e 7f \
        80 81 82 83 84 85 86 87 88 89 8a 8b 8c 8d 8e 8f 90 91 92 93 94 95 96 97 98 99 9a 9b 9c 9d 9e 9f \
        a0 a1 a2 a3 a4 a5 a6 a7 a8 a9 aa ab ac ad ae af b0 b1 b2 b3 b4 b5 b6 b7 b8 b9 ba bb bc bd be bf \
        c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 ca cb cc cd ce cf d0 d1 d2 d3 d4 d5 d6 d7 d8 d9 da db dc dd de df \
        e0 e1 e2 e3 e4 e5 e6 e7 e8 e9 ea eb ec ed ee ef f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 fa fb fc fd fe ff ]
        """
        XCTAssertEqual(expected, actual)
    }

    func testReadableBytesView() throws {
        self.buf.clear()
        self.buf.writeString("hello world 012345678")
        XCTAssertEqual("hello ", self.buf.readString(length: 6))
        self.buf.moveWriterIndex(to: self.buf.writerIndex - 10)
        XCTAssertEqual("world", String(decoding: self.buf.readableBytesView, as: Unicode.UTF8.self))
        XCTAssertEqual("world", self.buf.readString(length: self.buf.readableBytes))
    }

    func testReadableBytesViewNoReadableBytes() throws {
        self.buf.clear()
        let view = self.buf.readableBytesView
        XCTAssertEqual(0, view.count)
    }

    func testBytesView() throws {
        self.buf.clear()
        self.buf.writeString("hello world 012345678")
        XCTAssertEqual(self.buf.viewBytes(at: self.buf.readerIndex,
                                          length: self.buf.writerIndex - self.buf.readerIndex).map { (view: ByteBufferView) -> String in
                                            String(decoding: view, as: Unicode.UTF8.self)
                                          },
                       self.buf.getString(at: self.buf.readerIndex, length: self.buf.readableBytes))
        XCTAssertEqual(self.buf.viewBytes(at: 0, length: 0).map { Array($0) }, [])
        XCTAssertEqual(Array("hello world 012345678".utf8),
                       self.buf.viewBytes(at: 0, length: self.buf.readableBytes).map(Array.init))
    }

    func testViewsStartIndexIsStable() throws {
        self.buf.writeString("hello")
        let view: ByteBufferView? = self.buf.viewBytes(at: 1, length: 3)
        XCTAssertEqual(1, view?.startIndex)
        XCTAssertEqual(3, view?.count)
        XCTAssertEqual(4, view?.endIndex)
        XCTAssertEqual("ell", view.map { String(decoding: $0, as: Unicode.UTF8.self) })
    }

    func testSlicesOfByteBufferViewsAreByteBufferViews() throws {
        self.buf.writeString("hello")
        let view: ByteBufferView? = self.buf.viewBytes(at: 1, length: 3)
        XCTAssertEqual("ell", view.map { String(decoding: $0, as: Unicode.UTF8.self) })
        let viewSlice: ByteBufferView? = view.map { $0[$0.startIndex + 1 ..< $0.endIndex] }
        XCTAssertEqual("ll", viewSlice.map { String(decoding: $0, as: Unicode.UTF8.self) })
        XCTAssertEqual("l", viewSlice.map { String(decoding: $0.dropFirst(), as: Unicode.UTF8.self) })
        XCTAssertEqual("", viewSlice.map { String(decoding: $0.dropFirst().dropLast(), as: Unicode.UTF8.self) })
    }
    
    func testReadableBufferViewRangeEqualCapacity() throws {
        self.buf.clear()
        self.buf.moveWriterIndex(forwardBy: buf.capacity)
        let view = self.buf.readableBytesView
        let viewSlice: ByteBufferView = view[view.startIndex ..< view.endIndex]
        XCTAssertEqual(buf.readableBytes, viewSlice.count)
    }

    func testBufferViewCoWs() throws {
        self.buf.writeBytes([0x0, 0x1, 0x2])
        var view = self.buf.readableBytesView
        view.replaceSubrange(view.indices, with: [0xa, 0xb, 0xc])

        XCTAssertEqual(self.buf.readBytes(length: 3), [0x0, 0x1, 0x2])
        XCTAssertTrue(view.elementsEqual([0xa, 0xb, 0xc]))

        self.buf.writeBytes([0x0, 0x1, 0x2])
        view = self.buf.readableBytesView
        view.replaceSubrange(view.indices, with: [0xa, 0xb])

        XCTAssertEqual(self.buf.readBytes(length: 3), [0x0, 0x1, 0x2])
        XCTAssertTrue(view.elementsEqual([0xa, 0xb]))

        self.buf.writeBytes([0x0, 0x1, 0x2])
        view = self.buf.readableBytesView
        view.replaceSubrange(view.indices, with: [0xa, 0xb, 0xc, 0xd])

        XCTAssertEqual(self.buf.readBytes(length: 3), [0x0, 0x1, 0x2])
        XCTAssertTrue(view.elementsEqual([0xa, 0xb, 0xc, 0xd]))
    }

    func testBufferViewMutationViaSubscriptIndex() throws {
        self.buf.writeBytes([0x0, 0x1, 0x2])
        var view = self.buf.readableBytesView

        view[0] = 0xa
        view[1] = 0xb
        view[2] = 0xc

        XCTAssertTrue(view.elementsEqual([0xa, 0xb, 0xc]))
    }

    func testBufferViewReplaceBeyondEndOfRange() throws {
        self.buf.writeBytes([1, 2, 3])
        var view = self.buf.readableBytesView
        view.replaceSubrange(2..<3, with: [2, 3, 4])
        XCTAssertTrue(view.elementsEqual([1, 2, 2, 3, 4]))
    }

    func testBufferViewReplaceWithSubrangeOfSelf() throws {
        let oneToNine: [UInt8] = (1...9).map { $0 }
        self.buf.writeBytes(oneToNine)
        var view = self.buf.readableBytesView

        view[6..<9] = view[0..<3]
        XCTAssertTrue(view.elementsEqual([1, 2, 3, 4, 5, 6, 1, 2, 3]))

        view[0..<3] = view[1..<4]
        XCTAssertTrue(view.elementsEqual([2, 3, 4, 4, 5, 6, 1, 2, 3]))

        view[1..<4] = view[0..<3]
        XCTAssertTrue(view.elementsEqual([2, 2, 3, 4, 5, 6, 1, 2, 3]))
    }

    func testBufferViewMutationViaSubscriptRange() throws {
        let oneToNine: [UInt8] = (1...9).map { $0 }
        var oneToNineBuffer = self.allocator.buffer(capacity: 9)
        oneToNineBuffer.writeBytes(oneToNine)
        let oneToNineView = oneToNineBuffer.readableBytesView

        self.buf.writeBytes(Array(repeating: UInt8(0), count: 9))
        var view = self.buf.readableBytesView

        view[0..<3] = oneToNineView[0..<3]
        XCTAssertTrue(view.elementsEqual([1, 2, 3, 0, 0, 0, 0, 0, 0]))

        // Replace with shorter range
        view[3..<6] = oneToNineView[3..<5]
        XCTAssertTrue(view.elementsEqual([1, 2, 3, 4, 5, 0, 0, 0]))

        // Replace with longer range
        view[5..<8] = oneToNineView[5..<9]
        XCTAssertTrue(view.elementsEqual(oneToNine))
    }

    func testBufferViewReplaceSubrangeWithEqualLengthBytes() throws {
        self.buf.writeBytes([0x0, 0x1, 0x2, 0x3, 0x4])

        var view = ByteBufferView(self.buf)
        XCTAssertEqual(view.count, self.buf.readableBytes)

        view.replaceSubrange(view.indices.suffix(3), with: [0xd, 0xe, 0xf])

        var modifiedBuf = ByteBuffer(view)
        XCTAssertEqual(self.buf.readerIndex, modifiedBuf.readerIndex)
        XCTAssertEqual(self.buf.writerIndex, modifiedBuf.writerIndex)
        XCTAssertEqual([0x0, 0x1, 0xd, 0xe, 0xf], modifiedBuf.readBytes(length: modifiedBuf.readableBytes)!)
    }

    func testBufferViewReplaceSubrangeWithFewerBytes() throws {
        self.buf.writeBytes([0x0, 0x1, 0x2, 0x3, 0x4])

        var view = ByteBufferView(self.buf)
        view.replaceSubrange(view.indices.suffix(3), with: [0xd])

        var modifiedBuf = ByteBuffer(view)
        XCTAssertEqual(self.buf.readerIndex, modifiedBuf.readerIndex)
        XCTAssertEqual(self.buf.writerIndex - 2, modifiedBuf.writerIndex)
        XCTAssertEqual([0x0, 0x1, 0xd], modifiedBuf.readBytes(length: modifiedBuf.readableBytes)!)
    }

    func testBufferViewReplaceSubrangeWithMoreBytes() throws {
        self.buf.writeBytes([0x0, 0x1, 0x2, 0x3])

        var view = ByteBufferView(self.buf)
        XCTAssertTrue(view.elementsEqual([0x0, 0x1, 0x2, 0x3]))

        view.replaceSubrange(view.indices.suffix(1), with: [0xa, 0xb])
        XCTAssertTrue(view.elementsEqual([0x0, 0x1, 0x2, 0xa, 0xb]))

        var modifiedBuf = ByteBuffer(view)
        XCTAssertEqual(self.buf.readerIndex, modifiedBuf.readerIndex)
        XCTAssertEqual(self.buf.writerIndex + 1, modifiedBuf.writerIndex)
        XCTAssertEqual([0x0, 0x1, 0x2, 0xa, 0xb], modifiedBuf.readBytes(length: modifiedBuf.readableBytes)!)
    }

    func testBufferViewAppend() throws {
        self.buf.writeBytes([0x0, 0x1, 0x2, 0x3])

        var view = ByteBufferView(self.buf)
        XCTAssertTrue(view.elementsEqual([0x0, 0x1, 0x2, 0x3]))

        view.append(0xa)
        XCTAssertTrue(view.elementsEqual([0x0, 0x1, 0x2, 0x3, 0xa]))

        var modifiedBuf = ByteBuffer(view)
        XCTAssertEqual(self.buf.readerIndex, modifiedBuf.readerIndex)
        XCTAssertEqual(self.buf.writerIndex + 1, modifiedBuf.writerIndex)
        XCTAssertEqual([0x0, 0x1, 0x2, 0x3, 0xa], modifiedBuf.readBytes(length: modifiedBuf.readableBytes)!)
    }

    func testBufferViewAppendContentsOf() throws {
        self.buf.writeBytes([0x0, 0x1, 0x2, 0x3])

        var view = ByteBufferView(self.buf)
        XCTAssertTrue(view.elementsEqual([0x0, 0x1, 0x2, 0x3]))

        view.append(contentsOf: [0xa, 0xb])
        XCTAssertTrue(view.elementsEqual([0x0, 0x1, 0x2, 0x3, 0xa, 0xb]))

        var modifiedBuf = ByteBuffer(view)
        XCTAssertEqual(self.buf.readerIndex, modifiedBuf.readerIndex)
        XCTAssertEqual(self.buf.writerIndex + 2, modifiedBuf.writerIndex)
        XCTAssertEqual([0x0, 0x1, 0x2, 0x3, 0xa, 0xb], modifiedBuf.readBytes(length: modifiedBuf.readableBytes)!)
    }

    func testBufferViewEmpty() throws {
        self.buf.writeBytes([0, 1, 2])

        var view = ByteBufferView()
        view[0..<0] = self.buf.readableBytesView
        XCTAssertEqual(view.indices, 0..<3)

        self.buf = ByteBuffer(view)
        XCTAssertEqual(self.buf.readerIndex, 0)
        XCTAssertEqual(self.buf.writerIndex, 3)

        let anotherBuf = self.buf!
        XCTAssertEqual([0, 1, 2], self.buf.readBytes(length: self.buf.readableBytes))

        var anotherView = anotherBuf.readableBytesView
        anotherView.replaceSubrange(0..<3, with: [])
        XCTAssertTrue(anotherView.isEmpty)

        self.buf = ByteBuffer(anotherView)
        XCTAssertEqual(self.buf.readerIndex, 0)
        XCTAssertEqual(self.buf.writerIndex, 0)
        XCTAssertEqual([], self.buf.readBytes(length: self.buf.readableBytes))
    }

    func testBufferViewFirstIndex() {
        self.buf.clear()
        self.buf.writeBytes(Array(repeating: UInt8(0x4E), count: 1024))
        self.buf.setBytes([UInt8(0x59)], at: 1000)
        self.buf.setBytes([UInt8(0x59)], at: 1001)
        self.buf.setBytes([UInt8(0x59)], at: 1022)
        self.buf.setBytes([UInt8(0x59)], at: 3)
        self.buf.setBytes([UInt8(0x3F)], at: 1023)
        self.buf.setBytes([UInt8(0x3F)], at: 2)
        let view = self.buf.viewBytes(at: 5, length: 1010)
        XCTAssertEqual(1000, view?.firstIndex(of: UInt8(0x59)))
        XCTAssertNil(view?.firstIndex(of: UInt8(0x3F)))
    }

    func testBufferViewLastIndex() {
        self.buf.clear()
        self.buf.writeBytes(Array(repeating: UInt8(0x4E), count: 1024))
        self.buf.setBytes([UInt8(0x59)], at: 1000)
        self.buf.setBytes([UInt8(0x59)], at: 1001)
        self.buf.setBytes([UInt8(0x59)], at: 1022)
        self.buf.setBytes([UInt8(0x59)], at: 3)
        self.buf.setBytes([UInt8(0x3F)], at: 1023)
        self.buf.setBytes([UInt8(0x3F)], at: 2)
        let view = self.buf.viewBytes(at: 5, length: 1010)
        XCTAssertEqual(1001, view?.lastIndex(of: UInt8(0x59)))
        XCTAssertNil(view?.lastIndex(of: UInt8(0x3F)))
    }

    func testBufferViewContains() {
        self.buf.clear()
        self.buf.writeBytes(Array(repeating: UInt8(0x4E), count: 1024))
        self.buf.setBytes([UInt8(0x59)], at: 1000)
        let view: ByteBufferView?  = self.buf.viewBytes(at: 5, length: 1010)
        XCTAssertTrue(view?.contains(UInt8(0x4E)) == true)
        XCTAssertTrue(view?.contains(UInt8(0x59)) == true)
        XCTAssertTrue(view?.contains(UInt8(0x3F)) == false)
    }

    func testByteBuffersCanBeInitializedFromByteBufferViews() throws {
        self.buf.writeString("hello")

        let readableByteBuffer = ByteBuffer(self.buf.readableBytesView)
        XCTAssertEqual(self.buf, readableByteBuffer)

        let sliceByteBuffer = self.buf.viewBytes(at: 1, length: 3).map(ByteBuffer.init)
        XCTAssertEqual("ell", sliceByteBuffer.flatMap { $0.getString(at: 0, length: $0.readableBytes) })

        self.buf.clear()

        let emptyByteBuffer = ByteBuffer(self.buf.readableBytesView)
        XCTAssertEqual(self.buf, emptyByteBuffer)

        var fixedCapacityBuffer = self.allocator.buffer(capacity: 16)
        let capacity = fixedCapacityBuffer.capacity
        fixedCapacityBuffer.writeString(String(repeating: "x", count: capacity))
        XCTAssertEqual(capacity, fixedCapacityBuffer.capacity)
        XCTAssertEqual(fixedCapacityBuffer, ByteBuffer(fixedCapacityBuffer.readableBytesView))
    }

    func testReserveCapacityWhenOversize() throws {
        let oldCapacity = buf.capacity
        let oldPtrVal = buf.withVeryUnsafeBytes {
            UInt(bitPattern: $0.baseAddress!)
        }

        buf.reserveCapacity(oldCapacity - 1)
        let newPtrVal = buf.withVeryUnsafeBytes {
            UInt(bitPattern: $0.baseAddress!)
        }

        XCTAssertEqual(buf.capacity, oldCapacity)
        XCTAssertEqual(oldPtrVal, newPtrVal)
    }

    func testReserveCapacitySameCapacity() throws {
        let oldCapacity = buf.capacity
        let oldPtrVal = buf.withVeryUnsafeBytes {
            UInt(bitPattern: $0.baseAddress!)
        }

        buf.reserveCapacity(oldCapacity)
        let newPtrVal = buf.withVeryUnsafeBytes {
            UInt(bitPattern: $0.baseAddress!)
        }

        XCTAssertEqual(buf.capacity, oldCapacity)
        XCTAssertEqual(oldPtrVal, newPtrVal)
    }

    func testReserveCapacityLargerUniquelyReferencedCallsRealloc() throws {
        testReserveCapacityLarger_reallocCount = 0
        testReserveCapacityLarger_mallocCount = 0

        let alloc = ByteBufferAllocator(hookedMalloc: testReserveCapacityLarger_mallocHook,
                                        hookedRealloc: testReserveCapacityLarger_reallocHook,
                                        hookedFree: testReserveCapacityLarger_freeHook,
                                        hookedMemcpy: testReserveCapacityLarger_memcpyHook)
        var buf = alloc.buffer(capacity: 16)


        let oldCapacity = buf.capacity

        XCTAssertEqual(testReserveCapacityLarger_mallocCount, 1)
        XCTAssertEqual(testReserveCapacityLarger_reallocCount, 0)
        buf.reserveCapacity(32)
        XCTAssertEqual(testReserveCapacityLarger_mallocCount, 1)
        XCTAssertEqual(testReserveCapacityLarger_reallocCount, 1)
        XCTAssertNotEqual(buf.capacity, oldCapacity)
    }

    func testReserveCapacityLargerMultipleReferenceCallsMalloc() throws {
        testReserveCapacityLarger_reallocCount = 0
        testReserveCapacityLarger_mallocCount = 0

        let alloc = ByteBufferAllocator(hookedMalloc: testReserveCapacityLarger_mallocHook,
                                        hookedRealloc: testReserveCapacityLarger_reallocHook,
                                        hookedFree: testReserveCapacityLarger_freeHook,
                                        hookedMemcpy: testReserveCapacityLarger_memcpyHook)
        var buf = alloc.buffer(capacity: 16)
        var bufCopy = buf

        withExtendedLifetime(bufCopy) {
            let oldCapacity = buf.capacity
            let oldPtrVal = buf.withVeryUnsafeBytes {
                UInt(bitPattern: $0.baseAddress!)
            }

            XCTAssertEqual(testReserveCapacityLarger_mallocCount, 1)
            XCTAssertEqual(testReserveCapacityLarger_reallocCount, 0)
            buf.reserveCapacity(32)
            XCTAssertEqual(testReserveCapacityLarger_mallocCount, 2)
            XCTAssertEqual(testReserveCapacityLarger_reallocCount, 0)

            let newPtrVal = buf.withVeryUnsafeBytes {
                UInt(bitPattern: $0.baseAddress!)
            }

            XCTAssertNotEqual(buf.capacity, oldCapacity)
            XCTAssertNotEqual(oldPtrVal, newPtrVal)
        }
        bufCopy.writeString("foo") // stops the optimiser removing `bufCopy` which would make `reserveCapacity` use malloc instead of realloc
    }

    func testReserveCapacityWithMinimumWritableBytesWhenNotEnoughWritableBytes() {
        // Ensure we have a non-empty buffer since the writer index is involved here.
        self.buf.writeBytes((UInt8.min...UInt8.max))

        let writableBytes = self.buf.writableBytes
        self.buf.reserveCapacity(minimumWritableBytes: writableBytes + 1)
        XCTAssertGreaterThanOrEqual(self.buf.writableBytes, writableBytes + 1)
    }

    func testReserveCapacityWithMinimumWritableBytesWhenEnoughWritableBytes() {
        // Ensure we have a non-empty buffer since the writer index is involved here.
        self.buf.writeBytes((UInt8.min...UInt8.max))

        // Ensure we have some space.
        self.buf.reserveCapacity(minimumWritableBytes: 5)

        let oldPtrVal = self.buf.withVeryUnsafeBytes {
            UInt(bitPattern: $0.baseAddress!)
        }

        let writableBytes = self.buf.writableBytes
        self.buf.reserveCapacity(minimumWritableBytes: writableBytes - 1)

        let newPtrVal = self.buf.withVeryUnsafeBytes {
            UInt(bitPattern: $0.baseAddress!)
        }

        XCTAssertEqual(self.buf.writableBytes, writableBytes)
        XCTAssertEqual(oldPtrVal, newPtrVal)
    }

    func testReserveCapacityWithMinimumWritableBytesWhenSameWritableBytes() {
        // Ensure we have a non-empty buffer since the writer index is involved here.
        self.buf.writeBytes((UInt8.min...UInt8.max))

        // Ensure we have some space.
        self.buf.reserveCapacity(minimumWritableBytes: 5)

        let oldPtrVal = self.buf.withVeryUnsafeBytes {
            UInt(bitPattern: $0.baseAddress!)
        }

        let writableBytes = self.buf.writableBytes
        self.buf.reserveCapacity(minimumWritableBytes: writableBytes)

        let newPtrVal = self.buf.withVeryUnsafeBytes {
            UInt(bitPattern: $0.baseAddress!)
        }

        XCTAssertEqual(self.buf.writableBytes, writableBytes)
        XCTAssertEqual(oldPtrVal, newPtrVal)
    }

    func testReadWithFunctionsThatReturnNumberOfReadBytesAreDiscardable() {
        var buf = self.buf!
        buf.writeString("ABCD")

        /* deliberately not ignoring the result */ buf.readWithUnsafeReadableBytes { buffer in
            XCTAssertEqual(4, buffer.count)
            return 2
        }

        /* deliberately not ignoring the result */ buf.readWithUnsafeMutableReadableBytes { buffer in
            XCTAssertEqual(2, buffer.count)
            return 2
        }

        XCTAssertEqual(0, buf.readableBytes)
    }

    func testWriteAndSetAndGetAndReadEncoding() throws {
        var buf = self.buf!
        buf.clear()

        var writtenBytes = try assertNoThrowWithValue(buf.writeString("ÆBCD", encoding: .utf16LittleEndian))
        XCTAssertEqual(writtenBytes, 8)
        XCTAssertEqual(buf.readableBytes, 8)
        XCTAssertEqual(buf.getString(at: buf.readerIndex + 2, length: 6, encoding: .utf16LittleEndian), "BCD")

        writtenBytes = try assertNoThrowWithValue(buf.setString("EFGH", encoding: .utf32BigEndian, at: buf.readerIndex))
        XCTAssertEqual(writtenBytes, 16)
        XCTAssertEqual(buf.readableBytes, 8)
        XCTAssertEqual(buf.readString(length: 8, encoding: .utf32BigEndian), "EF")
        XCTAssertEqual(buf.readableBytes, 0)

        buf.clear()

        // Confirm that we do throw.
        XCTAssertThrowsError(try buf.setString("🤷‍♀️", encoding: .ascii, at: buf.readerIndex)) {
            XCTAssertEqual($0 as? ByteBufferFoundationError, .failedToEncodeString)
        }
        XCTAssertThrowsError(try buf.writeString("🤷‍♀️", encoding: .ascii)) {
            XCTAssertEqual($0 as? ByteBufferFoundationError, .failedToEncodeString)
        }
    }

    func testPossiblyLazilyBridgedString() {
        // won't hit the String writing fast path
        let utf16Bytes = Data([0xfe, 0xff, 0x00, 0x61, 0x00, 0x62, 0x00, 0x63, 0x00, 0xe4, 0x00, 0xe4, 0x00, 0xe4, 0x00, 0x0a])
        let slowString = String(data: utf16Bytes, encoding: .utf16)!

        self.buf.clear()
        let written = self.buf.writeString(slowString as String)
        XCTAssertEqual(10, written)
        XCTAssertEqual("abcäää\n", String(decoding: self.buf.readableBytesView, as: Unicode.UTF8.self))
    }

    func testWithVeryUnsafeMutableBytesWorksOnEmptyByteBuffer() {
        var buf = self.allocator.buffer(capacity: 0)
        XCTAssertEqual(0, buf.capacity)
        buf.withVeryUnsafeMutableBytes { ptr in
            XCTAssertEqual(0, ptr.count)
        }
    }

    func testWithVeryUnsafeMutableBytesYieldsPointerToWholeStorage() {
        var buf = self.allocator.buffer(capacity: 16)
        let capacity = buf.capacity
        XCTAssertGreaterThanOrEqual(capacity, 16)
        buf.writeString("1234")
        XCTAssertEqual(capacity, buf.capacity)
        buf.withVeryUnsafeMutableBytes { ptr in
            XCTAssertEqual(capacity, ptr.count)
            XCTAssertEqual("1234", String(decoding: ptr[0..<4], as: Unicode.UTF8.self))
        }
    }

    func testWithVeryUnsafeMutableBytesYieldsPointerToWholeStorageAndCanBeWritenTo() {
        var buf = self.allocator.buffer(capacity: 16)
        let capacity = buf.capacity
        XCTAssertGreaterThanOrEqual(capacity, 16)
        buf.writeString("1234")
        XCTAssertEqual(capacity, buf.capacity)
        buf.withVeryUnsafeMutableBytes { ptr in
            XCTAssertEqual(capacity, ptr.count)
            XCTAssertEqual("1234", String(decoding: ptr[0..<4], as: Unicode.UTF8.self))
            UnsafeMutableRawBufferPointer(rebasing: ptr[4..<8]).copyBytes(from: "5678".utf8)
        }
        buf.moveWriterIndex(forwardBy: 4)
        XCTAssertEqual("12345678", buf.readString(length: buf.readableBytes))

        buf.withVeryUnsafeMutableBytes { ptr in
            XCTAssertEqual(capacity, ptr.count)
            XCTAssertEqual("12345678", String(decoding: ptr[0..<8], as: Unicode.UTF8.self))
            ptr[0] = "X".utf8.first!
            UnsafeMutableRawBufferPointer(rebasing: ptr[8..<16]).copyBytes(from: "abcdefgh".utf8)
        }
        buf.moveWriterIndex(forwardBy: 8)
        XCTAssertEqual("abcdefgh", buf.readString(length: buf.readableBytes))
        buf.moveWriterIndex(to: 1)
        buf.moveReaderIndex(to: 0)
        XCTAssertEqual("X", buf.getString(at: 0, length: 1))
    }

    func testWithVeryUnsafeMutableBytesDoesCoW() {
        var buf = self.allocator.buffer(capacity: 16)
        let capacity = buf.capacity
        XCTAssertGreaterThanOrEqual(capacity, 16)
        buf.writeString("1234")
        let bufCopy = buf
        XCTAssertEqual(capacity, buf.capacity)
        buf.withVeryUnsafeMutableBytes { ptr in
            XCTAssertEqual(capacity, ptr.count)
            XCTAssertEqual("1234", String(decoding: ptr[0..<4], as: Unicode.UTF8.self))
            UnsafeMutableRawBufferPointer(rebasing: ptr[0..<8]).copyBytes(from: "abcdefgh".utf8)
        }
        buf.moveWriterIndex(forwardBy: 4)
        XCTAssertEqual("1234", String(decoding: bufCopy.readableBytesView, as: Unicode.UTF8.self))
        XCTAssertEqual("abcdefgh", String(decoding: buf.readableBytesView, as: Unicode.UTF8.self))
    }

    func testWithVeryUnsafeMutableBytesDoesCoWonSlices() {
        var buf = self.allocator.buffer(capacity: 16)
        let capacity = buf.capacity
        XCTAssertGreaterThanOrEqual(capacity, 16)
        buf.writeString("1234567890")
        var buf2 = buf.getSlice(at: 4, length: 4)!
        XCTAssertEqual(capacity, buf.capacity)
        let capacity2 = buf2.capacity
        buf2.withVeryUnsafeMutableBytes { ptr in
            XCTAssertEqual(capacity2, ptr.count)
            XCTAssertEqual("5678", String(decoding: ptr[0..<4], as: Unicode.UTF8.self))
            UnsafeMutableRawBufferPointer(rebasing: ptr[0..<4]).copyBytes(from: "QWER".utf8)
        }
        XCTAssertEqual("QWER", String(decoding: buf2.readableBytesView, as: Unicode.UTF8.self))
        XCTAssertEqual("1234567890", String(decoding: buf.readableBytesView, as: Unicode.UTF8.self))
    }

    func testGetDispatchDataWorks() {
        self.buf.clear()
        self.buf.writeString("abcdefgh")

        XCTAssertEqual(0, self.buf.getDispatchData(at: 7, length: 0)!.count)
        XCTAssertNil(self.buf.getDispatchData(at: self.buf.capacity, length: 1))
        XCTAssertEqual("abcdefgh", String(decoding: self.buf.getDispatchData(at: 0, length: 8)!, as: Unicode.UTF8.self))
        XCTAssertEqual("ef", String(decoding: self.buf.getDispatchData(at: 4, length: 2)!, as: Unicode.UTF8.self))
    }

    func testGetDispatchDataReadWrite() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4, alignment: 0)
        buffer.copyBytes(from: "1234".utf8)
        defer {
            buffer.deallocate()
        }
        self.buf.clear()
        self.buf.writeString("abcdefgh")
        self.buf.writeDispatchData( DispatchData.empty)
        self.buf.writeDispatchData( DispatchData(bytes: UnsafeRawBufferPointer(buffer)))
        XCTAssertEqual(12, self.buf.readableBytes)
        XCTAssertEqual("abcdefgh1234", String(decoding: self.buf.readDispatchData(length: 12)!, as: Unicode.UTF8.self))
        XCTAssertNil(self.buf.readDispatchData(length: 1))
        XCTAssertEqual(0, self.buf.readDispatchData(length: 0)?.count ?? 12)
    }

    func testVariousContiguousStorageAccessors() {
        self.buf.clear()
        self.buf.writeStaticString("abc0123456789efg")
        self.buf.moveReaderIndex(to: 3)
        self.buf.moveWriterIndex(to: 13)

        func inspectContiguousBytes<Bytes: ContiguousBytes>(bytes: Bytes, expectedString: String) {
            bytes.withUnsafeBytes { bytes in
                XCTAssertEqual(expectedString, String(decoding: bytes, as: Unicode.UTF8.self))
            }
        }
        inspectContiguousBytes(bytes: self.buf.readableBytesView, expectedString: "0123456789")
        let r1 = self.buf.readableBytesView.withContiguousStorageIfAvailable { bytes -> String in
            String(decoding: bytes, as: Unicode.UTF8.self)
        }
        XCTAssertEqual("0123456789", r1)

        self.buf.clear()
        inspectContiguousBytes(bytes: self.buf.readableBytesView, expectedString: "")
        let r2 = self.buf.readableBytesView.withContiguousStorageIfAvailable { bytes -> String in
            String(decoding: bytes, as: Unicode.UTF8.self)
        }
        XCTAssertEqual("", r2)
    }

    func testGetBytesThatAreNotReadable() {
        var buf = self.allocator.buffer(capacity: 256)

        // 1) Nothing available
        // no `get*` should work
        XCTAssertNil(buf.getInteger(at: 0, as: UInt8.self))
        XCTAssertNil(buf.getInteger(at: 0, as: UInt16.self))
        XCTAssertNil(buf.getInteger(at: 0, as: UInt32.self))
        XCTAssertNil(buf.getInteger(at: 0, as: UInt64.self))
        XCTAssertNil(buf.getString(at: 0, length: 1))
        XCTAssertNil(buf.getSlice(at: 0, length: 1))
        XCTAssertNil(buf.getData(at: 0, length: 1))
        XCTAssertNil(buf.getDispatchData(at: 0, length: 1))
        XCTAssertNil(buf.getBytes(at: 0, length: 1))
        XCTAssertNil(buf.getString(at: 0, length: 1, encoding: .utf8))
        XCTAssertNil(buf.viewBytes(at: 0, length: 1))

        // but some `get*` should be able to produce empties
        XCTAssertEqual("", buf.getString(at: 0, length: 0))
        XCTAssertEqual(0, buf.getSlice(at: 0, length: 0)?.capacity)
        XCTAssertEqual(Data(), buf.getData(at: 0, length: 0))
        XCTAssertEqual(0, buf.getDispatchData(at: 0, length: 0)?.count)
        XCTAssertEqual([], buf.getBytes(at: 0, length: 0))
        XCTAssertEqual("", buf.getString(at: 0, length: 0, encoding: .utf8))
        XCTAssertEqual("", buf.viewBytes(at: 0, length: 0).map { String(decoding: $0, as: Unicode.UTF8.self) })

        // 2) One byte available at the beginning
        buf.writeInteger(0x41, as: UInt8.self)

        // for most `get*`s, we can make them just not work
        XCTAssertNil(buf.getInteger(at: 0, as: UInt16.self))
        XCTAssertNil(buf.getInteger(at: 0, as: UInt32.self))
        XCTAssertNil(buf.getInteger(at: 0, as: UInt64.self))
        XCTAssertNil(buf.getString(at: 0, length: 2))
        XCTAssertNil(buf.getSlice(at: 0, length: 2))
        XCTAssertNil(buf.getData(at: 0, length: 2))
        XCTAssertNil(buf.getDispatchData(at: 0, length: 2))
        XCTAssertNil(buf.getBytes(at: 0, length: 2))
        XCTAssertNil(buf.getString(at: 0, length: 2, encoding: .utf8))
        XCTAssertNil(buf.viewBytes(at: 0, length: 2))

        XCTAssertNil(buf.getInteger(at: 1, as: UInt8.self))
        XCTAssertNil(buf.getInteger(at: 1, as: UInt16.self))
        XCTAssertNil(buf.getInteger(at: 1, as: UInt32.self))
        XCTAssertNil(buf.getInteger(at: 1, as: UInt64.self))
        XCTAssertNil(buf.getString(at: 1, length: 1))
        XCTAssertNil(buf.getSlice(at: 1, length: 1))
        XCTAssertNil(buf.getData(at: 1, length: 1))
        XCTAssertNil(buf.getDispatchData(at: 1, length: 1))
        XCTAssertNil(buf.getBytes(at: 1, length: 1))
        XCTAssertNil(buf.getString(at: 1, length: 1, encoding: .utf8))
        XCTAssertNil(buf.viewBytes(at: 1, length: 1))

        // on the other hand, we should be able to take that one byte out
        XCTAssertEqual(0x41, buf.getInteger(at: 0, as: UInt8.self))
        XCTAssertEqual("A", buf.getString(at: 0, length: 1))
        XCTAssertEqual(1, buf.getSlice(at: 0, length: 1)?.capacity)
        XCTAssertEqual(Data("A".utf8), buf.getData(at: 0, length: 1))
        XCTAssertEqual(1, buf.getDispatchData(at: 0, length: 1)?.count)
        XCTAssertEqual(["A".utf8.first!], buf.getBytes(at: 0, length: 1))
        XCTAssertEqual("A", buf.getString(at: 0, length: 1, encoding: .utf8))
        XCTAssertEqual("A", buf.viewBytes(at: 0, length: 1).map { String(decoding: $0, as: Unicode.UTF8.self) })

        // 3) Now let's have 4 bytes towards the end

        // we can make pretty much all `get*`s fail
        buf.setInteger(0x41414141, at: 251, as: UInt32.self)
        buf.moveWriterIndex(to: 255)
        buf.moveReaderIndex(to: 251)
        XCTAssertNil(buf.getInteger(at: 251, as: UInt64.self))
        XCTAssertNil(buf.getString(at: 251, length: 5))
        XCTAssertNil(buf.getSlice(at: 251, length: 5))
        XCTAssertNil(buf.getData(at: 251, length: 5))
        XCTAssertNil(buf.getDispatchData(at: 251, length: 5))
        XCTAssertNil(buf.getBytes(at: 251, length: 5))
        XCTAssertNil(buf.getString(at: 251, length: 5, encoding: .utf8))
        XCTAssertNil(buf.viewBytes(at: 251, length: 5))

        XCTAssertEqual(0x41, buf.getInteger(at: 254, as: UInt8.self))
        XCTAssertEqual(0x4141, buf.getInteger(at: 253, as: UInt16.self))
        XCTAssertEqual(0x41414141, buf.getInteger(at: 251, as: UInt32.self))
        XCTAssertEqual("AAAA", buf.getString(at: 251, length: 4))
        XCTAssertEqual(4, buf.getSlice(at: 251, length: 4)?.capacity)
        XCTAssertEqual(Data("AAAA".utf8), buf.getData(at: 251, length: 4))
        XCTAssertEqual(4, buf.getDispatchData(at: 251, length: 4)?.count)
        XCTAssertEqual(Array(repeating: "A".utf8.first!, count: 4), buf.getBytes(at: 251, length: 4))
        XCTAssertEqual("AAAA", buf.getString(at: 251, length: 4, encoding: .utf8))
        XCTAssertEqual("AAAA", buf.viewBytes(at: 251, length: 4).map { String(decoding: $0, as: Unicode.UTF8.self) })
    }

    func testByteBufferViewAsDataProtocol() {
        func checkEquals<D: DataProtocol>(expected: String, actual: D) {
            var actualBytesAsArray: [UInt8] = []
            for region in actual.regions {
                actualBytesAsArray += Array(region)
            }
            XCTAssertEqual(expected, String(decoding: actualBytesAsArray, as: Unicode.UTF8.self))
        }
        var buf = self.allocator.buffer(capacity: 32)
        buf.writeStaticString("0123abcd4567")
        buf.moveReaderIndex(forwardBy: 4)
        buf.moveWriterIndex(to: buf.writerIndex - 4)
        checkEquals(expected: "abcd", actual: buf.readableBytesView)
    }

    func testDataByteTransferStrategyNoCopy() {
        let byteCount = 200_000 // this needs to be large because Data might also decide to copy.
        self.buf.clear()
        self.buf.writeString(String(repeating: "x", count: byteCount))
        var byteBufferPointerValue: UInt = 0xbad
        var dataPointerValue: UInt = 0xdead
        self.buf.withUnsafeReadableBytes { ptr in
            byteBufferPointerValue = UInt(bitPattern: ptr.baseAddress)
        }
        if let data = self.buf.readData(length: byteCount, byteTransferStrategy: .noCopy) {
            data.withUnsafeBytes { ptr in
                dataPointerValue = UInt(bitPattern: ptr.baseAddress)
            }
        } else {
            XCTFail("unable to read Data from ByteBuffer")
        }

        XCTAssertEqual(byteBufferPointerValue, dataPointerValue)
    }

    func testDataByteTransferStrategyCopy() {
        let byteCount = 200_000 // this needs to be large because Data might also decide to copy.
        self.buf.clear()
        self.buf.writeString(String(repeating: "x", count: byteCount))
        var byteBufferPointerValue: UInt = 0xbad
        var dataPointerValue: UInt = 0xdead
        self.buf.withUnsafeReadableBytes { ptr in
            byteBufferPointerValue = UInt(bitPattern: ptr.baseAddress)
        }
        if let data = self.buf.readData(length: byteCount, byteTransferStrategy: .copy) {
            data.withUnsafeBytes { ptr in
                dataPointerValue = UInt(bitPattern: ptr.baseAddress)
            }
        } else {
            XCTFail("unable to read Data from ByteBuffer")
        }

        XCTAssertNotEqual(byteBufferPointerValue, dataPointerValue)
    }

    func testDataByteTransferStrategyAutomaticMayNotCopy() {
        let byteCount = 500_000 // this needs to be larger than ByteBuffer's heuristic's threshold.
        self.buf.clear()
        self.buf.writeString(String(repeating: "x", count: byteCount))
        var byteBufferPointerValue: UInt = 0xbad
        var dataPointerValue: UInt = 0xdead
        self.buf.withUnsafeReadableBytes { ptr in
            byteBufferPointerValue = UInt(bitPattern: ptr.baseAddress)
        }
        if let data = self.buf.readData(length: byteCount, byteTransferStrategy: .automatic) {
            data.withUnsafeBytes { ptr in
                dataPointerValue = UInt(bitPattern: ptr.baseAddress)
            }
        } else {
            XCTFail("unable to read Data from ByteBuffer")
        }

        XCTAssertEqual(byteBufferPointerValue, dataPointerValue)
    }

    func testDataByteTransferStrategyAutomaticMayCopy() {
        let byteCount = 200_000 // above Data's 'do not copy' but less than ByteBuffer's 'do not copy' threshold.
        self.buf.clear()
        self.buf.writeString(String(repeating: "x", count: byteCount))
        var byteBufferPointerValue: UInt = 0xbad
        var dataPointerValue: UInt = 0xdead
        self.buf.withUnsafeReadableBytes { ptr in
            byteBufferPointerValue = UInt(bitPattern: ptr.baseAddress)
        }
        if let data = self.buf.readData(length: byteCount, byteTransferStrategy: .automatic) {
            data.withUnsafeBytes { ptr in
                dataPointerValue = UInt(bitPattern: ptr.baseAddress)
            }
        } else {
            XCTFail("unable to read Data from ByteBuffer")
        }

        XCTAssertNotEqual(byteBufferPointerValue, dataPointerValue)
    }

    func testViewBytesIsHappyWithNegativeValues() {
        self.buf.clear()
        XCTAssertNil(self.buf.viewBytes(at: -1, length: 0))
        XCTAssertNil(self.buf.viewBytes(at: 0, length: -1))
        XCTAssertNil(self.buf.viewBytes(at: -1, length: -1))

        self.buf.writeString("hello world")
        self.buf.moveWriterIndex(forwardBy: 6)

        XCTAssertNil(self.buf.viewBytes(at: -1, length: 0))
        XCTAssertNil(self.buf.viewBytes(at: 0, length: -1))
        XCTAssertNil(self.buf.viewBytes(at: -1, length: -1))
    }

    func testByteBufferAllocatorSize1Capacity() {
        let buffer = ByteBufferAllocator().buffer(capacity: 1)
        XCTAssertEqual(1, buffer.capacity)
    }

    func testByteBufferModifiedWithoutAllocationLogic() {
        var buffer = ByteBufferAllocator().buffer(capacity: 1)
        let firstResult = buffer.modifyIfUniquelyOwned {
            $0.readableBytes
        }
        XCTAssertEqual(firstResult, 0)

        withExtendedLifetime(buffer) {
            var localCopy = buffer
            let secondResult = localCopy.modifyIfUniquelyOwned {
                $0.readableBytes
            }
            let thirdResult = buffer.modifyIfUniquelyOwned {
                $0.readableBytes
            }
            XCTAssertNil(secondResult)
            XCTAssertNil(thirdResult)
            localCopy.writeString("foo") // stops the optimiser getting rid of `localCopy`
        }

        let fourthResult = buffer.modifyIfUniquelyOwned {
            $0.readableBytes
        }
        XCTAssertEqual(fourthResult, 0)

        let fifthResult = buffer.modifyIfUniquelyOwned {
            $0.modifyIfUniquelyOwned {
                $0.readableBytes
            }
        }
        XCTAssertEqual(fifthResult, 0)
    }

    func testByteBufferModifyIfUniquelyOwnedMayThrow() {
        struct MyError: Error { }

        func doAThrow(_ b: inout ByteBuffer) throws {
            throw MyError()
        }

        var buffer = ByteBufferAllocator().buffer(capacity: 1)

        XCTAssertThrowsError(try buffer.modifyIfUniquelyOwned(doAThrow(_:))) { error in
            XCTAssertTrue(error is MyError)
        }

        // This can't actually throw but XCTAssertNoThrow isn't doing well here.
        try! withExtendedLifetime(buffer) {
            var localCopy = buffer
            XCTAssertNoThrow(try localCopy.modifyIfUniquelyOwned(doAThrow(_:)))
            XCTAssertNoThrow(try buffer.modifyIfUniquelyOwned(doAThrow(_:)))
        }

        XCTAssertThrowsError(try buffer.modifyIfUniquelyOwned(doAThrow(_:))) { error in
            XCTAssertTrue(error is MyError)
        }
    }

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
    func testDeprecatedSetBytes() {
        self.buf.clear()
        self.buf.writeString("hello")
        self.buf.set(buffer: self.buf, at: 5)
        self.buf.moveWriterIndex(forwardBy: 5)
        XCTAssertEqual("hellohello", self.buf.readString(length: 10))
    }
    
    func testWriteRepeatingBytes() {
        func write(count: Int, line: UInt = #line) {
            self.buf.clear()
            let written = self.buf.writeRepeatingByte(9, count: count)
            XCTAssertEqual(count, written)
            XCTAssertEqual(Array(repeating: UInt8(9), count: count), Array(self.buf.readableBytesView))
        }
        
        write(count: 1_000_000)
        write(count: 0)
    }
    
    func testSetRepeatingBytes() {
        func set(count: Int, at index: Int, padding: [UInt8] = [], line: UInt = #line) {
            
            // first write some bytes
            self.buf.clear()
            self.buf.writeBytes(padding)
            self.buf.writeRepeatingByte(9, count: count)
            self.buf.writeBytes(padding)
            
            // now overwrite
            let previousWriterIndex = self.buf.writerIndex
            let written = self.buf.setRepeatingByte(8, count: count, at: index)
            XCTAssertEqual(previousWriterIndex, self.buf.writerIndex) // writer index shouldn't have changed
            XCTAssertEqual(count, written)
            XCTAssertEqual(Array(repeating: UInt8(8), count: count), self.buf.getBytes(at: index, length: count)!)
            
            // check the padding is still ok
            XCTAssertEqual(self.buf.getBytes(at: 0, length: padding.count)!, padding)
            XCTAssertEqual(self.buf.getBytes(at: count + padding.count, length: padding.count)!, padding)
        }
        
        set(count: 1_000_000, at: 0)
        set(count: 0, at: 0)
        set(count: 10, at: 5, padding: [1, 1, 1, 1, 1])
    }
    
    func testSetRepeatingBytes_unqiueReference() {
        
        var buffer = self.buf!
        let copy = buffer
        
        buffer.writeRepeatingByte(2, count: 100)
        XCTAssertEqual(Array(buffer.readableBytesView), Array(repeating: 2, count: 100))
        XCTAssertNotEqual(buffer, copy)
    }

    func testWriteOptionalWorksForNilCase() {
        self.buf.writeString("hello")
        var startingWithNil: ByteBuffer? = nil
        let bytesWritten = startingWithNil.setOrWriteBuffer(&self.buf)
        XCTAssertEqual(5, bytesWritten)
        self.buf.writeString("hello")
        XCTAssertEqual(self.buf, startingWithNil)
    }

    func testWriteOptionalWorksForNonNilCase() {
        self.buf.writeString("hello")
        var nonNilBuffer: ByteBuffer? = self.buf
        let bytesWritten = nonNilBuffer.setOrWriteBuffer(&self.buf)
        XCTAssertEqual(5, bytesWritten)
        self.buf.writeString("hellohello")
        XCTAssertEqual(self.buf, nonNilBuffer)
    }

    func testWriteImmutableOptionalWorksForNilCase() {
        self.buf.writeString("hello")
        var startingWithNil: ByteBuffer? = nil
        let bytesWritten = startingWithNil.setOrWriteImmutableBuffer(self.buf)
        XCTAssertEqual(5, bytesWritten)
        XCTAssertEqual(self.buf, startingWithNil)
    }

    func testWriteImmutableOptionalWorksForNonNilCase() {
        self.buf.writeString("hello")
        var nonNilBuffer: ByteBuffer? = self.buf
        let bytesWritten = nonNilBuffer.setOrWriteImmutableBuffer(self.buf)
        XCTAssertEqual(5, bytesWritten)
        self.buf.writeString("hello")
        XCTAssertEqual(self.buf, nonNilBuffer)
    }

    func testWritingToEmptyDoesNotCauseTrouble() {
        var fromEmpty = ByteBuffer()
        XCTAssertEqual(0, fromEmpty.readableBytes)
        XCTAssertEqual(0, fromEmpty.capacity)
        let emptyStorage = fromEmpty.storagePointerIntegerValue()

        fromEmpty.writeInteger(1, as: UInt8.self)
        XCTAssertEqual(1, fromEmpty.readableBytes)
        XCTAssertNotEqual(emptyStorage, fromEmpty.storagePointerIntegerValue())
        XCTAssertGreaterThan(fromEmpty.capacity, 0)

        let empty = ByteBuffer()
        XCTAssertEqual(0, empty.readableBytes)
        XCTAssertEqual(0, empty.capacity)
        XCTAssertEqual(emptyStorage, empty.storagePointerIntegerValue())
    }

    func testReadEmptySliceFromEmpty() {
        self.buf = ByteBuffer()
        XCTAssertEqual(ByteBuffer(), self.buf.readSlice(length: 0))
    }

    func testConvenienceStringInitWorks() {
        let bufEmpty = ByteBuffer(string: "")
        let bufNonEmpty = ByteBuffer(string: "👩🏼‍✈️hello🙈")
        XCTAssertEqual("", String(buffer: bufEmpty))
        XCTAssertEqual("👩🏼‍✈️hello🙈", String(buffer: bufNonEmpty))

        XCTAssertEqual(self.allocator.buffer(string: "👩🏼‍✈️hello🙈"), bufNonEmpty)
    }

    func testConvenienceCreateUInt64() {
        var intBuffer = ByteBuffer(integer: UInt64(0x001122334455667788))
        XCTAssertEqual(self.allocator.buffer(integer: UInt64(0x001122334455667788)), intBuffer)
        let int = intBuffer.readInteger(as: UInt64.self)
        XCTAssertEqual(0x001122334455667788, int)
    }

    func testConvenienceCreateUInt8() {
        var intBuffer = ByteBuffer(integer: UInt8(0x88))
        XCTAssertEqual(self.allocator.buffer(integer: UInt8(0x88)), intBuffer)
        let int = intBuffer.readInteger(as: UInt8.self)
        XCTAssertEqual(0x88, int)
    }

    func testConvenienceCreateBuffer() {
        self.buf.writeString("hey")
        self.buf.writeString("you")
        self.buf.writeString("buffer")
        XCTAssertEqual("hey", self.buf.readString(length: 3))
        self.buf.moveWriterIndex(to: self.buf.writerIndex - 6)
        let newBuf = ByteBuffer(buffer: self.buf)
        XCTAssertEqual(self.allocator.buffer(buffer: self.buf), newBuf)

        XCTAssertEqual(newBuf, self.buf)
    }

    func testConvenienceCreateRepeatingByte() {
        var buf = ByteBuffer(repeating: 0x12, count: 100)
        XCTAssertEqual(self.allocator.buffer(repeating: 0x12, count: 100), buf)
        XCTAssertEqual(Array(repeating: UInt8(0x12), count: 100), buf.readBytes(length: 100))
        XCTAssertEqual(0, buf.readableBytes)
    }

    func testConvenienceCreateData() {
        let data = Data("helloyou\0buffer".utf8)
        let subData = data[data.firstIndex(of: UInt8(ascii: "y"))! ..< data.firstIndex(of: UInt8(ascii: "b"))!]
        XCTAssertNotEqual(0, subData.startIndex)
        let buffer = ByteBuffer(data: subData)
        XCTAssertEqual(ByteBuffer(string: "you\0"), buffer)
        XCTAssertEqual(self.allocator.buffer(string: "you\0"), buffer)
    }

    func testConvenienceCreateDispatchData() {
        var dd = DispatchData.empty
        for s in ["s", "t", "ri\0n", "g"] {
            XCTAssertNotNil(s.utf8.withContiguousStorageIfAvailable { ptr in
                dd.append(UnsafeRawBufferPointer(ptr))
            })
        }
        // The DispatchData should now be discontiguous.
        XCTAssertEqual(ByteBuffer(string: "stri\0ng"), ByteBuffer(dispatchData: dd))
        XCTAssertEqual(ByteBuffer(dispatchData: dd), self.allocator.buffer(dispatchData: dd))
    }

    func testConvenienceCreateStaticString() {
        XCTAssertEqual(ByteBuffer(string: "hello"), ByteBuffer(staticString: "hello"))
        XCTAssertEqual(ByteBuffer(string: "hello"), self.allocator.buffer(staticString: "hello"))
    }

    func testConvenienceCreateSubstring() {
        XCTAssertEqual(ByteBuffer(string: "hello"), ByteBuffer(substring: "hello"[...]))
        XCTAssertEqual(ByteBuffer(string: "hello"), self.allocator.buffer(substring: "hello"[...]))
    }

    func testConvenienceCreateBytes() {
        XCTAssertEqual(ByteBuffer(string: "\0string\0"), ByteBuffer(bytes: [UInt8(0)] + Array("string\0".utf8)))
        XCTAssertEqual(ByteBuffer(string: "\0string\0"),
                       self.allocator.buffer(bytes: [UInt8(0)] + Array("string\0".utf8)))
    }

    func testAllocatorGivesStableZeroSizedBuffers() {
        let b1 = ByteBufferAllocator().buffer(capacity: 0)
        let b2 = ByteBufferAllocator().buffer(capacity: 0)
        let b3 = self.allocator.buffer(capacity: 0)
        let b4 = self.allocator.buffer(capacity: 0)
        XCTAssertEqual(b1.storagePointerIntegerValue(), b2.storagePointerIntegerValue())
        XCTAssertEqual(b3.storagePointerIntegerValue(), b4.storagePointerIntegerValue())
    }

    func testClearOnZeroCapacityActuallyAllocates() {
        var b = ByteBufferAllocator().buffer(capacity: 0)
        let bEmptyStorage1 = b.storagePointerIntegerValue()
        b.clear()
        let bEmptyStorage2 = b.storagePointerIntegerValue()
        XCTAssertNotEqual(bEmptyStorage1, bEmptyStorage2)
    }

    func testCreateBufferFromSequence() {
        self.buf.writeString("hello")
        let aSequenceThatIsNotACollection = Array(buffer: self.buf).makeIterator()
        XCTAssertEqual(self.buf, self.allocator.buffer(bytes: aSequenceThatIsNotACollection))
        XCTAssertEqual(self.buf, ByteBuffer(bytes: aSequenceThatIsNotACollection))
    }

    func testWeDoNotResizeIfWeHaveExactlyTheRightCapacityAvailable() {
        let bufferSize = 32*1024
        var buffer = self.allocator.buffer(capacity: bufferSize)
        buffer.moveWriterIndex(forwardBy: bufferSize / 2)
        XCTAssertEqual(bufferSize, buffer.capacity)
        let oldBufferStorage = buffer.storagePointerIntegerValue()
        buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: bufferSize/2, { _ in return 0 })
        XCTAssertEqual(bufferSize, buffer.capacity)
        let newBufferStorage = buffer.storagePointerIntegerValue()
        XCTAssertEqual(oldBufferStorage, newBufferStorage)
    }
    
    func testWithUnsafeMutableReadableBytesNoCoW() {
        let storageID = self.buf.storagePointerIntegerValue()
        self.buf.withUnsafeMutableReadableBytes { ptr in
            XCTAssertEqual(0, ptr.count)
        }

        self.buf.writeString("hello \0 world!")
        self.buf.withUnsafeMutableReadableBytes { ptr in
            XCTAssertEqual("hello \0 world!", String(decoding: ptr, as: UTF8.self))
            ptr.copyBytes(from: "HELLO".utf8)
        }
        
        XCTAssertEqual("HELLO \0", self.buf.readString(length: 7))
        var slice = self.buf.getSlice(at: 8, length: 5) ?? ByteBuffer()
        self.buf = ByteBuffer()
        slice.withUnsafeMutableReadableBytes { ptr in
            XCTAssertEqual("world", String(decoding: ptr, as: UTF8.self))
            ptr.copyBytes(from: "WORLD".utf8)
        }
        XCTAssertEqual("WORLD", String(buffer: slice))
        XCTAssertEqual(storageID, slice.storagePointerIntegerValue() - 8)
    }
    
    func testWithUnsafeMutableReadableBytesCoWOfNonSlice() {
        let storageID = self.buf.storagePointerIntegerValue()
        self.buf.withUnsafeMutableReadableBytes { ptr in
            XCTAssertEqual(0, ptr.count)
        }
        
        self.buf.writeWithUnsafeMutableBytes(minimumWritableBytes: 5) { ptr in
            XCTAssertGreaterThanOrEqual(ptr.count, 5)
            ptr.copyBytes(from: "hello".utf8)
            return 5
        }
        
        var slice = self.buf.getSlice(at: 2, length: 2) ?? ByteBuffer()
        self.buf.withUnsafeMutableReadableBytes { ptr in
            XCTAssertEqual("hello", String(decoding: ptr, as: UTF8.self))
            ptr.copyBytes(from: "HELLO".utf8)
        }
        XCTAssertNotEqual(storageID, self.buf.storagePointerIntegerValue())
        XCTAssertEqual("ll", String(buffer: slice))
        slice.withUnsafeMutableReadableBytes { ptr in
            XCTAssertEqual("ll", String(decoding: ptr, as: UTF8.self))
            ptr.copyBytes(from: "XX".utf8)
        }
        XCTAssertEqual(storageID, slice.storagePointerIntegerValue() - 2)
        XCTAssertNotEqual(self.buf.storagePointerIntegerValue(), slice.storagePointerIntegerValue() - 2)
        XCTAssertEqual("XX", String(buffer: slice))
    }
    
    func testWithUnsafeMutableReadableBytesCoWOfSlice() {
        let storageID = self.buf.storagePointerIntegerValue()
        self.buf.writeString("hello")
        var slice = self.buf.getSlice(at: 2, length: 3) ?? ByteBuffer()
        slice.withUnsafeMutableReadableBytes { ptr in
            XCTAssertEqual("llo", String(decoding: ptr, as: UTF8.self))
            ptr.copyBytes(from: "foo".utf8)
        }
        XCTAssertNotEqual(storageID, slice.storagePointerIntegerValue() - 2)
        XCTAssertEqual("hello", String(buffer: self.buf))
        XCTAssertEqual("foo", String(buffer: slice))
    }

    func testWithUnsafeMutableReadableBytesAllThingsNonZero() {
        var buf = self.allocator.buffer(capacity: 32)
        let storageID = buf.storagePointerIntegerValue()

        // We start with reader/writer/sliceBegin indices = 0
        XCTAssertEqual(32, buf.capacity)
        XCTAssertEqual(0, buf.readerIndex)
        XCTAssertEqual(0, buf.writerIndex)

        buf.writeString("0123456789abcdef")
        XCTAssertEqual(32, buf.capacity)
        XCTAssertEqual(0, buf.readerIndex)
        XCTAssertEqual(16, buf.writerIndex)

        XCTAssertEqual("012", buf.readString(length: 3))
        XCTAssertEqual(32, buf.capacity)
        XCTAssertEqual(3, buf.readerIndex)
        XCTAssertEqual(16, buf.writerIndex)

        buf.withUnsafeMutableReadableBytes { ptr in
            ptr[ptr.endIndex - 1] = UInt8(ascii: "X")
        }

        var slice = buf.readSlice(length: 12) ?? ByteBuffer()
        XCTAssertEqual("X", String(buffer: buf))

        XCTAssertEqual(32, buf.capacity)
        XCTAssertEqual(15, buf.readerIndex)
        XCTAssertEqual(16, buf.writerIndex)

        XCTAssertEqual(0, slice.readerIndex)
        XCTAssertEqual(12, slice.writerIndex)
        XCTAssertEqual("34567", slice.readString(length: 5))
        XCTAssertEqual(5, slice.readerIndex)
        XCTAssertEqual(12, slice.writerIndex)

        buf = ByteBuffer() // make `slice` the owner of the storage
        slice.withUnsafeMutableReadableBytes { ptr in
            XCTAssertEqual("89abcde", String(decoding: ptr, as: UTF8.self))
            XCTAssertEqual(7, ptr.count)
            ptr.copyBytes(from: "7 bytes".utf8)
        }

        XCTAssertEqual(storageID, slice.storagePointerIntegerValue() - 3)
        XCTAssertEqual("7 bytes", String(buffer: slice))
    }
}


private enum AllocationExpectationState: Int {
    case begin
    case mallocDone
    case reallocDone
    case freeDone
}

private var testAllocationOfReallyBigByteBuffer_state = AllocationExpectationState.begin
private func testAllocationOfReallyBigByteBuffer_freeHook(_ ptr: UnsafeMutableRawPointer?) -> Void {
    precondition(AllocationExpectationState.reallocDone == testAllocationOfReallyBigByteBuffer_state)
    testAllocationOfReallyBigByteBuffer_state = .freeDone
    /* free the pointer initially produced by malloc and then rebased by realloc offsetting it back */
    free(ptr!.advanced(by: Int(Int32.max)))
}

private func testAllocationOfReallyBigByteBuffer_mallocHook(_ size: Int) -> UnsafeMutableRawPointer? {
    precondition(AllocationExpectationState.begin == testAllocationOfReallyBigByteBuffer_state)
    testAllocationOfReallyBigByteBuffer_state = .mallocDone
    /* return a 16 byte pointer here, good enough to write an integer in there */
    return malloc(16)
}

private func testAllocationOfReallyBigByteBuffer_reallocHook(_ ptr: UnsafeMutableRawPointer?, _ count: Int) -> UnsafeMutableRawPointer? {
    precondition(AllocationExpectationState.mallocDone == testAllocationOfReallyBigByteBuffer_state)
    testAllocationOfReallyBigByteBuffer_state = .reallocDone
    /* rebase this pointer by -Int32.max so that the byte copy extending the ByteBuffer below will land at actual index 0 into this buffer ;) */
    return ptr!.advanced(by: -Int(Int32.max))
}

private func testAllocationOfReallyBigByteBuffer_memcpyHook(_ dst: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ count: Int) -> Void {
    /* not actually doing any copies */
}


private var testReserveCapacityLarger_reallocCount = 0
private var testReserveCapacityLarger_mallocCount = 0
private func testReserveCapacityLarger_freeHook( _ ptr: UnsafeMutableRawPointer) -> Void {
    free(ptr)
}

private func testReserveCapacityLarger_mallocHook(_ size: Int) -> UnsafeMutableRawPointer? {
    testReserveCapacityLarger_mallocCount += 1
    return malloc(size)
}

private func testReserveCapacityLarger_reallocHook(_ ptr: UnsafeMutableRawPointer?, _ count: Int) -> UnsafeMutableRawPointer? {
    testReserveCapacityLarger_reallocCount += 1
    return realloc(ptr, count)
}

private func testReserveCapacityLarger_memcpyHook(_ dst: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ count: Int) -> Void {
    // No copying
}

extension ByteBuffer {
    func storagePointerIntegerValue() -> UInt {
        var pointer: UInt = 0
        self.withVeryUnsafeBytes { ptr in
            pointer = UInt(bitPattern: ptr.baseAddress!)
        }
        return pointer
    }
}

// MARK: - Array init
extension ByteBufferTest {
    
    func testCreateArrayFromBuffer() {
        let testString = "some sample data"
        let buffer = ByteBuffer(ByteBufferView(testString.utf8))
        XCTAssertEqual(Array(buffer: buffer), Array(testString.utf8))
    }
    
}

// MARK: - String init
extension ByteBufferTest {
    
    func testCreateStringFromBuffer() {
        let testString = "some sample data"
        let buffer = ByteBuffer(ByteBufferView(testString.utf8))
        XCTAssertEqual(String(buffer: buffer), testString)
    }
    
}

// MARK: - DispatchData init
extension ByteBufferTest {
    
    func testCreateDispatchDataFromBuffer() {
        let testString = "some sample data"
        let buffer = ByteBuffer(ByteBufferView(testString.utf8))
        let expectedData = testString.data(using: .utf8)!.withUnsafeBytes { (pointer) in
            DispatchData(bytes: pointer)
        }
        XCTAssertTrue(DispatchData(buffer: buffer).elementsEqual(expectedData))
    }
    
}

// MARK: - ExpressibleByArrayLiteral init
extension ByteBufferTest {
    
    func testCreateBufferFromArray() {
        let bufferView: ByteBufferView = [0x00, 0x01, 0x02]
        let buffer = ByteBuffer(ByteBufferView(bufferView))
        
        XCTAssertEqual(buffer.readableBytesView, [0x00, 0x01, 0x02])
    }

}

// MARK: - Equatable
extension ByteBufferTest {

    func testByteBufferViewEqualityWithRange() {
        var buffer = self.allocator.buffer(capacity: 8)
        buffer.writeString("AAAABBBB")
        
        let view = ByteBufferView(buffer: buffer, range: 2..<6)
        let comparisonBuffer: ByteBufferView = [0x41, 0x41, 0x42, 0x42]

        XCTAssertEqual(view, comparisonBuffer)
    }

    func testInvalidBufferEqualityWithDifferentRange() {
        var buffer = self.allocator.buffer(capacity: 4)
        buffer.writeString("AAAA")
        
        let view = ByteBufferView(buffer: buffer, range: 0..<2)
        let comparisonBuffer: ByteBufferView = [0x41, 0x41, 0x41, 0x41]

        XCTAssertNotEqual(view, comparisonBuffer)
    }

    func testInvalidBufferEqualityWithDifferentContent() {
        var buffer = self.allocator.buffer(capacity: 4)
        buffer.writeString("AAAA")
        
        let view = ByteBufferView(buffer: buffer, range: 0..<4)
        let comparisonBuffer: ByteBufferView = [0x41, 0x41, 0x00, 0x00]

        XCTAssertNotEqual(view, comparisonBuffer)
    }

}

// MARK: - Hashable
extension ByteBufferTest {

    func testHashableConformance() {
        let bufferView: ByteBufferView = [0x00, 0x01, 0x02]
        let comparisonBufferView: ByteBufferView = [0x00, 0x01, 0x02]

        XCTAssertEqual(bufferView.hashValue, comparisonBufferView.hashValue)
    }


    func testInvalidHash() {
        let bufferView: ByteBufferView = [0x00, 0x00, 0x00]
        let comparisonBufferView: ByteBufferView = [0x00, 0x01, 0x02]

        XCTAssertNotEqual(bufferView.hashValue, comparisonBufferView.hashValue)
    }

    func testValidHashFromSlice() {
        var buffer = self.allocator.buffer(capacity: 4)
        buffer.writeString("AAAA")

        let bufferView = ByteBufferView(buffer: buffer, range: 0..<2)
        let comparisonBufferView = ByteBufferView(buffer: buffer, range: 2..<4)

        XCTAssertEqual(bufferView.hashValue, comparisonBufferView.hashValue)
    }

    func testWritingMultipleIntegers() {
        let w1 = self.buf.writeMultipleIntegers(UInt32(1), UInt8(2), UInt16(3), UInt64(4), UInt16(5), endianness: .big)
        let w2 = self.buf.writeMultipleIntegers(UInt32(1), UInt8(2), UInt16(3), UInt64(4), UInt16(5), endianness: .little)
        XCTAssertEqual(17, w1)
        XCTAssertEqual(17, w2)

        let one1 = self.buf.readInteger(endianness: .big, as: UInt32.self)
        let two1 = self.buf.readInteger(endianness: .big, as: UInt8.self)
        let three1 = self.buf.readInteger(endianness: .big, as: UInt16.self)
        let four1 = self.buf.readInteger(endianness: .big, as: UInt64.self)
        let five1 = self.buf.readInteger(endianness: .big, as: UInt16.self)
        let one2 = self.buf.readInteger(endianness: .little, as: UInt32.self)
        let two2 = self.buf.readInteger(endianness: .little, as: UInt8.self)
        let three2 = self.buf.readInteger(endianness: .little, as: UInt16.self)
        let four2 = self.buf.readInteger(endianness: .little, as: UInt64.self)
        let five2 = self.buf.readInteger(endianness: .little, as: UInt16.self)

        XCTAssertEqual(1, one1)
        XCTAssertEqual(1, one2)
        XCTAssertEqual(2, two1)
        XCTAssertEqual(2, two2)
        XCTAssertEqual(3, three1)
        XCTAssertEqual(3, three2)
        XCTAssertEqual(4, four1)
        XCTAssertEqual(4, four2)
        XCTAssertEqual(5, five1)
        XCTAssertEqual(5, five2)

        XCTAssertEqual(self.buf.readableBytes, 0)
    }

    func testReadAndWriteMultipleIntegers() {
        for endianness in [Endianness.little, .big] {
            let v1: UInt8 = .random(in: .min ... .max)
            let v2: UInt16 = .random(in: .min ... .max)
            let v3: UInt32 = .random(in: .min ... .max)
            let v4: UInt64 = .random(in: .min ... .max)
            let v5: UInt64 = .random(in: .min ... .max)
            let v6: UInt32 = .random(in: .min ... .max)
            let v7: UInt16 = .random(in: .min ... .max)
            let v8: UInt8 = .random(in: .min ... .max)
            let v9: UInt16 = .random(in: .min ... .max)
            let v10: UInt32 = .random(in: .min ... .max)

            let startWriterIndex = self.buf.writerIndex
            let written = self.buf.writeMultipleIntegers(
                v1, v2, v3, v4, v5, v6, v7, v8, v9, v10,
                endianness: endianness,
                as: (UInt8, UInt16, UInt32, UInt64, UInt64, UInt32, UInt16, UInt8, UInt16, UInt32).self)
            XCTAssertEqual(startWriterIndex + written, self.buf.writerIndex)
            XCTAssertEqual(written, self.buf.readableBytes)

            let result = self.buf.readMultipleIntegers(endianness: endianness,
                                                       as: (UInt8, UInt16, UInt32, UInt64, UInt64, UInt32, UInt16, UInt8, UInt16, UInt32).self)
            XCTAssertNotNil(result)
            XCTAssertEqual(0, self.buf.readableBytes)

            XCTAssertEqual(v1, result?.0, "endianness: \(endianness)")
            XCTAssertEqual(v2, result?.1, "endianness: \(endianness)")
            XCTAssertEqual(v3, result?.2, "endianness: \(endianness)")
            XCTAssertEqual(v4, result?.3, "endianness: \(endianness)")
            XCTAssertEqual(v5, result?.4, "endianness: \(endianness)")
            XCTAssertEqual(v6, result?.5, "endianness: \(endianness)")
            XCTAssertEqual(v7, result?.6, "endianness: \(endianness)")
            XCTAssertEqual(v8, result?.7, "endianness: \(endianness)")
            XCTAssertEqual(v9, result?.8, "endianness: \(endianness)")
            XCTAssertEqual(v10, result?.9, "endianness: \(endianness)")
        }
    }

    func testAllByteBufferMultiByteVersions() {
        let i = UInt8(86)
        self.buf.writeMultipleIntegers(i, i)
        self.buf.writeMultipleIntegers(i, i, i)
        self.buf.writeMultipleIntegers(i, i, i, i)
        self.buf.writeMultipleIntegers(i, i, i, i, i)
        self.buf.writeMultipleIntegers(i, i, i, i, i, i)
        self.buf.writeMultipleIntegers(i, i, i, i, i, i, i)
        self.buf.writeMultipleIntegers(i, i, i, i, i, i, i, i)
        self.buf.writeMultipleIntegers(i, i, i, i, i, i, i, i, i)
        self.buf.writeMultipleIntegers(i, i, i, i, i, i, i, i, i, i)
        self.buf.writeMultipleIntegers(i, i, i, i, i, i, i, i, i, i, i)
        self.buf.writeMultipleIntegers(i, i, i, i, i, i, i, i, i, i, i, i)
        self.buf.writeMultipleIntegers(i, i, i, i, i, i, i, i, i, i, i, i, i)
        self.buf.writeMultipleIntegers(i, i, i, i, i, i, i, i, i, i, i, i, i, i)
        self.buf.writeMultipleIntegers(i, i, i, i, i, i, i, i, i, i, i, i, i, i, i)
        XCTAssertEqual(Array(repeating: UInt8(86), count: 119), Array(self.buf.readableBytesView))
        var values2 = self.buf.readMultipleIntegers(as: (UInt8, UInt8).self)!
        var values3 = self.buf.readMultipleIntegers(as: (UInt8, UInt8, UInt8).self)!
        var values4 = self.buf.readMultipleIntegers(as: (UInt8, UInt8, UInt8, UInt8).self)!
        var values5 = self.buf.readMultipleIntegers(as: (UInt8, UInt8, UInt8, UInt8, UInt8).self)!
        var values6 = self.buf.readMultipleIntegers(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self)!
        var values7 = self.buf.readMultipleIntegers(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self)!
        var values8 = self.buf.readMultipleIntegers(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self)!
        var values9 = self.buf.readMultipleIntegers(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self)!
        var values10 = self.buf.readMultipleIntegers(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self)!
        var values11 = self.buf.readMultipleIntegers(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self)!
        var values12 = self.buf.readMultipleIntegers(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self)!
        var values13 = self.buf.readMultipleIntegers(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self)!
        var values14 = self.buf.readMultipleIntegers(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self)!
        var values15 = self.buf.readMultipleIntegers(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self)!

        XCTAssertEqual([i, i], withUnsafeBytes(of: &values2, { Array($0) }))
        XCTAssertEqual([i, i, i], withUnsafeBytes(of: &values3, { Array($0) }))
        XCTAssertEqual([i, i, i, i], withUnsafeBytes(of: &values4, { Array($0) }))
        XCTAssertEqual([i, i, i, i, i], withUnsafeBytes(of: &values5, { Array($0) }))
        XCTAssertEqual([i, i, i, i, i, i], withUnsafeBytes(of: &values6, { Array($0) }))
        XCTAssertEqual([i, i, i, i, i, i, i], withUnsafeBytes(of: &values7, { Array($0) }))
        XCTAssertEqual([i, i, i, i, i, i, i, i], withUnsafeBytes(of: &values8, { Array($0) }))
        XCTAssertEqual([i, i, i, i, i, i, i, i, i], withUnsafeBytes(of: &values9, { Array($0) }))
        XCTAssertEqual([i, i, i, i, i, i, i, i, i, i], withUnsafeBytes(of: &values10, { Array($0) }))
        XCTAssertEqual([i, i, i, i, i, i, i, i, i, i, i], withUnsafeBytes(of: &values11, { Array($0) }))
        XCTAssertEqual([i, i, i, i, i, i, i, i, i, i, i, i], withUnsafeBytes(of: &values12, { Array($0) }))
        XCTAssertEqual([i, i, i, i, i, i, i, i, i, i, i, i, i], withUnsafeBytes(of: &values13, { Array($0) }))
        XCTAssertEqual([i, i, i, i, i, i, i, i, i, i, i, i, i, i], withUnsafeBytes(of: &values14, { Array($0) }))
        XCTAssertEqual([i, i, i, i, i, i, i, i, i, i, i, i, i, i, i], withUnsafeBytes(of: &values15, { Array($0) }))

        XCTAssertEqual(0, self.buf.readableBytes)
    }
}
