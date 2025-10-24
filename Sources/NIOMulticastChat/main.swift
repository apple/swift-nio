//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import CNIOLinux
import CNIOOpenBSD
import NIOCore
import NIOPosix

/// Implements a simple chat protocol.
private final class ChatMessageDecoder: ChannelInboundHandler {
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = Self.unwrapInboundIn(data)
        var buffer = envelope.data

        // To begin with, the chat messages are simply whole datagrams, no other length.
        guard let message = buffer.readString(length: buffer.readableBytes) else {
            print("Error: invalid string received")
            return
        }

        print("\(envelope.remoteAddress): \(message)")
    }
}

private final class ChatMessageEncoder: ChannelOutboundHandler {
    public typealias OutboundIn = AddressedEnvelope<String>
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = Self.unwrapOutboundIn(data)
        let buffer = context.channel.allocator.buffer(string: message.data)
        context.write(
            Self.wrapOutboundOut(AddressedEnvelope(remoteAddress: message.remoteAddress, data: buffer)),
            promise: promise
        )
    }
}

// We allow users to specify the interface they want to use here.
let targetDevice: NIONetworkDevice? = {
    if let interfaceAddress = CommandLine.arguments.dropFirst().first,
        let targetAddress = try? SocketAddress(ipAddress: interfaceAddress, port: 0)
    {
        for device in try! System.enumerateDevices() {
            if device.address == targetAddress {
                return device
            }
        }
        fatalError("Could not find device for \(interfaceAddress)")
    }
    return nil
}()

// For this chat protocol we temporarily squat on 224.1.0.26. This is a reserved multicast IPv4 address,
// so your machine is unlikely to have already joined this group. That helps properly demonstrate correct
// operation. We use port 7654 because, well, because why not.
let chatMulticastGroup = try! SocketAddress(ipAddress: "224.1.0.26", port: 7654)
let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

// Begin by setting up the basics of the bootstrap.
var datagramBootstrap = DatagramBootstrap(group: group)
    .channelOption(.socketOption(.so_reuseaddr), value: 1)
    .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandlers(ChatMessageEncoder(), ChatMessageDecoder())
        }
    }

// We cast our channel to MulticastChannel to obtain the multicast operations.
let datagramChannel =
    try datagramBootstrap
    .bind(host: "0.0.0.0", port: 7654)
    .flatMap { channel -> EventLoopFuture<Channel> in
        let channel = channel as! MulticastChannel
        return channel.joinGroup(chatMulticastGroup, device: targetDevice).map { channel }
    }.flatMap { channel -> EventLoopFuture<Channel> in
        guard let targetDevice = targetDevice else {
            return channel.eventLoop.makeSucceededFuture(channel)
        }

        let provider = channel as! SocketOptionProvider
        switch targetDevice.address {
        case .some(.v4(let addr)):
            return provider.setIPMulticastIF(addr.address.sin_addr).map { channel }
        case .some(.v6):
            return provider.setIPv6MulticastIF(CUnsignedInt(targetDevice.interfaceIndex)).map { channel }
        case .some(.unixDomainSocket):
            preconditionFailure("Should not be possible to create a multicast socket on a unix domain socket")
        case .none:
            preconditionFailure(
                "Should not be possible to create a multicast socket on an interface without an address"
            )
        }
    }.wait()

print("Now broadcasting, happy chatting.\nPress ^D to exit.")

while let line = readLine(strippingNewline: false) {
    datagramChannel.writeAndFlush(AddressedEnvelope(remoteAddress: chatMulticastGroup, data: line), promise: nil)
}

// Close the channel.
try! datagramChannel.close().wait()
try! group.syncShutdownGracefully()
