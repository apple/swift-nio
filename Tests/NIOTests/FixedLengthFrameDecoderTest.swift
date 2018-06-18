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

class FixedLengthFrameDecoderTest: XCTestCase {

    public func testDecodeIfFewerBytesAreSent() throws {
        let channel = EmbeddedChannel()

        let frameLength = 8
        try channel.pipeline.add(handler: FixedLengthFrameDecoder(frameLength: frameLength)).wait()

        var buffer = channel.allocator.buffer(capacity: frameLength)
        buffer.write(string: "xxxx")
        XCTAssertFalse(try channel.writeInbound(buffer))
        XCTAssertTrue(try channel.writeInbound(buffer))

        var outputBuffer: ByteBuffer? = channel.readInbound()
        XCTAssertEqual("xxxxxxxx", outputBuffer?.readString(length: frameLength))
        XCTAssertFalse(try channel.finish())
    }

    public func testDecodeIfMoreBytesAreSent() throws {
        let channel = EmbeddedChannel()

        let frameLength = 8
        try channel.pipeline.add(handler: FixedLengthFrameDecoder(frameLength: frameLength)).wait()

        var buffer = channel.allocator.buffer(capacity: 19)
        buffer.write(string: "xxxxxxxxaaaaaaaabbb")
        XCTAssertTrue(try channel.writeInbound(buffer))

        var outputBuffer: ByteBuffer? = channel.readInbound()
        XCTAssertEqual("xxxxxxxx", outputBuffer?.readString(length: frameLength))

        outputBuffer = channel.readInbound()
        XCTAssertEqual("aaaaaaaa", outputBuffer?.readString(length: frameLength))

        outputBuffer = channel.readInbound()
        XCTAssertNil(outputBuffer?.readString(length: frameLength))
        XCTAssertFalse(try channel.finish())
    }

    public func testRemoveHandlerWhenBufferIsNotEmpty() throws {
        let channel = EmbeddedChannel()

        let frameLength = 8
        let handler = FixedLengthFrameDecoder(frameLength: frameLength)
        try channel.pipeline.add(handler: handler).wait()

        var buffer = channel.allocator.buffer(capacity: 15)
        buffer.write(string: "xxxxxxxxxxxxxxx")
        XCTAssertTrue(try channel.writeInbound(buffer))

        var outputBuffer: ByteBuffer? = channel.readInbound()
        XCTAssertEqual("xxxxxxxx", outputBuffer?.readString(length: frameLength))

        _ = try channel.pipeline.remove(handler: handler).wait()
        XCTAssertThrowsError(try channel.throwIfErrorCaught()) { error in
            guard let error = error as? LeftOverBytesChannelPipelineError else {
                XCTFail()
                return
            }

            var expectedBuffer = channel.allocator.buffer(capacity: 7)
            expectedBuffer.write(string: "xxxxxxx")
            XCTAssertEqual(error.leftOverBytes, expectedBuffer)
        }
        XCTAssertFalse(try channel.finish())
    }

    public func testRemoveHandlerWhenBufferIsEmpty() throws {
        let channel = EmbeddedChannel()

        let frameLength = 8
        let handler = FixedLengthFrameDecoder(frameLength: frameLength)
        try channel.pipeline.add(handler: handler).wait()

        var buffer = channel.allocator.buffer(capacity: 6)
        buffer.write(string: "xxxxxxxx")
        XCTAssertTrue(try channel.writeInbound(buffer))

        var outputBuffer: ByteBuffer? = channel.readInbound()
        XCTAssertEqual("xxxxxxxx", outputBuffer?.readString(length: frameLength))

        _ = try channel.pipeline.remove(handler: handler).wait()
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        XCTAssertFalse(try channel.finish())
    }
}
