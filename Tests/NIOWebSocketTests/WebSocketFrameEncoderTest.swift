//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded
import NIOWebSocket
import XCTest

extension EmbeddedChannel {
    func readAllOutboundBuffers() throws -> ByteBuffer {
        var buffer = self.allocator.buffer(capacity: 100)
        while var writtenData = try self.readOutbound(as: ByteBuffer.self) {
            buffer.writeBuffer(&writtenData)
        }

        return buffer
    }

    func readAllOutboundBytes() throws -> [UInt8] {
        var buffer = try self.readAllOutboundBuffers()
        return buffer.readAllBytes()
    }
}

extension ByteBuffer {
    mutating func readAllBytes() -> [UInt8] {
        self.readBytes(length: self.readableBytes)!
    }
}

public final class WebSocketFrameEncoderTest: XCTestCase {
    public var channel: EmbeddedChannel!
    public var buffer: ByteBuffer!

    public override func setUp() {
        self.channel = EmbeddedChannel()
        self.buffer = channel.allocator.buffer(capacity: 128)
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder()))
    }

    public override func tearDown() {
        XCTAssertNoThrow(try self.channel.finish())
        self.channel = nil
        self.buffer = nil
    }

    private func assertFrameEncodes(frame: WebSocketFrame, expectedBytes: [UInt8]) {
        self.channel.writeAndFlush(frame, promise: nil)
        XCTAssertNoThrow(XCTAssertEqual(expectedBytes, try self.channel.readAllOutboundBytes()))
    }

    func testBasicFrameEncoding() throws {
        let dataString = "hello, world!"
        self.buffer.writeString("hello, world!")
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: self.buffer)
        let expectedBytes = [0x82, UInt8(dataString.count)] + Array(dataString.utf8)
        assertFrameEncodes(frame: frame, expectedBytes: expectedBytes)
    }

    func test16BitFrameLength() throws {
        let dataBytes = Array(repeating: UInt8(4), count: 1000)
        self.buffer.writeBytes(dataBytes)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: self.buffer)
        let expectedBytes = [0x81, UInt8(126), UInt8(0x03), UInt8(0xE8)] + dataBytes
        assertFrameEncodes(frame: frame, expectedBytes: expectedBytes)
    }

    func test64BitFrameLength() throws {
        let dataBytes = Array(repeating: UInt8(4), count: 65536)
        self.buffer.writeBytes(dataBytes)

        let frame = WebSocketFrame(fin: true, opcode: .binary, data: self.buffer)
        self.channel.writeAndFlush(frame, promise: nil)

        let expectedBytes: [UInt8] = [0x82, 0x7F, 0, 0, 0, 0, 0, 1, 0, 0]
        XCTAssertNoThrow(XCTAssertEqual(expectedBytes[...], try self.channel.readAllOutboundBytes()[..<10]))
    }

    func testEncodesEachReservedBitProperly() throws {
        let firstFrame = WebSocketFrame(fin: true, rsv1: true, opcode: .binary, data: self.buffer)
        let secondFrame = WebSocketFrame(fin: false, rsv2: true, opcode: .text, data: self.buffer)
        let thirdFrame = WebSocketFrame(fin: true, rsv3: true, opcode: .ping, data: self.buffer)

        assertFrameEncodes(frame: firstFrame, expectedBytes: [0xC2, 0x0])
        assertFrameEncodes(frame: secondFrame, expectedBytes: [0x21, 0x0])
        assertFrameEncodes(frame: thirdFrame, expectedBytes: [0x99, 0x0])
    }

    func testEncodesExtensionDataCorrectly() throws {
        let dataBytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        self.buffer.writeBytes(dataBytes)

        let frame = WebSocketFrame(
            fin: false,
            opcode: .text,
            data: self.buffer.getSlice(at: self.buffer.readerIndex, length: 5)!,
            extensionData: self.buffer.getSlice(at: self.buffer.readerIndex + 5, length: 5)!
        )
        assertFrameEncodes(
            frame: frame,
            expectedBytes: [0x01, 0x0A, 0x6, 0x7, 0x8, 0x9, 0xA, 0x1, 0x2, 0x3, 0x4, 0x5]
        )
    }

    func testMasksDataCorrectly() throws {
        let dataBytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let maskKey: WebSocketMaskingKey = [0x80, 0x08, 0x10, 0x01]
        self.buffer.writeBytes(dataBytes)

        let frame = WebSocketFrame(
            fin: true,
            opcode: .binary,
            maskKey: maskKey,
            data: self.buffer.getSlice(at: self.buffer.readerIndex, length: 5)!,
            extensionData: self.buffer.getSlice(at: self.buffer.readerIndex + 5, length: 5)!
        )
        assertFrameEncodes(
            frame: frame,
            expectedBytes: [
                0x82, 0x8A, 0x80, 0x08, 0x10, 0x01, 0x86, 0x0F, 0x18, 0x08, 0x8A, 0x09, 0x12, 0x02, 0x84, 0x0D,
            ]
        )
    }

    func testFrameEncoderReusesHeaderBufferWherePossible() {
        let dataBytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let maskKey: WebSocketMaskingKey = [0x80, 0x08, 0x10, 0x01]
        self.buffer.writeBytes(dataBytes)

        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: maskKey, data: self.buffer)

        // We're going to send the above frame twice, and capture the value of the backing pointer each time. It should
        // be identical in both cases so long as we force the header buffer to nil between uses.
        var headerBuffer: ByteBuffer? = nil
        self.channel.writeAndFlush(frame, promise: nil)
        XCTAssertNoThrow(headerBuffer = try self.channel.readOutbound(as: ByteBuffer.self))

        let originalPointer = headerBuffer?.withVeryUnsafeBytes { UInt(bitPattern: $0.baseAddress!) }
        headerBuffer = nil
        XCTAssertNoThrow(try self.channel.readOutbound(as: ByteBuffer.self))  // Throw away the body data.

        self.channel.writeAndFlush(frame, promise: nil)
        XCTAssertNoThrow(headerBuffer = try self.channel.readOutbound(as: ByteBuffer.self))

        let newPointer = headerBuffer?.withVeryUnsafeBytes { UInt(bitPattern: $0.baseAddress!) }
        XCTAssertNoThrow(try self.channel.readOutbound(as: ByteBuffer.self))  // Throw away the body data again.
        XCTAssertEqual(originalPointer, newPointer)
        XCTAssertNotNil(originalPointer)
    }

    func testFrameEncoderCanPrependHeaderToApplicationBuffer() {
        let dataBytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let maskKey: WebSocketMaskingKey = [0x80, 0x08, 0x10, 0x01]

        // We need 6 spare bytes for this header.
        self.buffer.moveWriterIndex(forwardBy: 6)
        self.buffer.moveReaderIndex(forwardBy: 6)
        self.buffer.writeBytes(dataBytes)

        let originalBuffer = self.buffer!
        self.buffer = nil  // gotta nil out here to enable prepending

        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: maskKey, data: originalBuffer)
        self.channel.writeAndFlush(frame, promise: nil)

        var result: ByteBuffer? = nil
        XCTAssertNoThrow(result = try self.channel.readOutbound(as: ByteBuffer.self))
        XCTAssertNoThrow(XCTAssertNil(try self.channel.readOutbound(as: ByteBuffer.self)))

        XCTAssertEqual(
            result?.readAllBytes(),
            [0x82, 0x8A, 0x80, 0x08, 0x10, 0x01, 0x81, 0x0A, 0x13, 0x05, 0x85, 0x0E, 0x17, 0x09, 0x89, 0x02]
        )
    }

    func testFrameEncoderCanPrependHeaderToExtensionBuffer() {
        let dataBytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let maskKey: WebSocketMaskingKey = [0x80, 0x08, 0x10, 0x01]

        // We need 6 spare bytes, but let's leave even more room.
        self.buffer.moveWriterIndex(forwardBy: 16)
        self.buffer.moveReaderIndex(forwardBy: 16)
        self.buffer.writeBytes(dataBytes)

        let originalBuffer = self.buffer!
        self.buffer = nil  // gotta nil out here to enable prepending

        // We need an extra buffer for application data, but it'll be empty.
        let applicationOriginalBuffer = ByteBufferAllocator().buffer(capacity: 1024)

        let frame = WebSocketFrame(
            fin: true,
            opcode: .binary,
            maskKey: maskKey,
            data: applicationOriginalBuffer,
            extensionData: originalBuffer
        )
        self.channel.writeAndFlush(frame, promise: nil)

        var extensionBuffer: ByteBuffer? = nil
        var applicationBuffer: ByteBuffer? = nil
        XCTAssertNoThrow(extensionBuffer = try self.channel.readOutbound(as: ByteBuffer.self))
        XCTAssertNoThrow(applicationBuffer = try self.channel.readOutbound(as: ByteBuffer.self))
        XCTAssertNoThrow(XCTAssertNil(try self.channel.readOutbound(as: ByteBuffer.self)))

        XCTAssertEqual(
            extensionBuffer?.readAllBytes(),
            [0x82, 0x8A, 0x80, 0x08, 0x10, 0x01, 0x81, 0x0A, 0x13, 0x05, 0x85, 0x0E, 0x17, 0x09, 0x89, 0x02]
        )
        XCTAssertEqual(applicationBuffer?.readAllBytes(), [])
    }

    func testFrameEncoderCanPrependMediumHeader() {
        let maskKey: WebSocketMaskingKey = [0x80, 0x08, 0x10, 0x01]

        // We need 8 spare bytes for this header.
        self.buffer.moveWriterIndex(forwardBy: 8)
        self.buffer.moveReaderIndex(forwardBy: 8)
        self.buffer.writeBytes(repeatElement(0, count: 126))

        let originalBuffer = self.buffer!
        self.buffer = nil  // gotta nil out here to enable prepending

        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: maskKey, data: originalBuffer)
        self.channel.writeAndFlush(frame, promise: nil)

        var result: ByteBuffer? = nil
        XCTAssertNoThrow(result = try self.channel.readOutbound(as: ByteBuffer.self))
        XCTAssertNoThrow(XCTAssertNil(try self.channel.readOutbound(as: ByteBuffer.self)))

        // The header size should be 8 bytes: leading byte, length, 2 extra length bytes, 4 byte mask.
        XCTAssertEqual(
            result?.readBytes(length: 8),
            [0x82, 0xFE, 0x00, 0x7E, 0x80, 0x08, 0x10, 0x01]
        )
    }

    func testFrameEncoderCanPrependLargeHeader() {
        let maskKey: WebSocketMaskingKey = [0x80, 0x08, 0x10, 0x01]

        // We need 14 spare bytes for this header.
        self.buffer.moveWriterIndex(forwardBy: 14)
        self.buffer.moveReaderIndex(forwardBy: 14)
        self.buffer.writeBytes(repeatElement(0, count: Int(UInt16.max) + 1))

        let originalBuffer = self.buffer!
        self.buffer = nil  // gotta nil out here to enable prepending

        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: maskKey, data: originalBuffer)
        self.channel.writeAndFlush(frame, promise: nil)

        var result: ByteBuffer? = nil
        XCTAssertNoThrow(result = try self.channel.readOutbound(as: ByteBuffer.self))
        XCTAssertNoThrow(XCTAssertNil(try self.channel.readOutbound(as: ByteBuffer.self)))

        // The header size should be 14 bytes: leading byte, length, 8 extra length bytes, 4 byte mask.
        XCTAssertEqual(
            result?.readBytes(length: 14),
            [0x82, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x80, 0x08, 0x10, 0x01]
        )
    }

    func testFrameEncoderFailsToPrependHeaderWithInsufficientSpace() {
        let dataBytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let maskKey: WebSocketMaskingKey = [0x80, 0x08, 0x10, 0x01]

        // We need 6 spare bytes for this header, so let's only free up 5.
        self.buffer.moveWriterIndex(forwardBy: 5)
        self.buffer.moveReaderIndex(forwardBy: 5)
        self.buffer.writeBytes(dataBytes)

        let originalBuffer = self.buffer!
        self.buffer = nil  // gotta nil out here to enable prepending

        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: maskKey, data: originalBuffer)
        self.channel.writeAndFlush(frame, promise: nil)

        var result: ByteBuffer? = nil
        XCTAssertNoThrow(result = try self.channel.readOutbound(as: ByteBuffer.self))
        XCTAssertNoThrow(XCTAssertNotNil(try self.channel.readOutbound(as: ByteBuffer.self)))
        XCTAssertNoThrow(XCTAssertNil(try self.channel.readOutbound(as: ByteBuffer.self)))

        // This will only be the frame header.
        XCTAssertEqual(
            result?.readAllBytes(),
            [0x82, 0x8A, 0x80, 0x08, 0x10, 0x01]
        )
    }

    func testFrameEncoderFailsToPrependMediumHeaderWithInsufficientSpace() {
        let maskKey: WebSocketMaskingKey = [0x80, 0x08, 0x10, 0x01]

        // We need 8 spare bytes for this header, so let's only leave 7.
        self.buffer.moveWriterIndex(forwardBy: 7)
        self.buffer.moveReaderIndex(forwardBy: 7)
        self.buffer.writeBytes(repeatElement(0, count: 126))

        let originalBuffer = self.buffer!
        self.buffer = nil  // gotta nil out here to enable prepending

        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: maskKey, data: originalBuffer)
        self.channel.writeAndFlush(frame, promise: nil)

        var result: ByteBuffer? = nil
        XCTAssertNoThrow(result = try self.channel.readOutbound(as: ByteBuffer.self))
        XCTAssertNoThrow(XCTAssertNotNil(try self.channel.readOutbound(as: ByteBuffer.self)))
        XCTAssertNoThrow(XCTAssertNil(try self.channel.readOutbound(as: ByteBuffer.self)))

        // This will only be the frame header.
        XCTAssertEqual(
            result?.readAllBytes(),
            [0x82, 0xFE, 0x00, 0x7E, 0x80, 0x08, 0x10, 0x01]
        )
    }

    func testFrameEncoderFailsToPrependLargeHeaderWithInsufficientSpace() {
        let maskKey: WebSocketMaskingKey = [0x80, 0x08, 0x10, 0x01]

        // We need 14 spare bytes for this header, so let's only leave 13
        self.buffer.moveWriterIndex(forwardBy: 13)
        self.buffer.moveReaderIndex(forwardBy: 13)
        self.buffer.writeBytes(repeatElement(0, count: Int(UInt16.max) + 1))

        let originalBuffer = self.buffer!
        self.buffer = nil  // gotta nil out here to enable prepending

        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: maskKey, data: originalBuffer)
        self.channel.writeAndFlush(frame, promise: nil)

        var result: ByteBuffer? = nil
        XCTAssertNoThrow(result = try self.channel.readOutbound(as: ByteBuffer.self))
        XCTAssertNoThrow(XCTAssertNotNil(try self.channel.readOutbound(as: ByteBuffer.self)))
        XCTAssertNoThrow(XCTAssertNil(try self.channel.readOutbound(as: ByteBuffer.self)))

        // This will only be the frame header.
        XCTAssertEqual(
            result?.readAllBytes(),
            [0x82, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x80, 0x08, 0x10, 0x01]
        )
    }
}
