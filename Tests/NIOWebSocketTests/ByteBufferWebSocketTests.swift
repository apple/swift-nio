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
import NIOWebSocket
import XCTest

final class ByteBufferWebSocketTests: XCTestCase {
    private var buffer = ByteBuffer()

    // MARK: - getWebSocketErrorCode(at:) Tests

    func testGetWebSocketErrorCode_WithValidCode() {
        let expected = WebSocketErrorCode.protocolError
        buffer.write(webSocketErrorCode: expected)

        let result = buffer.getWebSocketErrorCode(at: 0)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, expected)
        XCTAssertEqual(buffer.readerIndex, 0, "get should not mutate readerIndex")
    }

    func testGetWebSocketErrorCode_OutOfBoundsIndex() {
        // Write two codes, but try to get at an index beyond buffer
        let errorCode = WebSocketErrorCode.policyViolation
        buffer.write(webSocketErrorCode: errorCode)

        let result = buffer.getWebSocketErrorCode(at: 10)
        XCTAssertNil(result, "Should return nil for out-of-bounds index")
    }

    func testGetWebSocketErrorCode_EmptyBuffer() {
        let result = buffer.getWebSocketErrorCode(at: 0)
        XCTAssertNil(result, "Should return nil on empty buffer")
    }

    func testGetWebSocketErrorCode_RepeatedAccess() {
        let errorCode = WebSocketErrorCode.goingAway
        buffer.write(webSocketErrorCode: errorCode)

        let result1 = buffer.getWebSocketErrorCode(at: 0)
        let result2 = buffer.getWebSocketErrorCode(at: 0)
        XCTAssertEqual(result1, result2)
        XCTAssertEqual(buffer.readableBytes, 2)
        XCTAssertEqual(buffer.readerIndex, 0)
    }

    // MARK: - write(webSocketErrorCode:) Tests

    func testWriteWebSocketErrorCode() {
        let errorCode = WebSocketErrorCode.protocolError
        buffer.write(webSocketErrorCode: errorCode)

        // Should have written 2 bytes (UInt16)
        XCTAssertEqual(buffer.readableBytes, 2)

        let peeked = buffer.peekWebSocketErrorCode()
        XCTAssertEqual(peeked, errorCode)
    }

    // MARK: - readWebSocketErrorCode() Tests

    func testReadWebSocketErrorCode_Valid() {
        let expected = WebSocketErrorCode.policyViolation
        buffer.write(webSocketErrorCode: expected)

        let result = buffer.readWebSocketErrorCode()
        XCTAssertNotNil(result)
        XCTAssertEqual(result, expected, "readWebSocketErrorCode should decode the correct code")
        XCTAssertEqual(buffer.readableBytes, 0, "Buffer should be consumed after reading")
    }

    func testReadWebSocketErrorCode_NotEnoughBytes() {
        // Write 1 byte
        buffer.writeInteger(UInt8(0x02))
        let result = buffer.readWebSocketErrorCode()
        XCTAssertNil(result, "Should return nil if insufficient bytes")
        XCTAssertEqual(buffer.readerIndex, 0, "Reader index should not move if read fails")
    }

    func testPeekThenReadConsistency() {
        let errorCode = WebSocketErrorCode.goingAway
        buffer.write(webSocketErrorCode: errorCode)

        // Peek first
        let peeked = buffer.peekWebSocketErrorCode()
        XCTAssertEqual(peeked, errorCode)

        // Then read
        let read = buffer.readWebSocketErrorCode()
        XCTAssertEqual(read, errorCode)

        // After read peeking again should fail
        let afterRead = buffer.peekWebSocketErrorCode()
        XCTAssertNil(afterRead)
    }

    func testMultipleWritesAndReads() {
        let errorCodes: [WebSocketErrorCode] = [.goingAway, .unacceptableData, .protocolError]
        for errorCode in errorCodes {
            buffer.write(webSocketErrorCode: errorCode)
        }

        // Peek each one before reading to verify
        for (index, expected) in errorCodes.enumerated() {
            let offset = index * 2
            let peeked = buffer.getWebSocketErrorCode(at: buffer.readerIndex + offset)
            XCTAssertEqual(peeked, expected)
        }

        for expected in errorCodes {
            let read = buffer.readWebSocketErrorCode()
            XCTAssertEqual(read, expected)
        }

        XCTAssertEqual(buffer.readableBytes, 0, "Buffer should be fully consumed")
    }

    // MARK: - peekWebSocketErrorCode() Tests

    func testPeekWebSocketErrorCode_Normal() {
        var buffer = ByteBuffer()
        let errorCode = WebSocketErrorCode(codeNumber: 1002)
        buffer.write(webSocketErrorCode: errorCode)

        guard let webSocketCode = buffer.peekWebSocketErrorCode() else {
            XCTFail("Expected to read a valid WebSocketErrorCode.")
            return
        }
        XCTAssertEqual(webSocketCode, errorCode, "Should match the written error code.")
        XCTAssertEqual(buffer.readerIndex, 0, "peekWebSocketErrorCode() should not advance the reader index.")
    }

    func testPeekWebSocketErrorCode_NotEnoughBytes() {
        var buffer = ByteBuffer()
        // Only write a single byte, insufficient for a UInt16.
        buffer.writeInteger(UInt8(0x03))
        let code = buffer.peekWebSocketErrorCode()
        XCTAssertNil(code, "Should return nil if not enough bytes to form an error code.")
    }

    func testPeekWebSocketErrorCode_Repeated() {
        var buffer = ByteBuffer()
        let errorCode = WebSocketErrorCode(codeNumber: 1011)
        buffer.write(webSocketErrorCode: errorCode)

        let firstPeek = buffer.peekWebSocketErrorCode()
        let secondPeek = buffer.peekWebSocketErrorCode()
        XCTAssertEqual(firstPeek, secondPeek, "Repeated peeks should yield the same code.")
        XCTAssertEqual(buffer.readerIndex, 0, "peekWebSocketErrorCode() should not advance reader index.")
    }
}
