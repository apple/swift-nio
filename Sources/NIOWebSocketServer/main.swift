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

let websocketResponse = """
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Swift NIO WebSocket Test Page</title>
    <script>
        var wsconnection = new WebSocket("ws://localhost:8888/websocket");
        wsconnection.onmessage = function (msg) {
            var element = document.createElement("p");
            element.innerHTML = msg.data;

            var textDiv = document.getElementById("websocket-stream");
            textDiv.insertBefore(element, null);
        };
    </script>
  </head>
  <body>
    <h1>WebSocket Stream</h1>
    <div id="websocket-stream"></div>
  </body>
</html>
"""

private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var responseBody: ByteBuffer!

    func handlerAdded(context: ChannelHandlerContext) {
        self.responseBody = context.channel.allocator.buffer(string: websocketResponse)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.responseBody = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)

        // We're not interested in request bodies here: we're just serving up GET responses
        // to get the client to initiate a websocket request.
        guard case .head(let head) = reqPart else {
            return
        }

        // GETs only.
        guard case .GET = head.method else {
            self.respond405(context: context)
            return
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/html")
        headers.add(name: "Content-Length", value: String(self.responseBody.readableBytes))
        headers.add(name: "Connection", value: "close")
        let responseHead = HTTPResponseHead(version: .init(major: 1, minor: 1),
                                    status: .ok,
                                    headers: headers)
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(self.responseBody))), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil))).whenComplete { (_: Result<Void, Error>) in
            context.close(promise: nil)
        }
        context.flush()
    }

    private func respond405(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPResponseHead(version: .http1_1,
                                    status: .methodNotAllowed,
                                    headers: headers)
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil))).whenComplete { (_: Result<Void, Error>) in
            context.close(promise: nil)
        }
        context.flush()
    }
}

private final class WebSocketTimeHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private var awaitingClose: Bool = false

    public func handlerAdded(context: ChannelHandlerContext) {
        self.sendTime(context: context)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.opcode {
        case .connectionClose:
            self.receivedClose(context: context, frame: frame)
        case .ping:
            self.pong(context: context, frame: frame)
        case .text:
            var data = frame.unmaskedData
            let text = data.readString(length: data.readableBytes) ?? ""
            print(text)
        case .binary, .continuation, .pong:
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

    private func sendTime(context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }

        // We can't send if we sent a close message.
        guard !self.awaitingClose else { return }

        // We can't really check for error here, but it's also not the purpose of the
        // example so let's not worry about it.
        let theTime = NIODeadline.now().uptimeNanoseconds
        var buffer = context.channel.allocator.buffer(capacity: 12)
        buffer.writeString("\(theTime)")

        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        context.writeAndFlush(self.wrapOutboundOut(frame)).map {
            context.eventLoop.scheduleTask(in: .seconds(1), { self.sendTime(context: context) })
        }.whenFailure { (_: Error) in
            context.close(promise: nil)
        }
    }

    private func receivedClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
        // Handle a received close frame. In websockets, we're just going to send the close
        // frame and then close, unless we already sent our own close frame.
        if awaitingClose {
            // Cool, we started the close and were waiting for the user. We're done.
            context.close(promise: nil)
        } else {
            // This is an unsolicited close. We're going to send a response frame and
            // then, when we've sent it, close up shop. We should send back the close code the remote
            // peer sent us, unless they didn't send one at all.
            var data = frame.unmaskedData
            let closeDataCode = data.readSlice(length: 2) ?? ByteBuffer()
            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
            _ = context.write(self.wrapOutboundOut(closeFrame)).map { () in
                context.close(promise: nil)
            }
        }
    }

    private func pong(context: ChannelHandlerContext, frame: WebSocketFrame) {
        var frameData = frame.data
        let maskingKey = frame.maskKey

        if let maskingKey = maskingKey {
            frameData.webSocketUnmask(maskingKey)
        }

        let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
        context.write(self.wrapOutboundOut(responseFrame), promise: nil)
    }

    private func closeOnError(context: ChannelHandlerContext) {
        // We have hit an error, we want to close. We do that by sending a close frame and then
        // shutting down the write side of the connection.
        var data = context.channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: .protocolError)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        context.write(self.wrapOutboundOut(frame)).whenComplete { (_: Result<Void, Error>) in
            context.close(mode: .output, promise: nil)
        }
        awaitingClose = true
    }
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

let upgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                                 upgradePipelineHandler: { (channel: Channel, _: HTTPRequestHead) in
                                    channel.pipeline.addHandler(WebSocketTimeHandler())
                                 })

let bootstrap = ServerBootstrap(group: group)
    // Specify backlog and enable SO_REUSEADDR for the server itself
    .serverChannelOption(ChannelOptions.backlog, value: 256)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

    // Set the handlers that are applied to the accepted Channels
    .childChannelInitializer { channel in
        let httpHandler = HTTPHandler()
        let config: NIOHTTPServerUpgradeConfiguration = (
                        upgraders: [ upgrader ],
                        completionHandler: { _ in
                            channel.pipeline.removeHandler(httpHandler, promise: nil)
                        }
                    )
        return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config).flatMap {
            channel.pipeline.addHandler(httpHandler)
        }
    }

    // Enable SO_REUSEADDR for the accepted Channels
    .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

defer {
    try! group.syncShutdownGracefully()
}

// First argument is the program path
let arguments = CommandLine.arguments
let arg1 = arguments.dropFirst().first
let arg2 = arguments.dropFirst(2).first

let defaultHost = "localhost"
let defaultPort = 8888

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

// This will never unblock as we don't close the ServerChannel
try channel.closeFuture.wait()

print("Server closed")
