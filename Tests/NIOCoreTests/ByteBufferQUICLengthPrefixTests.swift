//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
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
    // MARK: - writeQUICVariableLengthInteger tests

    func testWriteOneByteQUICVariableLengthInteger() {
        // One byte, ie less than 63, just write out as-is
        for number in 0..<63 {
            var buffer = ByteBuffer()
            let bytesWritten = buffer.writeQUICVariableLengthInteger(number)
            XCTAssertEqual(bytesWritten, 1)
            XCTAssertEqual(buffer.readInteger(as: UInt8.self), UInt8(number))
            XCTAssertEqual(buffer.readableBytes, 0)
        }
    }

    func testWriteTwoByteQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        let bytesWritten = buffer.writeQUICVariableLengthInteger(0b00111011_10111101)
        XCTAssertEqual(bytesWritten, 2)
        // We need to mask the first 2 bits with 01 to indicate this is a 2 byte integer
        // Final result 0b01111011_10111101
        XCTAssertEqual(buffer.readInteger(as: UInt16.self), 0b01111011_10111101)
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testWriteFourByteQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        let bytesWritten = buffer.writeQUICVariableLengthInteger(0b00011101_01111111_00111110_01111101)
        XCTAssertEqual(bytesWritten, 4)
        // 2 bit mask is 10 for 4 bytes so this becomes 0b10011101_01111111_00111110_01111101
        XCTAssertEqual(buffer.readInteger(as: UInt32.self), 0b10011101_01111111_00111110_01111101)
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testWriteEightByteQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        let bytesWritten = buffer.writeQUICVariableLengthInteger(
            0b00000010_00011001_01111100_01011110_11111111_00010100_11101000_10001100
        )
        XCTAssertEqual(bytesWritten, 8)
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

    // MARK: - writeQUICVariableLengthPrefixed tests

    func testWriteMessageWithLengthOfZero() {
        var buffer = ByteBuffer()
        let bytesWritten = buffer.writeQUICVariableLengthPrefixed { _ in
            // write nothing
            0
        }
        XCTAssertEqual(bytesWritten, 4)  // we always encode the length as 4 bytes
        XCTAssertEqual(buffer.readQUICVariableLengthInteger(), 0)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    func testWriteMessageWithLengthOfOne() {
        var buffer = ByteBuffer()
        let bytesWritten = buffer.writeQUICVariableLengthPrefixed { buffer in
            buffer.writeString("A")
        }
        XCTAssertEqual(bytesWritten, 5)  // 4 for the length + 1 for the 'A'
        XCTAssertEqual(buffer.readQUICVariableLengthInteger(), 1)
        XCTAssertEqual(buffer.readString(length: 1), "A")
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    func testWriteMessageWithMultipleWrites() {
        var buffer = ByteBuffer()
        let bytesWritten = buffer.writeQUICVariableLengthPrefixed { buffer in
            buffer.writeString("Hello") + buffer.writeString(" ") + buffer.writeString("World")
        }
        XCTAssertEqual(bytesWritten, 15)  // 4 for the length, plus 11 for the string
        XCTAssertEqual(buffer.readQUICVariableLengthInteger(), 11)
        XCTAssertEqual(buffer.readString(length: 11), "Hello World")
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    func testWriteMessageWithLengthUsingFull4Bytes() {
        var buffer = ByteBuffer()
        // This is the largest possible length you could encode in 4 bytes
        let maxLength = 1_073_741_823 - 1
        let messageWithMaxLength = String(repeating: "A", count: maxLength)
        let bytesWritten = buffer.writeQUICVariableLengthPrefixed { buffer in
            buffer.writeString(messageWithMaxLength)
        }
        XCTAssertEqual(bytesWritten, maxLength + 4)  // 4 for the length plus the message itself
        XCTAssertEqual(buffer.readQUICVariableLengthInteger(), maxLength)
        XCTAssertEqual(buffer.readString(length: maxLength), messageWithMaxLength)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    func testWriteMessageWithLengthUsing8Bytes() {
        var buffer = ByteBuffer()
        // This is the largest possible length you could encode in 4 bytes
        let maxLength = 1_073_741_823
        let messageWithMaxLength = String(repeating: "A", count: maxLength)
        let bytesWritten = buffer.writeQUICVariableLengthPrefixed { buffer in
            buffer.writeString(messageWithMaxLength)
        }
        XCTAssertEqual(bytesWritten, maxLength + 8)  // 8 for the length plus the message itself
        XCTAssertEqual(buffer.readQUICVariableLengthInteger(), maxLength)
        XCTAssertEqual(buffer.readString(length: maxLength), messageWithMaxLength)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    // MARK: - writeQUICVariableLengthPrefixedBuffer tests

    func testWriteMessageWith1ByteLength() {
        var buffer = ByteBuffer()
        let bytesWritten = buffer.writeQUICVariableLengthPrefixedBuffer(ByteBuffer(string: "hello"))
        XCTAssertEqual(bytesWritten, 6)  // The length can be encoded in just 1 byte, followed by 'hello'
        XCTAssertEqual(buffer.readQUICVariableLengthInteger(), 5)
        XCTAssertEqual(buffer.readString(length: 5), "hello")
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    func testWriteMessageWith2ByteLength() {
        var buffer = ByteBuffer()
        let length = 100  // this can be anything between 64 and 16383
        let testString = String(repeating: "A", count: length)
        let bytesWritten = buffer.writeQUICVariableLengthPrefixedBuffer(ByteBuffer(string: testString))
        XCTAssertEqual(bytesWritten, length + 2)  // The length of the string, plus 2 bytes for the length
        XCTAssertEqual(buffer.readQUICVariableLengthInteger(), length)
        XCTAssertEqual(buffer.readString(length: length), testString)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    func testWriteMessageWith4ByteLength() {
        var buffer = ByteBuffer()
        let length = 20_000  // this can be anything between 16384 and 1073741823
        let testString = String(repeating: "A", count: length)
        let bytesWritten = buffer.writeQUICVariableLengthPrefixedBuffer(ByteBuffer(string: testString))
        XCTAssertEqual(bytesWritten, length + 4)  // The length of the string, plus 4 bytes for the length
        XCTAssertEqual(buffer.readQUICVariableLengthInteger(), length)
        XCTAssertEqual(buffer.readString(length: length), testString)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    func testWriteMessageWith8ByteLength() {
        var buffer = ByteBuffer()
        let length = 1_073_741_824  // this can be anything between 1073741824 and 4611686018427387903
        let testString = String(repeating: "A", count: length)
        let bytesWritten = buffer.writeQUICVariableLengthPrefixedBuffer(ByteBuffer(string: testString))
        XCTAssertEqual(bytesWritten, length + 8)  // The length of the string, plus 8 bytes for the length
        XCTAssertEqual(buffer.readQUICVariableLengthInteger(), length)
        XCTAssertEqual(buffer.readString(length: length), testString)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    // MARK: - writeQUICVariableLengthPrefixedString tests

    func testWriteQUICVariableLengthPrefixedString() {
        var buffer = ByteBuffer()
        let testString = "Hello World"  // length = 11
        let bytesWritten = buffer.writeQUICVariableLengthPrefixedString(testString)
        XCTAssertEqual(bytesWritten, 12)

        let length = buffer.readQUICVariableLengthInteger()
        XCTAssertEqual(length, 11)

        XCTAssertEqual(buffer.readString(length: 11), testString)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    // MARK: - writeQUICVariableLengthPrefixedBytes tests

    func testWriteQUICVariableLengthPrefixedBytes() {
        var buffer = ByteBuffer()
        let testBytes: [UInt8] = [1, 2, 3, 4, 5]  // length = 5
        let bytesWritten = buffer.writeQUICVariableLengthPrefixedBytes(testBytes)
        XCTAssertEqual(bytesWritten, 6)

        let length = buffer.readQUICVariableLengthInteger()
        XCTAssertEqual(length, 5)

        XCTAssertEqual(buffer.readBytes(length: 5), testBytes)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    // MARK: - testReadQUICVariableLengthPrefixedSlice tests

    func testReadQUICVariableLengthPrefixedSlice() {
        for size in [37, 15293, 494_878_333] {  // random sizes to hit different integer lengths
            var buffer = ByteBuffer()
            let value = ByteBuffer(repeating: 1, count: size)
            buffer.writeQUICVariableLengthPrefixedBuffer(value)
            XCTAssertEqual(buffer.readQUICVariableLengthPrefixedSlice(), value)
        }
    }
}
