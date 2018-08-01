//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIO
import Dispatch

private let newLine = "\n".utf8.first!

/// Very simple example codec which will buffer inbound data until a `\n` was found.
final class LineDelimiterCodec: ByteToMessageDecoder {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer

    public var cumulationBuffer: ByteBuffer?

    public func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let readable = buffer.withUnsafeReadableBytes { $0.index(of: newLine) }
        if let r = readable {
            ctx.fireChannelRead(self.wrapInboundOut(buffer.readSlice(length: r + 1)!))
            return .continue
        }
        return .needMoreData
    }
}

/// This `ChannelInboundHandler` demonstrates a few things:
///   * Synchronisation between `EventLoop`s.
///   * Mixing `Dispatch` and SwiftNIO.
///   * `Channel`s are thread-safe, `ChannelHandlerContext`s are not.
///
/// As we are using an `MultiThreadedEventLoopGroup` that uses more then 1 thread we need to ensure proper
/// synchronization on the shared state in the `ChatHandler` (as the same instance is shared across
/// child `Channel`s). For this a serial `DispatchQueue` is used when we modify the shared state (the `Dictionary`).
/// As `ChannelHandlerContext` is not thread-safe we need to ensure we only operate on the `Channel` itself while
/// `Dispatch` executed the submitted block.
final class ChatHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    // All access to channels is guarded by channelsSyncQueue.
    private let channelsSyncQueue = DispatchQueue(label: "channelsQueue")
    private var channels: [ObjectIdentifier: Channel] = [:]

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let id = ObjectIdentifier(ctx.channel)
        var read = self.unwrapInboundIn(data)

        // 64 should be good enough for the ipaddress
        var buffer = ctx.channel.allocator.buffer(capacity: read.readableBytes + 64)
        buffer.write(string: "(\(ctx.remoteAddress!)) - ")
        buffer.write(buffer: &read)
        self.channelsSyncQueue.async {
            // broadcast the message to all the connected clients except the one that wrote it.
            self.writeToAll(channels: self.channels.filter { id != $0.key }, buffer: buffer)
        }
    }

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        print("error: ", error)

        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        ctx.close(promise: nil)
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        let remoteAddress = ctx.remoteAddress!
        let channel = ctx.channel
        self.channelsSyncQueue.async {
            // broadcast the message to all the connected clients except the one that just became active.
            self.writeToAll(channels: self.channels, allocator: channel.allocator, message: "(ChatServer) - New client connected with address: \(remoteAddress)\n")

            self.channels[ObjectIdentifier(channel)] = channel
        }

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.write(string: "(ChatServer) - Welcome to: \(ctx.localAddress!)\n")
        ctx.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
    }

    public func channelInactive(ctx: ChannelHandlerContext) {
        let channel = ctx.channel
        self.channelsSyncQueue.async {
            if self.channels.removeValue(forKey: ObjectIdentifier(channel)) != nil {
                // Broadcast the message to all the connected clients except the one that just was disconnected.
                self.writeToAll(channels: self.channels, allocator: channel.allocator, message: "(ChatServer) - Client disconnected\n")
            }
        }
    }

    private func writeToAll(channels: [ObjectIdentifier: Channel], allocator: ByteBufferAllocator, message: String) {
        var buffer =  allocator.buffer(capacity: message.utf8.count)
        buffer.write(string: message)
        self.writeToAll(channels: channels, buffer: buffer)
    }

    private func writeToAll(channels: [ObjectIdentifier: Channel], buffer: ByteBuffer) {
        channels.forEach { $0.value.writeAndFlush(buffer, promise: nil) }
    }
}

// We need to share the same ChatHandler for all as it keeps track of all
// connected clients. For this ChatHandler MUST be thread-safe!
let chatHandler = ChatHandler()

let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
let bootstrap = ServerBootstrap(group: group)
    // Specify backlog and enable SO_REUSEADDR for the server itself
    .serverChannelOption(ChannelOptions.backlog, value: 256)
    .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

    // Set the handlers that are applied to the accepted Channels
    .childChannelInitializer { channel in
        // Add handler that will buffer data until a \n is received
        channel.pipeline.add(handler: LineDelimiterCodec()).then { v in
            // It's important we use the same handler for all accepted channels. The ChatHandler is thread-safe!
            channel.pipeline.add(handler: chatHandler)
        }
    }

    // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
    .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
    .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
    .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
    .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
defer {
    try! group.syncShutdownGracefully()
}

// First argument is the program path
let arguments = CommandLine.arguments
let arg1 = arguments.dropFirst().first
let arg2 = arguments.dropFirst(2).first

let defaultHost = "::1"
let defaultPort = 9999

enum BindTo {
    case ip(host: String, port: Int)
    case unixDomainSocket(path: String)
}

let bindTarget: BindTo
switch (arg1, arg1.flatMap(Int.init), arg2.flatMap(Int.init)) {
case (.some(let h), _ , .some(let p)):
    /* we got two arguments, let's interpret that as host and port */
    bindTarget = .ip(host: h, port: p)

case (let portString?, .none, _):
    // Couldn't parse as number, expecting unix domain socket path.
    bindTarget = .unixDomainSocket(path: portString)

case (_, let p?, _):
    // Only one argument --> port.
    bindTarget = .ip(host: defaultHost, port: p)

default:
    bindTarget = .ip(host: defaultHost, port: defaultPort)
}

let channel = try { () -> Channel in
    switch bindTarget {
    case .ip(let host, let port):
        return try bootstrap.bind(host: host, port: port).wait()
    case .unixDomainSocket(let path):
        return try bootstrap.bind(unixDomainSocketPath: path).wait()
    }
}()

guard let localAddress = channel.localAddress else {
    fatalError("Address was unable to bind. Please check that the socket was not closed or that the address family was understood.")
}
print("Server started and listening on \(localAddress)")

// This will never unblock as we don't close the ServerChannel.
try channel.closeFuture.wait()

print("ChatServer closed")
