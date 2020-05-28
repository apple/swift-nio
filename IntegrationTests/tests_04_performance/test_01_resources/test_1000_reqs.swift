//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

fileprivate final class ServerEchoHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

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
        print("error: ", error)

        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        context.close(promise: nil)
    }
}

fileprivate final class ClientHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Count the data in.
        let byteBuffer = self.unwrapInboundIn(data)
        self.bytesOutstanding -= byteBuffer.readableBytes
        if self.bytesOutstanding == 0 {
            // If we still have iterations to do send some more data.
            if (self.iterationsOutstanding > 0) {
                self.iterationsOutstanding -= 1
                sendBytes(clientChannel: context.channel)
            } else {
                self.whenDone!.succeed(())
            }
        }
    }

    // Flush it out. This can make use of gathering writes if multiple buffers are pending
    public func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error: ", error)

        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        context.close(promise: nil)
    }
    
    let pileOfBytes: [UInt8] = .init(repeating: 5, count: 1000)
    
    var iterationsOutstanding = 0
    var bytesOutstanding = 0
    var whenDone: EventLoopPromise<()>? = nil
    
    private func sendBytes(clientChannel: Channel) {
        bytesOutstanding += pileOfBytes.count
        var buffer = clientChannel.allocator.buffer(capacity: pileOfBytes.count)
        buffer.writeBytes(pileOfBytes)
        clientChannel.writeAndFlush(NIOAny(buffer), promise: nil)
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
    let serverChannel = try! ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ServerEchoHandler())
            }.bind(to: localhostPickPort).wait()
    defer {
        try! serverChannel.close().wait()
    }
    
    let clientHandler = ClientHandler()
    let clientChannel = try! ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.pipeline.addHandler(clientHandler)
        }
        .connect(to: serverChannel.localAddress!)
        .wait()
    defer {
        try! clientChannel.close().wait()
    }
    
    measure(identifier: identifier) {
        clientHandler.sendBytesAndWaitForReply(clientChannel: clientChannel)
    }
}

