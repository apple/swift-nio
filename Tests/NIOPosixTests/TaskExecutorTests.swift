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
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
    func _runTests(loop1: some EventLoop, loop2: some EventLoop) async {
        await withTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask(executorPreference: loop1.taskExecutor) {
                loop1.assertInEventLoop()
                loop2.assertNotInEventLoop()

                withUnsafeCurrentTask { task in
                    // this currently fails on macOS
                    XCTAssertEqual(task?.unownedTaskExecutor, loop1.taskExecutor.asUnownedTaskExecutor())
                }
            }

            taskGroup.addTask(executorPreference: loop2.taskExecutor) {
                loop1.assertNotInEventLoop()
                loop2.assertInEventLoop()

                withUnsafeCurrentTask { task in
                    // this currently fails on macOS
                    XCTAssertEqual(task?.unownedTaskExecutor, loop2.taskExecutor.asUnownedTaskExecutor())
                }
            }
        }

        let task = Task(executorPreference: loop1.taskExecutor) {
            loop1.assertInEventLoop()
            loop2.assertNotInEventLoop()

            withUnsafeCurrentTask { task in
                // this currently fails on macOS
                XCTAssertEqual(task?.unownedTaskExecutor, loop1.taskExecutor.asUnownedTaskExecutor())
            }
        }

        await task.value
    }
    #endif

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
    func testSelectableEventLoopAsTaskExecutor() async throws {
        #if compiler(>=6.0)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            try! group.syncShutdownGracefully()
        }
        var iterator = group.makeIterator()
        let loop1 = iterator.next()!
        let loop2 = iterator.next()!

        await self._runTests(loop1: loop1, loop2: loop2)
        #endif
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
    func testAsyncTestingEventLoopAsTaskExecutor() async throws {
        #if compiler(>=6.0)
        let loop1 = NIOAsyncTestingEventLoop()
        let loop2 = NIOAsyncTestingEventLoop()
        defer {
            try? loop1.syncShutdownGracefully()
            try? loop2.syncShutdownGracefully()
        }

        await withTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask(executorPreference: loop1.taskExecutor) {
                loop1.assertInEventLoop()
                loop2.assertNotInEventLoop()

                withUnsafeCurrentTask { task in
                    // this currently fails on macOS
                    XCTAssertEqual(task?.unownedTaskExecutor, loop1.taskExecutor.asUnownedTaskExecutor())
                }
            }

            taskGroup.addTask(executorPreference: loop2) {
                loop1.assertNotInEventLoop()
                loop2.assertInEventLoop()

                withUnsafeCurrentTask { task in
                    // this currently fails on macOS
                    XCTAssertEqual(task?.unownedTaskExecutor, loop2.taskExecutor.asUnownedTaskExecutor())
                }
            }
        }
        #endif
    }
}
