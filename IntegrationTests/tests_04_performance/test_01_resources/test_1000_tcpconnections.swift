//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

fileprivate final class DoNothingHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
}

func run(identifier: String) {
    let serverChannel = try! ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(DoNothingHandler())
            }.bind(to: localhostPickPort).wait()
    defer {
        try! serverChannel.close().wait()
    }
    
    let clientBootstrap = ClientBootstrap(group: group)
    
    measure(identifier: identifier) {
        let numberOfIterations = 1000
        
        for _ in 0 ..< numberOfIterations {
            let clientChannel = try! clientBootstrap.connect(to: serverChannel.localAddress!)
                    .wait()
            defer {
                try! clientChannel.close().wait()
            }
            // Send a byte to make sure everything is really open.
            var buffer = clientChannel.allocator.buffer(capacity: 1)
            buffer.writeInteger(1, as: UInt8.self)
            try! clientChannel.writeAndFlush(NIOAny(buffer)).wait()
        }
        return numberOfIterations
    }
}
