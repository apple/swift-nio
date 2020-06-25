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

fileprivate final class CountReadsHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    
    private var readsRemaining: Int
    private let completed: EventLoopPromise<Void>
    
    var completionFuture: EventLoopFuture<Void> {
        return self.completed.futureResult
    }
    
    init(numberOfReadsExpected: Int, completionPromise: EventLoopPromise<Void>) {
        self.readsRemaining = numberOfReadsExpected
        self.completed = completionPromise
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.readsRemaining -= 1
        if self.readsRemaining <= 0 {
            self.completed.succeed(())
        }
    }
}

func run(identifier: String) {
    let numberOfIterations = 1000
    
    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    defer {
        try! group.syncShutdownGracefully()
    }
    
    let serverHandler = CountReadsHandler(numberOfReadsExpected: numberOfIterations,
                                          completionPromise: group.next().makePromise())
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
                   // .childChannelInitializer { channel in
                     //   channel.pipeline.addHandler(ReceiveAndCloseHandler())
                   // }
                    .bind(host: "127.0.0.1", port: 0).flatMap {
                    (clientChannel) -> EventLoopFuture<Void> in
                    writeWaitAndClose(clientChannel: clientChannel, buffer: buffer, remoteAddress: remoteAddress)
                }
            }.wait()
        }
        try! serverHandler.completionFuture.wait()
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
