//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import NIOFoundationCompat
import XCTest

final class ByteBufferUUIDTests: XCTestCase {
    func testSetUUIDBytes() {
        let uuid = UUID(
            uuid: (
                0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7,
                0x8, 0x9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf
            )
        )
        var buffer = ByteBuffer()

        XCTAssertEqual(buffer.storageCapacity, 0)
        XCTAssertEqual(buffer.setUUIDBytes(uuid, at: 0), 16)
        XCTAssertEqual(buffer.writerIndex, 0)
        XCTAssertEqual(buffer.readableBytes, 0)
        XCTAssertGreaterThanOrEqual(buffer.storageCapacity, 16)

        buffer.moveWriterIndex(forwardBy: 16)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: 16)
        XCTAssertEqual(bytes, Array(0..<16))
    }

    func testSetUUIDBytesBlatsExistingBytes() {
        var buffer = ByteBuffer()
        buffer.writeRepeatingByte(.max, count: 32)

        let uuid = UUID(
            uuid: (
                0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7,
                0x8, 0x9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf
            )
        )
        buffer.setUUIDBytes(uuid, at: buffer.readerIndex + 4)

        XCTAssertEqual(buffer.readBytes(length: 4), Array(repeating: .max, count: 4))
        XCTAssertEqual(buffer.readBytes(length: 16), Array(0..<16))
        XCTAssertEqual(buffer.readBytes(length: 12), Array(repeating: .max, count: 12))
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testGetUUIDEmptyBuffer() {
        let buffer = ByteBuffer()
        XCTAssertNil(buffer.getUUIDBytes(at: 0))
    }

    func testGetUUIDAfterSet() {
        let uuid = UUID()
        var buffer = ByteBuffer()
        XCTAssertEqual(buffer.setUUIDBytes(uuid, at: 0), 16)
        // nil because there are no bytes to read
        XCTAssertNil(buffer.getUUIDBytes(at: 0))
    }

    func testWriteUUIDBytesIntoEmptyBuffer() {
        let uuid = UUID(
            uuid: (
                0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7,
                0x8, 0x9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf
            )
        )
        var buffer = ByteBuffer()

        XCTAssertEqual(buffer.writeUUIDBytes(uuid), 16)
        XCTAssertEqual(
            buffer.readableBytesView,
            [
                0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7,
                0x8, 0x9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf,
            ]
        )
        XCTAssertEqual(buffer.readableBytes, 16)
        XCTAssertEqual(buffer.writerIndex, 16)
    }

    func testWriteUUIDBytesIntoNonEmptyBuffer() {
        let uuid = UUID(
            uuid: (
                0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7,
                0x8, 0x9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf
            )
        )

        var buffer = ByteBuffer()
        buffer.writeRepeatingByte(42, count: 10)
        XCTAssertEqual(buffer.writeUUIDBytes(uuid), 16)
        XCTAssertEqual(buffer.readableBytes, 26)
        XCTAssertEqual(buffer.writerIndex, 26)

        XCTAssertEqual(
            buffer.readableBytesView.dropFirst(10),
            [0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7, 0x8, 0x9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf]
        )
    }

    func testReadUUID() {
        let uuid = UUID(
            uuid: (
                0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7,
                0x8, 0x9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf
            )
        )
        var buffer = ByteBuffer()
        XCTAssertEqual(buffer.writeUUIDBytes(uuid), 16)
        XCTAssertEqual(buffer.readUUIDBytes(), uuid)
        XCTAssertEqual(buffer.readableBytes, 0)
    }

    func testReadUUIDNotEnoughBytes() {
        var buffer = ByteBuffer()
        XCTAssertNil(buffer.readUUIDBytes())
        XCTAssertEqual(buffer.readerIndex, 0)

        buffer.writeRepeatingByte(0, count: 8)
        XCTAssertNil(buffer.readUUIDBytes())
        XCTAssertEqual(buffer.readerIndex, 0)

        buffer.writeRepeatingByte(0, count: 8)
        XCTAssertEqual(
            buffer.readUUIDBytes(),
            UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        )
        XCTAssertEqual(buffer.readerIndex, 16)
    }
}
