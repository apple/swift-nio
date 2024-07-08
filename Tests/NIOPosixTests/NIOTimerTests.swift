//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest

final class EmbeddedTimerTests: XCTestCase {

    func testFired() async {
        let loop = EmbeddedEventLoop()

        let handler = MockTimerHandler()
        XCTAssertEqual(handler.firedCount, 0)

        _ = loop.setTimer(for: .milliseconds(42), handler)
        XCTAssertEqual(handler.firedCount, 0)

        loop.advanceTime(by: .milliseconds(41))
        XCTAssertEqual(handler.firedCount, 0)

        loop.advanceTime(by: .milliseconds(1))
        XCTAssertEqual(handler.firedCount, 1)

        loop.advanceTime(by: .milliseconds(1))
        XCTAssertEqual(handler.firedCount, 1)
    }

    func testCancelled() async {
        let loop = EmbeddedEventLoop()
        let handler = MockTimerHandler()
        let handle = loop.setTimer(for: .milliseconds(42), handler)

        handle.cancel()
        XCTAssertEqual(handler.firedCount, 0)

        loop.advanceTime(by: .milliseconds(43))
        XCTAssertEqual(handler.firedCount, 0)
    }
}

final class NIOAsyncTestingEventLoopTimerTests: XCTestCase {

    func testFired() async {
        let loop = NIOAsyncTestingEventLoop()

        let handler = MockTimerHandler()
        XCTAssertEqual(handler.firedCount, 0)

        _ = loop.setTimer(for: .milliseconds(42), handler)
        XCTAssertEqual(handler.firedCount, 0)

        await loop.advanceTime(by: .milliseconds(41))
        XCTAssertEqual(handler.firedCount, 0)

        await loop.advanceTime(by: .milliseconds(1))
        XCTAssertEqual(handler.firedCount, 1)

        await loop.advanceTime(by: .milliseconds(1))
        XCTAssertEqual(handler.firedCount, 1)
    }

    func testCancelled() async {
        let loop = NIOAsyncTestingEventLoop()
        let handler = MockTimerHandler()
        let handle = loop.setTimer(for: .milliseconds(42), handler)

        handle.cancel()
        XCTAssertEqual(handler.firedCount, 0)

        await loop.advanceTime(by: .milliseconds(43))
        XCTAssertEqual(handler.firedCount, 0)
    }
}

final class MTELGTimerTests: XCTestCase {

    func testFired() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()

        let handler = MockTimerHandler()
        XCTAssertEqual(handler.firedCount, 0)

        _ = loop.setTimer(for: .milliseconds(1), handler)

        await fulfillment(of: [handler.timerDidFire], timeout: 0.01)
        XCTAssertEqual(handler.firedCount, 1)
    }

    func testCancel() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()

        let handler = MockTimerHandler()
        handler.timerDidFire.isInverted = true

        let handle = loop.setTimer(for: .milliseconds(1), handler)
        handle.cancel()

        await fulfillment(of: [handler.timerDidFire], timeout: 0.01)
        XCTAssertEqual(handler.firedCount, 0)
    }

    func testShutdown() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        defer { try! group.syncShutdownGracefully() }

        let handler = MockTimerHandler()
        handler.timerDidFire.isInverted = true

        _ = loop.setTimer(for: .milliseconds(100), handler)
        try await group.shutdownGracefully()

        await fulfillment(of: [handler.timerDidFire], timeout: 0.01)
        XCTAssertEqual(handler.firedCount, 0)
    }
}

fileprivate final class MockTimerHandler: NIOTimerHandler {
    var firedCount = 0
    var timerDidFire = XCTestExpectation(description: "Timer fired")

    func timerFired(eventLoop: some EventLoop) {
        self.firedCount += 1
        self.timerDidFire.fulfill()
    }
}

#if !canImport(Darwin) && swift(<5.9.2)
extension XCTestCase {
    func fulfillment(
        of expectations: [XCTestExpectation],
        timeout seconds: TimeInterval,
        enforceOrder enforceOrderOfFulfillment: Bool = false
    ) async {
        wait(for: expectations, timeout: seconds)
    }
}
#endif
