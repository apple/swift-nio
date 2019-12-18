//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import NIO

func run(identifier: String) {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let loop = group.next()
    let dg = DispatchGroup()

    measure(identifier: identifier) {
        loop.execute {
            for _ in 0..<10_000 {
                dg.enter()
                loop.scheduleTask(in: .nanoseconds(0)) { dg.leave() }
            }
        }
        dg.wait()
        return 10_000
    }

    try! group.syncShutdownGracefully()
}
