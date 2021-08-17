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
import NIOHTTP1
import NIOWebSocket

print("Establishing connection.")

enum ConnectTo {
    case ip(host: String, port: Int)
    case unixDomainSocket(path: String)
}

// The HTTP handler to be used to initiate the request.
// This initial request will be adapted by the WebSocket upgrader to contain the upgrade header parameters.
// Channel read will only be called if the upgrade fails.

private final class HTTPInitialRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPClientResponsePart
    public typealias OutboundOut = HTTPClientRequestPart

    public let target: ConnectTo

    public init(target: ConnectTo) {
        self.target = target
    }
    
    public func channelActive(context: ChannelHandlerContext) {
        print("Client connected to \(context.remoteAddress!)")

        // We are connected. It's time to send the message to the server to initialize the upgrade dance.
        var headers = HTTPHeaders()
        if case let .ip(host: host, port: port) = target {
            headers.add(name: "Host", value: "\(host):\(port)")
        }
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(0)")
        
        let requestHead = HTTPRequestHead(version: .http1_1,
                                          method: .GET,
                                          uri: "/",
                                          headers: headers)
        
        context.write(self.wrapOutboundOut(.head(requestHead)), promise: nil)
        
        let body = HTTPClientRequestPart.body(.byteBuffer(ByteBuffer()))
        context.write(self.wrapOutboundOut(body), promise: nil)
        
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        
        let clientResponse = self.unwrapInboundIn(data)
        
        print("Upgrade failed")
        
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
    
    public func handlerRemoved(context: ChannelHandlerContext) {
        print("HTTP handler removed.")
    }
    
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error: ", error)
        
        // As we are not really interested getting notified on success or failure
        // we just pass nil as promise to reduce allocations.
        context.close(promise: nil)
    }
}

// The web socket handler to be used once the upgrade has occurred.
// One added, it sends a ping-pong round trip with "Hello World" data.
// It also listens for any text frames from the server and prints them.

private final class WebSocketPingPongHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    
    let testFrameData: String = "Hello World"
    
    // This is being hit, channel active won't be called as it is already added.
    public func handlerAdded(context: ChannelHandlerContext) {
        print("WebSocket handler added.")
        self.pingTestFrameData(context: context)
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        print("WebSocket handler removed.")
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        
        switch frame.opcode {
        case .pong:
            self.pong(context: context, frame: frame)
        case .text:
            var data = frame.unmaskedData
            let text = data.readString(length: data.readableBytes) ?? ""
            print("Websocket: Received \(text)")
        case .connectionClose:
            self.receivedClose(context: context, frame: frame)
        case .binary, .continuation, .ping:
            // We ignore these frames.
            break
        default:
            // Unknown frames are errors.
            self.closeOnError(context: context)
        }
    }
    
    public func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    private func receivedClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
        // Handle a received close frame. We're just going to close.
        print("Received Close instruction from server")
        context.close(promise: nil)
    }
    
    private func pingTestFrameData(context: ChannelHandlerContext) {
        let buffer = context.channel.allocator.buffer(string: self.testFrameData)
        let frame = WebSocketFrame(fin: true, opcode: .ping, data: buffer)
        context.write(self.wrapOutboundOut(frame), promise: nil)
    }
    
    private func pong(context: ChannelHandlerContext, frame: WebSocketFrame) {
        var frameData = frame.data
        if let frameDataString = frameData.readString(length: self.testFrameData.count) {
            print("Websocket: Received: \(frameDataString)")
        }
    }
    
    private func closeOnError(context: ChannelHandlerContext) {
        // We have hit an error, we want to close. We do that by sending a close frame and then
        // shutting down the write side of the connection. The server will respond with a close of its own.
        var data = context.channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: .protocolError)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        context.write(self.wrapOutboundOut(frame)).whenComplete { (_: Result<Void, Error>) in
            context.close(mode: .output, promise: nil)
        }
    }
}

// First argument is the program path
let arguments = CommandLine.arguments
let arg1 = arguments.dropFirst().first
let arg2 = arguments.dropFirst(2).first

let defaultHost = "::1"
let defaultPort: Int = 8888

let connectTarget: ConnectTo
switch (arg1, arg1.flatMap(Int.init), arg2.flatMap(Int.init)) {
case (.some(let h), _ , .some(let p)):
    /* we got two arguments, let's interpret that as host and port */
    connectTarget = .ip(host: h, port: p)
case (.some(let portString), .none, _):
    /* couldn't parse as number, expecting unix domain socket path */
    connectTarget = .unixDomainSocket(path: portString)
case (_, .some(let p), _):
    /* only one argument --> port */
    connectTarget = .ip(host: defaultHost, port: p)
default:
    connectTarget = .ip(host: defaultHost, port: defaultPort)
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let bootstrap = ClientBootstrap(group: group)
    // Enable SO_REUSEADDR.
    .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .channelInitializer { channel in

        let httpHandler = HTTPInitialRequestHandler(target: connectTarget)

        let websocketUpgrader = NIOWebSocketClientUpgrader(requestKey: "OfS0wDaT5NoxF2gqm7Zj2YtetzM=",
                                                           upgradePipelineHandler: { (channel: Channel, _: HTTPResponseHead) in
            channel.pipeline.addHandler(WebSocketPingPongHandler())
        })

        let config: NIOHTTPClientUpgradeConfiguration = (
            upgraders: [ websocketUpgrader ],
            completionHandler: { _ in
                channel.pipeline.removeHandler(httpHandler, promise: nil)
        })

        return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMap {
            channel.pipeline.addHandler(httpHandler)
        }
}
defer {
    try! group.syncShutdownGracefully()
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
