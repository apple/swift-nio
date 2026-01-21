//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
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

private final class EchoChannelHandler: ChannelInboundHandler {
    fileprivate typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

private final class EchoRequestChannelHandler: ChannelInboundHandler {
    fileprivate typealias InboundIn = ByteBuffer

    private let messageSize = 10000
    private let numberOfWrites: Int
    private var batchCount = 0
    private let data: NIOAny
    private let readsCompletePromise: EventLoopPromise<Void>
    private var receivedData = 0

    init(numberOfWrites: Int, readsCompletePromise: EventLoopPromise<Void>) {
        self.numberOfWrites = numberOfWrites
        self.readsCompletePromise = readsCompletePromise
        self.data = NIOAny(ByteBuffer(repeating: 0, count: self.messageSize))
    }

    func channelActive(context: ChannelHandlerContext) {
        for _ in 0..<self.numberOfWrites {
            context.writeAndFlush(data, promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = Self.unwrapInboundIn(data)
        self.receivedData += buffer.readableBytes

        if self.receivedData == self.numberOfWrites * self.messageSize {
            self.readsCompletePromise.succeed()
        }
    }
}

func runTCPEcho(numberOfWrites: Int, eventLoop: any EventLoop) throws {
    let serverChannel = try ServerBootstrap(group: eventLoop)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(EchoChannelHandler())
            }
        }
        .bind(
            host: "127.0.0.1",
            port: 0
        ).wait()

    let readsCompletePromise = eventLoop.makePromise(of: Void.self)
    let clientChannel = try ClientBootstrap(group: eventLoop)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let echoRequestHandler = EchoRequestChannelHandler(
                    numberOfWrites: numberOfWrites,
                    readsCompletePromise: readsCompletePromise
                )
                try channel.pipeline.syncOperations.addHandler(echoRequestHandler)
            }
        }
        .connect(
            host: "127.0.0.1",
            port: serverChannel.localAddress!.port!
        ).wait()

    // Waiting for the client to collect all echoed data.
    try readsCompletePromise.futureResult.wait()
    try serverChannel.close().wait()
    try clientChannel.close().wait()
}
