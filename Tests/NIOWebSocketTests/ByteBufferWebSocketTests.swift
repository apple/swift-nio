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