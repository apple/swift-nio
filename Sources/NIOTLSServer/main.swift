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

import struct Foundation.URL
import NIO
import NIOOpenSSL
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#elseif os(Linux)
    import Glibc
#endif

private final class EchoHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let _ = ctx.writeAndFlush(data: data)
    }
}

let sslContext = try! SSLContext(configuration: TLSConfiguration.forServer(certificateChain: [.file("cert.pem")], privateKey: .file("key.pem")))


let group = MultiThreadedEventLoopGroup(numThreads: 1)
let bootstrap = ServerBootstrap(group: group)
    // Specify backlog and enable SO_REUSEADDR for the server itself
    .option(option: ChannelOptions.Backlog, value: 256)
    .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
    
    // Set the handlers that are applied to the accepted channels.
    .handler(childHandler: ChannelInitializer(initChannel: { channel in
        return channel.pipeline.add(handler: try! OpenSSLServerHandler(context: sslContext)).then(callback: { v2 in
            return channel.pipeline.add(handler: EchoHandler())
        })
    }))
    
    // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
    .option(childOption: ChannelOptions.Socket(IPPROTO_TCP, TCP_NODELAY), childValue: 1)
    .option(childOption: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), childValue: 1)
    .option(childOption: ChannelOptions.MaxMessagesPerRead, childValue: 1)

defer {
    try! group.syncShutdownGracefully()
}

// First argument is the program path
let arguments = CommandLine.arguments
let arg1 = arguments.dropFirst().first
let arg2 = arguments.dropFirst().dropFirst().first

var host: String = "::1"
var port: Int32 = 4433
switch (arg1, arg1.flatMap { Int32($0) }, arg2.flatMap { Int32($0) }) {
case (.some(let h), _ , .some(let p)):
    /* we got two arguments, let's interpret that as host and port */
    host = h
    port = p
case (_, .some(let p), _):
    /* only one argument --> port */
    port = p
default:
    ()
}

let channel = try bootstrap.bind(to: host, on: port).wait()

print("Server started and listening on \(channel.localAddress!)")

// This will never unblock as we not close the ServerChannel
try channel.closeFuture.wait()

print("Server closed")
