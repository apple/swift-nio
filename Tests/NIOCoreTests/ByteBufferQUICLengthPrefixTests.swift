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

final class ByteBufferQUICLengthPrefixTests: XCTestCase {
    private var buffer = ByteBuffer()

    // MARK: - writeQUICVariableLengthInteger tests

    func testWriteOneByteQUICVariableLengthInteger() {
        // One byte, ie less than 63, just write out as-is
        for number in 0..<63 {
            var buffer = ByteBuffer()
            buffer.writeQUICVariableLengthInteger(number)
            XCTAssertEqual(buffer.readInteger(as: UInt8.self), UInt8(number))
            XCTAssertEqual(buffer.readableBytes, 0)
        }
    }

    func testWriteTwoByteQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        buffer.writeQUICVariableLengthInteger(0b00111011_10111101)
        // We need to mask the first 2 bits with 01 to indicate this is a 2 byte integer
        // Final result 0b01111011_10111101
        XCTAssertEqual(buffer.readInteger(as: UInt16.self), 0b01111011_10111101)
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testWriteFourByteQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        buffer.writeQUICVariableLengthInteger(0b00011101_01111111_00111110_01111101)
        // 2 bit mask is 10 for 4 bytes so this becomes 0b10011101_01111111_00111110_01111101
        XCTAssertEqual(buffer.readInteger(as: UInt32.self), 0b10011101_01111111_00111110_01111101)
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testWriteEightByteQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        buffer.writeQUICVariableLengthInteger(0b00000010_00011001_01111100_01011110_11111111_00010100_11101000_10001100)
        // 2 bit mask is 11 for 8 bytes so this becomes 0b11000010_00011001_01111100_01011110_11111111_00010100_11101000_10001100
        XCTAssertEqual(
            buffer.readInteger(as: UInt64.self),
            0b11000010_00011001_01111100_01011110_11111111_00010100_11101000_10001100
        )
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    // MARK: - readQUICVariableLengthInteger tests

    func testReadEmptyQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        XCTAssertNil(buffer.readQUICVariableLengthInteger())
    }

    func testWriteReadQUICVariableLengthInteger() {
        for integer in [37, 15293, 494_878_333, 151_288_809_941_952_652] {
            var buffer = ByteBuffer()
            buffer.writeQUICVariableLengthInteger(integer)
            XCTAssertEqual(buffer.readQUICVariableLengthInteger(), integer)
        }
    }

    // MARK: - writeQUICLengthPrefixed with unknown length tests

    func testWriteMessageWithLengthOfZero() throws {
        let bytesWritten = self.buffer.writeQUICLengthPrefixed { _ in
            // write nothing
            0
        }
        XCTAssertEqual(bytesWritten, 4)  // we always encode the length as 4 bytes
        XCTAssertEqual(self.buffer.readQUICVariableLengthInteger(), 0)
        XCTAssertTrue(self.buffer.readableBytesView.isEmpty)
    }

    func testWriteMessageWithLengthOfOne() throws {
        let bytesWritten = self.buffer.writeQUICLengthPrefixed { buffer in
            buffer.writeString("A")
        }
        XCTAssertEqual(bytesWritten, 5)  // 4 for the length + 1 for the 'A'
        XCTAssertEqual(self.buffer.readQUICVariableLengthInteger(), 1)
        XCTAssertEqual(self.buffer.readString(length: 1), "A")
        XCTAssertTrue(self.buffer.readableBytesView.isEmpty)
    }

    func testWriteMessageWithMultipleWrites() throws {
        let bytesWritten = self.buffer.writeQUICLengthPrefixed { buffer in
            buffer.writeString("Hello") + buffer.writeString(" ") + buffer.writeString("World")
        }
        XCTAssertEqual(bytesWritten, 15)  // 4 for the length, plus 11 for the string
        XCTAssertEqual(self.buffer.readQUICVariableLengthInteger(), 11)
        XCTAssertEqual(self.buffer.readString(length: 11), "Hello World")
        XCTAssertTrue(self.buffer.readableBytesView.isEmpty)
    }

    func testWriteMessageWithLengthUsingFull4Bytes() throws {
        // This is the largest possible length you could encode in 4 bytes
        let maxLength = 1_073_741_823 - 1
        let messageWithMaxLength = String(repeating: "A", count: maxLength)
        let bytesWritten = self.buffer.writeQUICLengthPrefixed { buffer in
            buffer.writeString(messageWithMaxLength)
        }
        XCTAssertEqual(bytesWritten, maxLength + 4)  // 4 for the length plus the message itself
        XCTAssertEqual(self.buffer.readQUICVariableLengthInteger(), maxLength)
        XCTAssertEqual(self.buffer.readString(length: maxLength), messageWithMaxLength)
        XCTAssertTrue(self.buffer.readableBytesView.isEmpty)
    }

    func testWriteMessageWithLengthUsing8Bytes() throws {
        // This is the largest possible length you could encode in 4 bytes
        let maxLength = 1_073_741_823
        let messageWithMaxLength = String(repeating: "A", count: maxLength)
        let bytesWritten = self.buffer.writeQUICLengthPrefixed { buffer in
            buffer.writeString(messageWithMaxLength)
        }
        XCTAssertEqual(bytesWritten, maxLength + 8)  // 8 for the length plus the message itself
        XCTAssertEqual(self.buffer.readQUICVariableLengthInteger(), maxLength)
        XCTAssertEqual(self.buffer.readString(length: maxLength), messageWithMaxLength)
        XCTAssertTrue(self.buffer.readableBytesView.isEmpty)
    }

    // MARK: - writeQUICLengthPrefixed with known length tests

    func testWriteMessageWith1ByteLength() throws {
        let bytesWritten = self.buffer.writeQUICLengthPrefixed(ByteBuffer(string: "hello"))
        XCTAssertEqual(bytesWritten, 6)  // The length can be encoded in just 1 byte, followed by 'hello'
        XCTAssertEqual(self.buffer.readQUICVariableLengthInteger(), 5)
        XCTAssertEqual(self.buffer.readString(length: 5), "hello")
        XCTAssertTrue(self.buffer.readableBytesView.isEmpty)
    }

    func testWriteMessageWith2ByteLength() throws {
        let length = 100  // this can be anything between 64 and 16383
        let testString = String(repeating: "A", count: length)
        let bytesWritten = self.buffer.writeQUICLengthPrefixed(ByteBuffer(string: testString))
        XCTAssertEqual(bytesWritten, length + 2)  // The length of the string, plus 2 bytes for the length
        XCTAssertEqual(self.buffer.readQUICVariableLengthInteger(), length)
        XCTAssertEqual(self.buffer.readString(length: length), testString)
        XCTAssertTrue(self.buffer.readableBytesView.isEmpty)
    }

    func testWriteMessageWith4ByteLength() throws {
        let length = 20_000  // this can be anything between 16384 and 1073741823
        let testString = String(repeating: "A", count: length)
        let bytesWritten = self.buffer.writeQUICLengthPrefixed(ByteBuffer(string: testString))
        XCTAssertEqual(bytesWritten, length + 4)  // The length of the string, plus 4 bytes for the length
        XCTAssertEqual(self.buffer.readQUICVariableLengthInteger(), length)
        XCTAssertEqual(self.buffer.readString(length: length), testString)
        XCTAssertTrue(self.buffer.readableBytesView.isEmpty)
    }

    func testWriteMessageWith8ByteLength() throws {
        let length = 1_073_741_824  // this can be anything between 1073741824 and 4611686018427387903
        let testString = String(repeating: "A", count: length)
        let bytesWritten = self.buffer.writeQUICLengthPrefixed(ByteBuffer(string: testString))
        XCTAssertEqual(bytesWritten, length + 8)  // The length of the string, plus 8 bytes for the length
        XCTAssertEqual(self.buffer.readQUICVariableLengthInteger(), length)
        XCTAssertEqual(self.buffer.readString(length: length), testString)
        XCTAssertTrue(self.buffer.readableBytesView.isEmpty)
    }
}
