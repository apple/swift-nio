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

fileprivate final class WaitForReadHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    
    private var completed: EventLoopPromise<Void>
    
    func waitAndReset(nextPromise: EventLoopPromise<Void>) {
        try! self.completed.futureResult.wait()
        self.completed = nextPromise
    }
    
    init(completionPromise: EventLoopPromise<Void>) {
        self.completed = completionPromise
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.completed.succeed(())
    }
}

func run(identifier: String) {
    let numberOfIterations = 1000
    
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        try! group.syncShutdownGracefully()
    }
    
    let eventLoop = group.next()
    let serverHandler = WaitForReadHandler(completionPromise: eventLoop.makePromise())
    let serverChannel = try! DatagramBootstrap(group: group)
        .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        // Set the handlers that are applied to the bound channel
        .channelInitializer { channel in
            return channel.pipeline.addHandler(serverHandler)
        }
        .bind(host: "127.0.0.1", port: 0).wait()
    defer {
        try! serverChannel.close().wait()
    }

    let remoteAddress = serverChannel.localAddress!
    
    let clientBootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

    measure(identifier: identifier) {
        let buffer = ByteBuffer(integer: 1, as: UInt8.self)
        let el = group.next()

        for _ in 0 ..< numberOfIterations {
            try! el.flatSubmit {
                clientBootstrap
                    .bind(host: "127.0.0.1", port: 0).flatMap {
                    (clientChannel) -> EventLoopFuture<Void> in
                    writeWaitAndClose(clientChannel: clientChannel, buffer: buffer, remoteAddress: remoteAddress)
                }
            }.wait()
            serverHandler.waitAndReset(nextPromise: eventLoop.makePromise())
        }
        return numberOfIterations
    }
}

fileprivate func writeWaitAndClose(clientChannel: Channel, buffer: ByteBuffer, remoteAddress: SocketAddress) -> EventLoopFuture<Void> {
    // Send a byte to make sure everything is really open.
    let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: remoteAddress, data: buffer)
    return clientChannel.writeAndFlush(envelope).flatMap {
        clientChannel.close()
    }
}
