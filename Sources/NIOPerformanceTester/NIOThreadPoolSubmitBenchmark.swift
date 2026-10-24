//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import NIOCore
import NIOPosix

/// Submit one item at a time, waiting for completion before the next.
/// Every submit hits N sleeping threads — isolates wake-one vs wake-all.
final class NIOThreadPoolSerialWakeupBenchmark: Benchmark {
    private let numberOfThreads: Int
    private let numberOfTasks: Int
    private var pool: NIOThreadPool!

    init(numberOfThreads: Int, numberOfTasks: Int) {
        self.numberOfThreads = numberOfThreads
        self.numberOfTasks = numberOfTasks
    }

    func setUp() throws {
        self.pool = NIOThreadPool(numberOfThreads: self.numberOfThreads)
        self.pool.start()
    }

    func tearDown() {
        try! self.pool.syncShutdownGracefully()
    }

    func run() throws -> Int {
        let sem = DispatchSemaphore(value: 0)
        for _ in 0..<self.numberOfTasks {
            self.pool.submit { state in
                precondition(state == .active)
                sem.signal()
            }
            sem.wait()
        }
        return self.numberOfTasks
    }
}
