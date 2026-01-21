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

final class WebSocketMaskingKeyTests: XCTestCase {
    var generator = SystemRandomNumberGenerator()
    func testRandomMaskingKey() {
        let key = WebSocketMaskingKey.random(using: &generator)
        var buffer = ByteBuffer(bytes: [1, 2, 3, 4, 5, 6, 7, 8])
        buffer.webSocketMask(key)
        buffer.webSocketUnmask(key)
        XCTAssertEqual(buffer, ByteBuffer(bytes: [1, 2, 3, 4, 5, 6, 7, 8]))
    }

    func testRandomMaskingKeyIsNotAlwaysZero() {
        XCTAssertTrue(
            (0..<1000).contains { _ in
                WebSocketMaskingKey.random(using: &generator) != [0, 0, 0, 0]
            },
            "at least 1 of 1000 random masking keys should not be all zeros"
        )
    }

    func testRandomMaskingKeyIsNotAlwaysZeroWithDefaultGenerator() {
        XCTAssertTrue(
            (0..<1000).contains { _ in
                WebSocketMaskingKey.random() != [0, 0, 0, 0]
            },
            "at least 1 of 1000 random masking keys with default generator should not be all zeros"
        )
    }

    func testGetReservedBits() {
        let frame = WebSocketFrame(rsv1: true, opcode: .binary, data: .init())
        XCTAssertEqual(frame.reservedBits.contains(.rsv1), true)
        XCTAssertEqual(frame.reservedBits.contains(.rsv2), false)
        XCTAssertEqual(frame.reservedBits.contains(.rsv3), false)
        let frame2 = WebSocketFrame(rsv2: true, opcode: .binary, data: .init())
        XCTAssertEqual(frame2.reservedBits.contains(.rsv1), false)
        XCTAssertEqual(frame2.reservedBits.contains(.rsv2), true)
        XCTAssertEqual(frame2.reservedBits.contains(.rsv3), false)
        let frame3 = WebSocketFrame(rsv3: true, opcode: .binary, data: .init())
        XCTAssertEqual(frame3.reservedBits.contains(.rsv1), false)
        XCTAssertEqual(frame3.reservedBits.contains(.rsv2), false)
        XCTAssertEqual(frame3.reservedBits.contains(.rsv3), true)
    }

    func testSetReservedBits() {
        var frame = WebSocketFrame(opcode: .binary, data: .init())
        frame.reservedBits = .rsv1
        XCTAssertEqual(frame.reservedBits.contains(.rsv1), true)
        XCTAssertEqual(frame.reservedBits.contains(.rsv2), false)
        XCTAssertEqual(frame.reservedBits.contains(.rsv3), false)
        XCTAssertEqual(frame.fin, false)
        XCTAssertEqual(frame.opcode, .binary)
        frame.reservedBits = .rsv2
        XCTAssertEqual(frame.reservedBits.contains(.rsv1), false)
        XCTAssertEqual(frame.reservedBits.contains(.rsv2), true)
        XCTAssertEqual(frame.reservedBits.contains(.rsv3), false)
        XCTAssertEqual(frame.fin, false)
        XCTAssertEqual(frame.opcode, .binary)
        frame.reservedBits = .rsv3
        XCTAssertEqual(frame.reservedBits.contains(.rsv1), false)
        XCTAssertEqual(frame.reservedBits.contains(.rsv2), false)
        XCTAssertEqual(frame.reservedBits.contains(.rsv3), true)
        XCTAssertEqual(frame.fin, false)
        XCTAssertEqual(frame.opcode, .binary)
    }
}
