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
import XCTest

class HTTPServerProtocolErrorHandlerTest: XCTestCase {
    func testHandlesBasicErrors() throws {
        final class CloseOnHTTPErrorHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = Never

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                if let error = error as? HTTPParserError {
                    context.fireErrorCaught(error)
                    context.close(promise: nil)
                }
            }
        }
        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(CloseOnHTTPErrorHandler()).wait())

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("GET / HTTP/1.1\r\nContent-Length: -4\r\n\r\n")
        do {
            try channel.writeInbound(buffer)
        } catch HTTPParserError.invalidContentLength {
            // This error is expected
        }
        channel.embeddedEventLoop.run()

        // The channel should be closed at this stage.
        XCTAssertNoThrow(try channel.closeFuture.wait())

        // We expect exactly one ByteBuffer in the output.
        guard var written = try channel.readOutbound(as: ByteBuffer.self) else {
            XCTFail("No writes")
            return
        }

        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))

        // Check the response.
        assertResponseIs(
            response: written.readString(length: written.readableBytes)!,
            expectedResponseLine: "HTTP/1.1 400 Bad Request",
            expectedResponseHeaders: ["Connection: close", "Content-Length: 0"]
        )
    }

    func testIgnoresNonParserErrors() throws {
        enum DummyError: Error {
            case error
        }
        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).wait())

        channel.pipeline.fireErrorCaught(DummyError.error)
        XCTAssertThrowsError(try channel.throwIfErrorCaught()) { error in
            XCTAssertEqual(DummyError.error, error as? DummyError)
        }

        XCTAssertNoThrow(try channel.finish())
    }

    func testDoesNotSendAResponseIfResponseHasAlreadyStarted() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        XCTAssertNoThrow(
            try channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true)
                .wait()
        )
        let res = HTTPServerResponsePart.head(
            .init(
                version: .http1_1,
                status: .ok,
                headers: .init([("Content-Length", "0")])
            )
        )
        XCTAssertNoThrow(try channel.writeOutbound(res))
        // now we have started a response but it's not complete yet, let's inject a parser error
        channel.pipeline.fireErrorCaught(HTTPParserError.invalidEOFState)
        var allOutbound = try channel.readAllOutboundBuffers()
        let allOutboundString = allOutbound.readString(length: allOutbound.readableBytes)
        // there should be no HTTP/1.1 400 or anything in here
        XCTAssertEqual("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", allOutboundString)
        XCTAssertThrowsError(try channel.throwIfErrorCaught()) { error in
            XCTAssertEqual(.invalidEOFState, error as? HTTPParserError)
        }
    }

    func testCanHandleErrorsWhenResponseHasStarted() throws {
        enum NextExpectedState {
            case head
            case end
            case none
        }
        class DelayWriteHandler: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            private var nextExpected: NextExpectedState = .head

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let req = Self.unwrapInboundIn(data)
                switch req {
                case .head:
                    XCTAssertEqual(.head, self.nextExpected)
                    self.nextExpected = .end
                    let res = HTTPServerResponsePart.head(
                        .init(
                            version: .http1_1,
                            status: .ok,
                            headers: .init([("Content-Length", "0")])
                        )
                    )
                    context.writeAndFlush(Self.wrapOutboundOut(res), promise: nil)
                default:
                    XCTAssertEqual(.end, self.nextExpected)
                    self.nextExpected = .none
                }
            }

        }
        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(DelayWriteHandler()))

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("GET / HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\n\r\nGET / HT")
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(try channel.close().wait())
        channel.embeddedEventLoop.run()

        // The channel should be closed at this stage.
        XCTAssertNoThrow(try channel.closeFuture.wait())

        // We expect exactly one ByteBuffer in the output.
        guard var written = try channel.readOutbound(as: ByteBuffer.self) else {
            XCTFail("No writes")
            return
        }

        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound()))

        // Check the response.
        assertResponseIs(
            response: written.readString(length: written.readableBytes)!,
            expectedResponseLine: "HTTP/1.1 200 OK",
            expectedResponseHeaders: ["Content-Length: 0"]
        )
    }

    func testDoesSendAResponseIfInformationalHeaderWasSent() throws {
        let channel = EmbeddedChannel()
        defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: false)) }

        XCTAssertNoThrow(
            try channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true)
                .wait()
        )
        XCTAssertNoThrow(try channel.connect(to: .makeAddressResolvingHost("127.0.0.1", port: 0)).wait())

        // Send an head that expects a continue informational response
        let reqHeadBytes = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(string: reqHeadBytes)))
        let expectedHead = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/",
            headers: ["Transfer-Encoding": "chunked", "Expect": "100-continue"]
        )
        XCTAssertEqual(try channel.readInbound(as: HTTPServerRequestPart.self), .head(expectedHead))

        // Respond with continue informational response
        let continueResponse = HTTPResponseHead(version: .http1_1, status: .continue)
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(continueResponse)))
        XCTAssertEqual(
            try channel.readOutbound(as: ByteBuffer.self),
            ByteBuffer(string: "HTTP/1.1 100 Continue\r\n\r\n")
        )

        // Expects a hex digit... But receives garbage
        XCTAssertThrowsError(try channel.writeInbound(ByteBuffer(string: "xyz"))) {
            XCTAssertEqual($0 as? HTTPParserError, .invalidChunkSize)
        }

        // Receive a bad request
        XCTAssertEqual(
            try channel.readOutbound(as: ByteBuffer.self),
            ByteBuffer(string: "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
        )
    }

    func testDoesNotSendAResponseIfRealHeaderWasSentAfterInformationalHeader() throws {
        let channel = EmbeddedChannel()
        defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: false)) }

        XCTAssertNoThrow(try channel.connect(to: .makeAddressResolvingHost("127.0.0.1", port: 0)).wait())
        XCTAssertNoThrow(
            try channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true)
                .wait()
        )

        // Send an head that expects a continue informational response
        let reqHeadBytes = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(string: reqHeadBytes)))
        let expectedHead = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/",
            headers: ["Transfer-Encoding": "chunked", "Expect": "100-continue"]
        )
        XCTAssertEqual(try channel.readInbound(as: HTTPServerRequestPart.self), .head(expectedHead))

        // Respond with continue informational response
        let continueResponse = HTTPResponseHead(version: .http1_1, status: .continue)
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(continueResponse)))
        XCTAssertEqual(
            try channel.readOutbound(as: ByteBuffer.self),
            ByteBuffer(string: "HTTP/1.1 100 Continue\r\n\r\n")
        )

        // Send a a chunk
        XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(string: "6\r\nfoobar\r\n")))

        // Server responds with an actual head, even though request has not finished yet
        let acceptedResponse = HTTPResponseHead(version: .http1_1, status: .accepted, headers: ["Content-Length": "20"])
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(acceptedResponse)))
        XCTAssertEqual(
            try channel.readOutbound(as: ByteBuffer.self),
            ByteBuffer(string: "HTTP/1.1 202 Accepted\r\nContent-Length: 20\r\n\r\n")
        )

        // Client sends garbage chunk
        XCTAssertThrowsError(try channel.writeInbound(ByteBuffer(string: "xyz"))) {
            XCTAssertEqual($0 as? HTTPParserError, .invalidChunkSize)
        }

        XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self))
    }

}
