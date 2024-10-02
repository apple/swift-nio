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

/// A strategy which just writes integers as UInt8. Enforces the integer must be a particular number to aid testing. Forbids reads
struct UInt8WritingTestStrategy: NIOBinaryIntegerEncodingStrategy {
    let expectedWrite: Int

    func readInteger<IntegerType: FixedWidthInteger>(
        as: IntegerType.Type,
        from buffer: inout ByteBuffer
    ) -> IntegerType? {
        XCTFail("This should not be called")
        return 1
    }

    func writeInteger<IntegerType: FixedWidthInteger>(_ integer: IntegerType, to buffer: inout ByteBuffer) -> Int {
        XCTAssertEqual(Int(integer), self.expectedWrite)
        return buffer.writeInteger(UInt8(integer))
    }

    func writeInteger(_ integer: Int, reservedCapacity: Int, to buffer: inout ByteBuffer) -> Int {
        XCTFail("This should not be called")
        return 1
    }
}

// A which reads a single UInt8 for the length. Forbids writes
struct UInt8ReadingTestStrategy: NIOBinaryIntegerEncodingStrategy {
    let expectedRead: UInt8

    func readInteger<IntegerType: FixedWidthInteger>(
        as: IntegerType.Type,
        from buffer: inout ByteBuffer
    ) -> IntegerType? {
        let value = buffer.readInteger(as: UInt8.self)
        XCTAssertEqual(value, self.expectedRead)
        return value.flatMap(IntegerType.init)
    }

    func writeInteger<IntegerType: FixedWidthInteger>(_ integer: IntegerType, to buffer: inout ByteBuffer) -> Int {
        XCTFail("This should not be called")
        return 1
    }

    func writeInteger(_ integer: Int, reservedCapacity: Int, to buffer: inout ByteBuffer) -> Int {
        XCTFail("This should not be called")
        return 1
    }

    var requiredBytesHint: Int { 1 }
}

final class ByteBufferBinaryEncodedLengthPrefixTests: XCTestCase {
    // MARK: - simple readEncodedInteger and writeEncodedInteger tests

    func testReadWriteEncodedInteger() {
        struct TestStrategy: NIOBinaryIntegerEncodingStrategy {
            func readInteger<IntegerType: FixedWidthInteger>(
                as: IntegerType.Type,
                from buffer: inout ByteBuffer
            ) -> IntegerType? {
                10
            }

            func writeInteger<IntegerType: FixedWidthInteger>(
                _ integer: IntegerType,
                to buffer: inout ByteBuffer
            ) -> Int {
                XCTAssertEqual(integer, 10)
                return 1
            }

            func writeInteger(
                _ integer: Int,
                reservedCapacity: Int,
                to buffer: inout ByteBuffer
            ) -> Int {
                XCTFail("This should not be called")
                return 1
            }
        }

        // This should just call down to the strategy function
        var buffer = ByteBuffer()
        XCTAssertEqual(buffer.readEncodedInteger(strategy: TestStrategy()), 10)
        XCTAssertEqual(buffer.writeEncodedInteger(10, strategy: TestStrategy()), 1)
    }

    // MARK: - writeLengthPrefixed tests

    func testWriteLengthPrefixedFitsInReservedCapacity() {
        struct TestStrategy: NIOBinaryIntegerEncodingStrategy {
            func readInteger<IntegerType: FixedWidthInteger>(
                as: IntegerType.Type,
                from buffer: inout ByteBuffer
            ) -> IntegerType? {
                XCTFail("This should not be called")
                return 1
            }

            func writeInteger<IntegerType: FixedWidthInteger>(
                _ integer: IntegerType,
                to buffer: inout ByteBuffer
            ) -> Int {
                XCTFail("This should not be called")
                return 1
            }

            func writeInteger(
                _ integer: Int,
                reservedCapacity: Int,
                to buffer: inout ByteBuffer
            ) -> Int {
                XCTAssertEqual(Int(integer), 4)
                XCTAssertEqual(reservedCapacity, 1)
                return buffer.writeInteger(UInt8(integer))
            }

            var requiredBytesHint: Int { 1 }
        }

        var buffer = ByteBuffer()
        buffer.writeLengthPrefixed(strategy: TestStrategy()) { writer in
            writer.writeString("test")
        }

        XCTAssertEqual(buffer.readableBytes, 5)
        XCTAssertEqual(buffer.readBytes(length: 5), [4] + "test".utf8)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    func testWriteLengthPrefixedNeedsMoreThanReservedCapacity() {
        struct TestStrategy: NIOBinaryIntegerEncodingStrategy {
            func readInteger<IntegerType: FixedWidthInteger>(
                as: IntegerType.Type,
                from buffer: inout ByteBuffer
            ) -> IntegerType? {
                XCTFail("This should not be called")
                return 1
            }

            func writeInteger<IntegerType: FixedWidthInteger>(
                _ integer: IntegerType,
                to buffer: inout ByteBuffer
            ) -> Int {
                XCTFail("This should not be called")
                return 1
            }

            func writeInteger(
                _ integer: Int,
                reservedCapacity: Int,
                to buffer: inout ByteBuffer
            ) -> Int {
                XCTAssertEqual(Int(integer), 4)
                XCTAssertEqual(reservedCapacity, 1)
                // We use 8 bytes, but only one was reserved
                return buffer.writeInteger(UInt64(integer))
            }

            var requiredBytesHint: Int { 1 }
        }

        var buffer = ByteBuffer()
        buffer.writeLengthPrefixed(strategy: TestStrategy()) { writer in
            writer.writeString("test")
        }

        // The strategy above uses 8 bytes for encoding the length. The data is 4, making a total of 12 bytes written
        XCTAssertEqual(buffer.readableBytes, 12)
        XCTAssertEqual(buffer.readBytes(length: 12), [0, 0, 0, 0, 0, 0, 0, 4] + "test".utf8)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    func testWriteLengthPrefixedNeedsLessThanReservedCapacity() {
        struct TestStrategy: NIOBinaryIntegerEncodingStrategy {
            func readInteger<IntegerType: FixedWidthInteger>(
                as: IntegerType.Type,
                from buffer: inout ByteBuffer
            ) -> IntegerType? {
                XCTFail("This should not be called")
                return 1
            }

            func writeInteger<IntegerType: FixedWidthInteger>(
                _ integer: IntegerType,
                to buffer: inout ByteBuffer
            ) -> Int {
                XCTFail("This should not be called")
                return 1
            }

            func writeInteger(
                _ integer: Int,
                reservedCapacity: Int,
                to buffer: inout ByteBuffer
            ) -> Int {
                XCTAssertEqual(Int(integer), 4)
                XCTAssertEqual(reservedCapacity, 8)
                return buffer.writeInteger(UInt8(integer))
            }

            var requiredBytesHint: Int { 8 }
        }

        var buffer = ByteBuffer()
        buffer.writeLengthPrefixed(strategy: TestStrategy()) { writer in
            writer.writeString("test")
        }

        // The strategy above reserves 8 bytes, but only uses 1
        // The implementation will take care of removing the 7 spare bytes for us
        XCTAssertEqual(buffer.readableBytes, 5)
        XCTAssertEqual(buffer.readBytes(length: 5), [4] + "test".utf8)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    func testWriteLengthPrefixedThrowing() {
        // A strategy which fails the test if anything is called
        struct NeverCallStrategy: NIOBinaryIntegerEncodingStrategy {
            func readInteger<IntegerType: FixedWidthInteger>(
                as: IntegerType.Type,
                from buffer: inout ByteBuffer
            ) -> IntegerType? {
                XCTFail("This should not be called")
                return 1
            }

            func writeInteger<IntegerType: FixedWidthInteger>(
                _ integer: IntegerType,
                to buffer: inout ByteBuffer
            ) -> Int {
                XCTFail("This should not be called")
                return 1
            }

            func writeInteger(
                _ integer: Int,
                reservedCapacity: Int,
                to buffer: inout ByteBuffer
            ) -> Int {
                XCTFail("This should not be called")
                return 1
            }

            var requiredBytesHint: Int { 1 }
        }

        struct TestError: Error {}

        var buffer = ByteBuffer()
        do {
            try buffer.writeLengthPrefixed(strategy: NeverCallStrategy()) { _ in
                throw TestError()
            }
            XCTFail("Expected call to throw")
        } catch {
            // Nothing should have happened, buffer should still be empty
            XCTAssertTrue(buffer.readableBytesView.isEmpty)
        }
    }

    // MARK: - readLengthPrefixed tests

    func testReadLengthPrefixedSlice() {
        var buffer = ByteBuffer()
        buffer.writeBytes([5, 1, 2, 3, 4, 5])
        let slice = buffer.readLengthPrefixedSlice(strategy: UInt8ReadingTestStrategy(expectedRead: 5))
        XCTAssertEqual(slice?.readableBytesView, [1, 2, 3, 4, 5])
    }

    func testReadLengthPrefixedSliceInsufficientBytes() {
        var buffer = ByteBuffer()
        buffer.writeBytes([5, 1, 2, 3])  // We put a length of 5, followed by only 3 bytes
        let slice = buffer.readLengthPrefixedSlice(strategy: UInt8ReadingTestStrategy(expectedRead: 5))
        XCTAssertNil(slice)
        // The original buffer reader index should NOT move
        XCTAssertEqual(buffer.readableBytesView, [5, 1, 2, 3])
    }

    // MARK: - writeLengthPrefixed* tests

    func testWriteVariableLengthPrefixedString() {
        var buffer = ByteBuffer()
        let strategy = UInt8WritingTestStrategy(expectedWrite: 11)
        let testString = "Hello World"  // length = 11
        let bytesWritten = buffer.writeLengthPrefixedString(testString, strategy: strategy)
        XCTAssertEqual(bytesWritten, 11 + 1)  // we use 1 byte to write the length

        XCTAssertEqual(buffer.readableBytes, 12)
        XCTAssertEqual(buffer.readBytes(length: 12), [11] + testString.utf8)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    func testWriteVariableLengthPrefixedBytes() {
        var buffer = ByteBuffer()
        let strategy = UInt8WritingTestStrategy(expectedWrite: 10)
        let testBytes = [UInt8](repeating: 1, count: 10)
        let bytesWritten = buffer.writeLengthPrefixedBytes(testBytes, strategy: strategy)
        XCTAssertEqual(bytesWritten, 10 + 1)  // we use 1 byte to write the length

        XCTAssertEqual(buffer.readableBytes, 11)
        XCTAssertEqual(buffer.readBytes(length: 11), [10, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1])
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }

    func testWriteVariableLengthPrefixedBuffer() {
        var buffer = ByteBuffer()
        let strategy = UInt8WritingTestStrategy(expectedWrite: 4)
        let testBuffer = ByteBuffer(string: "test")
        let bytesWritten = buffer.writeLengthPrefixedBuffer(testBuffer, strategy: strategy)
        XCTAssertEqual(bytesWritten, 4 + 1)  // we use 1 byte to write the length

        XCTAssertEqual(buffer.readableBytes, 5)
        XCTAssertEqual(buffer.readBytes(length: 5), [4] + "test".utf8)
        XCTAssertTrue(buffer.readableBytesView.isEmpty)
    }
}
