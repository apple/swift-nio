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
import Dispatch
import NIO
import NIOHTTP1

extension ByteBuffer {
    init(string: String) {
        self = ByteBufferAllocator().buffer(capacity: string.utf8.count)
        self.write(string: string)
    }
}

private class MessageEndHandler<Head: Equatable, Body: Equatable>: ChannelInboundHandler {
    typealias InboundIn = HTTPPart<Head, Body>

    var seenEnd = false
    var seenBody = false
    var seenHead = false

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head:
            XCTAssertFalse(self.seenHead)
            self.seenHead = true
        case .body:
            XCTAssertFalse(self.seenBody)
            self.seenBody = true
        case .end:
            XCTAssertFalse(self.seenEnd)
            self.seenEnd = true
        }
    }
}

/// Tests for the HTTP decoder's handling of message body framing.
///
/// Mostly tests assertions in [RFC 7230 § 3.3.3](https://tools.ietf.org/html/rfc7230#section-3.3.3).
class HTTPDecoderLengthTest: XCTestCase {
    private var channel: EmbeddedChannel!
    private var loop: EmbeddedEventLoop!

    override func setUp() {
        self.channel = EmbeddedChannel()
        self.loop = (channel.eventLoop as! EmbeddedEventLoop)
    }

    override func tearDown() {
        self.channel = nil
        self.loop = nil
    }

    /// The mechanism by which EOF is being sent.
    enum EOFMechanism {
        case channelInactive
        case halfClosure
    }

    /// The various header fields that can be used to frame a response.
    enum FramingField {
        case contentLength
        case transferEncoding
        case neither
    }

    private func assertSemanticEOFOnChannelInactiveResponse(version: HTTPVersion, how eofMechanism: EOFMechanism) throws {
        class ChannelInactiveHandler: ChannelInboundHandler {
            typealias InboundIn = HTTPClientResponsePart
            var response: HTTPResponseHead?
            var receivedEnd = false
            var eof = false
            var body: [UInt8]?
            private let eofMechanism: EOFMechanism

            init(_ eofMechanism: EOFMechanism) {
                self.eofMechanism = eofMechanism
            }

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                switch self.unwrapInboundIn(data) {
                case .head(let h):
                    self.response = h
                case .end:
                    self.receivedEnd = true
                case .body(var b):
                    XCTAssertNil(self.body)
                    self.body = b.readBytes(length: b.readableBytes)!
                }
            }

            func channelInactive(ctx: ChannelHandlerContext) {
                if case .channelInactive = self.eofMechanism {
                    XCTAssert(self.receivedEnd, "Received channelInactive before response end!")
                    self.eof = true
                } else {
                    XCTAssert(self.eof, "Did not receive .inputClosed")
                }
            }

            func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
                guard case .halfClosure = self.eofMechanism else {
                    XCTFail("Got half closure when not expecting it")
                    return
                }

                guard let evt = event as? ChannelEvent, case .inputClosed = evt else {
                    ctx.fireUserInboundEventTriggered(event)
                    return
                }

                XCTAssert(self.receivedEnd, "Received inputClosed before response end!")
                self.eof = true
            }
        }

        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPResponseDecoder()).wait())

        let handler = ChannelInactiveHandler(eofMechanism)
        XCTAssertNoThrow(try channel.pipeline.add(handler: handler).wait())

        // Prime the decoder with a GET and consume it.
        XCTAssertTrue(try channel.writeOutbound(HTTPClientRequestPart.head(HTTPRequestHead(version: version, method: .GET, uri: "/"))))
        XCTAssertNotNil(channel.readOutbound())

        // We now want to send a HTTP/1.1 response. This response has no content-length, no transfer-encoding,
        // is not a response to a HEAD request, is not a 2XX response to CONNECT, and is not 1XX, 204, or 304.
        // That means, per RFC 7230 § 3.3.3, the body is framed by EOF. Because this is a response, that EOF
        // may be transmitted by channelInactive.
        let response = "HTTP/\(version.major).\(version.minor) 200 OK\r\nServer: example\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(IOData.byteBuffer(ByteBuffer(string: response))))

        // We should have a response but no body.
        XCTAssertNotNil(handler.response)
        XCTAssertNil(handler.body)
        XCTAssertFalse(handler.receivedEnd)
        XCTAssertFalse(handler.eof)

        // Send a body chunk. This should be immediately passed on. Still no end or EOF.
        XCTAssertNoThrow(try channel.writeInbound(IOData.byteBuffer(ByteBuffer(string: "some body data"))))
        XCTAssertNotNil(handler.response)
        XCTAssertEqual(handler.body!, Array("some body data".utf8))
        XCTAssertFalse(handler.receivedEnd)
        XCTAssertFalse(handler.eof)

        // Now we send EOF. This should cause a response end. The handler will enforce ordering.
        if case .halfClosure = eofMechanism {
            channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        } else {
            channel.pipeline.fireChannelInactive()
        }
        XCTAssertNotNil(handler.response)
        XCTAssertEqual(handler.body!, Array("some body data".utf8))
        XCTAssertTrue(handler.receivedEnd)
        XCTAssertTrue(handler.eof)

        XCTAssertFalse(try channel.finish())
    }

    func testHTTP11SemanticEOFOnChannelInactive() throws {
        try assertSemanticEOFOnChannelInactiveResponse(version: .init(major:1, minor: 1), how: .channelInactive)
    }

    func testHTTP10SemanticEOFOnChannelInactive() throws {
        try assertSemanticEOFOnChannelInactiveResponse(version: .init(major:1, minor: 0), how: .channelInactive)
    }

    func testHTTP11SemanticEOFOnHalfClosure() throws {
        try assertSemanticEOFOnChannelInactiveResponse(version: .init(major:1, minor: 1), how: .halfClosure)
    }

    func testHTTP10SemanticEOFOnHalfClosure() throws {
        try assertSemanticEOFOnChannelInactiveResponse(version: .init(major:1, minor: 0), how: .halfClosure)
    }

    private func assertIgnoresLengthFields(requestMethod: HTTPMethod,
                                           responseStatus: HTTPResponseStatus,
                                           responseFramingField: FramingField) throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPResponseDecoder()).wait())

        let handler = MessageEndHandler<HTTPResponseHead, ByteBuffer>()
        XCTAssertNoThrow(try channel.pipeline.add(handler: handler).wait())

        // Prime the decoder with a request and consume it.
        XCTAssertTrue(try channel.writeOutbound(HTTPClientRequestPart.head(HTTPRequestHead(version: .init(major: 1, minor: 1),
                                                                                           method: requestMethod,
                                                                                           uri: "/"))))
        XCTAssertNotNil(channel.readOutbound())

        // We now want to send a HTTP/1.1 response. This response may contain some length framing fields that RFC 7230 says MUST
        // be ignored.
        var response = channel.allocator.buffer(capacity: 256)
        response.write(string: "HTTP/1.1 \(responseStatus.code) \(responseStatus.reasonPhrase)\r\nServer: example\r\n")

        switch responseFramingField {
        case .contentLength:
            response.write(staticString: "Content-Length: 16\r\n")
        case .transferEncoding:
            response.write(staticString: "Transfer-Encoding: chunked\r\n")
        case .neither:
            break
        }
        response.write(staticString: "\r\n")

        XCTAssertNoThrow(try channel.writeInbound(IOData.byteBuffer(response)))

        // We should have a response, no body, and immediately see EOF.
        XCTAssert(handler.seenHead)
        XCTAssertFalse(handler.seenBody)
        XCTAssert(handler.seenEnd)

        XCTAssertFalse(try channel.finish())
    }

    func testIgnoresTransferEncodingFieldOnCONNECTResponses() throws {
        try assertIgnoresLengthFields(requestMethod: .CONNECT, responseStatus: .ok, responseFramingField: .transferEncoding)
    }

    func testIgnoresContentLengthFieldOnCONNECTResponses() throws {
        try assertIgnoresLengthFields(requestMethod: .CONNECT, responseStatus: .ok, responseFramingField: .contentLength)
    }

    func testEarlyFinishWithoutLengthAtAllOnCONNECTResponses() throws {
        try assertIgnoresLengthFields(requestMethod: .CONNECT, responseStatus: .ok, responseFramingField: .neither)
    }

    func testIgnoresTransferEncodingFieldOnHEADResponses() throws {
        try assertIgnoresLengthFields(requestMethod: .HEAD, responseStatus: .ok, responseFramingField: .transferEncoding)
    }

    func testIgnoresContentLengthFieldOnHEADResponses() throws {
        try assertIgnoresLengthFields(requestMethod: .HEAD, responseStatus: .ok, responseFramingField: .contentLength)
    }

    func testEarlyFinishWithoutLengthAtAllOnHEADResponses() throws {
        try assertIgnoresLengthFields(requestMethod: .HEAD, responseStatus: .ok, responseFramingField: .neither)
    }

    func testIgnoresTransferEncodingFieldOn1XXResponses() throws {
        try assertIgnoresLengthFields(requestMethod: .GET,
                                      responseStatus: .custom(code: 103, reasonPhrase: "Early Hints"),
                                      responseFramingField: .transferEncoding)
    }

    func testIgnoresContentLengthFieldOn1XXResponses() throws {
        try assertIgnoresLengthFields(requestMethod: .GET,
                                      responseStatus: .custom(code: 103, reasonPhrase: "Early Hints"),
                                      responseFramingField: .contentLength)
    }

    func testEarlyFinishWithoutLengthAtAllOn1XXResponses() throws {
        try assertIgnoresLengthFields(requestMethod: .GET,
                                      responseStatus: .custom(code: 103, reasonPhrase: "Early Hints"),
                                      responseFramingField: .neither)
    }

    func testIgnoresTransferEncodingFieldOn204Responses() throws {
        try assertIgnoresLengthFields(requestMethod: .GET, responseStatus: .noContent, responseFramingField: .transferEncoding)
    }

    func testIgnoresContentLengthFieldOn204Responses() throws {
        try assertIgnoresLengthFields(requestMethod: .GET, responseStatus: .noContent, responseFramingField: .contentLength)
    }

    func testEarlyFinishWithoutLengthAtAllOn204Responses() throws {
        try assertIgnoresLengthFields(requestMethod: .GET, responseStatus: .noContent, responseFramingField: .neither)
    }

    func testIgnoresTransferEncodingFieldOn304Responses() throws {
        try assertIgnoresLengthFields(requestMethod: .GET, responseStatus: .notModified, responseFramingField: .transferEncoding)
    }

    func testIgnoresContentLengthFieldOn304Responses() throws {
        try assertIgnoresLengthFields(requestMethod: .GET, responseStatus: .notModified, responseFramingField: .contentLength)
    }

    func testEarlyFinishWithoutLengthAtAllOn304Responses() throws {
        try assertIgnoresLengthFields(requestMethod: .GET, responseStatus: .notModified, responseFramingField: .neither)
    }

    private func assertRequestTransferEncodingHasNoBody(transferEncodingHeader: String) throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestDecoder()).wait())

        let handler = MessageEndHandler<HTTPRequestHead, ByteBuffer>()
        XCTAssertNoThrow(try channel.pipeline.add(handler: handler).wait())

        // Send a GET with the appropriate Transfer Encoding header.
        XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(string: "POST / HTTP/1.1\r\nTransfer-Encoding: \(transferEncodingHeader)\r\n\r\n")))

        // We should have a request, no body, and immediately see end of request.
        XCTAssert(handler.seenHead)
        XCTAssertFalse(handler.seenBody)
        XCTAssert(handler.seenEnd)

        XCTAssertFalse(try channel.finish())
    }

    func testMultipleTEWithChunkedLastHasNoBodyOnRequest() throws {
        // This is not quite right: RFC 7230 should allow this as chunked. However, http_parser
        // does not, so we don't either.
        try assertRequestTransferEncodingHasNoBody(transferEncodingHeader: "gzip, chunked")
    }

    func testMultipleTEWithChunkedFirstHasNoBodyOnRequest() throws {
        // Here http_parser is again wrong: strictly this should 400. Again, though,
        // if http_parser doesn't support this neither do we.
        try assertRequestTransferEncodingHasNoBody(transferEncodingHeader: "chunked, gzip")
    }

    func testMultipleTEWithChunkedInTheMiddleHasNoBodyOnRequest() throws {
        // Here http_parser is again wrong: strictly this should 400. Again, though,
        // if http_parser doesn't support this neither do we.
        try assertRequestTransferEncodingHasNoBody(transferEncodingHeader: "gzip, chunked, deflate")
    }

    private func assertResponseTransferEncodingHasBodyTerminatedByEOF(transferEncodingHeader: String, eofMechanism: EOFMechanism) throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPResponseDecoder()).wait())

        let handler = MessageEndHandler<HTTPResponseHead, ByteBuffer>()
        XCTAssertNoThrow(try channel.pipeline.add(handler: handler).wait())

        // Prime the decoder with a request and consume it.
        XCTAssertTrue(try channel.writeOutbound(HTTPClientRequestPart.head(HTTPRequestHead(version: .init(major: 1, minor: 1),
                                                                                           method: .GET,
                                                                                           uri: "/"))))
        XCTAssertNotNil(channel.readOutbound())

        // Send a 200 with the appropriate Transfer Encoding header. We should see the request,
        // but no body or end.
        XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nTransfer-Encoding: \(transferEncodingHeader)\r\n\r\n")))
        XCTAssert(handler.seenHead)
        XCTAssertFalse(handler.seenBody)
        XCTAssertFalse(handler.seenEnd)

        // Now send body. Note that this is *not* chunk encoded. We should also see a body.
        XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(string: "caribbean")))
        XCTAssert(handler.seenHead)
        XCTAssert(handler.seenBody)
        XCTAssertFalse(handler.seenEnd)

        // Now send EOF. This should send the end as well.
        if case .halfClosure = eofMechanism {
            channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        } else {
            channel.pipeline.fireChannelInactive()
        }
        XCTAssert(handler.seenHead)
        XCTAssert(handler.seenBody)
        XCTAssert(handler.seenEnd)

        XCTAssertFalse(try channel.finish())
    }

    func testMultipleTEWithChunkedLastHasEOFBodyOnResponseWithChannelInactive() throws {
        // This is not right: RFC 7230 should allow this as chunked, but http_parser instead parses it as
        // EOF-terminated. We can't easily override that, so we don't.
        try assertResponseTransferEncodingHasBodyTerminatedByEOF(transferEncodingHeader: "gzip, chunked", eofMechanism: .channelInactive)
    }

    func testMultipleTEWithChunkedFirstHasEOFBodyOnResponseWithChannelInactive() throws {
        // Here http_parser is right, and this is EOF terminated.
        try assertResponseTransferEncodingHasBodyTerminatedByEOF(transferEncodingHeader: "chunked, gzip", eofMechanism: .channelInactive)
    }

    func testMultipleTEWithChunkedInTheMiddleHasEOFBodyOnResponseWithChannelInactive() throws {
        // Here http_parser is right, and this is EOF terminated.
        try assertResponseTransferEncodingHasBodyTerminatedByEOF(transferEncodingHeader: "gzip, chunked, deflate", eofMechanism: .channelInactive)
    }

    func testMultipleTEWithChunkedLastHasEOFBodyOnResponseWithHalfClosure() throws {
        // This is not right: RFC 7230 should allow this as chunked, but http_parser instead parses it as
        // EOF-terminated. We can't easily override that, so we don't.
        try assertResponseTransferEncodingHasBodyTerminatedByEOF(transferEncodingHeader: "gzip, chunked", eofMechanism: .halfClosure)
    }

    func testMultipleTEWithChunkedFirstHasEOFBodyOnResponseWithHalfClosure() throws {
        // Here http_parser is right, and this is EOF terminated.
        try assertResponseTransferEncodingHasBodyTerminatedByEOF(transferEncodingHeader: "chunked, gzip", eofMechanism: .halfClosure)
    }

    func testMultipleTEWithChunkedInTheMiddleHasEOFBodyOnResponseWithHalfClosure() throws {
        // Here http_parser is right, and this is EOF terminated.
        try assertResponseTransferEncodingHasBodyTerminatedByEOF(transferEncodingHeader: "gzip, chunked, deflate", eofMechanism: .halfClosure)
    }

    func testRequestWithTEAndContentLengthErrors() throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestDecoder()).wait())

        // Send a GET with the invalid headers.
        do {
            try channel.writeInbound(ByteBuffer(string: "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n"))
            XCTFail("Did not throw")
        } catch HTTPParserError.unexpectedContentLength {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Must spin the loop.
        XCTAssertFalse(channel.isActive)
        (channel.eventLoop as! EmbeddedEventLoop).run()
    }

    func testResponseWithTEAndContentLengthErrors() throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPResponseDecoder()).wait())

        // Prime the decoder with a request.
        XCTAssertTrue(try channel.writeOutbound(HTTPClientRequestPart.head(HTTPRequestHead(version: .init(major: 1, minor: 1),
                                                                                           method: .GET,
                                                                                           uri: "/"))))

        // Send a 200 OK with the invalid headers.
        do {
            try channel.writeInbound(ByteBuffer(string: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n"))
            XCTFail("Did not throw")
        } catch HTTPParserError.unexpectedContentLength {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Must spin the loop.
        XCTAssertFalse(channel.isActive)
        (channel.eventLoop as! EmbeddedEventLoop).run()
    }

    private func assertRequestWithInvalidCLErrors(contentLengthField: String) throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestDecoder()).wait())

        // Send a GET with the invalid headers.
        do {
            try channel.writeInbound(ByteBuffer(string: "POST / HTTP/1.1\r\nContent-Length: \(contentLengthField)\r\n\r\n"))
            XCTFail("Did not throw")
        } catch HTTPParserError.invalidContentLength {
            // ok
        } catch HTTPParserError.unexpectedContentLength {
            // also ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Must spin the loop.
        XCTAssertFalse(channel.isActive)
        (channel.eventLoop as! EmbeddedEventLoop).run()
    }

    func testRequestWithMultipleDifferentContentLengthsFails() throws {
        try assertRequestWithInvalidCLErrors(contentLengthField: "4, 5")
    }

    func testRequestWithMultipleDifferentContentLengthsOnDifferentLinesFails() throws {
        try assertRequestWithInvalidCLErrors(contentLengthField: "4\r\nContent-Length: 5")
    }

    func testRequestWithInvalidContentLengthFails() throws {
        try assertRequestWithInvalidCLErrors(contentLengthField: "pie")
    }

    func testRequestWithIdenticalContentLengthRepeatedErrors() throws {
        // This is another case where http_parser is, if not wrong, then aggressively interpreting
        // the spec. Regardless, we match it.
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestDecoder()).wait())

        // Send two POSTs with repeated content length, one with one field and one with two.
        // Both should error.
        do {
            try channel.writeInbound(ByteBuffer(string: "POST / HTTP/1.1\r\nContent-Length: 4, 4\r\n\r\n"))
            XCTFail("Did not throw")
        } catch HTTPParserError.invalidContentLength {
            // ok
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        // Must spin the loop.
        XCTAssertFalse(channel.isActive)
        (channel.eventLoop as! EmbeddedEventLoop).run()
    }

    func testRequestWithMultipleIdenticalContentLengthFieldsErrors() throws {
        // This is another case where http_parser is, if not wrong, then aggressively interpreting
        // the spec. Regardless, we match it.
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestDecoder()).wait())

        do {
            try channel.writeInbound(ByteBuffer(string: "POST / HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 4\r\n\r\n"))
            XCTFail("Did not throw")
        } catch HTTPParserError.unexpectedContentLength {
            // ok
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        // Must spin the loop.
        XCTAssertFalse(channel.isActive)
        (channel.eventLoop as! EmbeddedEventLoop).run()
    }

    func testRequestWithoutExplicitLengthIsZeroLength() throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestDecoder()).wait())

        let handler = MessageEndHandler<HTTPRequestHead, ByteBuffer>()
        XCTAssertNoThrow(try channel.pipeline.add(handler: handler).wait())

        // Send a POST without a length field of any kind. This should be a zero-length request,
        // so .end should come immediately.
        XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(string: "POST / HTTP/1.1\r\nHost: example.org\r\n\r\n")))
        XCTAssert(handler.seenHead)
        XCTAssertFalse(handler.seenBody)
        XCTAssert(handler.seenEnd)

        XCTAssertFalse(try channel.finish())
    }
}
