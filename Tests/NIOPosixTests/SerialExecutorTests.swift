//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023-2024 Apple Inc. and the SwiftNIO project authors
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

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
actor EventLoopBoundActor {
    nonisolated let unownedExecutor: UnownedSerialExecutor

    var counter: Int = 0

    init(loop: EventLoop) {
        self.unownedExecutor = loop.executor.asUnownedSerialExecutor()
    }

    func assertInLoop(_ loop: EventLoop) {
        loop.assertInEventLoop()
        XCTAssertTrue(loop.inEventLoop)
    }

    func assertNotInLoop(_ loop: EventLoop) {
        loop.assertNotInEventLoop()
        XCTAssertFalse(loop.inEventLoop)
    }

    nonisolated func assumeInLoop() -> Int {
        self.assumeIsolated { actor in
            actor.counter
        }
    }
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
final class SerialExecutorTests: XCTestCase {
    var group: MultiThreadedEventLoopGroup!

    private func _testBasicExecutorFitsOnEventLoop(loop1: EventLoop, loop2: EventLoop) async throws {
        let testActor = EventLoopBoundActor(loop: loop1)
        await testActor.assertInLoop(loop1)
        await testActor.assertNotInLoop(loop2)
    }

    func testBasicExecutorFitsOnEventLoop_MTELG() async throws {
        let loops = Array(self.group.makeIterator())
        try await self._testBasicExecutorFitsOnEventLoop(loop1: loops[0], loop2: loops[1])
    }

    func testBasicExecutorFitsOnEventLoop_AsyncTestingEventLoop() async throws {
        let loop1 = NIOAsyncTestingEventLoop()
        let loop2 = NIOAsyncTestingEventLoop()
        func shutdown() async {
            await loop1.shutdownGracefully()
            await loop2.shutdownGracefully()
        }

        do {
            try await self._testBasicExecutorFitsOnEventLoop(loop1: loop1, loop2: loop2)
            await shutdown()
        } catch {
            await shutdown()
            throw error
        }
    }

    func testAssumeIsolation() async throws {
        let el = self.group.next()

        let testActor = EventLoopBoundActor(loop: el)
        let result = try await el.submit {
            testActor.assumeInLoop()
        }.get()
        XCTAssertEqual(result, 0)
    }

    override func setUp() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
        self.group = nil
    }
}
