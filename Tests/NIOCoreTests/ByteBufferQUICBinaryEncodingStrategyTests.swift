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

import XCTest

@testable import NIOCore

final class ByteBufferQUICBinaryEncodingStrategyTests: XCTestCase {
    // MARK: - writeEncodedInteger tests

    func testWriteOneByteQUICVariableLengthInteger() {
        // One byte, ie less than 63, just write out as-is
        for number in 0..<63 {
            var buffer = ByteBuffer()
            let strategy = ByteBuffer.QUICBinaryEncodingStrategy.quic
            let bytesWritten = strategy.writeInteger(number, to: &buffer)
            XCTAssertEqual(bytesWritten, 1)
            // The number is written exactly as is
            XCTAssertEqual(buffer.readInteger(as: UInt8.self), UInt8(number))
            XCTAssertEqual(buffer.readableBytes, 0)
        }
    }

    func testWriteBigUInt8() {
        // This test case specifically tests the scenario where 2 bytes are needed, but the number being written is UInt8.
        // A naive implementation of the quic variable length integer encoder might check whether the number is in
        // the range of 64..<16383, to determine that it should be written with 2 bytes.
        // However, constructing such a range on a UInt8 would actually construct 64..<0, because 16383 can't be represented as UInt8.
        // So this test makes sure we didn't make that mistake
        let number: UInt8 = .max
        var buffer = ByteBuffer()
        let strategy = ByteBuffer.QUICBinaryEncodingStrategy.quic
        let bytesWritten = strategy.writeInteger(number, to: &buffer)
        XCTAssertEqual(bytesWritten, 2)
        XCTAssertEqual(buffer.readInteger(as: UInt16.self), 0b01000000_11111111)
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testWriteTwoByteQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        let strategy = ByteBuffer.QUICBinaryEncodingStrategy.quic
        let bytesWritten = strategy.writeInteger(0b00111011_10111101, to: &buffer)
        XCTAssertEqual(bytesWritten, 2)
        // We need to mask the first 2 bits with 01 to indicate this is a 2 byte integer
        // Final result 0b01111011_10111101
        XCTAssertEqual(buffer.readInteger(as: UInt16.self), 0b01111011_10111101)
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testWriteFourByteQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        let strategy = ByteBuffer.QUICBinaryEncodingStrategy.quic
        let bytesWritten = strategy.writeInteger(0b00011101_01111111_00111110_01111101 as Int64, to: &buffer)
        XCTAssertEqual(bytesWritten, 4)
        // 2 bit mask is 10 for 4 bytes so this becomes 0b10011101_01111111_00111110_01111101
        XCTAssertEqual(buffer.readInteger(as: UInt32.self), 0b10011101_01111111_00111110_01111101)
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testWriteEightByteQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        let strategy = ByteBuffer.QUICBinaryEncodingStrategy.quic
        let bytesWritten = strategy.writeInteger(
            0b00000010_00011001_01111100_01011110_11111111_00010100_11101000_10001100 as Int64,
            to: &buffer
        )
        XCTAssertEqual(bytesWritten, 8)
        // 2 bit mask is 11 for 8 bytes so this becomes 0b11000010_00011001_01111100_01011110_11111111_00010100_11101000_10001100
        XCTAssertEqual(
            buffer.readInteger(as: UInt64.self),
            0b11000010_00011001_01111100_01011110_11111111_00010100_11101000_10001100
        )
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    // MARK: - writeEncodedIntegerWithReservedCapacity tests

    func testWriteOneByteQUICVariableLengthIntegerWithTwoBytesReserved() {
        // We only need one byte but the encoder will use 2 because we reserved 2
        var buffer = ByteBuffer()
        let strategy = ByteBuffer.QUICBinaryEncodingStrategy.quic
        let bytesWritten = strategy.writeInteger(0b00000001, reservedCapacity: 2, to: &buffer)
        XCTAssertEqual(bytesWritten, 2)
        XCTAssertEqual(buffer.readInteger(as: UInt16.self), UInt16(0b01000000_00000001))
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testRoundtripWithReservedCapacity() {
        // This test makes sure that a number encoded with more space than necessary can still be decoded as normal
        for reservedCapacity in [0, 1, 2, 4, 8] {
            let testNumbers: [Int64] = [0, 63, 15293, 494_878_333, 151_288_809_941_952_652]
            for testNumber in testNumbers {
                var buffer = ByteBuffer()
                let strategy = ByteBuffer.QUICBinaryEncodingStrategy.quic
                let bytesWritten = strategy.writeInteger(
                    testNumber,
                    reservedCapacity: reservedCapacity,
                    to: &buffer
                )
                let minRequiredBytes = ByteBuffer.QUICBinaryEncodingStrategy.bytesNeededForInteger(testNumber)
                // If the reserved capacity is higher than the min required, use the reserved number
                let expectedUsedBytes = max(minRequiredBytes, reservedCapacity)
                XCTAssertEqual(bytesWritten, expectedUsedBytes)
                XCTAssertEqual(strategy.readInteger(as: UInt64.self, from: &buffer), UInt64(testNumber))
                XCTAssertEqual(buffer.readableBytes, 0)
            }
        }
    }

    // MARK: - readEncodedInteger tests

    func testReadEmptyQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        let strategy = ByteBuffer.QUICBinaryEncodingStrategy.quic
        XCTAssertNil(strategy.readInteger(as: Int.self, from: &buffer))
    }

    func testWriteReadQUICVariableLengthInteger() {
        let strategy = ByteBuffer.QUICBinaryEncodingStrategy.quic
        let testNumbers: [Int64] = [37, 15293, 494_878_333, 151_288_809_941_952_652]
        for integer in testNumbers {
            var buffer = ByteBuffer()
            _ = strategy.writeInteger(integer, to: &buffer)
            XCTAssertEqual(strategy.readInteger(as: Int64.self, from: &buffer), integer)
        }
    }
}
