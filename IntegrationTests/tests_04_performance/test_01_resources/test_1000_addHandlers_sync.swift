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
import NIOEmbedded

private final class SimpleHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny
}

func run(identifier: String) {
    measure(identifier: identifier) {
        let iterations = 1000
        for _ in 0..<iterations {
            let channel = EmbeddedChannel()
            defer {
                _ = try! channel.finish()
            }
            try! channel.pipeline.syncOperations.addHandlers([
                SimpleHandler(),
                SimpleHandler(),
            ])
        }
        return iterations
    }
}
