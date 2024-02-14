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

final class SchedulingBenchmark: Benchmark {
    private var group: MultiThreadedEventLoopGroup!
    private var loops: EventLoopIterator!
    private let numTasks: Int

    init(numTasks: Int) {
        self.numTasks = numTasks
    }

    func setUp(runs: Int) throws {
        // The test schedules tasks for ~far future (and doesn't drain them). We therefore need
        // to have fresh loop for each performance run.
        //
        // We are preheating the ELG, sized to the expected # of perf runs. The preheating is
        // designed to avoid growing the `ScheduledTask` `PriorityQueue` during the actual test.
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: runs)
        self.group.makeIterator().forEach { loop in
            let loop = group.next()
            try! loop.submit {
                var counter: Int = 0
                for _ in 0..<self.numTasks {
                    loop.scheduleTask(in: .nanoseconds(0)) {
                        counter &+= 1
                    }
                }
            }.wait()
        }
        self.loops = self.group.makeIterator()
    }

    func tearDown() { }

    func run() -> Int {
        guard let loop = self.loops.next() else {
            fatalError("Test harness run the benchmark more times than it promised in `setUp()`")
        }
        let counter = try! loop.submit { () -> Int in
            var counter: Int = 0
            for _ in 0..<self.numTasks {
                loop.scheduleTask(in: .hours(1)) {
                    counter &+= 1
                }
            }

            return counter
        }.wait()

        return counter
    }

}
