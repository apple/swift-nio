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
            case let (.channelRead(b1), .channelRead(b2)):
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
        reads.append(.channelRead(unwrapInboundIn(data)))
        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as NIOHTTPObjectAggregatorEvent where evt == NIOHTTPObjectAggregatorEvent.httpFrameTooLong:
            reads.append(.httpFrameTooLongEvent)
        case let evt as NIOHTTPObjectAggregatorEvent where evt == NIOHTTPObjectAggregatorEvent.httpExpectationFailed:
            reads.append(.httpExpectationFailedEvent)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func clear() {
        reads.removeAll(keepingCapacity: true)
    }
}

private final class WriteRecorder: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = HTTPServerResponsePart

    public var writes: [HTTPServerResponsePart] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        writes.append(unwrapOutboundIn(data))

        context.write(data, promise: promise)
    }

    func clear() {
        writes.removeAll(keepingCapacity: true)
    }
}

private extension ByteBuffer {
    func assertContainsOnly(_ string: String) {
        let innerData = getString(at: readerIndex, length: readableBytes)!
        XCTAssertEqual(innerData, string)
    }
}

private func asHTTPResponseHead(_ response: HTTPServerResponsePart) -> HTTPResponseHead? {
    switch response {
    case let .head(resHead):
        return resHead
    default:
        return nil
    }
}

class NIOHTTPServerRequestAggregatorTest: XCTestCase {
    var channel: EmbeddedChannel!
    var requestHead: HTTPRequestHead!
    var responseHead: HTTPResponseHead!
    fileprivate var readRecorder: ReadRecorder<NIOHTTPServerRequestFull>!
    fileprivate var writeRecorder: WriteRecorder!
    fileprivate var aggregatorHandler: NIOHTTPServerRequestAggregator!

    override func setUp() {
        channel = EmbeddedChannel()
        readRecorder = ReadRecorder()
        writeRecorder = WriteRecorder()
        aggregatorHandler = NIOHTTPServerRequestAggregator(maxContentLength: 1024 * 1024)

        XCTAssertNoThrow(try channel.pipeline.addHandler(HTTPResponseEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(aggregatorHandler).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(readRecorder).wait())

        requestHead = HTTPRequestHead(version: .http1_1, method: .PUT, uri: "/path")
        requestHead.headers.add(name: "Host", value: "example.com")
        requestHead.headers.add(name: "X-Test", value: "True")

        responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        responseHead.headers.add(name: "Server", value: "SwiftNIO")

        // this activates the channel
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait())
    }

    /// Modify pipeline setup to use aggregator with a smaller `maxContentLength`
    private func resetSmallHandler(maxContentLength: Int) {
        XCTAssertNoThrow(try channel.pipeline.removeHandler(readRecorder!).wait())
        XCTAssertNoThrow(try channel.pipeline.removeHandler(aggregatorHandler!).wait())
        aggregatorHandler = NIOHTTPServerRequestAggregator(maxContentLength: maxContentLength)
        XCTAssertNoThrow(try channel.pipeline.addHandler(aggregatorHandler).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(readRecorder).wait())
    }

    override func tearDown() {
        if let channel = self.channel {
            XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true))
            self.channel = nil
        }
        requestHead = nil
        responseHead = nil
        readRecorder = nil
        writeRecorder = nil
        aggregatorHandler = nil
    }

    func testAggregateNoBody() {
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Only one request should have made it through.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(NIOHTTPServerRequestFull(head: requestHead, body: nil))])
    }

    func testAggregateWithBody() {
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.body(
            channel.allocator.buffer(string: "hello"))))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Only one request should have made it through.
        XCTAssertEqual(readRecorder.reads, [
            .channelRead(NIOHTTPServerRequestFull(
                head: requestHead,
                body: channel.allocator.buffer(string: "hello")
            )),
        ])
    }

    func testAggregateChunkedBody() {
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))

        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.body(
            channel.allocator.buffer(string: "hello"))))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.body(
            channel.allocator.buffer(string: "world"))))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Only one request should have made it through.
        XCTAssertEqual(readRecorder.reads, [
            .channelRead(NIOHTTPServerRequestFull(
                head: requestHead,
                body: channel.allocator.buffer(string: "helloworld")
            )),
        ])
    }

    func testAggregateWithTrailer() {
        var reqWithChunking: HTTPRequestHead = requestHead
        reqWithChunking.headers.add(name: "transfer-encoding", value: "chunked")
        reqWithChunking.headers.add(name: "Trailer", value: "X-Trailer")

        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(reqWithChunking)))

        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.body(
            channel.allocator.buffer(string: "hello"))))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.body(
            channel.allocator.buffer(string: "world"))))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(
            HTTPHeaders([("X-Trailer", "true")]))))

        reqWithChunking.headers.remove(name: "Trailer")
        reqWithChunking.headers.add(name: "X-Trailer", value: "true")

        // Trailer headers should get moved to normal ones
        XCTAssertEqual(readRecorder.reads, [
            .channelRead(NIOHTTPServerRequestFull(
                head: reqWithChunking,
                body: channel.allocator.buffer(string: "helloworld")
            )),
        ])
    }

    func testOversizeRequest() {
        resetSmallHandler(maxContentLength: 4)

        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        XCTAssertTrue(channel.isActive)

        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.body(
            channel.allocator.buffer(string: "he"))))
        XCTAssertEqual(writeRecorder.writes, [])

        XCTAssertThrowsError(try channel.writeInbound(HTTPServerRequestPart.body(
            channel.allocator.buffer(string: "llo")))) { error in
                XCTAssertEqual(NIOHTTPObjectAggregatorError.frameTooLong, error as? NIOHTTPObjectAggregatorError)
        }

        let resTooLarge = HTTPResponseHead(
            version: .http1_1,
            status: .payloadTooLarge,
            headers: HTTPHeaders([("Content-Length", "0"), ("connection", "close")])
        )

        XCTAssertEqual(writeRecorder.writes, [
            HTTPServerResponsePart.head(resTooLarge),
            HTTPServerResponsePart.end(nil),
        ])

        XCTAssertFalse(channel.isActive)
        XCTAssertThrowsError(try channel.writeInbound(HTTPServerRequestPart.end(nil))) { error in
            XCTAssertEqual(NIOHTTPObjectAggregatorError.connectionClosed, error as? NIOHTTPObjectAggregatorError)
        }
    }

    func testOversizedRequestWithoutKeepAlive() {
        resetSmallHandler(maxContentLength: 4)

        // send an HTTP/1.0 request with no keep-alive header
        let requestHead = HTTPRequestHead(
            version: .http1_0,
            method: .PUT, uri: "/path",
            headers: HTTPHeaders(
                [("Host", "example.com"), ("X-Test", "True"), ("content-length", "5")])
        )

        XCTAssertThrowsError(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))

        let resTooLarge = HTTPResponseHead(
            version: .http1_0,
            status: .payloadTooLarge,
            headers: HTTPHeaders([("Content-Length", "0"), ("connection", "close")])
        )

        XCTAssertEqual(writeRecorder.writes, [
            HTTPServerResponsePart.head(resTooLarge),
            HTTPServerResponsePart.end(nil),
        ])

        // Connection should be closed right away
        XCTAssertFalse(channel.isActive)

        XCTAssertThrowsError(try channel.writeInbound(HTTPServerRequestPart.end(nil))) { error in
            XCTAssertEqual(NIOHTTPObjectAggregatorError.connectionClosed, error as? NIOHTTPObjectAggregatorError)
        }
    }

    func testOversizedRequestWithContentLength() {
        resetSmallHandler(maxContentLength: 4)

        // HTTP/1.1 uses Keep-Alive unless told otherwise
        let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: .PUT, uri: "/path",
            headers: HTTPHeaders(
                [("Host", "example.com"), ("X-Test", "True"), ("content-length", "8")])
        )

        resetSmallHandler(maxContentLength: 4)

        XCTAssertThrowsError(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))

        let response = asHTTPResponseHead(writeRecorder.writes.first!)!
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
            XCTAssertThrowsError(try channel.writeInbound(requestPart))
        }

        // The aggregated message should not get passed up as it is too large.
        // There should only be one "frame too long" event despite multiple writes
        XCTAssertEqual(readRecorder.reads, [.httpFrameTooLongEvent])
        XCTAssertThrowsError(try channel.writeInbound(HTTPServerRequestPart.end(nil)))
        XCTAssertEqual(readRecorder.reads, [.httpFrameTooLongEvent])

        // Write another request that is small enough
        var secondReqWithContentLength: HTTPRequestHead = self.requestHead
        secondReqWithContentLength.headers.replaceOrAdd(name: "content-length", value: "2")

        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(secondReqWithContentLength)))

        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.body(
            channel.allocator.buffer(bytes: [1]))))
        XCTAssertEqual(readRecorder.reads, [.httpFrameTooLongEvent])
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.body(
            channel.allocator.buffer(bytes: [2]))))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertEqual(readRecorder.reads, [
            .httpFrameTooLongEvent,
            .channelRead(NIOHTTPServerRequestFull(
                head: secondReqWithContentLength,
                body: channel.allocator.buffer(bytes: [1, 2])
            )),
        ])
    }
}

class NIOHTTPClientResponseAggregatorTest: XCTestCase {
    var channel: EmbeddedChannel!
    var requestHead: HTTPRequestHead!
    var responseHead: HTTPResponseHead!
    fileprivate var readRecorder: ReadRecorder<NIOHTTPClientResponseFull>!
    fileprivate var aggregatorHandler: NIOHTTPClientResponseAggregator!

    override func setUp() {
        channel = EmbeddedChannel()
        readRecorder = ReadRecorder()
        aggregatorHandler = NIOHTTPClientResponseAggregator(maxContentLength: 1024 * 1024)

        XCTAssertNoThrow(try channel.pipeline.addHandler(HTTPRequestEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(aggregatorHandler).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(readRecorder).wait())

        requestHead = HTTPRequestHead(version: .http1_1, method: .PUT, uri: "/path")
        requestHead.headers.add(name: "Host", value: "example.com")
        requestHead.headers.add(name: "X-Test", value: "True")

        responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        responseHead.headers.add(name: "Server", value: "SwiftNIO")

        // this activates the channel
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait())
    }

    /// Modify pipeline setup to use aggregator with a smaller `maxContentLength`
    private func resetSmallHandler(maxContentLength: Int) {
        XCTAssertNoThrow(try channel.pipeline.removeHandler(readRecorder!).wait())
        XCTAssertNoThrow(try channel.pipeline.removeHandler(aggregatorHandler!).wait())
        aggregatorHandler = NIOHTTPClientResponseAggregator(maxContentLength: maxContentLength)
        XCTAssertNoThrow(try channel.pipeline.addHandler(aggregatorHandler).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(readRecorder!).wait())
    }

    override func tearDown() {
        if let channel = self.channel {
            XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true))
            self.channel = nil
        }
        requestHead = nil
        responseHead = nil
        readRecorder = nil
        aggregatorHandler = nil
    }

    func testOversizeResponseHead() {
        resetSmallHandler(maxContentLength: 5)

        var resHead: HTTPResponseHead = responseHead
        resHead.headers.replaceOrAdd(name: "content-length", value: "10")

        XCTAssertThrowsError(try channel.writeInbound(HTTPClientResponsePart.head(resHead)))
        XCTAssertThrowsError(try channel.writeInbound(HTTPClientResponsePart.end(nil)))

        // User event triggered
        XCTAssertEqual(readRecorder.reads, [.httpFrameTooLongEvent])
    }

    func testOversizeResponse() {
        resetSmallHandler(maxContentLength: 5)

        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.head(responseHead)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.body(
            channel.allocator.buffer(string: "hello"))))

        XCTAssertThrowsError(try channel.writeInbound(
            HTTPClientResponsePart.body(
                channel.allocator.buffer(string: "world"))))
        XCTAssertThrowsError(try channel.writeInbound(HTTPClientResponsePart.end(nil)))

        // User event triggered
        XCTAssertEqual(readRecorder.reads, [.httpFrameTooLongEvent])
    }

    func testAggregatedResponse() {
        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.head(responseHead)))
        XCTAssertNoThrow(try channel.writeInbound(
            HTTPClientResponsePart.body(
                channel.allocator.buffer(string: "hello"))))
        XCTAssertNoThrow(try channel.writeInbound(
            HTTPClientResponsePart.body(
                channel.allocator.buffer(string: "world"))))
        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.end(HTTPHeaders([("X-Trail", "true")]))))

        var aggregatedHead: HTTPResponseHead = responseHead
        aggregatedHead.headers.add(name: "X-Trail", value: "true")

        XCTAssertEqual(readRecorder.reads, [
            .channelRead(NIOHTTPClientResponseFull(
                head: aggregatedHead,
                body: channel.allocator.buffer(string: "helloworld")
            )),
        ])
    }

    func testOkAfterOversized() {
        resetSmallHandler(maxContentLength: 4)

        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.head(responseHead)))
        XCTAssertNoThrow(try channel.writeInbound(
            HTTPClientResponsePart.body(
                channel.allocator.buffer(string: "hell"))))
        XCTAssertThrowsError(try channel.writeInbound(
            HTTPClientResponsePart.body(
                channel.allocator.buffer(string: "owor"))))
        XCTAssertThrowsError(try channel.writeInbound(
            HTTPClientResponsePart.body(
                channel.allocator.buffer(string: "ld"))))
        XCTAssertThrowsError(try channel.writeInbound(HTTPClientResponsePart.end(nil)))

        // User event triggered
        XCTAssertEqual(readRecorder.reads, [.httpFrameTooLongEvent])

        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.head(responseHead)))
        XCTAssertNoThrow(try channel.writeInbound(
            HTTPClientResponsePart.body(
                channel.allocator.buffer(string: "test"))))
        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.end(nil)))

        XCTAssertEqual(readRecorder.reads, [
            .httpFrameTooLongEvent,
            .channelRead(NIOHTTPClientResponseFull(
                head: responseHead,
                body: channel.allocator.buffer(string: "test")
            )),
        ])
    }
}
