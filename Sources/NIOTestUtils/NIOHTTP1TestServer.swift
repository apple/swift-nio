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
import NIOConcurrencyHelpers
import NIOHTTP1

private final class BlockingQueue<Element> {
    private let condition = ConditionLock(value: false)
    private var buffer = CircularBuffer<Result<Element, Error>>()

    public struct TimeoutError: Error {}

    internal func append(_ element: Result<Element, Error>) {
        condition.lock()
        buffer.append(element)
        condition.unlock(withValue: true)
    }

    internal var isEmpty: Bool {
        condition.lock()
        defer { self.condition.unlock() }
        return buffer.isEmpty
    }

    internal func popFirst(deadline: NIODeadline) throws -> Element {
        let secondsUntilDeath = deadline - NIODeadline.now()
        guard condition.lock(whenValue: true,
                             timeoutSeconds: .init(secondsUntilDeath.nanoseconds / 1_000_000_000))
        else {
            throw TimeoutError()
        }
        let first = buffer.removeFirst()
        condition.unlock(withValue: !buffer.isEmpty)
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
        webServer.pushError(error)
        context.close(promise: nil)
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        webServer.pushChannelRead(unwrapInboundIn(data))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch unwrapOutboundIn(data) {
        case var .head(head):
            head.headers.replaceOrAdd(name: "connection", value: "close")
            head.headers.remove(name: "keep-alive")
            context.write(wrapOutboundOut(.head(head)), promise: promise)
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

    var receivedSoFar: ByteBuffer?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head:
            context.fireChannelRead(data)
        case var .body(buffer):
            receivedSoFar.setOrWriteBuffer(&buffer)
        case .end:
            if let receivedSoFar = self.receivedSoFar {
                context.fireChannelRead(wrapInboundOut(.body(receivedSoFar)))
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
    // all protected by eventLoop
    private let inboundBuffer: BlockingQueue<HTTPServerRequestPart> = .init()
    private var currentClientChannel: Channel?
    private var serverChannel: Channel!

    enum State {
        case channelsAvailable(CircularBuffer<Channel>)
        case waitingForChannel(EventLoopPromise<Void>)
        case idle
        case stopped
    }

    private var state: State = .idle

    func handleChannels() {
        eventLoop.assertInEventLoop()

        let channel: Channel
        switch state {
        case var .channelsAvailable(channels):
            channel = channels.removeFirst()
            if channels.isEmpty {
                state = .idle
            } else {
                state = .channelsAvailable(channels)
            }
        case .idle:
            let promise = eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenSuccess {
                self.handleChannels()
            }
            state = .waitingForChannel(promise)
            return
        case .waitingForChannel:
            preconditionFailure("illegal state \(state)")
        case .stopped:
            return
        }

        assert(currentClientChannel == nil)
        currentClientChannel = channel
        channel.closeFuture.whenSuccess {
            self.currentClientChannel = nil
            self.handleChannels()
        }
        channel.pipeline.configureHTTPServerPipeline().flatMap {
            channel.pipeline.addHandler(AggregateBodyHandler())
        }.flatMap {
            channel.pipeline.addHandler(WebServerHandler(webServer: self))
        }.whenSuccess {
            _ = channel.setOption(ChannelOptions.autoRead, value: true)
        }
    }

    public init(group: EventLoopGroup) {
        eventLoop = group.next()

        serverChannel = try! ServerBootstrap(group: eventLoop)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { channel in
                switch self.state {
                case var .channelsAvailable(channels):
                    channels.append(channel)
                    self.state = .channelsAvailable(channels)
                case let .waitingForChannel(promise):
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

public extension NIOHTTP1TestServer {
    internal struct NonEmptyInboundBufferOnStop: Error {}

    func stop() throws {
        assert(!eventLoop.inEventLoop)
        try eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            switch self.state {
            case let .channelsAvailable(channels):
                self.state = .stopped
                channels.forEach {
                    $0.close(promise: nil)
                }
            case let .waitingForChannel(promise):
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

    func readInbound(deadline: NIODeadline = .now() + .seconds(10)) throws -> HTTPServerRequestPart {
        eventLoop.assertNotInEventLoop()
        return try eventLoop.submit { () -> BlockingQueue<HTTPServerRequestPart> in
            self.inboundBuffer
        }.wait().popFirst(deadline: deadline)
    }

    func writeOutbound(_ data: HTTPServerResponsePart) throws {
        eventLoop.assertNotInEventLoop()
        try eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            if let channel = self.currentClientChannel {
                return channel.writeAndFlush(data)
            } else {
                return self.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
            }
        }.wait()
    }

    var serverPort: Int {
        eventLoop.assertNotInEventLoop()
        return serverChannel!.localAddress!.port!
    }
}

// MARK: - API for HTTP server

private extension NIOHTTP1TestServer {
    func pushChannelRead(_ state: HTTPServerRequestPart) {
        eventLoop.assertInEventLoop()
        inboundBuffer.append(.success(state))
    }

    func pushError(_ error: Error) {
        eventLoop.assertInEventLoop()
        inboundBuffer.append(.failure(error))
    }
}

public extension NIOHTTP1TestServer {
    /// Waits for a message part to be received and checks that it was a `.head` before returning
    /// the `HTTPRequestHead` it contained.
    ///
    /// - Parameters:
    ///   - deadline: The deadline by which a part must have been received.
    /// - Throws: If the part was not a `.head` or nothing was read before the deadline.
    /// - Returns: The `HTTPRequestHead` from the `.head`.
    func receiveHead(deadline: NIODeadline = .now() + .seconds(10)) throws -> HTTPRequestHead {
        let part = try readInbound(deadline: deadline)
        switch part {
        case let .head(head):
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
    func receiveHeadAndVerify(deadline: NIODeadline = .now() + .seconds(10),
                              _ verify: (HTTPRequestHead) throws -> Void = { _ in }) throws
    {
        try verify(receiveHead(deadline: deadline))
    }

    /// Waits for a message part to be received and checks that it was a `.body` before returning
    /// the `ByteBuffer` it contained.
    ///
    /// - Parameters:
    ///   - deadline: The deadline by which a part must have been received.
    /// - Throws: If the part was not a `.body` or nothing was read before the deadline.
    /// - Returns: The `ByteBuffer` from the `.body`.
    func receiveBody(deadline: NIODeadline = .now() + .seconds(10)) throws -> ByteBuffer {
        let part = try readInbound(deadline: deadline)
        switch part {
        case let .body(buffer):
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
    func receiveBodyAndVerify(deadline: NIODeadline = .now() + .seconds(10),
                              _ verify: (ByteBuffer) throws -> Void = { _ in }) throws
    {
        try verify(receiveBody(deadline: deadline))
    }

    /// Waits for a message part to be received and checks that it was a `.end` before returning
    /// the `HTTPHeaders?` it contained.
    ///
    /// - Parameters:
    ///   - deadline: The deadline by which a part must have been received.
    /// - Throws: If the part was not a `.end` or nothing was read before the deadline.
    /// - Returns: The `HTTPHeaders?` from the `.end`.
    func receiveEnd(deadline: NIODeadline = .now() + .seconds(10)) throws -> HTTPHeaders? {
        let part = try readInbound(deadline: deadline)
        switch part {
        case let .end(trailers):
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
    func receiveEndAndVerify(deadline _: NIODeadline = .now() + .seconds(10),
                             _ verify: (HTTPHeaders?) throws -> Void = { _ in }) throws
    {
        try verify(receiveEnd())
    }
}

public struct NIOHTTP1TestServerError: Error, Hashable, CustomStringConvertible {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String {
        reason
    }
}
