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
import NIOHTTP1

private class HTTPHandler : ChannelInboundHandler {
    public typealias InboundIn = HTTPRequest
    public typealias OutboundOut = HTTPResponse

    private var buffer: ByteBuffer? = nil
    private var keepAlive = false

    func channelRead(ctx: ChannelHandlerContext, data: IOData) {

        if let reqPart = self.tryUnwrapInboundIn(data) {
            switch reqPart {
            case .head(let request):
                keepAlive = request.isKeepAlive

                var responseHead = HTTPResponseHead(version: request.version, status: HTTPResponseStatus.ok)
                responseHead.headers.add(name: "content-length", value: "12")
                let response = HTTPResponse.head(responseHead)
                ctx.write(data: self.wrapOutboundOut(response), promise: nil)
            case .body(let content):
                switch content {
                case .more(_):
                    break
                case .last:
                    let content = HTTPResponse.body(HTTPBodyContent.last(buffer: buffer!.slice()))
                    if keepAlive {
                        ctx.write(data: self.wrapOutboundOut(content), promise: nil)
                    } else {
                        ctx.write(data: self.wrapOutboundOut(content)).whenComplete(callback: { _ in
                            ctx.close(promise: nil)
                        })
                    }
                }
            }
        }
    }

    func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.flush(promise: nil)
    }

    func handlerAdded(ctx: ChannelHandlerContext) throws {
        buffer = ctx.channel!.allocator.buffer(capacity: 12)
        buffer!.write(staticString: "Hello World!")
    }
}

let group = try MultiThreadedEventLoopGroup(numThreads: 1)
let bootstrap = ServerBootstrap(group: group)
    // Specify backlog and enable SO_REUSEADDR for the server itself
    .option(option: ChannelOptions.Backlog, value: 256)
    .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

    // Set the handlers that are applied to the accepted Channels
    .handler(childHandler: ChannelInitializer(initChannel: { channel in
        return channel.pipeline.add(handler: HTTPResponseEncoder()).then(callback: { v2 in
            return channel.pipeline.add(handler: HTTPRequestDecoder()).then(callback: { v2 in
                return channel.pipeline.add(handler: HTTPHandler())
            })
        })
    }))

    // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
    .option(childOption: ChannelOptions.Socket(IPPROTO_TCP, TCP_NODELAY), childValue: 1)
    .option(childOption: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), childValue: 1)
    .option(childOption: ChannelOptions.MaxMessagesPerRead, childValue: 1)

defer {
    _ = try? group.close()
}

// First argument is the program path
let arguments = CommandLine.arguments
let port = arguments.count == 2 ? Int32(arguments[1])! : 8888

let channel = try bootstrap.bind(to: "0.0.0.0", on: port).wait()

print("Server started and listening on 0.0.0.0:\(port)")

// This will never unblock as we not close the ServerChannel
try channel.closeFuture.wait()

print("Server closed")
