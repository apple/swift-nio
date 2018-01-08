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

@testable import NIO
import XCTest

public class EmbeddedEventLoopTest: XCTestCase {
    func testExecuteDoesNotImmediatelyRunTasks() throws {
        var callbackRan = false
        let loop = EmbeddedEventLoop()
        loop.execute { callbackRan = true }

        XCTAssertFalse(callbackRan)
        loop.run()
        XCTAssertTrue(callbackRan)
    }

    func testExecuteWillRunAllTasks() throws {
        var runCount = 0
        let loop = EmbeddedEventLoop()
        loop.execute { runCount += 1 }
        loop.execute { runCount += 1 }
        loop.execute { runCount += 1 }

        XCTAssertEqual(runCount, 0)
        loop.run()
        XCTAssertEqual(runCount, 3)
    }

    func testExecuteWillRunTasksAddedRecursively() throws {
        var sentinel = 0
        let loop = EmbeddedEventLoop()

        loop.execute {
            // This should execute first.
            XCTAssertEqual(sentinel, 0)
            sentinel = 1
            loop.execute {
                // This should execute third.
                XCTAssertEqual(sentinel, 2)
                sentinel = 3
            }
        }
        loop.execute {
            // This should execute second.
            XCTAssertEqual(sentinel, 1)
            sentinel = 2
        }

        XCTAssertEqual(sentinel, 0)
        loop.run()
        XCTAssertEqual(sentinel, 3)
    }

    func testTasksSubmittedAfterRunDontRun() throws {
        var callbackRan = false
        let loop = EmbeddedEventLoop()
        loop.execute { callbackRan = true }

        XCTAssertFalse(callbackRan)
        loop.run()
        loop.execute { callbackRan = false }
        XCTAssertTrue(callbackRan)
        loop.run()
        XCTAssertFalse(callbackRan)
    }

    func testShutdownGracefullyRunsTasks() throws {
        var callbackRan = false
        let loop = EmbeddedEventLoop()
        loop.execute { callbackRan = true }

        XCTAssertFalse(callbackRan)
        XCTAssertNoThrow(try loop.syncShutdownGracefully())
        XCTAssertTrue(callbackRan)
    }
}
