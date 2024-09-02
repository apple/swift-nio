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
            let strategy = ByteBuffer.QUICBinaryEncodingStrategy(reservedSpace: 0)
            let bytesWritten = strategy.writeInteger(number, to: &buffer)
            XCTAssertEqual(bytesWritten, 1)
            XCTAssertEqual(strategy.readInteger(as: UInt8.self, from: &buffer), UInt8(number))
            XCTAssertEqual(buffer.readableBytes, 0)
        }
    }

    func testWriteTwoByteQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        let strategy = ByteBuffer.QUICBinaryEncodingStrategy(reservedSpace: 0)
        let bytesWritten = strategy.writeInteger(0b00111011_10111101, to: &buffer)
        XCTAssertEqual(bytesWritten, 2)
        // We need to mask the first 2 bits with 01 to indicate this is a 2 byte integer
        // Final result 0b01111011_10111101
        XCTAssertEqual(buffer.readInteger(as: UInt16.self), 0b01111011_10111101)
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testWriteFourByteQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        let strategy = ByteBuffer.QUICBinaryEncodingStrategy(reservedSpace: 0)
        let bytesWritten = strategy.writeInteger(0b00011101_01111111_00111110_01111101, to: &buffer)
        XCTAssertEqual(bytesWritten, 4)
        // 2 bit mask is 10 for 4 bytes so this becomes 0b10011101_01111111_00111110_01111101
        XCTAssertEqual(buffer.readInteger(as: UInt32.self), 0b10011101_01111111_00111110_01111101)
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testWriteEightByteQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        let strategy = ByteBuffer.QUICBinaryEncodingStrategy(reservedSpace: 0)
        let bytesWritten = strategy.writeInteger(
            0b00000010_00011001_01111100_01011110_11111111_00010100_11101000_10001100,
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

    // MARK: - writeEncodedIntegerWithReservedSpace tests

    func testWriteOneByteQUICVariableLengthIntegerWithTwoBytesReserved() {
        // We only need one byte but the encoder will use 2 because we reserved 2
        var buffer = ByteBuffer()
        let strategy = ByteBuffer.QUICBinaryEncodingStrategy(reservedSpace: 0)
        let bytesWritten = strategy.writeIntegerWithReservedSpace(0b00000001, reservedSpace: 2, to: &buffer)
        XCTAssertEqual(bytesWritten, 2)
        XCTAssertEqual(buffer.readInteger(as: UInt16.self), UInt16(0b01000000_00000001))
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testRoundtripWithReservedSpace() {
        // This test makes sure that a number encoded with more space than necessary can still be decoded as normal
        for reservedSpace in [0, 1, 2, 4, 8] {
            for testNumber in [0, 63, 15293, 494_878_333, 151_288_809_941_952_652] {
                var buffer = ByteBuffer()
                let strategy = ByteBuffer.QUICBinaryEncodingStrategy(reservedSpace: 0)
                let bytesWritten = strategy.writeIntegerWithReservedSpace(
                    testNumber,
                    reservedSpace: reservedSpace,
                    to: &buffer
                )
                XCTAssertEqual(bytesWritten, max(strategy.bytesNeededForInteger(testNumber), reservedSpace))
                XCTAssertEqual(strategy.readInteger(as: UInt64.self, from: &buffer), UInt64(testNumber))
                XCTAssertEqual(buffer.readableBytes, 0)
            }
        }
    }

    // MARK: - readEncodedInteger tests

    func testReadEmptyQUICVariableLengthInteger() {
        var buffer = ByteBuffer()
        let strategy = ByteBuffer.QUICBinaryEncodingStrategy(reservedSpace: 0)
        XCTAssertNil(strategy.readInteger(as: Int.self, from: &buffer))
    }

    func testWriteReadQUICVariableLengthInteger() {
        let strategy = ByteBuffer.QUICBinaryEncodingStrategy(reservedSpace: 0)
        for integer in [37, 15293, 494_878_333, 151_288_809_941_952_652] {
            var buffer = ByteBuffer()
            _ = strategy.writeInteger(integer, to: &buffer)
            XCTAssertEqual(strategy.readInteger(as: Int.self, from: &buffer), integer)
        }
    }
}
