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
import Dispatch

class BlockingIOThreadPoolTest: XCTestCase {
    func testDoubleShutdownWorks() throws {
        let threadPool = BlockingIOThreadPool(numberOfThreads: 17)
        threadPool.start()
        try threadPool.syncShutdownGracefully()
        try threadPool.syncShutdownGracefully()
    }

    func testStateCancelled() throws {
        let threadPool = BlockingIOThreadPool(numberOfThreads: 17)
        let group = DispatchGroup()
        group.enter()
        threadPool.submit { state in
            XCTAssertEqual(BlockingIOThreadPool.WorkItemState.cancelled, state)
            group.leave()
        }
        group.wait()
        try threadPool.syncShutdownGracefully()
    }

    func testStateActive() throws {
        let threadPool = BlockingIOThreadPool(numberOfThreads: 17)
        threadPool.start()
        let group = DispatchGroup()
        group.enter()
        threadPool.submit { state in
            XCTAssertEqual(BlockingIOThreadPool.WorkItemState.active, state)
            group.leave()
        }
        group.wait()
        try threadPool.syncShutdownGracefully()
    }
}
