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
    func testMessageLengthOfZero() throws {
        let bytesWritten = try buffer.writeLengthPrefix(as: UInt8.self) { buffer in
            // write nothing
        }
        XCTAssertEqual(bytesWritten, 1)
        XCTAssertEqual(buffer.readInteger(as: UInt8.self), 0)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }
    func testMessageLengthOfOne() throws {
        let bytesWritten = try buffer.writeLengthPrefix(as: UInt8.self) { buffer in
            buffer.writeString("A")
        }
        XCTAssertEqual(bytesWritten, 2)
        XCTAssertEqual(buffer.readInteger(as: UInt8.self), 1)
        XCTAssertEqual(buffer.readString(length: 1), "A")
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }
    func testMessageWithMultipleWrites() throws {
        let bytesWritten = try buffer.writeLengthPrefix(as: UInt8.self) { buffer in
            buffer.writeString("Hello")
            buffer.writeString(" ")
            buffer.writeString("World")
        }
        XCTAssertEqual(bytesWritten, 12)
        XCTAssertEqual(buffer.readInteger(as: UInt8.self), 11)
        XCTAssertEqual(buffer.readString(length: 11), "Hello World")
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }
    func testMessageWithMaxLength() throws {
        let messageWithMaxLength = String(repeating: "A", count: 255)
        let bytesWritten = try buffer.writeLengthPrefix(as: UInt8.self) { buffer in
            buffer.writeString(messageWithMaxLength)
        }
        XCTAssertEqual(bytesWritten, 256)
        XCTAssertEqual(buffer.readInteger(as: UInt8.self), 255)
        XCTAssertEqual(buffer.readString(length: 255), messageWithMaxLength)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }
    func testTooLongMessage() throws {
        let messageWithMaxLength = String(repeating: "A", count: 256)
        XCTAssertThrowsError(
            try buffer.writeLengthPrefix(as: UInt8.self) { buffer in
                buffer.writeString(messageWithMaxLength)
            }
        )
    }
    func testMessageWithBigEndianInteger() throws {
        let message = String(repeating: "A", count: 256)
        let bytesWritten = try buffer.writeLengthPrefix(endianness: .big, as: UInt16.self) { buffer in
            buffer.writeString(message)
        }
        XCTAssertEqual(bytesWritten, 258)
        XCTAssertEqual(buffer.readInteger(endianness: .big, as: UInt16.self), 256)
        XCTAssertEqual(buffer.readString(length: 256), message)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }
    func testMessageWithLittleEndianInteger() throws {
        let message = String(repeating: "A", count: 256)
        let bytesWritten = try buffer.writeLengthPrefix(endianness: .little, as: UInt16.self) { buffer in
            buffer.writeString(message)
        }
        XCTAssertEqual(bytesWritten, 258)
        XCTAssertEqual(buffer.readInteger(endianness: .little, as: UInt16.self), 256)
        XCTAssertEqual(buffer.readString(length: 256), message)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }
}
