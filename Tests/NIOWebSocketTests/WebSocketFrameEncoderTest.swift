//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIO
import NIOWebSocket

extension EmbeddedChannel {
    func readAllOutboundBuffers() -> ByteBuffer {
        var buffer = self.allocator.buffer(capacity: 100)
        while case .some(.byteBuffer(var writtenData)) = self.readOutbound() {
            buffer.write(buffer: &writtenData)
        }

        return buffer
    }

    func readAllOutboundBytes() -> [UInt8] {
        var buffer = self.readAllOutboundBuffers()
        return buffer.readBytes(length: buffer.readableBytes)!
    }
}

public class WebSocketFrameEncoderTest: XCTestCase {
    public var channel: EmbeddedChannel!
    public var buffer: ByteBuffer!

    public override func setUp() {
        self.channel = EmbeddedChannel()
        self.buffer = channel.allocator.buffer(capacity: 128)
        XCTAssertNoThrow(try self.channel.pipeline.add(handler: WebSocketFrameEncoder()).wait())
    }

    public override func tearDown() {
        XCTAssertNoThrow(try self.channel.finish())
        self.channel = nil
        self.buffer = nil
    }

    private func assertFrameEncodes(frame: WebSocketFrame, expectedBytes: [UInt8]) {
        self.channel.writeAndFlush(frame, promise: nil)
        let writtenBytes = self.channel.readAllOutboundBytes()
        XCTAssertEqual(writtenBytes, expectedBytes)
    }

    func testBasicFrameEncoding() throws {
        let dataString = "hello, world!"
        self.buffer.write(string: "hello, world!")
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: self.buffer)
        let expectedBytes = [0x82, UInt8(dataString.count)] + Array(dataString.utf8)
        assertFrameEncodes(frame: frame, expectedBytes: expectedBytes)
    }

    func test16BitFrameLength() throws {
        let dataBytes = Array(repeating: UInt8(4), count: 1000)
        self.buffer.write(bytes: dataBytes)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: self.buffer)
        let expectedBytes = [0x81, UInt8(126), UInt8(0x03), UInt8(0xE8)] + dataBytes
        assertFrameEncodes(frame: frame, expectedBytes: expectedBytes)
    }

    func test64BitFrameLength() throws {
        let dataBytes = Array(repeating: UInt8(4), count: 65536)
        self.buffer.write(bytes: dataBytes)

        let frame = WebSocketFrame(fin: true, opcode: .binary, data: self.buffer)
        self.channel.writeAndFlush(frame, promise: nil)

        let writtenBytes = self.channel.readAllOutboundBytes()
        let expectedBytes: [UInt8] = [0x82, 0x7F, 0, 0, 0, 0, 0, 1, 0, 0]
        XCTAssertEqual(writtenBytes[..<10], expectedBytes[...])
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
        self.buffer.write(bytes: dataBytes)

        let frame = WebSocketFrame(fin: false,
                                   opcode: .text,
                                   data: self.buffer.getSlice(at: self.buffer.readerIndex, length: 5)!,
                                   extensionData: self.buffer.getSlice(at: self.buffer.readerIndex + 5, length: 5)!)
        assertFrameEncodes(frame: frame,
                           expectedBytes: [0x01, 0x0A, 0x6, 0x7, 0x8, 0x9, 0xA, 0x1, 0x2, 0x3, 0x4, 0x5])
    }

    func testMasksDataCorrectly() throws {
        let dataBytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let maskKey: WebSocketMaskingKey = [0x80, 0x08, 0x10, 0x01]
        self.buffer.write(bytes: dataBytes)

        let frame = WebSocketFrame(fin: true,
                                   opcode: .binary,
                                   maskKey: maskKey,
                                   data: self.buffer.getSlice(at: self.buffer.readerIndex, length: 5)!,
                                   extensionData: self.buffer.getSlice(at: self.buffer.readerIndex + 5, length: 5)!)
        assertFrameEncodes(frame: frame,
                           expectedBytes: [0x82, 0x8A, 0x80, 0x08, 0x10, 0x01, 0x86, 0x0F, 0x18, 0x08, 0x8A, 0x09, 0x12, 0x02, 0x84, 0x0D])
    }
}
