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
import NIOEmbedded
import NIOHTTP1
import NIOTestUtils
import XCTest

private final class ReadRecorder<T: Equatable>: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = T

    enum Event: Equatable {
        case channelRead(InboundIn)
        case httpFrameTooLongEvent
        case httpExpectationFailedEvent

        static func == (lhs: Event, rhs: Event) -> Bool {
            switch (lhs, rhs) {
            case (.channelRead(let b1), .channelRead(let b2)):
                return b1 == b2
            case (.httpFrameTooLongEvent, .httpFrameTooLongEvent):
                return true
            case (.httpExpectationFailedEvent, .httpExpectationFailedEvent):
                return true
            default:
                return false
            }
        }
    }

    public var reads: [Event] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.reads.append(.channelRead(Self.unwrapInboundIn(data)))
        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as NIOHTTPObjectAggregatorEvent where evt == NIOHTTPObjectAggregatorEvent.httpFrameTooLong:
            self.reads.append(.httpFrameTooLongEvent)
        case let evt as NIOHTTPObjectAggregatorEvent where evt == NIOHTTPObjectAggregatorEvent.httpExpectationFailed:
            self.reads.append(.httpExpectationFailedEvent)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func clear() {
        self.reads.removeAll(keepingCapacity: true)
    }
}

private final class WriteRecorder: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = HTTPServerResponsePart

    public var writes: [HTTPServerResponsePart] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.writes.append(Self.unwrapOutboundIn(data))

        context.write(data, promise: promise)
    }

    func clear() {
        self.writes.removeAll(keepingCapacity: true)
    }
}

extension ByteBuffer {
    fileprivate func assertContainsOnly(_ string: String) {
        let innerData = self.getString(at: self.readerIndex, length: self.readableBytes)!
        XCTAssertEqual(innerData, string)
    }
}

private func asHTTPResponseHead(_ response: HTTPServerResponsePart) -> HTTPResponseHead? {
    switch response {
    case .head(let resHead):
        return resHead
    default:
        return nil
    }
}

class NIOHTTPServerRequestAggregatorTest: XCTestCase {
    var channel: EmbeddedChannel! = nil
    var requestHead: HTTPRequestHead! = nil
    var responseHead: HTTPResponseHead! = nil
    fileprivate var readRecorder: ReadRecorder<NIOHTTPServerRequestFull>! = nil
    fileprivate var writeRecorder: WriteRecorder! = nil
    fileprivate var aggregatorHandler: NIOHTTPServerRequestAggregator! = nil

    override func setUp() {
        self.channel = EmbeddedChannel()
        self.readRecorder = ReadRecorder()
        self.writeRecorder = WriteRecorder()
        self.aggregatorHandler = NIOHTTPServerRequestAggregator(maxContentLength: 1024 * 1024)

        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder()))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(self.writeRecorder))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(self.aggregatorHandler))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(self.readRecorder))

        self.requestHead = HTTPRequestHead(version: .http1_1, method: .PUT, uri: "/path")
        self.requestHead.headers.add(name: "Host", value: "example.com")
        self.requestHead.headers.add(name: "X-Test", value: "True")

        self.responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        self.responseHead.headers.add(name: "Server", value: "SwiftNIO")

        // this activates the channel
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait())
    }

    /// Modify pipeline setup to use aggregator with a smaller `maxContentLength`
    private func resetSmallHandler(maxContentLength: Int) {
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.removeHandler(self.readRecorder!).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.removeHandler(self.aggregatorHandler!).wait())
        self.aggregatorHandler = NIOHTTPServerRequestAggregator(maxContentLength: maxContentLength)
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(self.aggregatorHandler))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(self.readRecorder))
    }

    override func tearDown() {
        if let channel = self.channel {
            XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true))
            self.channel = nil
        }
        self.requestHead = nil
        self.responseHead = nil
        self.readRecorder = nil
        self.writeRecorder = nil
        self.aggregatorHandler = nil
    }

    func testAggregateNoBody() {
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Only one request should have made it through.
        XCTAssertEqual(
            self.readRecorder.reads,
            [.channelRead(NIOHTTPServerRequestFull(head: self.requestHead, body: nil))]
        )
    }

    func testAggregateWithBody() {
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTPServerRequestPart.body(
                    channel.allocator.buffer(string: "hello")
                )
            )
        )
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Only one request should have made it through.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(
                    NIOHTTPServerRequestFull(
                        head: self.requestHead,
                        body: channel.allocator.buffer(string: "hello")
                    )
                )
            ]
        )
    }

    func testAggregateChunkedBody() {
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))

        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTPServerRequestPart.body(
                    channel.allocator.buffer(string: "hello")
                )
            )
        )
        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTPServerRequestPart.body(
                    channel.allocator.buffer(string: "world")
                )
            )
        )
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Only one request should have made it through.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(
                    NIOHTTPServerRequestFull(
                        head: self.requestHead,
                        body: channel.allocator.buffer(string: "helloworld")
                    )
                )
            ]
        )
    }

    func testAggregateWithTrailer() {
        var reqWithChunking: HTTPRequestHead = self.requestHead
        reqWithChunking.headers.add(name: "transfer-encoding", value: "chunked")
        reqWithChunking.headers.add(name: "Trailer", value: "X-Trailer")

        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(reqWithChunking)))

        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTPServerRequestPart.body(
                    channel.allocator.buffer(string: "hello")
                )
            )
        )
        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTPServerRequestPart.body(
                    channel.allocator.buffer(string: "world")
                )
            )
        )
        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTPServerRequestPart.end(
                    HTTPHeaders.init([("X-Trailer", "true")])
                )
            )
        )

        reqWithChunking.headers.remove(name: "Trailer")
        reqWithChunking.headers.add(name: "X-Trailer", value: "true")

        // Trailer headers should get moved to normal ones
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(
                    NIOHTTPServerRequestFull(
                        head: reqWithChunking,
                        body: channel.allocator.buffer(string: "helloworld")
                    )
                )
            ]
        )
    }

    func testOversizeRequest() {
        resetSmallHandler(maxContentLength: 4)

        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertTrue(channel.isActive)

        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTPServerRequestPart.body(
                    channel.allocator.buffer(string: "he")
                )
            )
        )
        XCTAssertEqual(self.writeRecorder.writes, [])

        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTPServerRequestPart.body(
                    channel.allocator.buffer(string: "llo")
                )
            )
        ) { error in
            XCTAssertEqual(NIOHTTPObjectAggregatorError.frameTooLong, error as? NIOHTTPObjectAggregatorError)
        }

        let resTooLarge = HTTPResponseHead(
            version: .http1_1,
            status: .payloadTooLarge,
            headers: HTTPHeaders([("Content-Length", "0"), ("connection", "close")])
        )

        XCTAssertEqual(
            self.writeRecorder.writes,
            [
                HTTPServerResponsePart.head(resTooLarge),
                HTTPServerResponsePart.end(nil),
            ]
        )

        XCTAssertFalse(channel.isActive)
        XCTAssertThrowsError(try self.channel.writeInbound(HTTPServerRequestPart.end(nil))) { error in
            XCTAssertEqual(NIOHTTPObjectAggregatorError.connectionClosed, error as? NIOHTTPObjectAggregatorError)
        }
    }

    func testOversizedRequestWithoutKeepAlive() {
        resetSmallHandler(maxContentLength: 4)

        // send an HTTP/1.0 request with no keep-alive header
        let requestHead: HTTPRequestHead = HTTPRequestHead(
            version: .http1_0,
            method: .PUT,
            uri: "/path",
            headers: HTTPHeaders(
                [("Host", "example.com"), ("X-Test", "True"), ("content-length", "5")])
        )

        XCTAssertThrowsError(try self.channel.writeInbound(HTTPServerRequestPart.head(requestHead)))

        let resTooLarge = HTTPResponseHead(
            version: .http1_0,
            status: .payloadTooLarge,
            headers: HTTPHeaders([("Content-Length", "0"), ("connection", "close")])
        )

        XCTAssertEqual(
            self.writeRecorder.writes,
            [
                HTTPServerResponsePart.head(resTooLarge),
                HTTPServerResponsePart.end(nil),
            ]
        )

        // Connection should be closed right away
        XCTAssertFalse(channel.isActive)

        XCTAssertThrowsError(try self.channel.writeInbound(HTTPServerRequestPart.end(nil))) { error in
            XCTAssertEqual(NIOHTTPObjectAggregatorError.connectionClosed, error as? NIOHTTPObjectAggregatorError)
        }
    }

    func testOversizedRequestWithContentLength() {
        resetSmallHandler(maxContentLength: 4)

        // HTTP/1.1 uses Keep-Alive unless told otherwise
        let requestHead: HTTPRequestHead = HTTPRequestHead(
            version: .http1_1,
            method: .PUT,
            uri: "/path",
            headers: HTTPHeaders(
                [("Host", "example.com"), ("X-Test", "True"), ("content-length", "8")])
        )

        resetSmallHandler(maxContentLength: 4)

        XCTAssertThrowsError(try self.channel.writeInbound(HTTPServerRequestPart.head(requestHead)))

        let response = asHTTPResponseHead(self.writeRecorder.writes.first!)!
        XCTAssertEqual(response.status, .payloadTooLarge)
        XCTAssertEqual(response.headers[canonicalForm: "content-length"], ["0"])
        XCTAssertEqual(response.version, requestHead.version)

        // Connection should be kept open
        XCTAssertTrue(channel.isActive)

        // An ill-behaved client may continue writing the request
        let requestParts = [
            HTTPServerRequestPart.body(channel.allocator.buffer(bytes: [1, 2, 3, 4])),
            HTTPServerRequestPart.body(channel.allocator.buffer(bytes: [5, 6])),
            HTTPServerRequestPart.body(channel.allocator.buffer(bytes: [7, 8])),
        ]

        for requestPart in requestParts {
            XCTAssertThrowsError(try self.channel.writeInbound(requestPart))
        }

        // The aggregated message should not get passed up as it is too large.
        // There should only be one "frame too long" event despite multiple writes
        XCTAssertEqual(self.readRecorder.reads, [.httpFrameTooLongEvent])
        XCTAssertThrowsError(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        XCTAssertEqual(self.readRecorder.reads, [.httpFrameTooLongEvent])

        // Write another request that is small enough
        var secondReqWithContentLength: HTTPRequestHead = self.requestHead
        secondReqWithContentLength.headers.replaceOrAdd(name: "content-length", value: "2")

        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(secondReqWithContentLength)))

        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTPServerRequestPart.body(
                    channel.allocator.buffer(bytes: [1])
                )
            )
        )
        XCTAssertEqual(self.readRecorder.reads, [.httpFrameTooLongEvent])
        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTPServerRequestPart.body(
                    channel.allocator.buffer(bytes: [2])
                )
            )
        )
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .httpFrameTooLongEvent,
                .channelRead(
                    NIOHTTPServerRequestFull(
                        head: secondReqWithContentLength,
                        body: channel.allocator.buffer(bytes: [1, 2])
                    )
                ),
            ]
        )
    }
}

class NIOHTTPClientResponseAggregatorTest: XCTestCase {
    var channel: EmbeddedChannel! = nil
    var requestHead: HTTPRequestHead! = nil
    var responseHead: HTTPResponseHead! = nil
    fileprivate var readRecorder: ReadRecorder<NIOHTTPClientResponseFull>! = nil
    fileprivate var aggregatorHandler: NIOHTTPClientResponseAggregator! = nil

    override func setUp() {
        self.channel = EmbeddedChannel()
        self.readRecorder = ReadRecorder()
        self.aggregatorHandler = NIOHTTPClientResponseAggregator(maxContentLength: 1024 * 1024)

        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(HTTPRequestEncoder()))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(self.aggregatorHandler))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(self.readRecorder))

        self.requestHead = HTTPRequestHead(version: .http1_1, method: .PUT, uri: "/path")
        self.requestHead.headers.add(name: "Host", value: "example.com")
        self.requestHead.headers.add(name: "X-Test", value: "True")

        self.responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        self.responseHead.headers.add(name: "Server", value: "SwiftNIO")

        // this activates the channel
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait())
    }

    /// Modify pipeline setup to use aggregator with a smaller `maxContentLength`
    private func resetSmallHandler(maxContentLength: Int) {
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.removeHandler(self.readRecorder!).wait())
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.removeHandler(self.aggregatorHandler!).wait())
        self.aggregatorHandler = NIOHTTPClientResponseAggregator(maxContentLength: maxContentLength)
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(self.aggregatorHandler))
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(self.readRecorder!))
    }

    override func tearDown() {
        if let channel = self.channel {
            XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true))
            self.channel = nil
        }
        self.requestHead = nil
        self.responseHead = nil
        self.readRecorder = nil
        self.aggregatorHandler = nil
    }

    func testOversizeResponseHead() {
        resetSmallHandler(maxContentLength: 5)

        var resHead: HTTPResponseHead = self.responseHead
        resHead.headers.replaceOrAdd(name: "content-length", value: "10")

        XCTAssertThrowsError(try self.channel.writeInbound(HTTPClientResponsePart.head(resHead)))
        XCTAssertThrowsError(try self.channel.writeInbound(HTTPClientResponsePart.end(nil)))

        // User event triggered
        XCTAssertEqual(self.readRecorder.reads, [.httpFrameTooLongEvent])
    }

    func testOversizeResponse() {
        resetSmallHandler(maxContentLength: 5)

        XCTAssertNoThrow(try self.channel.writeInbound(HTTPClientResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTPClientResponsePart.body(
                    self.channel.allocator.buffer(string: "hello")
                )
            )
        )

        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTPClientResponsePart.body(
                    self.channel.allocator.buffer(string: "world")
                )
            )
        )
        XCTAssertThrowsError(try self.channel.writeInbound(HTTPClientResponsePart.end(nil)))

        // User event triggered
        XCTAssertEqual(self.readRecorder.reads, [.httpFrameTooLongEvent])
    }

    func testAggregatedResponse() {
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPClientResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTPClientResponsePart.body(
                    self.channel.allocator.buffer(string: "hello")
                )
            )
        )
        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTPClientResponsePart.body(
                    self.channel.allocator.buffer(string: "world")
                )
            )
        )
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPClientResponsePart.end(HTTPHeaders([("X-Trail", "true")]))))

        var aggregatedHead: HTTPResponseHead = self.responseHead
        aggregatedHead.headers.add(name: "X-Trail", value: "true")

        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(
                    NIOHTTPClientResponseFull(
                        head: aggregatedHead,
                        body: self.channel.allocator.buffer(string: "helloworld")
                    )
                )
            ]
        )
    }

    func testOkAfterOversized() {
        resetSmallHandler(maxContentLength: 4)

        XCTAssertNoThrow(try self.channel.writeInbound(HTTPClientResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTPClientResponsePart.body(
                    self.channel.allocator.buffer(string: "hell")
                )
            )
        )
        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTPClientResponsePart.body(
                    self.channel.allocator.buffer(string: "owor")
                )
            )
        )
        XCTAssertThrowsError(
            try self.channel.writeInbound(
                HTTPClientResponsePart.body(
                    self.channel.allocator.buffer(string: "ld")
                )
            )
        )
        XCTAssertThrowsError(try self.channel.writeInbound(HTTPClientResponsePart.end(nil)))

        // User event triggered
        XCTAssertEqual(self.readRecorder.reads, [.httpFrameTooLongEvent])

        XCTAssertNoThrow(try self.channel.writeInbound(HTTPClientResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(
            try self.channel.writeInbound(
                HTTPClientResponsePart.body(
                    self.channel.allocator.buffer(string: "test")
                )
            )
        )
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPClientResponsePart.end(nil)))

        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .httpFrameTooLongEvent,
                .channelRead(
                    NIOHTTPClientResponseFull(
                        head: self.responseHead,
                        body: self.channel.allocator.buffer(string: "test")
                    )
                ),
            ]
        )
    }

}
