//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
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

    #if compiler(>=6.0)
    nonisolated func assumeInLoop() -> Int {
        self.assumeIsolated { actor in
            actor.counter
        }
    }
    #endif
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
final class SerialExecutorTests: XCTestCase {
    private func _testBasicExecutorFitsOnEventLoop(loop1: EventLoop, loop2: EventLoop) async throws {
        let testActor = EventLoopBoundActor(loop: loop1)
        await testActor.assertInLoop(loop1)
        await testActor.assertNotInLoop(loop2)
    }

    func testBasicExecutorFitsOnEventLoop_MTELG() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            try! group.syncShutdownGracefully()
        }
        let loops = Array(group.makeIterator())
        try await self._testBasicExecutorFitsOnEventLoop(loop1: loops[0], loop2: loops[1])
    }

    func testBasicExecutorFitsOnEventLoop_AsyncTestingEventLoop() async throws {
        let loop1 = NIOAsyncTestingEventLoop()
        let loop2 = NIOAsyncTestingEventLoop()
        defer {
            try? loop1.syncShutdownGracefully()
            try? loop2.syncShutdownGracefully()
        }

        try await self._testBasicExecutorFitsOnEventLoop(loop1: loop1, loop2: loop2)
    }

    func testAssumeIsolation() async throws {
        #if compiler(<6.0)
        throw XCTSkip("Custom executors are only supported in 5.9")
        #else

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let el = group.next()

        let testActor = EventLoopBoundActor(loop: el)
        let result = try await el.submit {
            testActor.assumeInLoop()
        }.get()
        XCTAssertEqual(result, 0)
        #endif
    }
}
