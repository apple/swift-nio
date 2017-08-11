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
import Foundation
import NIO


private final class EchoHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    public func channelRead(ctx: ChannelHandlerContext, data: IOData) {
        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        ctx.write(data: data, promise: nil)
    }

    // Flush it out. This can make use of gathering writes if multiple buffers are pending
    public func channelReadComplete(ctx: ChannelHandlerContext) {
        
        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        ctx.flush(promise: nil)
    }

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        print("error: ", error)
        
        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        ctx.close(promise: nil)
    }
}
let group = try MultiThreadedEventLoopGroup(numThreads: 1)
let bootstrap = ServerBootstrap(group: group)
    // Specify backlog and enable SO_REUSEADDR for the server itself
    .option(option: ChannelOptions.Backlog, value: 256)
    .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

    // Set the handlers that are appled to the accepted Channels
    .handler(childHandler: ChannelInitializer(initChannel: { channel in
        // Ensure we not read faster then we can write by adding the BackPressureHandler into the pipeline.
        return channel.pipeline.add(handler: BackPressureHandler()).then(callback: { v in
            return channel.pipeline.add(handler: EchoHandler())
        })
    }))

    // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
    .option(childOption: ChannelOptions.Socket(IPPROTO_TCP, TCP_NODELAY), childValue: 1)
    .option(childOption: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), childValue: 1)
    .option(childOption: ChannelOptions.MaxMessagesPerRead, childValue: 16)
    .option(childOption: ChannelOptions.RecvAllocator, childValue: FixedSizeRecvByteBufferAllocator(capacity: 8192))
defer {
    _ = try? group.close()
}

// First argument is the program path
let arguments = CommandLine.arguments
let arg1 = arguments.dropFirst().first
let arg2 = arguments.dropFirst().dropFirst().first

var host: String = "::1"
var port: Int32 = 9999
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
