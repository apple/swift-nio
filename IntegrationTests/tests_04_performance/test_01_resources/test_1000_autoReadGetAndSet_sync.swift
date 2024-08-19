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

import NIOCore
import NIOPosix

func run(identifier: String) {
    MultiThreadedEventLoopGroup.withCurrentThreadAsEventLoop { loop in
        ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).map { server in
            measure(identifier: identifier) {
                let iterations = 1000

                let syncOptions = server.syncOptions!

                for _ in 0..<iterations {
                    let autoReadOption = try! syncOptions.getOption(.autoRead)
                    try! syncOptions.setOption(.autoRead, value: !autoReadOption)
                }

                return iterations
            }
        }.always { _ in
            loop.shutdownGracefully { _ in }
        }
    }
}
