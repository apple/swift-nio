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

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fatalError("unexpected \(error)")
    }
}

func run(identifier: String) {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        try! group.syncShutdownGracefully()
    }

    let serverChannel = try! ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ReceiveAndCloseHandler())
            }.bind(host: "127.0.0.1", port: 0).wait()
    defer {
        try! serverChannel.close().wait()
    }

    let clientBootstrap = ClientBootstrap(group: group)

    measure(identifier: identifier) {
        let numberOfIterations = 1000
        let serverAddress = serverChannel.localAddress!
        let buffer = ByteBuffer(integer: 1, as: UInt8.self)
        let el = group.next()

        for _ in 0 ..< numberOfIterations {
            try! el.flatSubmit {
                clientBootstrap.connect(to: serverAddress).flatMap { clientChannel in
                    // Send a byte to make sure everything is really open.
                    clientChannel.writeAndFlush(buffer).flatMap {
                        clientChannel.closeFuture
                    }
                }
            }.wait()
        }
        return numberOfIterations
    }
}
