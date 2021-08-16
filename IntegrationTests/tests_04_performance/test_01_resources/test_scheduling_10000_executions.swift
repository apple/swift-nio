//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
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
        let dg = DispatchGroup()

        try! loop.submit {
            for _ in 0..<10_000 {
                dg.enter()
                loop.execute { dg.leave() }
            }
        }.wait()
        dg.wait()
        try! group.syncShutdownGracefully()
        return 10_000
    }
}
