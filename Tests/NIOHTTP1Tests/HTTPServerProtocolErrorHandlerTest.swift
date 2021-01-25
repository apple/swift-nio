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

import XCTest
import NIO
import NIOHTTP1

class HTTPServerProtocolErrorHandlerTest: XCTestCase {
    func testHandlesBasicErrors() throws {
        class CloseOnHTTPErrorHandler: ChannelInboundHandler {
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
        assertResponseIs(response: written.readString(length: written.readableBytes)!,
                         expectedResponseLine: "HTTP/1.1 400 Bad Request",
                         expectedResponseHeaders: ["Connection: close", "Content-Length: 0"])
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

        XCTAssertNoThrow(try channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true).wait())
        let res = HTTPServerResponsePart.head(.init(version: .http1_1,
                                                    status: .ok,
                                                    headers: .init([("Content-Length", "0")])))
        XCTAssertNoThrow(try channel.writeAndFlush(res).wait())
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
                let req = self.unwrapInboundIn(data)
                switch req {
                case .head:
                    XCTAssertEqual(.head, self.nextExpected)
                    self.nextExpected = .end
                    let res = HTTPServerResponsePart.head(.init(version: .http1_1,
                                                                status: .ok,
                                                                headers: .init([("Content-Length", "0")])))
                    context.writeAndFlush(self.wrapOutboundOut(res), promise: nil)
                default:
                    XCTAssertEqual(.end, self.nextExpected)
                    self.nextExpected = .none
                }
            }


        }
        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
            channel.pipeline.addHandler(DelayWriteHandler())
        }.wait())

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
        assertResponseIs(response: written.readString(length: written.readableBytes)!,
                         expectedResponseLine: "HTTP/1.1 200 OK",
                         expectedResponseHeaders: ["Content-Length: 0"])
    }
}
