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

    public func testDecodeIfLessBytesAreSend() throws {
        let channel = EmbeddedChannel()

        let frameLength = 8
        _ = try channel.pipeline.add(handler: FixedLengthFrameDecoder(frameLength: frameLength)).wait()

        var buffer = channel.allocator.buffer(capacity: frameLength)
        buffer.write(string: "xxxx")
        XCTAssertFalse(try channel.writeInbound(buffer))
        XCTAssertTrue(try channel.writeInbound(buffer))

        var outputBuffer: ByteBuffer? = channel.readInbound()
        XCTAssertEqual("xxxxxxxx", outputBuffer?.readString(length: frameLength))
    }

    public func testDecodeIfMoreBytesAreSend() throws {
        let channel = EmbeddedChannel()

        let frameLength = 8
        _ = try channel.pipeline.add(handler: FixedLengthFrameDecoder(frameLength: frameLength)).wait()

        var buffer = channel.allocator.buffer(capacity: 19)
        buffer.write(string: "xxxxxxxxaaaaaaaabbb")
        XCTAssertTrue(try channel.writeInbound(buffer))

        var outputBuffer: ByteBuffer? = channel.readInbound()
        XCTAssertEqual("xxxxxxxx", outputBuffer?.readString(length: frameLength))

        outputBuffer = channel.readInbound()
        XCTAssertEqual("aaaaaaaa", outputBuffer?.readString(length: frameLength))

        outputBuffer = channel.readInbound()
        XCTAssertNil(outputBuffer?.readString(length: frameLength))
    }

}
