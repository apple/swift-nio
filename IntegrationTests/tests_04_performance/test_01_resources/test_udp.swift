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

func run(identifier: String) {
    measure(identifier: identifier) {
        var numberDone = 1
        for _ in 0..<10 {
            let newDones = try! doUdpRequests(group: group, number: 1000)
            precondition(newDones == 1000)
            numberDone += newDones
        }
        return numberDone
    }
}

// MARK: Share?
/// Repeatedly send, echo and receive a number of UDP requests.
/// Based on the UDPEchoClient/Server example.

private final class EchoHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        context.write(data, promise: nil)
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        context.flush()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error: ", error)

        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        context.close(promise: nil)
    }
}

private final class EchoHandlerClient: ChannelInboundHandler {
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>
    private var numBytesOutstanding = 0
    private var repetitionsRemaining : Int
    
    private let remoteAddressInitializer: () throws -> SocketAddress
    
    init(remoteAddressInitializer: @escaping () throws -> SocketAddress,
         numberOfRepetitions: Int) {
        self.remoteAddressInitializer = remoteAddressInitializer
        self.repetitionsRemaining = numberOfRepetitions
    }
    
    public func channelActive(context: ChannelHandlerContext) {
        // Channel is available. It's time to send the message to the server to initialize the ping-pong sequence.
        sendSomeDataIfDesiredOrClose(context: context)
    }
    
    private func sendSomeDataIfDesiredOrClose(context: ChannelHandlerContext) {
        if (repetitionsRemaining > 0) {
            do {
                repetitionsRemaining -= 1
                
                // Get the server address.
                let remoteAddress = try self.remoteAddressInitializer()
                
                // Set the transmission data.
                let line = "Something to send there and back again."
                var buffer = context.channel.allocator.buffer(capacity: line.utf8.count)
                buffer.writeString(line)
                self.numBytesOutstanding += buffer.readableBytes
                
                // Forward the data.
                let envolope = AddressedEnvelope<ByteBuffer>(remoteAddress: remoteAddress, data: buffer)
                
                context.writeAndFlush(self.wrapOutboundOut(envolope), promise: nil)
                
            } catch {
                print("Could not resolve remote address")
            }
        }
        else {
            // We're all done - hurrah!
            context.close(promise: nil)
        }
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = self.unwrapInboundIn(data)
        let byteBuffer = envelope.data
        
        self.numBytesOutstanding -= byteBuffer.readableBytes
        
        if self.numBytesOutstanding <= 0 {
            // Got back everything we sent - maybe send some more.
            sendSomeDataIfDesiredOrClose(context: context)
        }
    }
    
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error: ", error)
        
        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        context.close(promise: nil)
    }
}

func doUdpRequests(group: EventLoopGroup, number numberOfRequests: Int) throws -> Int {
    let serverChannel = try DatagramBootstrap(group: group)
        .channelOption(ChannelOptions.socketOption(.reuseaddr), value: 1)
        // Set the handlers that are applied to the bound channel
        .channelInitializer { channel in
            // Ensure we don't read faster than we can write by adding the BackPressureHandler into the pipeline.
            return channel.pipeline.addHandler(EchoHandler())
        }
        .bind(to: localhostPickPort).wait()

    defer {
        try! serverChannel.close().wait()
    }
    
    let remoteAddress = { () -> SocketAddress in serverChannel.localAddress! }

    let clientChannel = try DatagramBootstrap(group: group)
        // Enable SO_REUSEADDR.
        .channelOption(ChannelOptions.socketOption(.reuseaddr), value: 1)
        .channelInitializer { channel in
            channel.pipeline.addHandler(EchoHandlerClient(remoteAddressInitializer: remoteAddress, numberOfRepetitions: numberOfRequests))
        }
        .bind(to: localhostPickPort).wait()

    // Will be closed after all the work is done and replies received.
    try clientChannel.closeFuture.wait()
    return numberOfRequests
}
