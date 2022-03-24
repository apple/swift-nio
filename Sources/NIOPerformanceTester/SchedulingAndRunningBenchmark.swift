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

final class SchedulingAndRunningBenchmark: Benchmark {
    private var group: MultiThreadedEventLoopGroup!
    private var loop: EventLoop!
    private var dg: DispatchGroup!
    private var counter = 0
    private let numTasks: Int

    init(numTasks: Int) {
        self.numTasks = numTasks
    }

    func setUp() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        loop = group.next()
        dg = DispatchGroup()

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
        try! self.loop.submit {
            for _ in 0..<self.numTasks {
                self.dg.enter()

                self.loop.scheduleTask(in: .nanoseconds(0)) {
                    self.counter &+= 1
                    self.dg.leave()
                }
            }
        }.wait()
        self.dg.wait()

        return counter
    }

}
