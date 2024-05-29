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
    @available(macOS 9999.0, iOS 9999.0, watchOS 9999.0, tvOS 9999.0, *)
    func testBasicExecutorFitsOnEventLoop_MTELG() async throws {
        #if compiler(>=6.0)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            try! group.syncShutdownGracefully()
        }
        let loops = Array(group.makeIterator())
        await withTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask(executorPreference: loops[0].taskExecutor) {
                loops[0].assertInEventLoop()
                loops[1].assertNotInEventLoop()

                withUnsafeCurrentTask { task in
                    // this currently fails on macOS
                    XCTAssertEqual(task?.unownedTaskExecutor, loops[0].taskExecutor.asUnownedTaskExecutor())
                }
            }

            taskGroup.addTask(executorPreference: loops[1].taskExecutor) {
                loops[0].assertNotInEventLoop()
                loops[1].assertInEventLoop()

                withUnsafeCurrentTask { task in
                    // this currently fails on macOS
                    XCTAssertEqual(task?.unownedTaskExecutor, loops[1].taskExecutor.asUnownedTaskExecutor())
                }
            }
        }
        #endif
    }
}
