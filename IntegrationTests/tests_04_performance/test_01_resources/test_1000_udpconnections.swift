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
    
    let serverHandler = CountReadsHandler(numberOfReadsExpected: numberOfIterations,
                                          completionPromise: group.next().makePromise())
    let serverChannel = try! DatagramBootstrap(group: group)
        .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        // Set the handlers that are applied to the bound channel
        .channelInitializer { channel in
            return channel.pipeline.addHandler(serverHandler)
        }
        .bind(to: localhostPickPort).wait()
    defer {
        try! serverChannel.close().wait()
    }

    let remoteAddress = serverChannel.localAddress!
    
    let clientBootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

    measure(identifier: identifier) {
        let buffer = ByteBuffer(integer: 1, as: UInt8.self)
        for _ in 0 ..< numberOfIterations {
            let clientChannel = try! clientBootstrap.bind(to: localhostPickPort).wait()
            defer {
                try! clientChannel.close().wait()
            }
            
            // Send a byte to make sure everything is really open.
            let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: remoteAddress, data: buffer)
            clientChannel.writeAndFlush(envelope, promise: nil)
        }
        try! serverHandler.completionFuture.wait()
        return numberOfIterations
    }
}

