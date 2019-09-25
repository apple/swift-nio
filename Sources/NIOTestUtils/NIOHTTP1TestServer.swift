//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
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
import NIOConcurrencyHelpers

private final class BlockingQueue<Element> {
    private let condition = ConditionLock(value: false)
    private var buffer = CircularBuffer<Result<Element, Error>>()

    public struct TimeoutError: Error {}

    internal func append(_ element: Result<Element, Error>) {
        self.condition.lock()
        self.buffer.append(element)
        self.condition.unlock(withValue: true)
    }

    internal var isEmpty: Bool {
        self.condition.lock()
        defer { self.condition.unlock() }
        return self.buffer.isEmpty
    }

    internal func popFirst(deadline: NIODeadline) throws -> Element {
        let secondsUntilDeath = deadline - NIODeadline.now()
        guard self.condition.lock(whenValue: true,
                                  timeoutSeconds: .init(secondsUntilDeath.nanoseconds / 1_000_000_000)) else {
                                    throw TimeoutError()
        }
        let first = self.buffer.removeFirst()
        self.condition.unlock(withValue: !self.buffer.isEmpty)
        return try first.get()
    }
}

private final class WebServerHandler: ChannelDuplexHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    private let webServer: NIOHTTP1TestServer

    init(webServer: NIOHTTP1TestServer) {
        self.webServer = webServer
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.webServer.pushError(error)
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.webServer.pushChannelRead(self.unwrapInboundIn(data))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch self.unwrapOutboundIn(data) {
        case .head(var head):
            head.headers.replaceOrAdd(name: "connection", value: "close")
            head.headers.remove(name: "keep-alive")
            context.write(self.wrapOutboundOut(.head(head)), promise: promise)
        case .body:
            context.write(data, promise: promise)
        case .end:
            context.write(data).map {
                context.close(promise: nil)
            }.cascade(to: promise)
        }
    }
}

private final class AggregateBodyHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerRequestPart

    var receivedSoFar: ByteBuffer? = nil

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head:
            context.fireChannelRead(data)
        case .body(var buffer):
            if self.receivedSoFar == nil {
                self.receivedSoFar = buffer
            } else {
                self.receivedSoFar?.writeBuffer(&buffer)
            }
        case .end:
            if let receivedSoFar = self.receivedSoFar {
                context.fireChannelRead(self.wrapInboundOut(.body(receivedSoFar)))
            }
            context.fireChannelRead(data)
        }
    }

}

/// HTTP1 server that accepts and process only one request at a time.
/// This helps writing tests against a real server while keeping the ability to
/// write tests and assertions the same way we would if we were testing a
/// `ChannelHandler` in isolation.
public final class NIOHTTP1TestServer {
    private let eventLoop: EventLoop
    // all protected by eventLoop
    private let inboundBuffer: BlockingQueue<HTTPServerRequestPart> = .init()
    private var currentClientChannel: Channel? = nil
    private var serverChannel: Channel! = nil

    public init(group: EventLoopGroup) {
        self.eventLoop = group.next()

        self.serverChannel = try! ServerBootstrap(group: self.eventLoop)
            .serverChannelOption(ChannelOptions.autoRead, value: false)
            .serverChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelInitializer { channel in
                assert(self.currentClientChannel == nil)
                self.currentClientChannel = channel
                channel.closeFuture.whenSuccess {
                    self.currentClientChannel = nil
                    if let serverChannel = self.serverChannel {
                        serverChannel.read()
                    }
                }
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(AggregateBodyHandler())
                }.flatMap {
                    channel.pipeline.addHandler(WebServerHandler(webServer: self))
                }
        }
        .bind(host: "127.0.0.1", port: 0)
            .map {
                $0.read()
                return $0
        }
        .wait()
    }
}

// MARK: - Public API for test driver
extension NIOHTTP1TestServer {
    struct NonEmptyInboundBufferOnStop: Error {}

    public func stop() throws {
        assert(!self.eventLoop.inEventLoop)
        try self.eventLoop.submit {
            self.serverChannel.close().flatMapThrowing {
                self.serverChannel = nil
                guard self.inboundBuffer.isEmpty else {
                    throw NonEmptyInboundBufferOnStop()
                }
            }
        }.wait().wait()
    }

    public func readInbound(deadline: NIODeadline = .now() + .seconds(10)) throws -> HTTPServerRequestPart {
        assert(!self.eventLoop.inEventLoop)
        return try self.eventLoop.submit { () -> BlockingQueue<HTTPServerRequestPart> in
            self.inboundBuffer
        }.wait().popFirst(deadline: deadline)
    }

    public func writeOutbound(_ data: HTTPServerResponsePart) throws {
        assert(!self.eventLoop.inEventLoop)
        try self.eventLoop.submit { () -> EventLoopFuture<Void> in
            if let channel = self.currentClientChannel {
                return channel.writeAndFlush(data)
            } else {
                return self.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
            }
        }.wait().wait()
    }

    public var serverPort: Int {
        assert(!self.eventLoop.inEventLoop)
        return self.serverChannel!.localAddress!.port!
    }
}

// MARK: - API for HTTP server
extension NIOHTTP1TestServer {
    fileprivate func pushChannelRead(_ state: HTTPServerRequestPart) {
        self.eventLoop.assertInEventLoop()
        self.inboundBuffer.append(.success(state))
    }

    fileprivate func pushError(_ error: Error) {
        self.eventLoop.assertInEventLoop()
        self.inboundBuffer.append(.failure(error))
    }
}
