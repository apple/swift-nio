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
import NIOCore
import NIOPosix

private final class EchoHandler: ChannelInboundHandler {
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

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

// We don't need more than one thread, as we're creating only one datagram channel.
let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
var bootstrap = DatagramBootstrap(group: group)
    // Specify backlog and enable SO_REUSEADDR
    .channelOption(.socketOption(.so_reuseaddr), value: 1)

    // Set the handlers that are applied to the bound channel
    .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(EchoHandler())
        }
    }

defer {
    try! group.syncShutdownGracefully()
}

var arguments = CommandLine.arguments.dropFirst(0)  // just to get an ArraySlice<String> from [String]
if arguments.dropFirst().first == .some("--enable-gathering-reads") {
    bootstrap = bootstrap.channelOption(.datagramVectorReadMessageCount, value: 30)
    bootstrap = bootstrap.channelOption(
        .recvAllocator,
        value: FixedSizeRecvByteBufferAllocator(capacity: 30 * 2048)
    )
    arguments = arguments.dropFirst()
}
let arg1 = arguments.dropFirst().first
let arg2 = arguments.dropFirst().dropFirst().first

let defaultHost = "::1"
let defaultPort = 9999

enum BindTo {
    case ip(host: String, port: Int)
    case unixDomainSocket(path: String)
}

let bindTarget: BindTo
switch (arg1, arg1.flatMap(Int.init), arg2.flatMap(Int.init)) {
case (.some(let h), _, .some(let p)):
    // we got two arguments, let's interpret that as host and port
    bindTarget = .ip(host: h, port: p)
case (.some(let portString), .none, _):
    // couldn't parse as number, expecting unix domain socket path
    bindTarget = .unixDomainSocket(path: portString)
case (_, .some(let p), _):
    // only one argument --> port
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

print("Server started and listening on \(channel.localAddress!)")

// This will never unblock as we don't close the channel
try channel.closeFuture.wait()

print("Server closed")
