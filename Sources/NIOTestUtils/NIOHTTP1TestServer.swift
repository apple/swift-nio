//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

typealias SendableHTTPServerResponsePart = HTTPPart<HTTPResponseHead, ByteBuffer>

extension HTTPServerResponsePart {
    init(_ target: SendableHTTPServerResponsePart) {
        switch target {
        case .head(let head):
            self = .head(head)
        case .body(let body):
            self = .body(.byteBuffer(body))
        case .end(let end):
            self = .end(end)
        }
    }
}

extension SendableHTTPServerResponsePart {
    init(_ target: HTTPServerResponsePart) throws {
        switch target {
        case .head(let head):
            self = .head(head)
        case .body(.byteBuffer(let body)):
            self = .body(body)
        case .body(.fileRegion):
            throw NIOHTTP1TestServerError(
                reason: "FileRegion is not Sendable and cannot be passed across concurrency domains"
            )
        case .end(let end):
            self = .end(end)
        }
    }
}

/// A helper handler to transform a Sendable response into a
/// non-Sendable one, to manage warnings.
private final class TransformerHandler: ChannelOutboundHandler {
    typealias OutboundIn = SendableHTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let response = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(.init(response)), promise: promise)
    }
}

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
        guard
            self.condition.lock(
                whenValue: true,
                timeoutSeconds: .init(secondsUntilDeath.nanoseconds / 1_000_000_000)
            )
        else {
            throw TimeoutError()
        }
        let first = self.buffer.removeFirst()
        self.condition.unlock(withValue: !self.buffer.isEmpty)
        return try first.get()
    }
}

extension BlockingQueue: @unchecked Sendable where Element: Sendable {}

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
        self.webServer.pushChannelRead(Self.unwrapInboundIn(data))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let loopBoundContext = context.loopBound
        switch Self.unwrapOutboundIn(data) {
        case .head(var head):
            head.headers.replaceOrAdd(name: "connection", value: "close")
            head.headers.remove(name: "keep-alive")
            context.write(Self.wrapOutboundOut(.head(head)), promise: promise)
        case .body:
            context.write(data, promise: promise)
        case .end:
            context.write(data).map {
                let context = loopBoundContext.value
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
        switch Self.unwrapInboundIn(data) {
        case .head:
            context.fireChannelRead(data)
        case .body(var buffer):
            self.receivedSoFar.setOrWriteBuffer(&buffer)
        case .end:
            if let receivedSoFar = self.receivedSoFar {
                context.fireChannelRead(Self.wrapInboundOut(.body(receivedSoFar)))
            }
            context.fireChannelRead(data)
        }
    }
}

/// HTTP1 server that accepts and process only one request at a time.
/// This helps writing tests against a real server while keeping the ability to
/// write tests and assertions the same way we would if we were testing a
/// `ChannelHandler` in isolation.
/// `NIOHTTP1TestServer` enables writing test cases for HTTP1 clients that have
/// complex behaviours like client implementing a protocol where an high level
/// operation translates into several, possibly parallel, HTTP requests.
///
/// With `NIOHTTP1TestServer` we have:
///  - visibility on the `HTTPServerRequestPart`s received by the server;
///  - control over the `HTTPServerResponsePart`s send by the server.
///
/// The following code snippet shows an example test case where the client
/// under test sends a request to the server.
///
///     // Setup the test environment.
///     let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
///     let allocator = ByteBufferAllocator()
///     let testServer = NIOHTTP1TestServer(group: group)
///     defer {
///         XCTAssertNoThrow(try testServer.stop())
///         XCTAssertNoThrow(try group.syncShutdownGracefully())
///     }
///
///     // Use your library to send a request to the server.
///     let requestBody = "ping"
///     var requestComplete: EventLoopFuture<String>!
///     XCTAssertNoThrow(requestComplete = try sendRequestTo(
///         URL(string: "http://127.0.0.1:\(testServer.serverPort)/some-route")!,
///         body: requestBody))
///
///     // Assert the server received the expected request.
///     XCTAssertNoThrow(try testServer.receiveHeadAndVerify { head in
///         XCTAssertEqual(head, .init(version: .http1_1,
///                                    method: .GET,
///                                    uri: "/some-route",
///                                    headers: .init([
///                                        ("Content-Type", "text/plain; charset=utf-8"),
///                                        ("Content-Length", "4")])))
///     })
///     var requestBuffer = allocator.buffer(capacity: 128)
///     requestBuffer.writeString(requestBody)
///     XCTAssertNoThrow(try testServer.receiveBodyAndVerify { body in
///         XCTAssertEqual(body, requestBuffer)
///     })
///     XCTAssertNoThrow(try testServer.receiveEndAndVerify { trailers in
///         XCTAssertNil(trailers)
///     })
///
///     // Make the server send a response to the client.
///     let responseBody = "pong"
///     var responseBuffer = allocator.buffer(capacity: 128)
///     responseBuffer.writeString(responseBody)
///     XCTAssertNoThrow(try testServer.writeOutbound(.head(.init(version: .http1_1, status: .ok))))
///     XCTAssertNoThrow(try testServer.writeOutbound(.body(.byteBuffer(responseBuffer))))
///     XCTAssertNoThrow(try testServer.writeOutbound(.end(nil)))
///
///     // Assert that the client received the response from the server.
///     XCTAssertNoThrow(XCTAssertEqual(responseBody, try requestComplete.wait()))
public final class NIOHTTP1TestServer {
    private let eventLoop: EventLoop
    private let aggregateBody: Bool
    // all protected by eventLoop
    private let inboundBuffer: BlockingQueue<HTTPServerRequestPart> = .init()
    private var currentClientChannel: Channel? = nil
    private var serverChannel: Channel! = nil

    enum State {
        case channelsAvailable(CircularBuffer<Channel>)
        case waitingForChannel(EventLoopPromise<Void>)
        case idle
        case stopped
    }
    private var state: State = .idle

    func handleChannels() {
        self.eventLoop.assertInEventLoop()

        let channel: Channel
        switch self.state {
        case .channelsAvailable(var channels):
            channel = channels.removeFirst()
            if channels.isEmpty {
                self.state = .idle
            } else {
                self.state = .channelsAvailable(channels)
            }
        case .idle:
            let promise = self.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenSuccess {
                self.handleChannels()
            }
            self.state = .waitingForChannel(promise)
            return
        case .waitingForChannel:
            preconditionFailure("illegal state \(self.state)")
        case .stopped:
            return
        }

        assert(self.currentClientChannel == nil)
        self.currentClientChannel = channel
        channel.closeFuture.whenSuccess {
            self.currentClientChannel = nil
            self.handleChannels()
            return
        }
        do {
            try channel.pipeline.syncOperations.configureHTTPServerPipeline()
            if self.aggregateBody {
                try channel.pipeline.syncOperations.addHandler(AggregateBodyHandler())
            }
            try channel.pipeline.syncOperations.addHandler(WebServerHandler(webServer: self))
            try channel.pipeline.syncOperations.addHandler(TransformerHandler())
            _ = try channel.syncOptions!.setOption(.autoRead, value: true)
        } catch {
            // This happens when the channel has been closed while it was waiting in
            // the pipeline. It's benign: the closure passed to the close future above will
            // have executed already, and started working on getting the next channel.
            channel.close(promise: nil)
        }
    }

    public convenience init(group: EventLoopGroup) {
        self.init(group: group, aggregateBody: true)
    }

    public init(group: EventLoopGroup, aggregateBody: Bool) {
        self.eventLoop = group.next()
        self.aggregateBody = aggregateBody

        self.serverChannel = try! ServerBootstrap(group: self.eventLoop)
            .childChannelOption(.autoRead, value: false)
            .childChannelInitializer { channel in
                switch self.state {
                case .channelsAvailable(var channels):
                    channels.append(channel)
                    self.state = .channelsAvailable(channels)
                case .waitingForChannel(let promise):
                    self.state = .channelsAvailable([channel])
                    promise.succeed(())
                case .idle:
                    self.state = .channelsAvailable([channel])
                case .stopped:
                    channel.close(promise: nil)
                }
                return channel.eventLoop.makeSucceededFuture(())
            }
            .bind(host: "127.0.0.1", port: 0)
            .map { channel in
                self.handleChannels()
                return channel
            }
            .wait()
    }
}

// MARK: - Public API for test driver
extension NIOHTTP1TestServer {
    struct NonEmptyInboundBufferOnStop: Error {}

    public func stop() throws {
        assert(!self.eventLoop.inEventLoop)
        try self.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            switch self.state {
            case .channelsAvailable(let channels):
                self.state = .stopped
                for channel in channels {
                    channel.close(promise: nil)
                }
            case .waitingForChannel(let promise):
                self.state = .stopped
                promise.fail(ChannelError.ioOnClosedChannel)
            case .idle:
                self.state = .stopped
            case .stopped:
                preconditionFailure("double stopped NIOHTTP1TestServer")
            }
            return self.serverChannel.close().flatMapThrowing {
                self.serverChannel = nil
                guard self.inboundBuffer.isEmpty else {
                    throw NonEmptyInboundBufferOnStop()
                }
            }.always { _ in
                self.currentClientChannel?.close(promise: nil)
            }
        }.wait()
    }

    public func readInbound(deadline: NIODeadline = .now() + .seconds(10)) throws -> HTTPServerRequestPart {
        self.eventLoop.assertNotInEventLoop()
        return try self.eventLoop.submit { () -> BlockingQueue<HTTPServerRequestPart> in
            self.inboundBuffer
        }.wait().popFirst(deadline: deadline)
    }

    public func writeOutbound(_ data: HTTPServerResponsePart) throws {
        self.eventLoop.assertNotInEventLoop()

        let transformed = try SendableHTTPServerResponsePart(data)
        try self.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            if let channel = self.currentClientChannel {
                return channel.writeAndFlush(transformed)
            } else {
                return self.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
            }
        }.wait()
    }

    public var serverPort: Int {
        self.eventLoop.assertNotInEventLoop()
        return self.serverChannel!.localAddress!.port!
    }
}

// All mutable state is protected through `eventLoop`
extension NIOHTTP1TestServer: @unchecked Sendable {}

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

extension NIOHTTP1TestServer {
    /// Waits for a message part to be received and checks that it was a `.head` before returning
    /// the `HTTPRequestHead` it contained.
    ///
    /// - Parameters:
    ///   - deadline: The deadline by which a part must have been received.
    /// - Throws: If the part was not a `.head` or nothing was read before the deadline.
    /// - Returns: The `HTTPRequestHead` from the `.head`.
    public func receiveHead(deadline: NIODeadline = .now() + .seconds(10)) throws -> HTTPRequestHead {
        let part = try self.readInbound(deadline: deadline)
        switch part {
        case .head(let head):
            return head
        default:
            throw NIOHTTP1TestServerError(reason: "Expected .head but got '\(part)'")
        }
    }

    /// Waits for a message part to be received and checks that it was a `.head` before passing
    /// it to the `verify` block.
    ///
    /// - Parameters:
    ///   - deadline: The deadline by which a part must have been received.
    ///   - verify: A closure which can be used to verify the contents of the `HTTPRequestHead`.
    /// - Throws: If the part was not a `.head` or nothing was read before the deadline.
    public func receiveHeadAndVerify(
        deadline: NIODeadline = .now() + .seconds(10),
        _ verify: (HTTPRequestHead) throws -> Void = { _ in }
    ) throws {
        try verify(self.receiveHead(deadline: deadline))
    }

    /// Waits for a message part to be received and checks that it was a `.body` before returning
    /// the `ByteBuffer` it contained.
    ///
    /// - Parameters:
    ///   - deadline: The deadline by which a part must have been received.
    /// - Throws: If the part was not a `.body` or nothing was read before the deadline.
    /// - Returns: The `ByteBuffer` from the `.body`.
    public func receiveBody(deadline: NIODeadline = .now() + .seconds(10)) throws -> ByteBuffer {
        let part = try self.readInbound(deadline: deadline)
        switch part {
        case .body(let buffer):
            return buffer
        default:
            throw NIOHTTP1TestServerError(reason: "Expected .body but got '\(part)'")
        }
    }

    /// Waits for a message part to be received and checks that it was a `.body` before passing
    /// it to the `verify` block.
    ///
    /// - Parameters:
    ///   - deadline: The deadline by which a part must have been received.
    ///   - verify: A closure which can be used to verify the contents of the `ByteBuffer`.
    /// - Throws: If the part was not a `.body` or nothing was read before the deadline.
    public func receiveBodyAndVerify(
        deadline: NIODeadline = .now() + .seconds(10),
        _ verify: (ByteBuffer) throws -> Void = { _ in }
    ) throws {
        try verify(self.receiveBody(deadline: deadline))
    }

    /// Waits for a message part to be received and checks that it was a `.end` before returning
    /// the `HTTPHeaders?` it contained.
    ///
    /// - Parameters:
    ///   - deadline: The deadline by which a part must have been received.
    /// - Throws: If the part was not a `.end` or nothing was read before the deadline.
    /// - Returns: The `HTTPHeaders?` from the `.end`.
    public func receiveEnd(deadline: NIODeadline = .now() + .seconds(10)) throws -> HTTPHeaders? {
        let part = try self.readInbound(deadline: deadline)
        switch part {
        case .end(let trailers):
            return trailers
        default:
            throw NIOHTTP1TestServerError(reason: "Expected .end but got '\(part)'")
        }
    }

    /// Waits for a message part to be received and checks that it was a `.end` before passing
    /// it to the `verify` block.
    ///
    /// - Parameters:
    ///   - deadline: The deadline by which a part must have been received.
    ///   - verify: A closure which can be used to verify the contents of the `HTTPHeaders?`.
    /// - Throws: If the part was not a `.end` or nothing was read before the deadline.
    public func receiveEndAndVerify(
        deadline: NIODeadline = .now() + .seconds(10),
        _ verify: (HTTPHeaders?) throws -> Void = { _ in }
    ) throws {
        try verify(self.receiveEnd())
    }
}

public struct NIOHTTP1TestServerError: Error, Hashable, CustomStringConvertible {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String {
        self.reason
    }
}
