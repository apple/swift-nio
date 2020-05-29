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
    let serverChannel = try! DatagramBootstrap(group: group)
        .options([.allowImmediateLocalEndpointAddressReuse])
        // Set the handlers that are applied to the bound channel
        .channelInitializer { channel in
            return channel.pipeline.addHandler(DoNothingHandler())
        }
        .bind(to: localhostPickPort).wait()
    defer {
        try! serverChannel.close().wait()
    }

    let remoteAddress = serverChannel.localAddress!
    
    let clientBootstrap = DatagramBootstrap(group: group)
            .options([.allowImmediateLocalEndpointAddressReuse])

    measure(identifier: identifier) {
        let numberOfIterations = 1000
        var buffer = ByteBufferAllocator().buffer(capacity: 1)
        buffer.writeInteger(1, as: UInt8.self)
        for _ in 0 ..< numberOfIterations {
            let clientChannel = try! clientBootstrap.bind(to: localhostPickPort).wait()
            defer {
                try! clientChannel.close().wait()
            }
            
            // Send a byte to make sure everything is really open.
            let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: remoteAddress, data: buffer)
            clientChannel.writeAndFlush(envelope, promise: nil)
        }
        return numberOfIterations
    }
}

