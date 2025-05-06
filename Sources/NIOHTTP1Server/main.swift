//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
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

extension String {
    func chopPrefix(_ prefix: String) -> String? {
        if self.unicodeScalars.starts(with: prefix.unicodeScalars) {
            return String(self[self.index(self.startIndex, offsetBy: prefix.count)...])
        } else {
            return nil
        }
    }

    func containsDotDot() -> Bool {
        for idx in self.indices {
            if self[idx] == "." && idx < self.index(before: self.endIndex) && self[self.index(after: idx)] == "." {
                return true
            }
        }
        return false
    }
}

private func httpResponseHead(
    request: HTTPRequestHead,
    status: HTTPResponseStatus,
    headers: HTTPHeaders = HTTPHeaders()
) -> HTTPResponseHead {
    var head = HTTPResponseHead(version: request.version, status: status, headers: headers)
    let connectionHeaders: [String] = head.headers[canonicalForm: "connection"].map { $0.lowercased() }

    if !connectionHeaders.contains("keep-alive") && !connectionHeaders.contains("close") {
        // the user hasn't pre-set either 'keep-alive' or 'close', so we might need to add headers

        switch (request.isKeepAlive, request.version.major, request.version.minor) {
        case (true, 1, 0):
            // HTTP/1.0 and the request has 'Connection: keep-alive', we should mirror that
            head.headers.add(name: "Connection", value: "keep-alive")
        case (false, 1, let n) where n >= 1:
            // HTTP/1.1 (or treated as such) and the request has 'Connection: close', we should mirror that
            head.headers.add(name: "Connection", value: "close")
        default:
            // we should match the default or are dealing with some HTTP that we don't support, let's leave as is
            ()
        }
    }
    return head
}

private final class HTTPHandler: ChannelInboundHandler {
    private enum FileIOMethod {
        case sendfile
        case nonblockingFileIO
    }
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    private enum State {
        case idle
        case waitingForRequestBody
        case sendingResponse

        mutating func requestReceived() {
            precondition(self == .idle, "Invalid state for request received: \(self)")
            self = .waitingForRequestBody
        }

        mutating func requestComplete() {
            precondition(self == .waitingForRequestBody, "Invalid state for request complete: \(self)")
            self = .sendingResponse
        }

        mutating func responseComplete() {
            precondition(self == .sendingResponse, "Invalid state for response complete: \(self)")
            self = .idle
        }
    }

    private var buffer: ByteBuffer! = nil
    private var keepAlive = false
    private var state = State.idle
    private let htdocsPath: String

    private var infoSavedRequestHead: HTTPRequestHead?
    private var infoSavedBodyBytes: Int = 0

    private var continuousCount: Int = 0

    private var handler: ((ChannelHandlerContext, HTTPServerRequestPart) -> Void)?
    private var handlerFuture: EventLoopFuture<Void>?
    private let fileIO: NonBlockingFileIO
    private let defaultResponse = "Hello World\r\n"

    public init(fileIO: NonBlockingFileIO, htdocsPath: String) {
        self.htdocsPath = htdocsPath
        self.fileIO = fileIO
    }

    func handleInfo(context: ChannelHandlerContext, request: HTTPServerRequestPart) {
        switch request {
        case .head(let request):
            self.infoSavedRequestHead = request
            self.infoSavedBodyBytes = 0
            self.keepAlive = request.isKeepAlive
            self.state.requestReceived()
        case .body(buffer: let buf):
            self.infoSavedBodyBytes += buf.readableBytes
        case .end:
            self.state.requestComplete()
            let response = """
                HTTP method: \(self.infoSavedRequestHead!.method)\r
                URL: \(self.infoSavedRequestHead!.uri)\r
                body length: \(self.infoSavedBodyBytes)\r
                headers: \(self.infoSavedRequestHead!.headers)\r
                client: \(context.remoteAddress?.description ?? "zombie")\r
                IO: SwiftNIO Electric Boogaloo™️\r\n
                """
            self.buffer.clear()
            self.buffer.writeString(response)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "\(response.utf8.count)")
            context.write(
                Self.wrapOutboundOut(
                    .head(httpResponseHead(request: self.infoSavedRequestHead!, status: .ok, headers: headers))
                ),
                promise: nil
            )
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(self.buffer))), promise: nil)
            self.completeResponse(context, trailers: nil, promise: nil)
        }
    }

    func handleEcho(context: ChannelHandlerContext, request: HTTPServerRequestPart) {
        self.handleEcho(context: context, request: request, balloonInMemory: false)
    }

    func handleEcho(context: ChannelHandlerContext, request: HTTPServerRequestPart, balloonInMemory: Bool = false) {
        switch request {
        case .head(let request):
            self.keepAlive = request.isKeepAlive
            self.infoSavedRequestHead = request
            self.state.requestReceived()
            if balloonInMemory {
                self.buffer.clear()
            } else {
                context.writeAndFlush(
                    Self.wrapOutboundOut(.head(httpResponseHead(request: request, status: .ok))),
                    promise: nil
                )
            }
        case .body(buffer: var buf):
            if balloonInMemory {
                self.buffer.writeBuffer(&buf)
            } else {
                context.writeAndFlush(Self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
            }
        case .end:
            self.state.requestComplete()
            if balloonInMemory {
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "\(self.buffer.readableBytes)")
                context.write(
                    Self.wrapOutboundOut(
                        .head(httpResponseHead(request: self.infoSavedRequestHead!, status: .ok, headers: headers))
                    ),
                    promise: nil
                )
                context.write(Self.wrapOutboundOut(.body(.byteBuffer(self.buffer))), promise: nil)
                self.completeResponse(context, trailers: nil, promise: nil)
            } else {
                self.completeResponse(context, trailers: nil, promise: nil)
            }
        }
    }

    func handleJustWrite(
        context: ChannelHandlerContext,
        request: HTTPServerRequestPart,
        statusCode: HTTPResponseStatus = .ok,
        string: String,
        trailer: (String, String)? = nil,
        delay: TimeAmount = .nanoseconds(0)
    ) {
        switch request {
        case .head(let request):
            self.keepAlive = request.isKeepAlive
            self.state.requestReceived()
            context.writeAndFlush(
                Self.wrapOutboundOut(.head(httpResponseHead(request: request, status: statusCode))),
                promise: nil
            )
        case .body(buffer: _):
            ()
        case .end:
            self.state.requestComplete()
            let loopBoundContext = context.loopBound
            let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
            context.eventLoop.scheduleTask(in: delay) { () -> Void in
                let `self` = loopBoundSelf.value
                let context = loopBoundContext.value
                var buf = context.channel.allocator.buffer(capacity: string.utf8.count)
                buf.writeString(string)
                context.writeAndFlush(Self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
                var trailers: HTTPHeaders? = nil
                if let trailer = trailer {
                    trailers = HTTPHeaders()
                    trailers?.add(name: trailer.0, value: trailer.1)
                }

                self.completeResponse(context, trailers: trailers, promise: nil)
            }
        }
    }

    func handleContinuousWrites(context: ChannelHandlerContext, request: HTTPServerRequestPart) {
        switch request {
        case .head(let request):
            self.keepAlive = request.isKeepAlive
            self.continuousCount = 0
            self.state.requestReceived()
            let eventLoop = context.eventLoop
            let loopBoundContext = NIOLoopBound(context, eventLoop: eventLoop)
            let loopBoundSelf = NIOLoopBound(self, eventLoop: eventLoop)
            @Sendable func doNext() {
                let `self` = loopBoundSelf.value
                let context = loopBoundContext.value
                self.buffer.clear()
                self.continuousCount += 1
                self.buffer.writeString("line \(self.continuousCount)\n")
                context.writeAndFlush(Self.wrapOutboundOut(.body(.byteBuffer(self.buffer)))).map {
                    eventLoop.scheduleTask(in: .milliseconds(400), doNext)
                }.whenFailure { (_: Error) in
                    loopBoundSelf.value.completeResponse(loopBoundContext.value, trailers: nil, promise: nil)
                }
            }
            context.writeAndFlush(
                Self.wrapOutboundOut(.head(httpResponseHead(request: request, status: .ok))),
                promise: nil
            )
            doNext()
        case .end:
            self.state.requestComplete()
        default:
            break
        }
    }

    func handleMultipleWrites(
        context: ChannelHandlerContext,
        request: HTTPServerRequestPart,
        strings: [String],
        delay: TimeAmount
    ) {
        switch request {
        case .head(let request):
            self.keepAlive = request.isKeepAlive
            self.continuousCount = 0
            self.state.requestReceived()
            let eventLoop = context.eventLoop
            let loopBoundContext = NIOLoopBound(context, eventLoop: eventLoop)
            let loopBoundSelf = NIOLoopBound(self, eventLoop: eventLoop)
            @Sendable func doNext() {
                let `self` = loopBoundSelf.value
                let context = loopBoundContext.value
                self.buffer.clear()
                self.buffer.writeString(strings[self.continuousCount])
                self.continuousCount += 1
                context.writeAndFlush(Self.wrapOutboundOut(.body(.byteBuffer(self.buffer)))).whenSuccess {
                    let `self` = loopBoundSelf.value
                    let context = loopBoundContext.value
                    if self.continuousCount < strings.count {
                        eventLoop.scheduleTask(in: delay, doNext)
                    } else {
                        self.completeResponse(context, trailers: nil, promise: nil)
                    }
                }
            }
            context.writeAndFlush(
                Self.wrapOutboundOut(.head(httpResponseHead(request: request, status: .ok))),
                promise: nil
            )
            doNext()
        case .end:
            self.state.requestComplete()
        default:
            break
        }
    }

    func dynamicHandler(request reqHead: HTTPRequestHead) -> ((ChannelHandlerContext, HTTPServerRequestPart) -> Void)? {
        if let howLong = reqHead.uri.chopPrefix("/dynamic/write-delay/") {
            return { context, req in
                self.handleJustWrite(
                    context: context,
                    request: req,
                    string: self.defaultResponse,
                    delay: Int64(howLong).map { .milliseconds($0) } ?? .seconds(0)
                )
            }
        }

        switch reqHead.uri {
        case "/dynamic/echo":
            return self.handleEcho
        case "/dynamic/echo_balloon":
            return { self.handleEcho(context: $0, request: $1, balloonInMemory: true) }
        case "/dynamic/pid":
            return { context, req in self.handleJustWrite(context: context, request: req, string: "\(getpid())") }
        case "/dynamic/write-delay":
            return { context, req in
                self.handleJustWrite(
                    context: context,
                    request: req,
                    string: self.defaultResponse,
                    delay: .milliseconds(100)
                )
            }
        case "/dynamic/info":
            return self.handleInfo
        case "/dynamic/trailers":
            return { context, req in
                self.handleJustWrite(
                    context: context,
                    request: req,
                    string: "\(getpid())\r\n",
                    trailer: ("Trailer-Key", "Trailer-Value")
                )
            }
        case "/dynamic/continuous":
            return self.handleContinuousWrites
        case "/dynamic/count-to-ten":
            return {
                self.handleMultipleWrites(
                    context: $0,
                    request: $1,
                    strings: (1...10).map { "\($0)" },
                    delay: .milliseconds(100)
                )
            }
        case "/dynamic/client-ip":
            return { context, req in
                self.handleJustWrite(
                    context: context,
                    request: req,
                    string: "\(context.remoteAddress.debugDescription)"
                )
            }
        default:
            return { context, req in
                self.handleJustWrite(context: context, request: req, statusCode: .notFound, string: "not found")
            }
        }
    }

    private func handleFile(
        context: ChannelHandlerContext,
        request: HTTPServerRequestPart,
        ioMethod: FileIOMethod,
        path: String
    ) {
        self.buffer.clear()
        let eventLoop = context.eventLoop
        let allocator = context.channel.allocator
        let loopBoundContext = NIOLoopBound(context, eventLoop: eventLoop)
        let loopBoundSelf = NIOLoopBound(self, eventLoop: eventLoop)

        @Sendable func sendErrorResponse(request: HTTPRequestHead, _ error: Error) {
            let context = loopBoundContext.value
            var body = allocator.buffer(capacity: 128)
            let response = { () -> HTTPResponseHead in
                switch error {
                case let e as IOError where e.errnoCode == ENOENT:
                    body.writeStaticString("IOError (not found)\r\n")
                    return httpResponseHead(request: request, status: .notFound)
                case let e as IOError:
                    body.writeStaticString("IOError (other)\r\n")
                    body.writeString(e.description)
                    body.writeStaticString("\r\n")
                    return httpResponseHead(request: request, status: .notFound)
                default:
                    body.writeString("\(type(of: error)) error\r\n")
                    return httpResponseHead(request: request, status: .internalServerError)
                }
            }()
            body.writeString("\(error)")
            body.writeStaticString("\r\n")
            context.write(Self.wrapOutboundOut(.head(response)), promise: nil)
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
            context.channel.close(promise: nil)
        }

        @Sendable func responseHead(request: HTTPRequestHead, fileRegion region: FileRegion) -> HTTPResponseHead {
            var response = httpResponseHead(request: request, status: .ok)
            response.headers.add(name: "Content-Length", value: "\(region.endIndex)")
            response.headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            return response
        }

        switch request {
        case .head(let request):
            self.keepAlive = request.isKeepAlive
            self.state.requestReceived()
            guard !request.uri.containsDotDot() else {
                let response = httpResponseHead(request: request, status: .forbidden)
                context.write(Self.wrapOutboundOut(.head(response)), promise: nil)
                self.completeResponse(context, trailers: nil, promise: nil)
                return
            }
            let path = self.htdocsPath + "/" + path
            let fileHandleAndRegion = self.fileIO.openFile(_deprecatedPath: path, eventLoop: context.eventLoop)
            fileHandleAndRegion.whenFailure {
                sendErrorResponse(request: request, $0)
            }
            fileHandleAndRegion.whenSuccess { [fileIO = self.fileIO] (file, region) in
                let context = loopBoundContext.value
                let loopBoundFile = NIOLoopBound(file, eventLoop: eventLoop)
                switch ioMethod {
                case .nonblockingFileIO:
                    let responseStarted = NIOLoopBoundBox(false, eventLoop: eventLoop)
                    let response = responseHead(request: request, fileRegion: region)
                    if region.readableBytes == 0 {
                        responseStarted.value = true
                        context.write(Self.wrapOutboundOut(.head(response)), promise: nil)
                    }
                    return fileIO.readChunked(
                        fileRegion: region,
                        chunkSize: 32 * 1024,
                        allocator: context.channel.allocator,
                        eventLoop: context.eventLoop
                    ) { buffer in
                        let context = loopBoundContext.value
                        if !responseStarted.value {
                            responseStarted.value = true
                            context.write(Self.wrapOutboundOut(.head(response)), promise: nil)
                        }
                        return context.writeAndFlush(Self.wrapOutboundOut(.body(.byteBuffer(buffer))))
                    }.flatMap { () -> EventLoopFuture<Void> in
                        let context = loopBoundContext.value
                        let `self` = loopBoundSelf.value
                        let p = context.eventLoop.makePromise(of: Void.self)
                        self.completeResponse(context, trailers: nil, promise: p)
                        return p.futureResult
                    }.flatMapError { error in
                        let context = loopBoundContext.value
                        let `self` = loopBoundSelf.value
                        if !responseStarted.value {
                            let response = httpResponseHead(request: request, status: .ok)
                            context.write(Self.wrapOutboundOut(.head(response)), promise: nil)
                            var buffer = context.channel.allocator.buffer(capacity: 100)
                            buffer.writeString("fail: \(error)")
                            context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                            self.state.responseComplete()
                            return context.writeAndFlush(Self.wrapOutboundOut(.end(nil)))
                        } else {
                            return context.close()
                        }
                    }.whenComplete { (_: Result<Void, Error>) in
                        _ = try? loopBoundFile.value.close()
                    }
                case .sendfile:
                    let context = loopBoundContext.value
                    let response = responseHead(request: request, fileRegion: region)
                    context.write(Self.wrapOutboundOut(.head(response)), promise: nil)
                    context.writeAndFlush(Self.wrapOutboundOut(.body(.fileRegion(region)))).flatMap {
                        let context = loopBoundContext.value
                        let p = context.eventLoop.makePromise(of: Void.self)
                        loopBoundSelf.value.completeResponse(context, trailers: nil, promise: p)
                        return p.futureResult
                    }.flatMapError { (_: Error) in
                        loopBoundContext.value.close()
                    }.whenComplete { (_: Result<Void, Error>) in
                        _ = try? loopBoundFile.value.close()
                    }
                }
            }
        case .end:
            self.state.requestComplete()
        default:
            fatalError("oh noes: \(request)")
        }
    }

    private func completeResponse(
        _ context: ChannelHandlerContext,
        trailers: HTTPHeaders?,
        promise: EventLoopPromise<Void>?
    ) {
        self.state.responseComplete()
        let loopBoundContext = context.loopBound

        let promise = self.keepAlive ? promise : (promise ?? context.eventLoop.makePromise())
        if !self.keepAlive {
            promise!.futureResult.whenComplete { (_: Result<Void, Error>) in
                let context = loopBoundContext.value
                context.close(promise: nil)
            }
        }
        self.handler = nil

        context.writeAndFlush(Self.wrapOutboundOut(.end(trailers)), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = Self.unwrapInboundIn(data)
        if let handler = self.handler {
            handler(context, reqPart)
            return
        }

        switch reqPart {
        case .head(let request):
            if request.uri.unicodeScalars.starts(with: "/dynamic".unicodeScalars) {
                self.handler = self.dynamicHandler(request: request)
                self.handler!(context, reqPart)
                return
            } else if let path = request.uri.chopPrefix("/sendfile/") {
                self.handler = { self.handleFile(context: $0, request: $1, ioMethod: .sendfile, path: path) }
                self.handler!(context, reqPart)
                return
            } else if let path = request.uri.chopPrefix("/fileio/") {
                self.handler = { self.handleFile(context: $0, request: $1, ioMethod: .nonblockingFileIO, path: path) }
                self.handler!(context, reqPart)
                return
            }

            self.keepAlive = request.isKeepAlive
            self.state.requestReceived()

            var responseHead = httpResponseHead(request: request, status: HTTPResponseStatus.ok)
            self.buffer.clear()
            self.buffer.writeString(self.defaultResponse)
            responseHead.headers.add(name: "content-length", value: "\(self.buffer!.readableBytes)")
            let response = HTTPServerResponsePart.head(responseHead)
            context.write(Self.wrapOutboundOut(response), promise: nil)
        case .body:
            break
        case .end:
            self.state.requestComplete()
            let content = HTTPServerResponsePart.body(.byteBuffer(buffer!.slice()))
            context.write(Self.wrapOutboundOut(content), promise: nil)
            self.completeResponse(context, trailers: nil, promise: nil)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.buffer = context.channel.allocator.buffer(capacity: 0)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
            // The remote peer half-closed the channel. At this time, any
            // outstanding response will now get the channel closed, and
            // if we are idle or waiting for a request body to finish we
            // will close the channel immediately.
            switch self.state {
            case .idle, .waitingForRequestBody:
                context.close(promise: nil)
            case .sendingResponse:
                self.keepAlive = false
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

// First argument is the program path
var arguments = CommandLine.arguments.dropFirst(0)  // just to get an ArraySlice<String> from [String]
var allowHalfClosure = true
if arguments.dropFirst().first == .some("--disable-half-closure") {
    allowHalfClosure = false
    arguments = arguments.dropFirst()
}
let arg1 = arguments.dropFirst().first
let arg2 = arguments.dropFirst(2).first
let arg3 = arguments.dropFirst(3).first

let defaultHost = "::1"
let defaultPort = 8888
let defaultHtdocs = "/dev/null/"

enum BindTo {
    case ip(host: String, port: Int)
    case unixDomainSocket(path: String)
    case stdio
}

let htdocs: String
let bindTarget: BindTo

switch (arg1, arg1.flatMap(Int.init), arg2, arg2.flatMap(Int.init), arg3) {
case (.some(let h), _, _, .some(let p), let maybeHtdocs):
    // second arg an integer --> host port [htdocs]
    bindTarget = .ip(host: h, port: p)
    htdocs = maybeHtdocs ?? defaultHtdocs
case (_, .some(let p), let maybeHtdocs, _, _):
    // first arg an integer --> port [htdocs]
    bindTarget = .ip(host: defaultHost, port: p)
    htdocs = maybeHtdocs ?? defaultHtdocs
case (.some(let portString), .none, let maybeHtdocs, .none, .none):
    // couldn't parse as number --> uds-path-or-stdio [htdocs]
    if portString == "-" {
        bindTarget = .stdio
    } else {
        bindTarget = .unixDomainSocket(path: portString)
    }
    htdocs = maybeHtdocs ?? defaultHtdocs
default:
    htdocs = defaultHtdocs
    bindTarget = BindTo.ip(host: defaultHost, port: defaultPort)
}

func childChannelInitializer(channel: Channel) -> EventLoopFuture<Void> {
    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMapThrowing {
        try channel.pipeline.syncOperations.addHandler(HTTPHandler(fileIO: fileIO, htdocsPath: htdocs))
    }
}

let fileIO = NonBlockingFileIO(threadPool: .singleton)
let socketBootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
    // Specify backlog and enable SO_REUSEADDR for the server itself
    .serverChannelOption(.backlog, value: 256)
    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)

    // Set the handlers that are applied to the accepted Channels
    .childChannelInitializer(childChannelInitializer(channel:))

    // Enable SO_REUSEADDR for the accepted Channels
    .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
    .childChannelOption(.maxMessagesPerRead, value: 1)
    .childChannelOption(.allowRemoteHalfClosure, value: allowHalfClosure)
let pipeBootstrap = NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton)
    // Set the handlers that are applied to the accepted Channels
    .channelInitializer(childChannelInitializer(channel:))

    .channelOption(.maxMessagesPerRead, value: 1)
    .channelOption(.allowRemoteHalfClosure, value: allowHalfClosure)
print("htdocs = \(htdocs)")

let channel = try { () -> Channel in
    switch bindTarget {
    case .ip(let host, let port):
        return try socketBootstrap.bind(host: host, port: port).wait()
    case .unixDomainSocket(let path):
        return try socketBootstrap.bind(unixDomainSocketPath: path).wait()
    case .stdio:
        return try pipeBootstrap.takingOwnershipOfDescriptors(input: STDIN_FILENO, output: STDOUT_FILENO).wait()
    }
}()

let localAddress: String
if case .stdio = bindTarget {
    localAddress = "STDIO"
} else {
    guard let channelLocalAddress = channel.localAddress else {
        fatalError(
            "Address was unable to bind. Please check that the socket was not closed or that the address family was understood."
        )
    }
    localAddress = "\(channelLocalAddress)"
}
print("Server started and listening on \(localAddress), htdocs path \(htdocs)")

// This will never unblock as we don't close the ServerChannel
try channel.closeFuture.wait()

print("Server closed")
