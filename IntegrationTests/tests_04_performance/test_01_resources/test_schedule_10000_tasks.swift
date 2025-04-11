//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
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

func run(identifier: String) {
    measure(identifier: identifier) {
        let group = MultiThreadedEventLoopGroup.preheatedSingleton
        let loop = group.next()
        let (counter, tasks) = try! loop.submit { () -> (Int, [Scheduled<Void>]) in
            let iterations = 10_000
            var counter: Int = 0
            var tasks = [Scheduled<Void>]()
            tasks.reserveCapacity(iterations)

            for _ in 0..<iterations {
                let task = loop.scheduleTask(in: .hours(1)) {
                    counter &+= 1
                }
                tasks.append(task)
            }

            return (counter, tasks)
        }.wait()

        for task in tasks {
            task.cancel()
        }

        return counter
    }
}
