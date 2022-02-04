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
import NIOPosix

func run(identifier: String) {
    measure(identifier: identifier) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let counter = try! loop.submit { () -> Int in
            var counter: Int = 0

            for _ in 0..<10000 {
                loop.scheduleTask(in: .hours(1)) {
                    counter &+= 1
                }
            }

            return counter
        }.wait()

        try! group.syncShutdownGracefully()
        return counter
    }
}
