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

fileprivate final class ReceiveAndCloseHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let byteBuffer = self.unwrapInboundIn(data)
        precondition(byteBuffer.readableBytes == 1)
        context.channel.close(promise: nil)
    }
}

func run(identifier: String) {
    let serverChannel = try! ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ReceiveAndCloseHandler())
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
            // For boring reasons we need to turn off linger.
            _ = try! (clientChannel as? SocketOptionProvider)?.setSoLinger(linger(l_onoff: 1, l_linger: 0)).wait()
            // Send a byte to make sure everything is really open.
            var buffer = clientChannel.allocator.buffer(capacity: 1)
            buffer.writeInteger(1, as: UInt8.self)
            clientChannel.writeAndFlush(NIOAny(buffer), promise: nil)
            // Wait for the close to come from the server side.
            try! clientChannel.closeFuture.wait()
        }
        return numberOfIterations
    }
}
