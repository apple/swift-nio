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

final class TaskExecutorTests: XCTestCase {
    #if compiler(>=6.0)
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func _runTests(loop1: some EventLoop, loop2: some EventLoop) async {
        let executor1 = loop1.taskExecutor
        let executor2 = loop2.taskExecutor
        await withTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask(executorPreference: executor1) {
                loop1.assertInEventLoop()
                loop2.assertNotInEventLoop()

                withUnsafeCurrentTask { task in
                    // this currently fails on macOS
                    XCTAssertEqual(task?.unownedTaskExecutor, executor1.asUnownedTaskExecutor())
                }
            }

            taskGroup.addTask(executorPreference: executor2) {
                loop1.assertNotInEventLoop()
                loop2.assertInEventLoop()

                withUnsafeCurrentTask { task in
                    // this currently fails on macOS
                    XCTAssertEqual(task?.unownedTaskExecutor, executor2.asUnownedTaskExecutor())
                }
            }
        }

        let task = Task(executorPreference: executor1) {
            loop1.assertInEventLoop()
            loop2.assertNotInEventLoop()

            withUnsafeCurrentTask { task in
                // this currently fails on macOS
                XCTAssertEqual(task?.unownedTaskExecutor, executor1.asUnownedTaskExecutor())
            }
        }

        await task.value
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func testSelectableEventLoopAsTaskExecutor() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        var iterator = group.makeIterator()
        let loop1 = iterator.next()!
        let loop2 = iterator.next()!

        await self._runTests(loop1: loop1, loop2: loop2)
        try! await group.shutdownGracefully()
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func testAsyncTestingEventLoopAsTaskExecutor() async throws {
        let loop1 = NIOAsyncTestingEventLoop()
        let loop2 = NIOAsyncTestingEventLoop()

        await self._runTests(loop1: loop1, loop2: loop2)

        await loop1.shutdownGracefully()
        await loop2.shutdownGracefully()
    }
    #endif
}
