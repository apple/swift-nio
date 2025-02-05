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

print("Please enter line to send to the server")
let line = readLine(strippingNewline: true)!

private final class EchoHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
    private var sendBytes = 0
    private var receiveBuffer: ByteBuffer = ByteBuffer()

    public func channelActive(context: ChannelHandlerContext) {
        print("Client connected to \(context.remoteAddress?.description ?? "unknown")")

        // We are connected. It's time to send the message to the server to initialize the ping-pong sequence.
        let buffer = context.channel.allocator.buffer(string: line)
        self.sendBytes = buffer.readableBytes
        context.writeAndFlush(Self.wrapOutboundOut(buffer), promise: nil)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var unwrappedInboundData = Self.unwrapInboundIn(data)
        self.sendBytes -= unwrappedInboundData.readableBytes
        receiveBuffer.writeBuffer(&unwrappedInboundData)

        if self.sendBytes == 0 {
            let string = String(buffer: receiveBuffer)
            print("Received: '\(string)' back from the server, closing channel.")
            context.close(promise: nil)
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error: ", error)

        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        context.close(promise: nil)
    }
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let bootstrap = ClientBootstrap(group: group)
    // Enable SO_REUSEADDR.
    .channelOption(.socketOption(.so_reuseaddr), value: 1)
    .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(EchoHandler())
        }
    }
defer {
    try! group.syncShutdownGracefully()
}

// First argument is the program path
let arguments = CommandLine.arguments
let arg1 = arguments.dropFirst().first
let arg2 = arguments.dropFirst(2).first

let defaultHost = "::1"
let defaultPort: Int = 9999

enum ConnectTo {
    case ip(host: String, port: Int)
    case unixDomainSocket(path: String)
    case vsock(_: VsockAddress)
}

let connectTarget: ConnectTo
switch (arg1, arg1.flatMap(Int.init), arg2.flatMap(Int.init)) {
case (_, .some(let cid), .some(let port)):
    // we got two arguments (Int, Int), let's interpret that as vsock cid and port
    connectTarget = .vsock(
        VsockAddress(
            cid: VsockAddress.ContextID(cid),
            port: VsockAddress.Port(port)
        )
    )
case (.some(let h), .none, .some(let p)):
    // we got two arguments (String, Int), let's interpret that as host and port
    connectTarget = .ip(host: h, port: p)
case (.some(let portString), .none, .none):
    // we got one argument (String), let's interpret that as unix domain socket path
    connectTarget = .unixDomainSocket(path: portString)
case (_, .some(let p), _):
    // we got one argument (Int), let's interpret that as port on default host
    connectTarget = .ip(host: defaultHost, port: p)
default:
    connectTarget = .ip(host: defaultHost, port: defaultPort)
}

let channel = try { () -> Channel in
    switch connectTarget {
    case .ip(let host, let port):
        return try bootstrap.connect(host: host, port: port).wait()
    case .unixDomainSocket(let path):
        return try bootstrap.connect(unixDomainSocketPath: path).wait()
    case .vsock(let vsockAddress):
        return try bootstrap.connect(to: vsockAddress).wait()
    }
}()

// Will be closed after we echo-ed back to the server.
try channel.closeFuture.wait()

print("Client closed")
