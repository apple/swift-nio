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
    private var loop: EventLoop!
    private let numTasks: Int

    init(numTasks: Int) {
        self.numTasks = numTasks
    }

    func setUp() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        loop = group.next()

        // We are preheating the EL to avoid growing the `ScheduledTask` `PriorityQueue`
        // during the actual test
        try! self.loop.submit {
            var counter: Int = 0
            for _ in 0..<self.numTasks {
                self.loop.scheduleTask(in: .nanoseconds(0)) {
                    counter &+= 1
                }
            }
        }.wait()
    }

    func tearDown() { }

    func run() -> Int {
        let counter = try! self.loop.submit { () -> Int in
            var counter: Int = 0
            for _ in 0..<self.numTasks {
                self.loop.scheduleTask(in: .hours(1)) {
                    counter &+= 1
                }
            }

            return counter
        }.wait()

        return counter
    }

}
