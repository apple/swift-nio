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
import NIOPosix

func run(identifier: String) {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let loop = group.next()
    let dg = DispatchGroup()

    measure(identifier: identifier) {
        var counter = 0

        try! loop.submit {
            for _ in 0..<10000 {
                dg.enter()

                loop.scheduleTask(in: .nanoseconds(0)) {
                    counter &+= 1
                    dg.leave()
                }
            }
        }.wait()
        dg.wait()

        return counter
    }

    try! group.syncShutdownGracefully()
}
