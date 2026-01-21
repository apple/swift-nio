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

import Dispatch
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

final class NIOLockBenchmark: Benchmark, @unchecked Sendable {
    // mutable state is protected by the lock

    private let numberOfThreads: Int
    private let lockOperationsPerThread: Int
    private let threadPool: NIOThreadPool
    private let group: EventLoopGroup
    private let sem1 = DispatchSemaphore(value: 0)
    private let sem2 = DispatchSemaphore(value: 0)
    private let sem3 = DispatchSemaphore(value: 0)
    private var opsDone = 0

    private let lock = NIOLock()

    init(numberOfThreads: Int, lockOperationsPerThread: Int) {
        self.numberOfThreads = numberOfThreads
        self.lockOperationsPerThread = lockOperationsPerThread
        self.threadPool = NIOThreadPool(numberOfThreads: numberOfThreads)
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func setUp() throws {
        self.threadPool.start()
    }

    func tearDown() {
        try! self.threadPool.syncShutdownGracefully()
        try! self.group.syncShutdownGracefully()
    }

    func run() throws -> Int {
        self.lock.withLock {
            self.opsDone = 0
        }
        for _ in 0..<self.numberOfThreads {
            _ = self.threadPool.runIfActive(eventLoop: self.group.next()) {
                self.sem1.signal()
                self.sem2.wait()

                for _ in 0..<self.lockOperationsPerThread {
                    self.lock.withLock {
                        self.opsDone &+= 1
                    }
                }

                self.sem3.signal()
            }
        }
        // Wait until all threads are ready.
        for _ in 0..<self.numberOfThreads {
            self.sem1.wait()
        }
        // Kick off the work.
        for _ in 0..<self.numberOfThreads {
            self.sem2.signal()
        }
        // Wait until all threads are done.
        for _ in 0..<self.numberOfThreads {
            self.sem3.wait()
        }

        let done = self.lock.withLock { self.opsDone }
        precondition(done == self.numberOfThreads * self.lockOperationsPerThread)
        return done
    }
}
