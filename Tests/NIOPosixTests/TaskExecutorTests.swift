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
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func testBasicExecutorFitsOnEventLoop_MTELG() async throws {
        #if compiler(>=6.0)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let loops = Array(group.makeIterator())
        await withTaskGroup(of: Void.self) { taskGroup in
            let loop0Executor = loops[0].taskExecutor
            let loop1Executor = loops[1].taskExecutor
            taskGroup.addTask(executorPreference: loop0Executor) {
                loops[0].assertInEventLoop()
                loops[1].assertNotInEventLoop()

                withUnsafeCurrentTask { task in
                    // this currently fails on macOS
                    XCTAssertEqual(task?.unownedTaskExecutor, loop0Executor.asUnownedTaskExecutor())
                }
            }

            taskGroup.addTask(executorPreference: loop1Executor) {
                loops[0].assertNotInEventLoop()
                loops[1].assertInEventLoop()

                withUnsafeCurrentTask { task in
                    // this currently fails on macOS
                    XCTAssertEqual(task?.unownedTaskExecutor, loop1Executor.asUnownedTaskExecutor())
                }
            }
        }
        try await group.shutdownGracefully()
        #endif
    }
}
