//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import NIOPosix

final class RunIfActiveBenchmark: Benchmark {
    private var threadPool: NIOThreadPool!

    private var loop: EventLoop!
    private var dg: DispatchGroup!
    private var counter = 0

    private let numThreads: Int
    private let numTasks: Int

    init(numThreads: Int, numTasks: Int) {
        self.numThreads = numThreads
        self.numTasks = numTasks
    }

    func setUp() throws {
        self.threadPool = NIOThreadPool(numberOfThreads: self.numThreads)
        self.threadPool.start()

        // Prewarm the internal NIOThreadPool request queue, to avoid CoW
        // work during the test runs.
        let semaphore = DispatchSemaphore(value: 0)
        let eventLoop = MultiThreadedEventLoopGroup.singleton.any()
        let futures = (0..<self.numTasks).map { _ in
            self.threadPool.runIfActive(eventLoop: eventLoop) {
                // Hold back all the work items, until they all got scheduled
                semaphore.wait()
            }
        }

        for _ in (0..<self.numTasks) {
            semaphore.signal()
        }

        _ = try EventLoopFuture.whenAllSucceed(futures, on: eventLoop).wait()
    }

    func tearDown() {
        try! self.threadPool.syncShutdownGracefully()
    }

    func run() -> Int {
        let eventLoop = MultiThreadedEventLoopGroup.singleton.any()

        let futures = (0..<self.numTasks).map { _ in
            self.threadPool.runIfActive(eventLoop: eventLoop) {
                // Empty work item body
            }
        }

        _ = try! EventLoopFuture.whenAllSucceed(futures, on: eventLoop).wait()

        return 0
    }
}
