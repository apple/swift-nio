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
import NIO
import NIOHTTP1
import class Foundation.NSNull /* dummy just to get Foundation to link */

extension String {
    func chopPrefix(_ prefix: String) -> String? {
        if self.hasPrefix(prefix) {
            return String(self[self.index(self.startIndex, offsetBy: prefix.count)...])
        } else {
            return nil
        }
    }
}

private final class HTTPHandler: ChannelInboundHandler {
    private enum FileIOMethod {
        case sendfile
        case nonblockingFileIO
    }
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    private var buffer: ByteBuffer! = nil
    private var keepAlive = false
    private let htdocsPath: String

    private var infoSavedRequestHead: HTTPRequestHead?
    private var infoSavedBodyBytes: Int = 0

    private var continuousCount: Int = 0

    private var handler: ((ChannelHandlerContext, HTTPServerRequestPart) -> Void)? = nil
    private var handlerFuture: EventLoopFuture<()>?
    private let fileIO: NonBlockingFileIO

    public init(fileIO: NonBlockingFileIO, htdocsPath: String) {
        self.htdocsPath = htdocsPath
        self.fileIO = fileIO
    }

    func handleInfo(ctx: ChannelHandlerContext, request: HTTPServerRequestPart) {
        switch request {
        case .head(let request):
            self.infoSavedRequestHead = request
            self.infoSavedBodyBytes = 0
        case .body(buffer: let buf):
            self.infoSavedBodyBytes += buf.readableBytes
        case .end(_):
            let response = """
            HTTP method: \(self.infoSavedRequestHead!.method)\r
            URL: \(self.infoSavedRequestHead!.uri)\r
            body length: \(self.infoSavedBodyBytes)\r
            headers: \(self.infoSavedRequestHead!.headers)\r
            client: \(ctx.channel.remoteAddress?.description ?? "zombie")\r
            IO: SwiftNIO Electric Boogaloo™️\r\n
            """
            self.buffer.clear()
            self.buffer.write(string: response)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "\(response.utf8.count)")
            ctx.write(data: self.wrapOutboundOut(.head(HTTPResponseHead(version: self.infoSavedRequestHead!.version, status: .ok, headers: headers))), promise: nil)
            ctx.write(data: self.wrapOutboundOut(.body(.byteBuffer(self.buffer))), promise: nil)
            ctx.writeAndFlush(data: self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    func handleEcho(ctx: ChannelHandlerContext, request: HTTPServerRequestPart) {
        self.handleEcho(ctx: ctx, request: request, balloonInMemory: false)
    }

    func handleEcho(ctx: ChannelHandlerContext, request: HTTPServerRequestPart, balloonInMemory: Bool = false) {
        switch request {
        case .head(let request):
            if balloonInMemory {
                self.buffer.clear()
            } else {
                ctx.writeAndFlush(data: self.wrapOutboundOut(.head(.init(version: request.version, status: .ok))), promise: nil)
            }
        case .body(buffer: var buf):
            if balloonInMemory {
                self.buffer.write(buffer: &buf)
            } else {
                ctx.writeAndFlush(data: self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
            }
        case .end(_):
            if balloonInMemory {
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "\(self.buffer.readableBytes)")
                ctx.write(data: self.wrapOutboundOut(.head(HTTPResponseHead(version: HTTPVersion(major: 1, minor: 0), status: .ok, headers: headers))), promise: nil)
                ctx.write(data: self.wrapOutboundOut(.body(.byteBuffer(self.buffer))), promise: nil)
                ctx.write(data: self.wrapOutboundOut(.end(nil)), promise: nil)
            } else {
                ctx.writeAndFlush(data: self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }

    func handleJustWrite(ctx: ChannelHandlerContext, request: HTTPServerRequestPart, statusCode: HTTPResponseStatus = .ok, string: String, trailer: (String, String)? = nil, delay: TimeAmount = .nanoseconds(0)) {
        switch request {
        case .head(let request):
            ctx.writeAndFlush(data: self.wrapOutboundOut(.head(.init(version: request.version, status: .ok))), promise: nil)
        case .body(buffer: _):
            ()
        case .end(_):
            let _ = ctx.eventLoop.scheduleTask(in: delay) { () -> Void in
                var buf = ctx.channel.allocator.buffer(capacity: string.utf8.count)
                buf.write(string: string)
                ctx.writeAndFlush(data: self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
                var trailers: HTTPHeaders? = nil
                if let trailer = trailer {
                    trailers = HTTPHeaders()
                    trailers?.add(name: trailer.0, value: trailer.1)
                }
                ctx.writeAndFlush(data: self.wrapOutboundOut(.end(trailers)), promise: nil)
            }
        }
    }

    func handleContinuousWrites(ctx: ChannelHandlerContext, request: HTTPServerRequestPart) {
        switch request {
        case .head(let request):
            self.continuousCount = 0
            func doNext() {
                self.buffer.clear()
                self.continuousCount += 1
                self.buffer.write(string: "line \(self.continuousCount)\n")
                ctx.writeAndFlush(data: self.wrapOutboundOut(.body(.byteBuffer(self.buffer)))).whenComplete { res in
                    switch res {
                    case .success(()):
                        _ = ctx.eventLoop.scheduleTask(in: .milliseconds(400), doNext)
                    case .failure(_):
                        ctx.writeAndFlush(data: self.wrapOutboundOut(.end(nil)), promise: nil)
                    }
                }
            }
            ctx.writeAndFlush(data: self.wrapOutboundOut(.head(HTTPResponseHead(version: request.version, status: .ok))), promise: nil)
            doNext()
        default:
            ()
        }
    }

    func handleMultipleWrites(ctx: ChannelHandlerContext, request: HTTPServerRequestPart, strings: [String], delay: TimeAmount) {
        switch request {
        case .head(let request):
            self.continuousCount = 0
            func doNext() {
                self.buffer.clear()
                self.buffer.write(string: strings[self.continuousCount])
                ctx.writeAndFlush(data: self.wrapOutboundOut(.body(.byteBuffer(self.buffer)))).whenComplete { res in
                    switch res {
                    case .success(()):
                        if self.continuousCount < strings.count - 1 {
                            _ = ctx.eventLoop.scheduleTask(in: delay, doNext)
                        } else {
                            ctx.writeAndFlush(data: self.wrapOutboundOut(.end(nil)), promise: nil)
                        }
                    case .failure(_):
                        ()
                    }
                }
                self.continuousCount += 1
            }
            ctx.writeAndFlush(data: self.wrapOutboundOut(.head(HTTPResponseHead(version: request.version, status: .ok))), promise: nil)
            doNext()
        default:
            ()
        }
    }

    func dynamicHandler(request reqHead: HTTPRequestHead) -> ((ChannelHandlerContext, HTTPServerRequestPart) -> Void)? {
        switch reqHead.uri {
        case "/dynamic/echo":
            return self.handleEcho
        case "/dynamic/echo_balloon":
            return { self.handleEcho(ctx: $0, request: $1, balloonInMemory: true) }
        case "/dynamic/pid":
            return { ctx, req in self.handleJustWrite(ctx: ctx, request: req, string: "\(getpid())") }
        case "/dynamic/write-delay":
            return { ctx, req in self.handleJustWrite(ctx: ctx, request: req, string: "Hello World\r\n", delay: .milliseconds(100)) }
        case "/dynamic/info":
            return self.handleInfo
        case "/dynamic/trailers":
            return { ctx, req in self.handleJustWrite(ctx: ctx, request: req, string: "\(getpid())\r\n", trailer: ("Trailer-Key", "Trailer-Value")) }
        case "/dynamic/continuous":
            return self.handleContinuousWrites
        case "/dynamic/count-to-ten":
            return { self.handleMultipleWrites(ctx: $0, request: $1, strings: (1...10).map { "\($0)\r\n" }, delay: .milliseconds(100)) }
        case "/dynamic/client-ip":
            return { ctx, req in self.handleJustWrite(ctx: ctx, request: req, string: "\(ctx.channel.remoteAddress.debugDescription)") }
        default:
            return { ctx, req in self.handleJustWrite(ctx: ctx, request: req, statusCode: .notFound, string: "not found") }
        }
    }

    private func handleFile(ctx: ChannelHandlerContext, request: HTTPServerRequestPart, ioMethod: FileIOMethod, path: String) {
        self.buffer.clear()

        switch request {
        case .head(let request):
            guard !request.uri.contains("..") else {
                let response = HTTPResponseHead(version: request.version, status: .forbidden)
                ctx.write(data: self.wrapOutboundOut(.head(response)), promise: nil)
                ctx.writeAndFlush(data: self.wrapOutboundOut(.end(nil)), promise: nil)
                return
            }
            let path = self.htdocsPath + "/" + path
            do {
                let region = try FileRegion(file: path)
                var response = HTTPResponseHead(version: request.version, status: .ok)

                response.headers.add(name: "Content-Length", value: "\(region.endIndex)")
                response.headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")

                switch ioMethod {
                case .nonblockingFileIO:
                    var responseStarted = false
                    self.fileIO.readChunked(fileRegion: region,
                                            chunkSize: 32 * 1024,
                                            allocator: ctx.channel.allocator,
                                            eventLoop: ctx.eventLoop) { buffer in
                                                if !responseStarted {
                                                    responseStarted = true
                                                    ctx.write(data: self.wrapOutboundOut(.head(response)), promise: nil)
                                                }
                                                return ctx.writeAndFlush(data: self.wrapOutboundOut(.body(.byteBuffer(buffer))))
                        }.then { _ in
                            ctx.writeAndFlush(data: self.wrapOutboundOut(.end(nil)))
                        }.thenIfError { error in
                            if !responseStarted {
                                let response = HTTPResponseHead(version: request.version, status: .ok)
                                ctx.write(data: self.wrapOutboundOut(.head(response)), promise: nil)
                                var buffer = ctx.channel.allocator.buffer(capacity: 100)
                                buffer.write(string: "fail: \(error.localizedDescription)")
                                ctx.write(data: self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                                return ctx.writeAndFlush(data: self.wrapOutboundOut(.end(nil)))
                            } else {
                                return ctx.close()
                            }
                        }.whenComplete { res in
                            _ = try? region.close()
                        }
                case .sendfile:
                    ctx.write(data: self.wrapOutboundOut(.head(response))).then { _ in
                        ctx.writeAndFlush(data: self.wrapOutboundOut(.body(.fileRegion(region))))
                    } .then { _ in
                        ctx.writeAndFlush(data: self.wrapOutboundOut(.end(nil)))
                    }.thenIfError { _ in
                        ctx.close()
                    }.whenComplete { _ in
                        _ = try? region.close()
                    }
                }
            } catch {
                var body = ctx.channel.allocator.buffer(capacity: 128)
                let response = { () -> HTTPResponseHead in
                    switch error {
                    case let e as IOError where e.errnoCode == ENOENT:
                        body.write(staticString: "IOError (not found)\r\n")
                        return HTTPResponseHead(version: request.version, status: .notFound)
                    case let e as IOError:
                        body.write(staticString: "IOError (other)\r\n")
                        body.write(string: e.description)
                        body.write(staticString: "\r\n")
                        return HTTPResponseHead(version: request.version, status: .notFound)
                    default:
                        body.write(string: "\(type(of: error)) error\r\n")
                        return HTTPResponseHead(version: request.version, status: .internalServerError)
                    }
                }()
                body.write(string: error.localizedDescription)
                body.write(staticString: "\r\n")
                ctx.write(data: self.wrapOutboundOut(.head(response)), promise: nil)
                ctx.write(data: self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
                ctx.writeAndFlush(data: self.wrapOutboundOut(.end(nil)), promise: nil)
                ctx.channel.close(promise: nil)
            }
        case .end(_):
            ()
        default:
            fatalError("oh noes: \(request)")
        }
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)
        if let handler = self.handler {
            handler(ctx, reqPart)
            return
        }

        switch reqPart {
        case .head(let request):
            keepAlive = request.isKeepAlive

            if request.uri.hasPrefix("/dynamic") {
                self.handler = self.dynamicHandler(request: request)
                self.handler!(ctx, reqPart)
                return
            } else if let path = request.uri.chopPrefix("/sendfile/") {
                self.handler = { self.handleFile(ctx: $0, request: $1, ioMethod: .sendfile, path: path) }
                self.handler!(ctx, reqPart)
                return
            } else if let path = request.uri.chopPrefix("/fileio/") {
                self.handler = { self.handleFile(ctx: $0, request: $1, ioMethod: .nonblockingFileIO, path: path) }
                self.handler!(ctx, reqPart)
                return
            }

            var responseHead = HTTPResponseHead(version: request.version, status: HTTPResponseStatus.ok)
            responseHead.headers.add(name: "content-length", value: "12")
            let response = HTTPServerResponsePart.head(responseHead)
            ctx.write(data: self.wrapOutboundOut(response), promise: nil)
        case .body:
            break
        case .end:
            let content = HTTPServerResponsePart.body(.byteBuffer(buffer!.slice()))
            ctx.write(data: self.wrapOutboundOut(content), promise: nil)

            if keepAlive {
                ctx.write(data: self.wrapOutboundOut(HTTPServerResponsePart.end(nil)), promise: nil)
            } else {
                ctx.write(data: self.wrapOutboundOut(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                    ctx.close(promise: nil)
                }
            }
        }
    }

    func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.flush(promise: nil)
    }

    func handlerAdded(ctx: ChannelHandlerContext) throws {
        self.buffer = ctx.channel.allocator.buffer(capacity: 12)
        self.buffer.write(staticString: "Hello World!")
    }
}

// First argument is the program path
let arguments = CommandLine.arguments
let arg1 = arguments.dropFirst().first
let arg2 = arguments.dropFirst().dropFirst().first
let arg3 = arguments.dropFirst().dropFirst().dropFirst().first

let defaultHost = "::1"
let defaultPort: Int32 = 8888
let defaultHtdocs = "/dev/null/"

enum BindTo {
    case ip(host: String, port: Int32)
    case unixDomainSocket(path: String)
}

let htdocs: String
let bindTarget: BindTo
switch (arg1, arg1.flatMap { Int32($0) }, arg2, arg2.flatMap { Int32($0) }, arg3) {
case (.some(let h), _ , _, .some(let p), let maybeHtdocs):
    /* second arg an integer --> host port [htdocs] */
    bindTarget = .ip(host: h, port: p)
    htdocs = maybeHtdocs ?? defaultHtdocs
case (_, .some(let p), let maybeHtdocs, _, _):
    /* first arg an integer --> port [htdocs] */
    bindTarget = .ip(host: defaultHost, port: p)
    htdocs = maybeHtdocs ?? defaultHtdocs
case (.some(let portString), .none, let maybeHtdocs, .none, .none):
    /* couldn't parse as number --> uds-path [htdocs] */
    bindTarget = .unixDomainSocket(path: portString)
    htdocs = maybeHtdocs ?? defaultHtdocs
default:
    htdocs = defaultHtdocs
    bindTarget = BindTo.ip(host: defaultHost, port: defaultPort)
}

let group = MultiThreadedEventLoopGroup(numThreads: 1)
let fileIO = NonBlockingFileIO(numberOfThreads: 6)
let bootstrap = ServerBootstrap(group: group)
    // Specify backlog and enable SO_REUSEADDR for the server itself
    .serverChannelOption(ChannelOptions.backlog, value: 256)
    .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

    // Set the handlers that are applied to the accepted Channels
    .childChannelInitializer { channel in
        return channel.pipeline.addHTTPServerHandlers().then { _ in
            return channel.pipeline.add(handler: HTTPHandler(fileIO: fileIO, htdocsPath: htdocs))
        }
    }

    // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
    .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
    .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
    .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

defer {
    try! fileIO.syncShutdownGracefully()
    try! group.syncShutdownGracefully()
}

print("htdocs = \(htdocs)")

let channel = try { () -> Channel in
    switch bindTarget {
    case .ip(let host, let port):
        return try bootstrap.bind(to: host, on: port).wait()
    case .unixDomainSocket(let path):
        return try bootstrap.bind(to: path).wait()
    }
    }()

print("Server started and listening on \(channel.localAddress!), htdocs path \(htdocs)")

// This will never unblock as we don't close the ServerChannel
try channel.closeFuture.wait()

print("Server closed")
