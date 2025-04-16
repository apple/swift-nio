//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
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
import NIOTestUtils
import XCTest

typealias SendableRequestPart = HTTPPart<HTTPRequestHead, ByteBuffer>

extension HTTPClientRequestPart {
    init(_ target: SendableRequestPart) {
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

extension SendableRequestPart {
    init(_ target: HTTPClientRequestPart) throws {
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

/// A helper handler to transform a Sendable request into a
/// non-Sendable one, to manage warnings.
private final class TransformerHandler: ChannelOutboundHandler {
    typealias OutboundIn = SendableRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let response = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(.init(response)), promise: nil)
    }
}

class NIOHTTP1TestServerTest: XCTestCase {
    private var group: EventLoopGroup!
    private let allocator = ByteBufferAllocator()

    override func setUp() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
        self.group = nil
    }

    func connect(serverPort: Int, responsePromise: EventLoopPromise<String>) throws -> EventLoopFuture<Channel> {
        let bootstrap = ClientBootstrap(group: self.group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    try sync.addHTTPClientHandlers(position: .first, leftOverBytesStrategy: .fireError)
                    try sync.addHandler(AggregateBodyHandler())
                    try sync.addHandler(TestHTTPHandler(responsePromise: responsePromise))
                    try sync.addHandler(TransformerHandler())
                }
            }
        return bootstrap.connect(host: "127.0.0.1", port: serverPort)
    }

    private func sendRequest(channel: Channel, uri: String, message: String) {
        let requestBuffer = allocator.buffer(string: message)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(requestBuffer.readableBytes)")

        let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: uri,
            headers: headers
        )

        channel.write(SendableRequestPart.head(requestHead), promise: nil)
        channel.write(SendableRequestPart.body(requestBuffer), promise: nil)
        channel.writeAndFlush(SendableRequestPart.end(nil), promise: nil)
    }

    private func sendRequestTo(_ url: URL, body: String) throws -> EventLoopFuture<String> {
        let responsePromise = self.group.next().makePromise(of: String.self)
        let channel = try connect(serverPort: url.port!, responsePromise: responsePromise).wait()
        sendRequest(channel: channel, uri: url.path, message: body)
        return responsePromise.futureResult
    }

    func testTheExampleInTheDocs() {
        // Setup the test environment.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let allocator = ByteBufferAllocator()
        let testServer = NIOHTTP1TestServer(group: group)
        defer {
            XCTAssertNoThrow(try testServer.stop())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        // Use your library to send a request to the server.
        let requestBody = "ping"
        var requestComplete: EventLoopFuture<String>!
        XCTAssertNoThrow(
            requestComplete = try sendRequestTo(
                URL(string: "http://127.0.0.1:\(testServer.serverPort)/some-route")!,
                body: requestBody
            )
        )

        // Assert the server received the expected request.
        // Use custom methods if you only want some specific assertions on part
        // of the request.
        XCTAssertNoThrow(
            XCTAssertEqual(
                .head(
                    .init(
                        version: .http1_1,
                        method: .GET,
                        uri: "/some-route",
                        headers: .init([
                            ("Content-Type", "text/plain; charset=utf-8"),
                            ("Content-Length", "4"),
                        ])
                    )
                ),
                try testServer.readInbound()
            )
        )
        var requestBuffer = allocator.buffer(capacity: 128)
        requestBuffer.writeString(requestBody)
        XCTAssertNoThrow(
            XCTAssertEqual(
                .body(requestBuffer),
                try testServer.readInbound()
            )
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                .end(nil),
                try testServer.readInbound()
            )
        )

        // Make the server send a response to the client.
        let responseBody = "pong"
        var responseBuffer = allocator.buffer(capacity: 128)
        responseBuffer.writeString(responseBody)
        XCTAssertNoThrow(try testServer.writeOutbound(.head(.init(version: .http1_1, status: .ok))))
        XCTAssertNoThrow(try testServer.writeOutbound(.body(.byteBuffer(responseBuffer))))
        XCTAssertNoThrow(try testServer.writeOutbound(.end(nil)))

        // Assert that the client received the response from the server.
        XCTAssertNoThrow(XCTAssertEqual(responseBody, try requestComplete.wait()))
    }

    func testSimpleRequest() {
        let uri = "/request"
        let requestMessage = "request message"
        let responseMessage = "response message"
        let testServer = NIOHTTP1TestServer(group: self.group)
        defer {
            XCTAssertNoThrow(try testServer.stop())
        }

        // Establish the connection and send the request
        let responsePromise = self.group.next().makePromise(of: String.self)
        var channel: Channel!
        XCTAssertNoThrow(
            channel = try self.connect(serverPort: testServer.serverPort, responsePromise: responsePromise).wait()
        )

        // Send a request to the server
        self.sendRequest(channel: channel, uri: uri, message: requestMessage)
        let response = responsePromise.futureResult

        // Assert we received the expected request
        XCTAssertNoThrow(try testServer.readInbound().assertHead(expectedURI: uri))
        XCTAssertNoThrow(try testServer.readInbound().assertBody(expectedMessage: requestMessage))
        XCTAssertNoThrow(try testServer.readInbound().assertEnd())

        // Send the response to the client
        let responseBuffer = allocator.buffer(string: responseMessage)
        XCTAssertNoThrow(try testServer.writeOutbound(.head(.init(version: .http1_1, status: .ok))))
        XCTAssertNoThrow(try testServer.writeOutbound(.body(.byteBuffer(responseBuffer))))
        XCTAssertNoThrow(try testServer.writeOutbound(.end(nil)))

        // Verify that the client got what the server sent
        XCTAssertNoThrow(XCTAssertEqual(responseMessage, try response.wait()))
    }

    func testConcurrentRequests() {
        let testServer = NIOHTTP1TestServer(group: self.group)
        defer {
            XCTAssertNoThrow(try testServer.stop())
        }

        // Establish two "concurrent" requests
        let request1URI = "/request1"
        let request1Message = "Request #1"
        let response1Promise = self.group.next().makePromise(of: String.self)
        var channel1: Channel!
        XCTAssertNoThrow(
            channel1 = try self.connect(serverPort: testServer.serverPort, responsePromise: response1Promise).wait()
        )

        let request2URI = "/request2"
        let request2Message = "Request #2"
        let response2Promise = self.group.next().makePromise(of: String.self)
        var channel2: Channel!
        XCTAssertNoThrow(
            channel2 = try self.connect(serverPort: testServer.serverPort, responsePromise: response2Promise).wait()
        )

        // Both channels are connected to the server. Request on `channel1`
        // connected connection first so `testServer` will handle it completely
        // before moving on to the request on `channel2`.

        // Send a request to the server using the second channel (Accepted but the server is not handling it)
        self.sendRequest(channel: channel2, uri: request2URI, message: request2Message)

        // Check that nothing happened. The server is blocked waiting for the first
        // request to complete so it times out and throws when we try to read from it
        // before the first request completes.
        XCTAssertThrowsError(try testServer.readInbound(deadline: .now() + .milliseconds(5)))

        // Send a request to the server using the second channel (Currently handled by the server)
        self.sendRequest(channel: channel1, uri: request1URI, message: request1Message)

        // Assert we received the expected request from client1
        XCTAssertNoThrow(try testServer.readInbound().assertHead(expectedURI: request1URI))
        XCTAssertNoThrow(try testServer.readInbound().assertBody(expectedMessage: request1Message))
        XCTAssertNoThrow(try testServer.readInbound().assertEnd())

        // Send the response to client1
        let response1Message = "Response #1"
        let response1Buffer = allocator.buffer(string: response1Message)
        XCTAssertNoThrow(try testServer.writeOutbound(.head(.init(version: .http1_1, status: .ok))))
        XCTAssertNoThrow(try testServer.writeOutbound(.body(.byteBuffer(response1Buffer))))
        XCTAssertNoThrow(try testServer.writeOutbound(.end(nil)))

        // Assert we received the expected request from client2
        XCTAssertNoThrow(try testServer.readInbound().assertHead(expectedURI: request2URI))
        XCTAssertNoThrow(try testServer.readInbound().assertBody(expectedMessage: request2Message))
        XCTAssertNoThrow(try testServer.readInbound().assertEnd())

        // Send the response to client2
        let response2Message = "Response #2"
        let response2Buffer = allocator.buffer(string: response2Message)
        XCTAssertNoThrow(try testServer.writeOutbound(.head(.init(version: .http1_1, status: .ok))))
        XCTAssertNoThrow(try testServer.writeOutbound(.body(.byteBuffer(response2Buffer))))
        XCTAssertNoThrow(try testServer.writeOutbound(.end(nil)))

        // Verify that the each client got their own response
        XCTAssertNoThrow(XCTAssertEqual(response1Message, try response1Promise.futureResult.wait()))
        XCTAssertNoThrow(XCTAssertEqual(response2Message, try response2Promise.futureResult.wait()))
    }

    func testTestWebServerCanBeReleased() {
        weak var weakTestServer: NIOHTTP1TestServer? = nil
        func doIt() {
            let testServer = NIOHTTP1TestServer(group: self.group)
            weakTestServer = testServer
            XCTAssertNoThrow(try testServer.stop())
        }
        doIt()
        assert(weakTestServer == nil, within: .milliseconds(500))
    }

    func testStopClosesAcceptedChannel() {
        let testServer = NIOHTTP1TestServer(group: self.group)

        let responsePromise = self.group.next().makePromise(of: String.self)
        var channel: Channel!
        XCTAssertNoThrow(
            channel = try self.connect(
                serverPort: testServer.serverPort,
                responsePromise: responsePromise
            ).wait()
        )
        self.sendRequest(channel: channel, uri: "/uri", message: "hello")

        XCTAssertNoThrow(try testServer.readInbound().assertHead(expectedURI: "/uri"))
        XCTAssertNoThrow(try testServer.readInbound().assertBody(expectedMessage: "hello"))
        XCTAssertNoThrow(try testServer.readInbound().assertEnd())

        XCTAssertNoThrow(try testServer.stop())
        XCTAssertNotNil(channel)
        XCTAssertNoThrow(try channel.closeFuture.wait())
    }

    func testReceiveAndVerify() {
        let testServer = NIOHTTP1TestServer(group: self.group)

        let responsePromise = self.group.next().makePromise(of: String.self)
        var channel: Channel!
        XCTAssertNoThrow(
            channel = try self.connect(
                serverPort: testServer.serverPort,
                responsePromise: responsePromise
            ).wait()
        )
        self.sendRequest(channel: channel, uri: "/uri", message: "hello")

        XCTAssertNoThrow(
            try testServer.receiveHeadAndVerify { head in
                XCTAssertEqual(head.uri, "/uri")
            }
        )

        XCTAssertNoThrow(
            try testServer.receiveBodyAndVerify { buffer in
                XCTAssertEqual(buffer, ByteBuffer(string: "hello"))
            }
        )

        XCTAssertNoThrow(
            try testServer.receiveEndAndVerify { trailers in
                XCTAssertNil(trailers)
            }
        )

        XCTAssertNoThrow(try testServer.stop())
        XCTAssertNotNil(channel)
        XCTAssertNoThrow(try channel.closeFuture.wait())
    }

    func testReceive() throws {
        let testServer = NIOHTTP1TestServer(group: self.group)

        let responsePromise = self.group.next().makePromise(of: String.self)
        var channel: Channel!
        XCTAssertNoThrow(
            channel = try self.connect(
                serverPort: testServer.serverPort,
                responsePromise: responsePromise
            ).wait()
        )
        self.sendRequest(channel: channel, uri: "/uri", message: "hello")

        let head = try assertNoThrowWithValue(try testServer.receiveHead())
        XCTAssertEqual(head.uri, "/uri")

        let body = try assertNoThrowWithValue(try testServer.receiveBody())
        XCTAssertEqual(body, ByteBuffer(string: "hello"))

        let trailers = try assertNoThrowWithValue(try testServer.receiveEnd())
        XCTAssertNil(trailers)

        XCTAssertNoThrow(try testServer.stop())
        XCTAssertNotNil(channel)
        XCTAssertNoThrow(try channel.closeFuture.wait())
    }

    func testReceiveAndVerifyWrongPart() {
        let testServer = NIOHTTP1TestServer(group: self.group)

        let responsePromise = self.group.next().makePromise(of: String.self)
        var channel: Channel!
        XCTAssertNoThrow(
            channel = try self.connect(
                serverPort: testServer.serverPort,
                responsePromise: responsePromise
            ).wait()
        )
        self.sendRequest(channel: channel, uri: "/uri", message: "hello")

        XCTAssertThrowsError(try testServer.receiveEndAndVerify()) { error in
            XCTAssert(error is NIOHTTP1TestServerError)
        }

        XCTAssertThrowsError(try testServer.receiveHeadAndVerify()) { error in
            XCTAssert(error is NIOHTTP1TestServerError)
        }

        XCTAssertThrowsError(try testServer.receiveBodyAndVerify()) { error in
            XCTAssert(error is NIOHTTP1TestServerError)
        }

        XCTAssertNoThrow(try testServer.stop())
        XCTAssertNotNil(channel)
        XCTAssertNoThrow(try channel.closeFuture.wait())
    }

    func testReceiveBodyWithoutAggregation() {
        let testServer = NIOHTTP1TestServer(group: self.group, aggregateBody: false)

        let responsePromise = self.group.next().makePromise(of: String.self)
        var channel: Channel!
        XCTAssertNoThrow(
            channel = try self.connect(
                serverPort: testServer.serverPort,
                responsePromise: responsePromise
            ).wait()
        )

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/uri", headers: headers)
        channel.writeAndFlush(SendableRequestPart.head(requestHead), promise: nil)
        XCTAssertNoThrow(
            try testServer.receiveHeadAndVerify { head in
                XCTAssertEqual(head.uri, "/uri")
                XCTAssertEqual(head.headers["Content-Type"], ["text/plain; charset=utf-8"])
            }
        )
        XCTAssertNoThrow(try testServer.writeOutbound(.head(.init(version: .http1_1, status: .ok))))

        for _ in 0..<10 {
            channel.writeAndFlush(
                SendableRequestPart.body(ByteBuffer(string: "ping")),
                promise: nil
            )
            XCTAssertNoThrow(
                try testServer.receiveBodyAndVerify { buffer in
                    XCTAssertEqual(String(buffer: buffer), "ping")
                }
            )
            XCTAssertNoThrow(try testServer.writeOutbound(.body(.byteBuffer(ByteBuffer(string: "pong")))))
        }

        channel.writeAndFlush(SendableRequestPart.end(nil), promise: nil)
        XCTAssertNoThrow(
            try testServer.receiveEndAndVerify { trailers in
                XCTAssertNil(trailers)
            }
        )
        XCTAssertNoThrow(try testServer.writeOutbound(.end(nil)))

        XCTAssertNoThrow(try testServer.stop())
        XCTAssertNotNil(channel)
        XCTAssertNoThrow(try channel.closeFuture.wait())
    }

    func testCloseChannelWhileItIsWaiting() throws {
        let testServer = NIOHTTP1TestServer(group: self.group, aggregateBody: false)
        let firstResponsePromise = self.group.next().makePromise(of: String.self)
        let firstChannel = try self.connect(serverPort: testServer.serverPort, responsePromise: firstResponsePromise)
            .wait()

        // Send a request head and wait for it to be sent, and received at the test server so we know the connection is well underway.
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/uri")
        firstChannel.writeAndFlush(SendableRequestPart.head(requestHead), promise: nil)
        XCTAssertNoThrow(
            try testServer.receiveHeadAndVerify { head in
                XCTAssertEqual(head.uri, "/uri")
            }
        )

        // Create a second channel now.
        let secondResponsePromise = self.group.next().makePromise(of: String.self)
        let secondChannel = try self.connect(serverPort: testServer.serverPort, responsePromise: secondResponsePromise)
            .wait()

        // To burn a little time and convince ourselves that things are going fairly well, we can send a body payload on the first channel
        // and confirm it comes through.
        firstChannel.writeAndFlush(
            SendableRequestPart.body(ByteBuffer(string: "ping")),
            promise: nil
        )
        XCTAssertNoThrow(
            try testServer.receiveBodyAndVerify { buffer in
                XCTAssertEqual(String(buffer: buffer), "ping")
            }
        )

        // Now, close the second channel.
        try secondChannel.close().wait()

        // Now we can complete the transaction.
        firstChannel.writeAndFlush(SendableRequestPart.end(nil), promise: nil)
        XCTAssertNoThrow(
            try testServer.receiveEndAndVerify { trailers in
                XCTAssertNil(trailers)
            }
        )
        XCTAssertNoThrow(try testServer.writeOutbound(.head(.init(version: .http1_1, status: .ok))))
        XCTAssertNoThrow(try testServer.writeOutbound(.end(nil)))

        // The promise for the second should error.
        XCTAssertThrowsError(try secondResponsePromise.futureResult.wait())
    }
}

private final class TestHTTPHandler: ChannelInboundHandler {
    public typealias InboundIn = HTTPClientResponsePart
    public typealias OutboundOut = HTTPClientRequestPart

    private let responsePromise: EventLoopPromise<String>

    init(responsePromise: EventLoopPromise<String>) {
        self.responsePromise = responsePromise
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        struct HandlerRemovedBeforeReceivingFullRequestError: Error {}
        self.responsePromise.fail(HandlerRemovedBeforeReceivingFullRequestError())
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head(let responseHead):
            guard case .ok = responseHead.status else {
                self.responsePromise.fail(ResponseError.badStatus)
                return
            }
        case .body(let byteBuffer):
            // We're using AggregateBodyHandler so we see all the body content at once
            let string = String(buffer: byteBuffer)
            self.responsePromise.succeed(string)
        case .end:
            context.close(promise: nil)
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.responsePromise.fail(error)
        context.close(promise: nil)
    }
}

extension HTTPServerRequestPart {
    func assertHead(expectedURI: String, file: StaticString = #filePath, line: UInt = #line) {
        switch self {
        case .head(let head):
            XCTAssertEqual(.GET, head.method)
            XCTAssertEqual(expectedURI, head.uri)
            XCTAssertEqual("text/plain; charset=utf-8", head.headers["Content-Type"].first)
        default:
            XCTFail("Expected head, got \(self)", file: (file), line: line)
        }
    }

    func assertBody(expectedMessage: String, file: StaticString = #filePath, line: UInt = #line) {
        switch self {
        case .body(let buffer):
            // Note that the test server coalesces the body parts for us.
            XCTAssertEqual(
                expectedMessage,
                String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self)
            )
        default:
            XCTFail("Expected body, got \(self)", file: (file), line: line)
        }
    }

    func assertEnd(file: StaticString = #filePath, line: UInt = #line) {
        switch self {
        case .end(_):
            ()
        default:
            XCTFail("Expected end, got \(self)", file: (file), line: line)
        }
    }
}

private final class AggregateBodyHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias InboundOut = HTTPClientResponsePart

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

private enum ResponseError: Error {
    case badStatus
    case missingResponse
}

func assert(
    _ condition: @autoclosure () -> Bool,
    within time: TimeAmount,
    testInterval: TimeAmount? = nil,
    _ message: String = "condition not satisfied in time",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let testInterval = testInterval ?? TimeAmount.nanoseconds(time.nanoseconds / 5)
    let endTime = NIODeadline.now() + time

    repeat {
        if condition() { return }
        usleep(UInt32(testInterval.nanoseconds / 1000))
    } while NIODeadline.now() < endTime

    if !condition() {
        XCTFail(message, file: (file), line: line)
    }
}

func assertNoThrowWithValue<T>(
    _ body: @autoclosure () throws -> T,
    defaultValue: T? = nil,
    message: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    do {
        return try body()
    } catch {
        XCTFail("\(message.map { $0 + ": " } ?? "")unexpected error \(error) thrown", file: (file), line: line)
        if let defaultValue = defaultValue {
            return defaultValue
        } else {
            throw error
        }
    }
}
