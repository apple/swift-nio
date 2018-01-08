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

private class EmbeddedTestError: Error { }

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

    func testCanControlTime() throws {
        var callbackCount = 0
        let loop = EmbeddedEventLoop()
        _ = loop.scheduleTask(in: .nanoseconds(5)) {
            callbackCount += 1
        }

        XCTAssertEqual(callbackCount, 0)
        loop.advanceTime(by: .nanoseconds(4))
        XCTAssertEqual(callbackCount, 0)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(callbackCount, 1)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(callbackCount, 1)
        loop.advanceTime(by: .hours(1))
        XCTAssertEqual(callbackCount, 1)
    }

    func testCanScheduleMultipleTasks() throws {
        var sentinel = 0
        let loop = EmbeddedEventLoop()
        for index in 1...10 {
            _ = loop.scheduleTask(in: .nanoseconds(index)) {
                sentinel = index
            }
        }

        for val in 1...10 {
            XCTAssertEqual(sentinel, val - 1)
            loop.advanceTime(by: .nanoseconds(1))
            XCTAssertEqual(sentinel, val)
        }
    }

    func testExecutedTasksFromScheduledOnesAreRun() throws {
        var sentinel = 0
        let loop = EmbeddedEventLoop()
        _ = loop.scheduleTask(in: .nanoseconds(5)) {
            sentinel = 1
            loop.execute {
                sentinel = 2
            }
        }

        loop.advanceTime(by: .nanoseconds(4))
        XCTAssertEqual(sentinel, 0)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(sentinel, 2)
    }

    func testScheduledTasksFromScheduledTasksProperlySchedule() throws {
        var sentinel = 0
        let loop = EmbeddedEventLoop()
        _ = loop.scheduleTask(in: .nanoseconds(5)) {
            sentinel = 1
            _ = loop.scheduleTask(in: .nanoseconds(3)) {
                sentinel = 2
            }
            _ = loop.scheduleTask(in: .nanoseconds(5)) {
                sentinel = 3
            }
        }

        loop.advanceTime(by: .nanoseconds(4))
        XCTAssertEqual(sentinel, 0)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(sentinel, 1)
        loop.advanceTime(by: .nanoseconds(2))
        XCTAssertEqual(sentinel, 1)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(sentinel, 2)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(sentinel, 2)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(sentinel, 3)
    }

    func testScheduledTasksFromExecutedTasks() throws {
        var sentinel = 0
        let loop = EmbeddedEventLoop()
        loop.execute {
            XCTAssertEqual(sentinel, 0)
            _ = loop.scheduleTask(in: .nanoseconds(5)) {
                XCTAssertEqual(sentinel, 1)
                sentinel = 2
            }
            loop.execute { sentinel = 1 }
        }

        loop.advanceTime(by: .nanoseconds(5))
        XCTAssertEqual(sentinel, 2)
    }

    func testCancellingScheduledTasks() throws {
        let loop = EmbeddedEventLoop()
        let task = loop.scheduleTask(in: .nanoseconds(10), { XCTFail("Cancelled task ran") })
        _ = loop.scheduleTask(in: .nanoseconds(5)) {
            task.cancel()
        }

        loop.advanceTime(by: .nanoseconds(20))
    }

    func testScheduledTasksFuturesFire() throws {
        var fired = false
        let loop = EmbeddedEventLoop()
        let task = loop.scheduleTask(in: .nanoseconds(5)) { return true }
        task.futureResult.whenSuccess { fired = $0 }

        loop.advanceTime(by: .nanoseconds(4))
        XCTAssertFalse(fired)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertTrue(fired)
    }

    func testScheduledTasksFuturesError() throws {
        var err: EmbeddedTestError? = nil
        var fired = false
        let loop = EmbeddedEventLoop()
        let task = loop.scheduleTask(in: .nanoseconds(5)) {
            err = EmbeddedTestError()
            throw err!
        }
        task.futureResult.whenComplete { result in
            fired = true
            switch result {
            case .success:
                XCTFail("Scheduled future completed")
            case .failure(let caughtErr):
                XCTAssertTrue(err === caughtErr as? EmbeddedTestError)
            }
        }

        loop.advanceTime(by: .nanoseconds(4))
        XCTAssertFalse(fired)
        loop.advanceTime(by: .nanoseconds(1))
        XCTAssertTrue(fired)
    }
}
