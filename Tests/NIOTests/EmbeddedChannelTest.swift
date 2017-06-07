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
@testable import NIO

class EmbeddedChannelTest: XCTestCase {
    func testWriteByteBuffer() throws {
        let channel = EmbeddedChannel()
        var buf = try channel.allocator.buffer(capacity: 1024)
        buf.write(string: "hello")

        let f = channel.write(data: buf, promise:channel.eventLoop.newPromise(type: Void.self))

        var ranBlock = false
        f.whenSuccess {
            XCTAssertEqual(buf, channel.outboundBuffer[0] as! ByteBuffer)
            ranBlock = true
        }
        try f.wait()

        XCTAssert(ranBlock)
    }
}
