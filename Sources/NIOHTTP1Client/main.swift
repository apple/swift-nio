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
import NIOHTTP1
import NIOPosix

print("Please enter line to send to the server")
let line = readLine(strippingNewline: true)!

private final class HTTPEchoHandler: ChannelInboundHandler {
    public typealias InboundIn = HTTPClientResponsePart
    public typealias OutboundOut = HTTPClientRequestPart

    public func channelActive(context: ChannelHandlerContext) {
        // In production code, you should check if `context.remoteAddress` is actually
        // present, as in rare situations it can be `nil`.
        print("Client connected to \(context.remoteAddress!)")

        // We are connected. It's time to send the message to the server to initialize the ping-pong sequence.

        let buffer = context.channel.allocator.buffer(string: line)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(buffer.readableBytes)")

        // This sample only sends an echo request.
        // The sample server has more functionality which can be easily tested by playing with the URI.
        // For example, try "/dynamic/count-to-ten" or "/dynamic/client-ip"

        let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/dynamic/echo",
            headers: headers
        )

        context.write(Self.wrapOutboundOut(.head(requestHead)), promise: nil)

        context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {

        let clientResponse = Self.unwrapInboundIn(data)

        switch clientResponse {
        case .head(let responseHead):
            print("Received status: \(responseHead.status)")
        case .body(let byteBuffer):
            let string = String(buffer: byteBuffer)
            print("Received: '\(string)' back from the server.")
        case .end:
            print("Closing channel.")
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
            try channel.pipeline.syncOperations.addHTTPClientHandlers(
                position: .first,
                leftOverBytesStrategy: .fireError
            )
            try channel.pipeline.syncOperations.addHandler(HTTPEchoHandler())
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
let defaultPort: Int = 8888

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

// Will be closed after we echo-ed back to the server.
try channel.closeFuture.wait()

print("Client closed")
