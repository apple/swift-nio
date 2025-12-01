//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
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

private final class UDPEchoHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }
}

private final class UDPEchoRequestHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let buffer = ByteBuffer(repeating: 0, count: 512)
    private let numberOfWrites: Int
    private let remoteAddress: SocketAddress
    private var receivedCount = 0
    private let readsCompletePromise: EventLoopPromise<Void>

    init(
        numberOfWrites: Int,
        remoteAddress: SocketAddress,
        readsCompletePromise: EventLoopPromise<Void>
    ) {
        self.numberOfWrites = numberOfWrites
        self.remoteAddress = remoteAddress
        self.readsCompletePromise = readsCompletePromise
    }

    func channelActive(context: ChannelHandlerContext) {
        self.writeAgain(context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.receivedCount += 1

        if self.receivedCount == self.numberOfWrites {
            self.readsCompletePromise.succeed()
        } else {
            self.writeAgain(context: context)
        }
    }

    private func writeAgain(context: ChannelHandlerContext) {
        let envelope = AddressedEnvelope(
            remoteAddress: self.remoteAddress,
            data: buffer
        )
        context.write(Self.wrapOutboundOut(envelope), promise: nil)
        context.flush()
    }
}

func runUDPEcho(numberOfWrites: Int, eventLoop: any EventLoop) throws {
    let address = try SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 0)

    // Create server channel
    let serverChannel = try DatagramBootstrap(group: eventLoop)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(UDPEchoHandler())
            }
        }
        .bind(to: address)
        .wait()

    let readsCompletePromise = eventLoop.makePromise(of: Void.self)

    // Create client channel
    let clientChannel = try DatagramBootstrap(group: eventLoop)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let handler = UDPEchoRequestHandler(
                    numberOfWrites: numberOfWrites,
                    remoteAddress: serverChannel.localAddress!,
                    readsCompletePromise: readsCompletePromise
                )
                try channel.pipeline.syncOperations.addHandler(handler)
            }
        }
        .bind(to: address)
        .wait()

    // Wait for all echoes to complete
    try readsCompletePromise.futureResult.wait()

    // Cleanup
    try serverChannel.close().wait()
    try clientChannel.close().wait()
}

func runUDPEchoPacketInfo(numberOfWrites: Int, eventLoop: any EventLoop) throws {
    let address = try SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 0)

    // Create server channel with receivePacketInfo enabled
    let serverChannel = try DatagramBootstrap(group: eventLoop)
        .channelOption(.receivePacketInfo, value: true)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(UDPEchoHandler())
            }
        }
        .bind(to: address)
        .wait()

    let readsCompletePromise = eventLoop.makePromise(of: Void.self)

    // Create client channel with receivePacketInfo enabled
    let clientChannel = try DatagramBootstrap(group: eventLoop)
        .channelOption(.receivePacketInfo, value: true)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let handler = UDPEchoRequestHandler(
                    numberOfWrites: numberOfWrites,
                    remoteAddress: serverChannel.localAddress!,
                    readsCompletePromise: readsCompletePromise
                )
                try channel.pipeline.syncOperations.addHandler(handler)
            }
        }
        .bind(to: address)
        .wait()

    // Wait for all echoes to complete
    try readsCompletePromise.futureResult.wait()

    // Cleanup
    try serverChannel.close().wait()
    try clientChannel.close().wait()
}
