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
            buffer.writeString("Hello") + 
            buffer.writeString(" ") +
            buffer.writeString("World")
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
            buffer.readLengthPrefixed(as: UInt8.self) { length, buffer in
                return length
            }, 
            0
        )
    }
    func testReadMessageWithLengthOfOne() {
        buffer.writeInteger(UInt8(1))
        buffer.writeString("A")
        XCTAssertEqual(
            buffer.readLengthPrefixed(as: UInt8.self) { length, buffer in
                buffer.readString(length: length)
            },
            "A"
        )
    }
    func testReadMessageWithLengthOfTen() {
        buffer.writeInteger(UInt8(11))
        buffer.writeString("Hello World")
        XCTAssertEqual(
            buffer.readLengthPrefixed(as: UInt8.self) { length, buffer in
                buffer.readString(length: length)
            },
            "Hello World"
        )
    }
    func testReadMessageWithMaxLength() {
        buffer.writeInteger(UInt8(255))
        buffer.writeString(String(repeating: "A", count: 255))
        XCTAssertEqual(
            buffer.readLengthPrefixed(as: UInt8.self) { length, buffer in
                buffer.readString(length: length)
            },
            String(repeating: "A", count: 255)
        )
    }
    func testReadOneByteTooMuch() {
        buffer.writeInteger(UInt8(1))
        buffer.writeString("AB")
        XCTAssertEqual(
            buffer.readLengthPrefixed(as: UInt8.self) { length, buffer -> String? in
                XCTAssertEqual(buffer.readString(length: length), "A")
                return buffer.readString(length: 1)
            },
            nil
        )
    }
    func testReadOneByteTooFew() {
        buffer.writeInteger(UInt8(2))
        buffer.writeString("AB")
        XCTAssertEqual(
        buffer.readLengthPrefixed(as: UInt8.self) { length, buffer -> String? in
                buffer.readString(length: length - 1)
            },
            "A"
        )
    }
    func testReadMessageWithBigEndianInteger() {
        buffer.writeInteger(UInt16(256), endianness: .big)
        buffer.writeString(String(repeating: "A", count: 256))
        XCTAssertEqual(
            buffer.readLengthPrefixed(endianness: .big, as: UInt16.self) { length, buffer in
                buffer.readString(length: length)
            },
            String(repeating: "A", count: 256)
        )
    }
    func testReadMessageWithLittleEndianInteger() {
        buffer.writeInteger(UInt16(256), endianness: .little)
        buffer.writeString(String(repeating: "A", count: 256))
        XCTAssertEqual(
            buffer.readLengthPrefixed(endianness: .little, as: UInt16.self) { length, buffer in
                buffer.readString(length: length)
            },
            String(repeating: "A", count: 256)
        )
    }
    func testReadMessageWithMaliciousLength() {
        buffer.writeInteger(UInt64(Int.max) + 1)
        buffer.writeString("A")
        XCTAssertEqual(
            buffer.readLengthPrefixed(as: UInt64.self) { length, buffer -> Int in
                XCTFail("should never be called")
                return 0
            },
            nil
        )
    }
}
