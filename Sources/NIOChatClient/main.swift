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

private final class ChatHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = Self.unwrapInboundIn(data)
        print(String(buffer: buffer))
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
            try channel.pipeline.syncOperations.addHandler(ChatHandler())
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
let defaultPort = 9999

enum ConnectTo {
    case ip(host: String, port: Int)
    case unixDomainSocket(path: String)
}

let connectTarget: ConnectTo
switch (arg1, arg1.flatMap(Int.init), arg2.flatMap(Int.init)) {
case (.some(let h), _, .some(let p)):
    // we got two arguments, let's interpret that as host and port
    connectTarget = .ip(host: h, port: p)
case (.some(let portString), .none, _):
    // couldn't parse as number, expecting unix domain socket path
    connectTarget = .unixDomainSocket(path: portString)
case (_, .some(let p), _):
    // only one argument --> port
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
    }
}()

// In production code, you should check if `channel.remoteAddress` is actually
// present, as in rare situations it can be `nil`.
print("ChatClient connected to ChatServer: \(channel.remoteAddress!), happy chatting\n. Press ^D to exit.")

while let line = readLine(strippingNewline: false) {
    let buffer = channel.allocator.buffer(string: line)
    try! channel.writeAndFlush(buffer).wait()
}

// EOF, close connect
try! channel.close().wait()

print("ChatClient closed")
