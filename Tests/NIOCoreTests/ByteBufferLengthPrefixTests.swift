//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
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

final class ByteBufferLengthPrefixTests: XCTestCase {
    private var buffer = ByteBuffer()

    // MARK: - writeLengthPrefixed Tests
    func testWriteMessageWithLengthOfZero() throws {
        let bytesWritten = try buffer.writeLengthPrefixed(as: UInt8.self) { buffer in
            // write nothing
            0
        }
        XCTAssertEqual(bytesWritten, 1)
        XCTAssertEqual(buffer.readInteger(as: UInt8.self), 0)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }
    func testWriteMessageWithLengthOfOne() throws {
        let bytesWritten = try buffer.writeLengthPrefixed(as: UInt8.self) { buffer in
            buffer.writeString("A")
        }
        XCTAssertEqual(bytesWritten, 2)
        XCTAssertEqual(buffer.readInteger(as: UInt8.self), 1)
        XCTAssertEqual(buffer.readString(length: 1), "A")
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }
    func testWriteMessageWithMultipleWrites() throws {
        let bytesWritten = try buffer.writeLengthPrefixed(as: UInt8.self) { buffer in
            buffer.writeString("Hello") + buffer.writeString(" ") + buffer.writeString("World")
        }
        XCTAssertEqual(bytesWritten, 12)
        XCTAssertEqual(buffer.readInteger(as: UInt8.self), 11)
        XCTAssertEqual(buffer.readString(length: 11), "Hello World")
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }
    func testWriteMessageWithMaxLength() throws {
        let messageWithMaxLength = String(repeating: "A", count: 255)
        let bytesWritten = try buffer.writeLengthPrefixed(as: UInt8.self) { buffer in
            buffer.writeString(messageWithMaxLength)
        }
        XCTAssertEqual(bytesWritten, 256)
        XCTAssertEqual(buffer.readInteger(as: UInt8.self), 255)
        XCTAssertEqual(buffer.readString(length: 255), messageWithMaxLength)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }
    func testWriteTooLongMessage() throws {
        let messageWithMaxLength = String(repeating: "A", count: 256)
        XCTAssertThrowsError(
            try buffer.writeLengthPrefixed(as: UInt8.self) { buffer in
                buffer.writeString(messageWithMaxLength)
            }
        )
    }
    func testWriteMessageWithBigEndianInteger() throws {
        let message = String(repeating: "A", count: 256)
        let bytesWritten = try buffer.writeLengthPrefixed(endianness: .big, as: UInt16.self) { buffer in
            buffer.writeString(message)
        }
        XCTAssertEqual(bytesWritten, 258)
        XCTAssertEqual(buffer.readInteger(endianness: .big, as: UInt16.self), 256)
        XCTAssertEqual(buffer.readString(length: 256), message)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }
    func testWriteMessageWithLittleEndianInteger() throws {
        let message = String(repeating: "A", count: 256)
        let bytesWritten = try buffer.writeLengthPrefixed(endianness: .little, as: UInt16.self) { buffer in
            buffer.writeString(message)
        }
        XCTAssertEqual(bytesWritten, 258)
        XCTAssertEqual(buffer.readInteger(endianness: .little, as: UInt16.self), 256)
        XCTAssertEqual(buffer.readString(length: 256), message)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    // MARK: - readLengthPrefixed Tests
    func testReadMessageWithLengthOfZero() {
        buffer.writeInteger(UInt8(0))
        XCTAssertEqual(
            try buffer.readLengthPrefixed(as: UInt8.self) { buffer in
                buffer
            },
            ByteBuffer()
        )
    }
    func testReadMessageWithLengthOfOne() {
        buffer.writeInteger(UInt8(1))
        buffer.writeString("A")
        XCTAssertEqual(
            try buffer.readLengthPrefixed(as: UInt8.self) { buffer in
                var buffer = buffer
                return buffer.readString(length: buffer.readableBytes)
            },
            "A"
        )
    }
    func testReadMessageWithLengthOfTen() {
        buffer.writeInteger(UInt8(11))
        buffer.writeString("Hello World")
        XCTAssertEqual(
            try buffer.readLengthPrefixed(as: UInt8.self) { buffer in
                var buffer = buffer
                return buffer.readString(length: buffer.readableBytes)
            },
            "Hello World"
        )
    }
    func testReadMessageWithMaxLength() {
        buffer.writeInteger(UInt8(255))
        buffer.writeString(String(repeating: "A", count: 255))
        XCTAssertEqual(
            try buffer.readLengthPrefixed(as: UInt8.self) { buffer in
                var buffer = buffer
                return buffer.readString(length: buffer.readableBytes)
            },
            String(repeating: "A", count: 255)
        )
    }
    func testReadOneByteTooMuch() {
        buffer.writeInteger(UInt8(1))
        buffer.writeString("AB")
        XCTAssertThrowsError(
            try buffer.readLengthPrefixed(as: UInt8.self) { buffer -> String? in
                var buffer = buffer
                XCTAssertEqual(buffer.readString(length: buffer.readableBytes), "A")
                return buffer.readString(length: 1)
            }
        )
    }
    func testReadOneByteTooFew() {
        buffer.writeInteger(UInt8(2))
        buffer.writeString("AB")
        XCTAssertEqual(
            try buffer.readLengthPrefixed(as: UInt8.self) { buffer -> String? in
                var buffer = buffer
                return buffer.readString(length: buffer.readableBytes - 1)
            },
            "A"
        )
    }
    func testReadMessageWithBigEndianInteger() {
        buffer.writeInteger(UInt16(256), endianness: .big)
        buffer.writeString(String(repeating: "A", count: 256))
        XCTAssertEqual(
            try buffer.readLengthPrefixed(endianness: .big, as: UInt16.self) { buffer in
                var buffer = buffer
                return buffer.readString(length: buffer.readableBytes)
            },
            String(repeating: "A", count: 256)
        )
    }
    func testReadMessageWithLittleEndianInteger() {
        buffer.writeInteger(UInt16(256), endianness: .little)
        buffer.writeString(String(repeating: "A", count: 256))
        XCTAssertEqual(
            try buffer.readLengthPrefixed(endianness: .little, as: UInt16.self) { buffer in
                var buffer = buffer
                return buffer.readString(length: buffer.readableBytes)
            },
            String(repeating: "A", count: 256)
        )
    }
    func testReadMessageWithMaliciousLength() {
        buffer.writeInteger(UInt64(Int.max) + 1)
        buffer.writeString("A")
        XCTAssertEqual(
            try buffer.readLengthPrefixed(as: UInt64.self) { buffer -> ByteBuffer in
                XCTFail("should never be called")
                return buffer
            },
            nil
        )
    }
    func testReadMessageWithNegativeLength() {
        buffer.writeInteger(Int8(-1))
        buffer.writeString("A")
        XCTAssertEqual(
            try buffer.readLengthPrefixed(as: Int8.self) { buffer -> ByteBuffer in
                XCTFail("should never be called")
                return buffer
            },
            nil
        )
    }

    // MARK: - readLengthPrefixedSlice
    func testReadSliceWithBigEndianInteger() {
        buffer.writeInteger(UInt16(256), endianness: .big)
        buffer.writeString(String(repeating: "A", count: 256))
        XCTAssertEqual(
            buffer.readLengthPrefixedSlice(endianness: .big, as: UInt16.self),
            ByteBuffer(string: String(repeating: "A", count: 256))
        )
        XCTAssertTrue(buffer.readableBytes == 0)
    }
    func testReadSliceWithLittleEndianInteger() {
        buffer.writeInteger(UInt16(256), endianness: .little)
        buffer.writeString(String(repeating: "A", count: 256))
        XCTAssertEqual(
            buffer.readLengthPrefixedSlice(endianness: .little, as: UInt16.self),
            ByteBuffer(string: String(repeating: "A", count: 256))
        )
        XCTAssertTrue(buffer.readableBytes == 0)
    }

    // MARK: - getLengthPrefixedSlice
    func testGetSliceWithBigEndianInteger() {
        buffer.writeString("some data before the length prefix")
        buffer.writeInteger(UInt16(256), endianness: .big)
        buffer.writeString(String(repeating: "A", count: 256))
        XCTAssertEqual(
            buffer.getLengthPrefixedSlice(at: 34, endianness: .big, as: UInt16.self),
            ByteBuffer(string: String(repeating: "A", count: 256))
        )
        XCTAssertTrue(buffer.readerIndex == 0)
    }
    func testGetSliceWithLittleEndianInteger() {
        buffer.writeString("some data before the length prefix")
        buffer.writeInteger(UInt16(256), endianness: .little)
        buffer.writeString(String(repeating: "A", count: 256))
        XCTAssertEqual(
            buffer.getLengthPrefixedSlice(at: 34, endianness: .little, as: UInt16.self),
            ByteBuffer(string: String(repeating: "A", count: 256))
        )
        XCTAssertTrue(buffer.readerIndex == 0)
    }

    // MARK: - peekLengthPrefixedSlice Tests

    func testPeekLengthPrefixedSlice_Normal() {
        var buffer = ByteBuffer()
        let message: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        // Write a length prefix (UInt8).
        buffer.writeInteger(UInt8(message.count))
        buffer.writeBytes(message)

        // Peeks the length prefix, reads that many bytes into a slice.
        guard let slice = buffer.peekLengthPrefixedSlice(as: UInt8.self) else {
            XCTFail("Expected a valid length-prefixed slice.")
            return
        }
        XCTAssertEqual(slice.readableBytes, message.count)
        XCTAssertEqual(slice.getBytes(at: 0, length: message.count), message)
        XCTAssertEqual(buffer.readerIndex, 0, "peekLengthPrefixedSlice() should not advance reader index.")
    }

    func testPeekLengthPrefixedSlice_InvalidPrefix() {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(10))
        buffer.writeBytes([1, 2, 3])

        let slice = buffer.peekLengthPrefixedSlice(as: UInt8.self)
        XCTAssertNil(slice, "Should return nil if actual data is less than the length prefix.")
    }

    func testPeekLengthPrefixedSlice_Repeated() {
        var buffer = ByteBuffer()
        let message: [UInt8] = [0x01, 0x02, 0x03]
        buffer.writeInteger(UInt8(message.count))
        buffer.writeBytes(message)

        let firstPeek = buffer.peekLengthPrefixedSlice(as: UInt8.self)
        let secondPeek = buffer.peekLengthPrefixedSlice(as: UInt8.self)
        XCTAssertNotNil(firstPeek)
        XCTAssertNotNil(secondPeek, "Repeated calls should yield the same slice.")
        XCTAssertEqual(buffer.readerIndex, 0, "Reader index remains unchanged after repeated peeks.")
    }
}
