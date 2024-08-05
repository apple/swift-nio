//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
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

private final class DoNothingHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
}

func run(identifier: String) {
    measure(identifier: identifier) {
        let numberOfIterations = 1000
        for _ in 0..<numberOfIterations {
            _ = DatagramBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(DoNothingHandler())
                }
        }
        return numberOfIterations
    }
}
