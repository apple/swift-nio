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

private final class ServerEchoHandler: ChannelInboundHandler {
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        context.write(data, promise: nil)
    }

    // Flush it out. This can make use of gathering writes if multiple buffers are pending
    public func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        fatalError()
    }
}

private final class ClientHandler: ChannelInboundHandler {
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let remoteAddress: SocketAddress

    init(remoteAddress: SocketAddress) {
        self.remoteAddress = remoteAddress
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // If we still have iterations to do send some more data.
        if self.iterationsOutstanding > 0 {
            self.iterationsOutstanding -= 1
            sendBytes(clientChannel: context.channel)
        } else {
            self.whenDone!.succeed(())
        }
    }

    // Flush it out. This can make use of gathering writes if multiple buffers are pending
    public func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        fatalError()
    }

    var iterationsOutstanding = 0
    var whenDone: EventLoopPromise<Void>? = nil

    private func sendBytes(clientChannel: Channel) {
        var buffer = clientChannel.allocator.buffer(capacity: 1)
        buffer.writeInteger(3, as: UInt8.self)
        // Send the data with ECN
        let metadata = AddressedEnvelope<ByteBuffer>.Metadata(ecnState: .transportCapableFlag1)
        let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: remoteAddress, data: buffer, metadata: metadata)
        clientChannel.writeAndFlush(Self.wrapOutboundOut(envelope), promise: nil)
    }

    func sendBytesAndWaitForReply(clientChannel: Channel) -> Int {
        let numberOfIterations = 1000

        // Setup for iteration.
        self.iterationsOutstanding = numberOfIterations
        self.whenDone = clientChannel.eventLoop.makePromise()
        // Kick start
        sendBytes(clientChannel: clientChannel)
        // Wait for completion.
        try! self.whenDone!.futureResult.wait()
        return numberOfIterations
    }
}

func run(identifier: String) {
    let serverChannel = try! DatagramBootstrap(group: group)
        .channelOption(.explicitCongestionNotification, value: true)
        // Set the handlers that are applied to the bound channel
        .channelInitializer { channel in
            channel.pipeline.addHandler(ServerEchoHandler())
        }
        .bind(to: localhostPickPort).wait()
    defer {
        try! serverChannel.close().wait()
    }

    let remoteAddress = serverChannel.localAddress!
    let clientHandler = ClientHandler(remoteAddress: remoteAddress)

    let clientChannel = try! DatagramBootstrap(group: group)
        .channelOption(.explicitCongestionNotification, value: true)
        .channelInitializer { channel in
            channel.pipeline.addHandler(clientHandler)
        }
        .bind(to: localhostPickPort).wait()
    defer {
        try! clientChannel.close().wait()
    }

    measure(identifier: identifier) {
        clientHandler.sendBytesAndWaitForReply(clientChannel: clientChannel)
    }
}
