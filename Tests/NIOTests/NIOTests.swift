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

import NIO
import XCTest

/// This test suite is focused just on confirming that the umbrella NIO module behaves as expected.
final class NIOTests: XCTestCase {
    func testCanUseTheVariousNIOTypes() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.finish())

        let buffer = ByteBuffer()
        XCTAssertEqual(buffer.readableBytes, 0)
    }
}
