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

private final class ReceiveAndCloseHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let byteBuffer = Self.unwrapInboundIn(data)
        precondition(byteBuffer.readableBytes == 1)
        context.channel.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fatalError("unexpected \(error)")
    }
}

private final class LingerSettingHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    public func handlerAdded(context: ChannelHandlerContext) {
        (context.channel as? SocketOptionProvider)?.setSoLinger(linger(l_onoff: 1, l_linger: 0))
            .whenFailure({ error in fatalError("Failed to set linger \(error)") })
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
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.addHandler(ReceiveAndCloseHandler())
        }.bind(host: "127.0.0.1", port: 0).wait()
    defer {
        try! serverChannel.close().wait()
    }

    let clientHandler = LingerSettingHandler()
    let clientBootstrap = ClientBootstrap(group: group).channelInitializer { channel in
        channel.pipeline.addHandler(clientHandler)
    }

    measure(identifier: identifier) {
        let numberOfIterations = 1000
        let serverAddress = serverChannel.localAddress!
        let buffer = ByteBuffer(integer: 1, as: UInt8.self)
        let el = group.next()

        for _ in 0..<numberOfIterations {
            try! el.flatSubmit {
                clientBootstrap.connect(to: serverAddress).flatMap { (clientChannel) -> EventLoopFuture<Void> in
                    writeWaitAndClose(clientChannel: clientChannel, buffer: buffer)
                        .flatMap { clientChannel.closeFuture }
                }
            }.wait()
        }
        return numberOfIterations
    }
}

private func writeWaitAndClose(clientChannel: Channel, buffer: ByteBuffer) -> EventLoopFuture<Void> {
    // Send a byte to make sure everything is really open.
    clientChannel.writeAndFlush(buffer).flatMap {
        clientChannel.closeFuture
    }
}
