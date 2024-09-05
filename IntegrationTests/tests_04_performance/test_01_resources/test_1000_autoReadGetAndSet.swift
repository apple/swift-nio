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
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        try! group.syncShutdownGracefully()
    }

    let server = try! ServerBootstrap(group: group)
        .bind(host: "127.0.0.1", port: 0)
        .wait()
    defer {
        try! server.close().wait()
    }

    measure(identifier: identifier) {
        let iterations = 1000

        for _ in 0..<iterations {
            let autoReadOption = try! server.getOption(.autoRead).wait()
            try! server.setOption(.autoRead, value: !autoReadOption).wait()
        }

        return iterations
    }
}
