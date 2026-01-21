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
let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
let bootstrap = ServerBootstrap(group: group)
    // Specify backlog and enable SO_REUSEADDR for the server itself
    .serverChannelOption(.backlog, value: 256)
    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)

    // Set the handlers that are appled to the accepted Channels
    .childChannelInitializer { channel in
        // Ensure we don't read faster than we can write by adding the BackPressureHandler into the pipeline.
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(BackPressureHandler())
            try channel.pipeline.syncOperations.addHandler(EchoHandler())
        }
    }

    // Enable SO_REUSEADDR for the accepted Channels
    .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
    .childChannelOption(.maxMessagesPerRead, value: 16)
    .childChannelOption(.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
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
    case vsock(_: VsockAddress)
}

let bindTarget: BindTo
switch (arg1, arg1.flatMap(Int.init), arg2.flatMap(Int.init)) {
case (_, .some(let cid), .some(let port)):
    // we got two arguments (Int, Int), let's interpret that as vsock cid and port
    bindTarget = .vsock(
        VsockAddress(
            cid: VsockAddress.ContextID(cid),
            port: VsockAddress.Port(port)
        )
    )
case (.some(let h), _, .some(let p)):
    // we got two arguments (String, Int), let's interpret that as host and port
    bindTarget = .ip(host: h, port: p)
case (.some(let pathString), .none, .none):
    // we got one argument (String), let's interpret that unix domain socket path
    bindTarget = .unixDomainSocket(path: pathString)
case (_, .some(let p), .none):
    // we got one argument (Int), let's interpret that as port on default host
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
    case .vsock(let vsockAddress):
        return try bootstrap.bind(to: vsockAddress).wait()
    }
}()

switch bindTarget {
case .ip, .unixDomainSocket:
    print("Server started and listening on \(channel.localAddress!)")
case .vsock(let vsockAddress):
    print("Server started and listening on \(vsockAddress)")
}

// This will never unblock as we don't close the ServerChannel
try channel.closeFuture.wait()

print("Server closed")
