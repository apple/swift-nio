//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOTestUtils
import XCTest

class NIOHTTP1TestServerTest: XCTestCase {
    private var group: EventLoopGroup!

    override func setUp() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
        self.group = nil
    }

    func testSimpleRequest() {
        let testServer = NIOHTTP1TestServer(group: self.group)
        defer {
            XCTAssertNoThrow(try testServer.stop())
        }
        XCTFail("Not implemented yet")
    }

    func testConcurrentRequests() {
        XCTFail("Not implemented yet")
    }

    func testServerConnectionClose() {
        XCTFail("Not implemented yet")
    }
}
