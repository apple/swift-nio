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

final class NIOWebSocketFrameAggregatorTests: XCTestCase {
    let channel = EmbeddedChannel(
        handler: NIOWebSocketFrameAggregator(
            minNonFinalFragmentSize: 1,
            maxAccumulatedFrameCount: 4,
            maxAccumulatedFrameSize: 32
        )
    )
    
    override func tearDown() {
        XCTAssertEqual(try self.channel.finish().isClean, true)
    }
    
    func testEmptyButFinalFrameIsForwardedEvenIfMinNonFinalFragmentSizeIsGreaterThanZero() throws {
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: ByteBuffer())
        try channel.writeInbound(frame)
        XCTAssertEqual(try channel.readInbound(as: WebSocketFrame.self), frame)
    }
    
    func testTooSmallAndNonFinalFrameThrows() throws {
        let frame = WebSocketFrame(fin: false, opcode: .binary, data: ByteBuffer())
        XCTAssertThrowsError(try channel.writeInbound(frame))
    }
    
    func testTooBigFrameThrows() throws {
        let frame = WebSocketFrame(fin: false, opcode: .binary, data: ByteBuffer(repeating: 2, count: 33))
        XCTAssertThrowsError(try channel.writeInbound(frame))
    }
    
    func testTooBigAccumulatedFrameThrows() throws {
        let frame1 = WebSocketFrame(fin: false, opcode: .binary, data: ByteBuffer(repeating: 2, count: 32))
        try channel.writeInbound(frame1)
        
        let frame2 = WebSocketFrame(fin: false, opcode: .binary, data: ByteBuffer(repeating: 3, count: 1))
        XCTAssertThrowsError(try channel.writeInbound(frame2))
    }
    
    func testTooManyFramesThrow() throws {
        let firstFrame = WebSocketFrame(fin: false, opcode: .binary, data: ByteBuffer(repeating: 2, count: 2))
        try channel.writeInbound(firstFrame)
        let fragment = WebSocketFrame(fin: false, opcode: .continuation, data: ByteBuffer(repeating: 2, count: 2))
        try channel.writeInbound(fragment)
        try channel.writeInbound(fragment)
        XCTAssertThrowsError(try channel.writeInbound(fragment))
    }
    func testAlmostTooManyFramesDoNotThrow() throws {
        let firstFrame = WebSocketFrame(fin: false, opcode: .binary, data: ByteBuffer(repeating: 2, count: 2))
        try channel.writeInbound(firstFrame)
        let fragment = WebSocketFrame(fin: false, opcode: .continuation, data: ByteBuffer(repeating: 2, count: 2))
        try channel.writeInbound(fragment)
        try channel.writeInbound(fragment)
        let lastFrame = WebSocketFrame(fin: true, opcode: .continuation, data: ByteBuffer(repeating: 2, count: 2))
        try channel.writeInbound(lastFrame)
        
        let completeFrame = WebSocketFrame(fin: true, opcode: .binary, data: ByteBuffer(repeating: 2, count: 8))
        let aggregatedFrame = try channel.readInbound(as: WebSocketFrame.self)
        XCTAssertEqual(aggregatedFrame, completeFrame)
    }
    
    func testTextFrameIsStillATextFrameAfterAggregation() throws {
        let firstFrame = WebSocketFrame(fin: false, opcode: .text, data: ByteBuffer(repeating: 2, count: 2))
        try channel.writeInbound(firstFrame)
        let fragment = WebSocketFrame(fin: false, opcode: .continuation, data: ByteBuffer(repeating: 2, count: 2))
        try channel.writeInbound(fragment)
        try channel.writeInbound(fragment)
        let lastFrame = WebSocketFrame(fin: true, opcode: .continuation, data: ByteBuffer(repeating: 2, count: 2))
        try channel.writeInbound(lastFrame)
        
        let completeFrame = WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(repeating: 2, count: 8))
        XCTAssertEqual(try channel.readInbound(as: WebSocketFrame.self), completeFrame)
    }
    
    func testPingFrameIsForwarded() throws {
        let controlFrame = WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer())
        try channel.writeInbound(controlFrame)
        XCTAssertEqual(try channel.readInbound(as: WebSocketFrame.self), controlFrame)
        
        let fragment = WebSocketFrame(fin: false, opcode: .text, data: ByteBuffer(repeating: 2, count: 2))
        try channel.writeInbound(fragment)
        
        try channel.writeInbound(controlFrame)
        XCTAssertEqual(try channel.readInbound(as: WebSocketFrame.self), controlFrame, "should forward control frames during buffering")
    }
    
    func testPongFrameIsForwarded() throws {
        let controlFrame = WebSocketFrame(fin: true, opcode: .pong, data: ByteBuffer())
        try channel.writeInbound(controlFrame)
        XCTAssertEqual(try channel.readInbound(as: WebSocketFrame.self), controlFrame)
        
        let fragment = WebSocketFrame(fin: false, opcode: .text, data: ByteBuffer(repeating: 2, count: 2))
        try channel.writeInbound(fragment)
        
        try channel.writeInbound(controlFrame)
        XCTAssertEqual(try channel.readInbound(as: WebSocketFrame.self), controlFrame, "should forward control frames during buffering")
    }
    
    func testCloseConnectionFrameIsForwarded() throws {
        let controlFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer())
        try channel.writeInbound(controlFrame)
        XCTAssertEqual(try channel.readInbound(as: WebSocketFrame.self), controlFrame)
        
        let fragment = WebSocketFrame(fin: false, opcode: .text, data: ByteBuffer(repeating: 2, count: 2))
        try channel.writeInbound(fragment)
        
        try channel.writeInbound(controlFrame)
        XCTAssertEqual(try channel.readInbound(as: WebSocketFrame.self), controlFrame, "should forward control frames during buffering")
    }
    
    func testFrameAggregationWithMask() throws {
        var firstFrameData = ByteBuffer(repeating: 2, count: 2)
        let firsFrameMask: WebSocketMaskingKey = [1, 2, 3, 4]
        firstFrameData.webSocketMask(firsFrameMask)
        let firstFrame = WebSocketFrame(fin: false, opcode: .binary, maskKey: firsFrameMask, data: firstFrameData)
        try channel.writeInbound(firstFrame)
        
        var fragmentData = ByteBuffer(repeating: 3, count: 2)
        let fragmentMaskKey: WebSocketMaskingKey = [5, 6, 7, 8]
        fragmentData.webSocketMask(fragmentMaskKey)
        let fragment = WebSocketFrame(fin: false, opcode: .continuation, maskKey: fragmentMaskKey, data: fragmentData)
        try channel.writeInbound(fragment)
        try channel.writeInbound(fragment)
        
        var lastFrameData = ByteBuffer(repeating: 4, count: 2)
        let lastFrameMaskKey: WebSocketMaskingKey = [9, 10, 11, 12]
        lastFrameData.webSocketMask(lastFrameMaskKey)
        let lastFrame = WebSocketFrame(fin: true, opcode: .continuation, maskKey: lastFrameMaskKey, data: lastFrameData)
        try channel.writeInbound(lastFrame)
        
        let completeFrame = WebSocketFrame(fin: true, opcode: .binary, data: ByteBuffer(bytes: [2, 2, 3, 3, 3, 3, 4, 4]))
        let aggregatedFrame = try channel.readInbound(as: WebSocketFrame.self)
        XCTAssertEqual(aggregatedFrame, completeFrame)
    }
}

