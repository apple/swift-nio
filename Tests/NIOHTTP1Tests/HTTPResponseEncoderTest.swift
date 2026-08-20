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

import NIOEmbedded
import XCTest

@testable import NIOCore
@testable import NIOHTTP1

extension ByteBuffer {
    fileprivate func assertContainsOnly(_ string: String) {
        let innerData = self.getString(at: self.readerIndex, length: self.readableBytes)!
        XCTAssertEqual(innerData, string)
    }
}

extension HTTPResponseEncoder.Configuration {
    fileprivate static let noFramingTransformation: HTTPResponseEncoder.Configuration = {
        var config = HTTPResponseEncoder.Configuration()
        config.automaticallySetFramingHeaders = false
        return config
    }()
}

class HTTPResponseEncoderTests: XCTestCase {
    private func sendResponse(
        withStatus status: HTTPResponseStatus,
        andHeaders headers: HTTPHeaders,
        version: HTTPVersion = .http1_1,
        configuration: HTTPResponseEncoder.Configuration = .init()
    ) -> ByteBuffer {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertEqual(true, try? channel.finish().isClean)
        }

        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder(configuration: configuration))
        )
        var switchingResponse = HTTPResponseHead(version: version, status: status)
        switchingResponse.headers = headers
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(switchingResponse)))
        do {
            if let buffer = try channel.readOutbound(as: ByteBuffer.self) {
                return buffer
            } else {
                fatalError("Could not read ByteBuffer from channel")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
            var buf = channel.allocator.buffer(capacity: 16)
            buf.writeString("unexpected error: \(error)")
            return buf
        }
    }

    /// The encoder writes hand-optimised status lines for the well-known statuses (rather than
    /// going through the general `default` path that uses `HTTPResponseStatus.reasonPhrase`). Those
    /// fast paths must stay in lockstep with `reasonPhrase` and must carry the correct HTTP version,
    /// otherwise the bytes on the wire depend on whether a status happens to have a fast path.
    func testStatusLineFastPathsMatchCanonicalReasonPhraseAndVersion() throws {
        let statuses: [HTTPResponseStatus] = [
            .continue, .switchingProtocols, .processing,
            .ok, .created, .accepted, .nonAuthoritativeInformation, .noContent, .resetContent,
            .partialContent, .multiStatus, .alreadyReported, .imUsed,
            .multipleChoices, .movedPermanently, .found, .seeOther, .notModified, .useProxy,
            .temporaryRedirect, .permanentRedirect,
            .badRequest, .unauthorized, .paymentRequired, .forbidden, .notFound, .methodNotAllowed,
            .notAcceptable, .proxyAuthenticationRequired, .requestTimeout, .conflict, .gone,
            .lengthRequired, .preconditionFailed, .payloadTooLarge, .uriTooLong, .unsupportedMediaType,
            .rangeNotSatisfiable, .expectationFailed, .imATeapot, .misdirectedRequest,
            .unprocessableEntity, .locked, .failedDependency, .upgradeRequired, .preconditionRequired,
            .tooManyRequests, .requestHeaderFieldsTooLarge, .unavailableForLegalReasons,
            .internalServerError, .notImplemented, .badGateway, .serviceUnavailable, .gatewayTimeout,
            .httpVersionNotSupported, .variantAlsoNegotiates, .insufficientStorage, .loopDetected,
            .notExtended, .networkAuthenticationRequired,
        ]

        for version in [HTTPVersion.http1_0, .http1_1] {
            for status in statuses {
                let written = sendResponse(
                    withStatus: status,
                    andHeaders: HTTPHeaders(),
                    version: version
                )
                let bytes = String(buffer: written)
                let statusLine = bytes.components(separatedBy: "\r\n").first ?? ""
                let expected = "HTTP/\(version.major).\(version.minor) \(status.code) \(status.reasonPhrase)"
                XCTAssertEqual(
                    statusLine,
                    expected,
                    "status line for \(status) on HTTP/\(version.major).\(version.minor) did not match canonical form"
                )
            }
        }
    }

    func testNoAutoHeadersFor101() throws {
        let writtenData = sendResponse(withStatus: .switchingProtocols, andHeaders: HTTPHeaders())
        writtenData.assertContainsOnly("HTTP/1.1 101 Switching Protocols\r\n\r\n")
    }

    func testNoAutoHeadersForCustom1XX() throws {
        let headers = HTTPHeaders([("Link", "</styles.css>; rel=preload; as=style")])
        let writtenData = sendResponse(withStatus: .custom(code: 103, reasonPhrase: "Early Hints"), andHeaders: headers)
        writtenData.assertContainsOnly("HTTP/1.1 103 Early Hints\r\nLink: </styles.css>; rel=preload; as=style\r\n\r\n")
    }

    func testNoAutoHeadersFor204() throws {
        let writtenData = sendResponse(withStatus: .noContent, andHeaders: HTTPHeaders())
        writtenData.assertContainsOnly("HTTP/1.1 204 No Content\r\n\r\n")
    }

    func testNoAutoHeadersWhenDisabled() throws {
        let writtenData = sendResponse(
            withStatus: .ok,
            andHeaders: HTTPHeaders(),
            configuration: .noFramingTransformation
        )
        writtenData.assertContainsOnly("HTTP/1.1 200 OK\r\n\r\n")
    }

    func testNoContentLengthHeadersFor101() throws {
        let headers = HTTPHeaders([("content-length", "0")])
        let writtenData = sendResponse(withStatus: .switchingProtocols, andHeaders: headers)
        writtenData.assertContainsOnly("HTTP/1.1 101 Switching Protocols\r\n\r\n")
    }

    func testAllowContentLengthHeadersWhenForced_for101() throws {
        let headers = HTTPHeaders([("content-length", "0")])
        let writtenData = sendResponse(
            withStatus: .switchingProtocols,
            andHeaders: headers,
            configuration: .noFramingTransformation
        )
        writtenData.assertContainsOnly("HTTP/1.1 101 Switching Protocols\r\ncontent-length: 0\r\n\r\n")
    }

    func testNoContentLengthHeadersForCustom1XX() throws {
        let headers = HTTPHeaders([("Link", "</styles.css>; rel=preload; as=style"), ("content-length", "0")])
        let writtenData = sendResponse(withStatus: .custom(code: 103, reasonPhrase: "Early Hints"), andHeaders: headers)
        writtenData.assertContainsOnly("HTTP/1.1 103 Early Hints\r\nLink: </styles.css>; rel=preload; as=style\r\n\r\n")
    }

    func testAllowContentLengthHeadersWhenForced_forCustom1XX() throws {
        let headers = HTTPHeaders([("Link", "</styles.css>; rel=preload; as=style"), ("content-length", "0")])
        let writtenData = sendResponse(
            withStatus: .custom(code: 103, reasonPhrase: "Early Hints"),
            andHeaders: headers,
            configuration: .noFramingTransformation
        )
        writtenData.assertContainsOnly(
            "HTTP/1.1 103 Early Hints\r\nLink: </styles.css>; rel=preload; as=style\r\ncontent-length: 0\r\n\r\n"
        )
    }

    func testNoContentLengthHeadersFor204() throws {
        let headers = HTTPHeaders([("content-length", "0")])
        let writtenData = sendResponse(withStatus: .noContent, andHeaders: headers)
        writtenData.assertContainsOnly("HTTP/1.1 204 No Content\r\n\r\n")
    }

    func testAllowContentLengthHeadersWhenForced_For204() throws {
        let headers = HTTPHeaders([("content-length", "0")])
        let writtenData = sendResponse(
            withStatus: .noContent,
            andHeaders: headers,
            configuration: .noFramingTransformation
        )
        writtenData.assertContainsOnly("HTTP/1.1 204 No Content\r\ncontent-length: 0\r\n\r\n")
    }

    func testNoContentLengthHeadersFor304() throws {
        let headers = HTTPHeaders([("content-length", "0")])
        let writtenData = sendResponse(withStatus: .notModified, andHeaders: headers)
        writtenData.assertContainsOnly("HTTP/1.1 304 Not Modified\r\n\r\n")
    }

    func testNoTransferEncodingHeadersFor101() throws {
        let headers = HTTPHeaders([("transfer-encoding", "chunked")])
        let writtenData = sendResponse(withStatus: .switchingProtocols, andHeaders: headers)
        writtenData.assertContainsOnly("HTTP/1.1 101 Switching Protocols\r\n\r\n")
    }

    func testAllowTransferEncodingHeadersWhenForced_for101() throws {
        let headers = HTTPHeaders([("transfer-encoding", "chunked")])
        let writtenData = sendResponse(
            withStatus: .switchingProtocols,
            andHeaders: headers,
            configuration: .noFramingTransformation
        )
        writtenData.assertContainsOnly("HTTP/1.1 101 Switching Protocols\r\ntransfer-encoding: chunked\r\n\r\n")
    }

    func testNoTransferEncodingHeadersForCustom1XX() throws {
        let headers = HTTPHeaders([("Link", "</styles.css>; rel=preload; as=style"), ("transfer-encoding", "chunked")])
        let writtenData = sendResponse(withStatus: .custom(code: 103, reasonPhrase: "Early Hints"), andHeaders: headers)
        writtenData.assertContainsOnly("HTTP/1.1 103 Early Hints\r\nLink: </styles.css>; rel=preload; as=style\r\n\r\n")
    }

    func testAllowTransferEncodingHeadersWhenForced_forCustom1XX() throws {
        let headers = HTTPHeaders([("Link", "</styles.css>; rel=preload; as=style"), ("transfer-encoding", "chunked")])
        let writtenData = sendResponse(
            withStatus: .custom(code: 103, reasonPhrase: "Early Hints"),
            andHeaders: headers,
            configuration: .noFramingTransformation
        )
        writtenData.assertContainsOnly(
            "HTTP/1.1 103 Early Hints\r\nLink: </styles.css>; rel=preload; as=style\r\ntransfer-encoding: chunked\r\n\r\n"
        )
    }

    func testNoTransferEncodingHeadersFor204() throws {
        let headers = HTTPHeaders([("transfer-encoding", "chunked")])
        let writtenData = sendResponse(withStatus: .noContent, andHeaders: headers)
        writtenData.assertContainsOnly("HTTP/1.1 204 No Content\r\n\r\n")
    }

    func testAllowTransferEncodingHeadersWhenForced_for204() throws {
        let headers = HTTPHeaders([("transfer-encoding", "chunked")])
        let writtenData = sendResponse(
            withStatus: .noContent,
            andHeaders: headers,
            configuration: .noFramingTransformation
        )
        writtenData.assertContainsOnly("HTTP/1.1 204 No Content\r\ntransfer-encoding: chunked\r\n\r\n")
    }

    func testNoTransferEncodingHeadersFor304() throws {
        let headers = HTTPHeaders([("transfer-encoding", "chunked")])
        let writtenData = sendResponse(withStatus: .notModified, andHeaders: headers)
        writtenData.assertContainsOnly("HTTP/1.1 304 Not Modified\r\n\r\n")
    }

    func testNoChunkedEncodingForHTTP10() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertEqual(true, try? channel.finish().isClean)
        }

        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder()))

        // This response contains neither Transfer-Encoding: chunked or Content-Length.
        let response = HTTPResponseHead(version: .http1_0, status: .ok)
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(response)))
        guard let b = try channel.readOutbound(as: ByteBuffer.self) else {
            XCTFail("Could not read byte buffer")
            return
        }
        let writtenResponse = b.getString(at: b.readerIndex, length: b.readableBytes)!
        XCTAssertEqual(writtenResponse, "HTTP/1.0 200 OK\r\n\r\n")
    }

    func testFullPipelineCanDisableFramingHeaders_withFuture() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        XCTAssertNoThrow(
            try channel.pipeline.configureHTTPServerPipeline(withEncoderConfiguration: .noFramingTransformation).wait()
        )
        let request = ByteBuffer(string: "GET / HTTP/1.1\r\n\r\n")
        XCTAssertNoThrow(try channel.writeInbound(request))

        let response = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(response)))

        guard let buffer = try channel.readOutbound(as: ByteBuffer.self) else {
            XCTFail("Could not read buffer")
            return
        }

        buffer.assertContainsOnly("HTTP/1.1 200 OK\r\n\r\n")
    }

    func testFullPipelineCanDisableFramingHeaders_syncOperations() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                withEncoderConfiguration: .noFramingTransformation
            )
        )
        let request = ByteBuffer(string: "GET / HTTP/1.1\r\n\r\n")
        XCTAssertNoThrow(try channel.writeInbound(request))

        let response = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(response)))

        guard let buffer = try channel.readOutbound(as: ByteBuffer.self) else {
            XCTFail("Could not read buffer")
            return
        }

        buffer.assertContainsOnly("HTTP/1.1 200 OK\r\n\r\n")
    }

    func testFullPipelineCanDisableFramingHeaders_sendWithoutChunked() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                withEncoderConfiguration: .noFramingTransformation
            )
        )
        let request = ByteBuffer(string: "GET / HTTP/1.1\r\n\r\n")
        XCTAssertNoThrow(try channel.writeInbound(request))

        let response = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(response)))

        guard let buffer = try channel.readOutbound(as: ByteBuffer.self) else {
            XCTFail("Could not read buffer")
            return
        }

        buffer.assertContainsOnly("HTTP/1.1 200 OK\r\n\r\n")

        let body = ByteBuffer(string: "hello world!")
        try channel.writeOutbound(HTTPServerResponsePart.body(.byteBuffer(body)))
        guard let bodyBuffer = try channel.readOutbound(as: ByteBuffer.self) else {
            XCTFail("Unable to read buffer")
            return
        }
        XCTAssertEqual(bodyBuffer, body)

        try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        guard let trailerBuffer = try channel.readOutbound(as: ByteBuffer.self) else {
            XCTFail("Unable to read buffer")
            return
        }
        XCTAssertEqual(trailerBuffer.readableBytes, 0)
    }

    func testFullPipelineCanDisableFramingHeaders_sendWithChunked() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                withEncoderConfiguration: .noFramingTransformation
            )
        )
        let request = ByteBuffer(string: "GET / HTTP/1.1\r\n\r\n")
        XCTAssertNoThrow(try channel.writeInbound(request))

        let response = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["transfer-encoding": "chunked"])
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(response)))

        guard let buffer = try channel.readOutbound(as: ByteBuffer.self) else {
            XCTFail("Could not read buffer")
            return
        }

        buffer.assertContainsOnly("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")

        let body = ByteBuffer(string: "hello world!")
        try channel.writeOutbound(HTTPServerResponsePart.body(.byteBuffer(body)))
        guard let prefixBuffer = try channel.readOutbound(as: ByteBuffer.self) else {
            XCTFail("Unable to read buffer")
            return
        }
        guard let bodyBuffer = try channel.readOutbound(as: ByteBuffer.self) else {
            XCTFail("Unable to read buffer")
            return
        }
        guard let suffixBuffer = try channel.readOutbound(as: ByteBuffer.self) else {
            XCTFail("Unable to read buffer")
            return
        }
        XCTAssertEqual(prefixBuffer, ByteBuffer(string: "c\r\n"))
        XCTAssertEqual(bodyBuffer, body)
        XCTAssertEqual(suffixBuffer, ByteBuffer(string: "\r\n"))

        try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        guard let trailerBuffer = try channel.readOutbound(as: ByteBuffer.self) else {
            XCTFail("Unable to read buffer")
            return
        }
        XCTAssertEqual(trailerBuffer, ByteBuffer(string: "0\r\n\r\n"))
    }

    func testConflictingFramingHeadersStripsTransferEncoding() throws {
        let headers = HTTPHeaders([
            ("transfer-encoding", "chunked"),
            ("content-length", "3"),
        ])
        let writtenData = sendResponse(withStatus: .ok, andHeaders: headers)
        writtenData.assertContainsOnly("HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\n")
    }

    // MARK: - HEAD/CONNECT response body suppression

    /// Adds only the response encoder, lets it observe a request with `requestMethod`, then writes
    /// the given (bodyless) response and returns all response bytes as a single string.
    private func encodeResponse(
        toRequestMethod requestMethod: HTTPMethod,
        status: HTTPResponseStatus,
        headers: HTTPHeaders = HTTPHeaders(),
        configuration: HTTPResponseEncoder.Configuration = .init()
    ) throws -> String {
        let channel = EmbeddedChannel()
        defer { XCTAssertEqual(true, try? channel.finish().isClean) }

        // Feed the encoder the request method, exactly as the paired request decoder would when the
        // request was decoded.
        let encoder = HTTPResponseEncoder(configuration: configuration)
        try channel.pipeline.syncOperations.addHandler(encoder)
        encoder.recordRequestMethod(requestMethod)

        var responseHead = HTTPResponseHead(version: .http1_1, status: status)
        responseHead.headers = headers
        try channel.writeOutbound(HTTPServerResponsePart.head(responseHead))
        try channel.writeOutbound(HTTPServerResponsePart.end(nil))

        var all = channel.allocator.buffer(capacity: 128)
        while var buffer = try channel.readOutbound(as: ByteBuffer.self) {
            all.writeBuffer(&buffer)
        }
        return String(buffer: all)
    }

    /// Asserts that writing a body part for a response to `requestMethod` (a HEAD/CONNECT request,
    /// which cannot have a body) fails with ``NIOHTTPResponseEncoderError/responseBodyNotAllowed``.
    private func assertBodyWriteRejected(
        forRequestMethod requestMethod: HTTPMethod,
        configuration: HTTPResponseEncoder.Configuration = .init(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        let encoder = HTTPResponseEncoder(configuration: configuration)
        try channel.pipeline.syncOperations.addHandler(encoder)
        encoder.recordRequestMethod(requestMethod)

        try channel.writeOutbound(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok)))
        XCTAssertThrowsError(
            try channel.writeOutbound(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "hello")))),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? NIOHTTPResponseEncoderError, .responseBodyNotAllowed, file: file, line: line)
        }
    }

    func testHeadResponseOmitsChunkedTerminator() throws {
        // A 200 with no Content-Length is chunked for a GET; for a HEAD the framing header is
        // preserved but the terminator ("0\r\n\r\n") — an illegal body — must not be written.
        XCTAssertEqual(
            try self.encodeResponse(toRequestMethod: .HEAD, status: .ok),
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n"
        )
    }

    func testHeadResponsePreservesExplicitContentLength() throws {
        // An explicit Content-Length (what a GET would return) is preserved and no body is sent.
        XCTAssertEqual(
            try self.encodeResponse(toRequestMethod: .HEAD, status: .ok, headers: ["content-length": "1000"]),
            "HTTP/1.1 200 OK\r\ncontent-length: 1000\r\n\r\n"
        )
    }

    func testWritingBodyToHeadResponseIsRejected() throws {
        // A HEAD response must not carry a body: writing one is rejected rather than silently dropped.
        try self.assertBodyWriteRejected(forRequestMethod: .HEAD)
    }

    func testWritingBodyToHeadResponseIsRejectedInManualFramingMode() throws {
        // Body suppression is method-based, so it applies even when the caller owns the framing headers.
        try self.assertBodyWriteRejected(forRequestMethod: .HEAD, configuration: .noFramingTransformation)
    }

    func testConnectResponseOmitsFramingHeaders() throws {
        // A CONNECT response carries no body, and a 2xx CONNECT response must not include
        // Transfer-Encoding or Content-Length (it switches to a tunnel), so no framing header is
        // emitted.
        XCTAssertEqual(
            try self.encodeResponse(toRequestMethod: .CONNECT, status: .ok),
            "HTTP/1.1 200 OK\r\n\r\n"
        )
    }

    func testWritingBodyToConnectResponseIsRejected() throws {
        // A CONNECT response must not carry a body either.
        try self.assertBodyWriteRejected(forRequestMethod: .CONNECT)
    }

    func testConnectResponseStripsExplicitContentLength() throws {
        // A 2xx CONNECT response must not carry Content-Length either; it's stripped.
        XCTAssertEqual(
            try self.encodeResponse(toRequestMethod: .CONNECT, status: .ok, headers: ["content-length": "1000"]),
            "HTTP/1.1 200 OK\r\n\r\n"
        )
    }

    func testManualFramingModeStillOmitsHeadResponseTerminator() throws {
        // With automaticallySetFramingHeaders = false the caller owns the framing headers (here a
        // chunked Transfer-Encoding is left untouched), but the end-of-body marker is still
        // suppressed for a HEAD response.
        XCTAssertEqual(
            try self.encodeResponse(
                toRequestMethod: .HEAD,
                status: .ok,
                headers: ["transfer-encoding": "chunked"],
                configuration: .noFramingTransformation
            ),
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n"
        )
    }

    func testGetResponseStillEmitsChunkedTerminator() throws {
        // Control: the identical response to a GET must still be chunked, terminator included.
        XCTAssertEqual(
            try self.encodeResponse(toRequestMethod: .GET, status: .ok),
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n0\r\n\r\n"
        )
    }

    func testEncoderWithoutObservedRequestFallsBackToStatusFraming() throws {
        // If the encoder never observes a request (e.g. placed before the decoder, or used
        // standalone) it behaves exactly as before: status-only framing, terminator included.
        let channel = EmbeddedChannel()
        defer { XCTAssertEqual(true, try? channel.finish().isClean) }
        try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder())
        try channel.writeOutbound(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok)))
        try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        var all = channel.allocator.buffer(capacity: 128)
        while var buffer = try channel.readOutbound(as: ByteBuffer.self) {
            all.writeBuffer(&buffer)
        }
        XCTAssertEqual(String(buffer: all), "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n0\r\n\r\n")
    }

    func testHeadThenGetOnConfiguredServerPipelineKeepsConnectionUsable() throws {
        // End-to-end via configureHTTPServerPipeline: the HEAD response carries no body, and a
        // subsequent GET on the same keep-alive connection is framed normally. This proves the
        // request-method queue advances correctly and the response stream isn't corrupted.
        let channel = EmbeddedChannel()
        defer { XCTAssertNoThrow(try channel.finish()) }
        try channel.pipeline.syncOperations.configureHTTPServerPipeline()

        func readAllOutbound() throws -> String {
            var all = channel.allocator.buffer(capacity: 128)
            while var buffer = try channel.readOutbound(as: ByteBuffer.self) {
                all.writeBuffer(&buffer)
            }
            return String(buffer: all)
        }
        func drainInboundRequest() throws {
            while try channel.readInbound(as: HTTPServerRequestPart.self) != nil {}
        }

        try channel.writeInbound(ByteBuffer(string: "HEAD /foo HTTP/1.1\r\nhost: example.com\r\n\r\n"))
        try drainInboundRequest()
        try channel.writeOutbound(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok)))
        try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        XCTAssertEqual(try readAllOutbound(), "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")

        try channel.writeInbound(ByteBuffer(string: "GET /foo HTTP/1.1\r\nhost: example.com\r\n\r\n"))
        try drainInboundRequest()
        try channel.writeOutbound(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok)))
        try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        XCTAssertEqual(try readAllOutbound(), "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n0\r\n\r\n")
    }

    func testRequestMethodQueuePreservesFIFOOrderThroughOverflow() {
        // The single in-flight case is inline; more than one pending (as when a peer pipelines and
        // the decoder reads ahead) spills to the overflow buffer. Either way, order must be FIFO.
        var queue = HTTPServerRequestMethodQueue()
        XCTAssertNil(queue.popFirst())

        // Common case: append then pop, repeatedly, never using overflow.
        queue.append(.GET)
        XCTAssertEqual(queue.popFirst(), .GET)
        XCTAssertNil(queue.popFirst())

        // Several pending at once (pipelining) must come back oldest-first.
        queue.append(.HEAD)
        queue.append(.GET)
        queue.append(.CONNECT)
        XCTAssertEqual(queue.popFirst(), .HEAD)
        XCTAssertEqual(queue.popFirst(), .GET)
        XCTAssertEqual(queue.popFirst(), .CONNECT)
        XCTAssertNil(queue.popFirst())

        // Interleaving append/pop after overflow was used still preserves order.
        queue.append(.HEAD)
        queue.append(.GET)
        XCTAssertEqual(queue.popFirst(), .HEAD)
        queue.append(.CONNECT)
        XCTAssertEqual(queue.popFirst(), .GET)
        XCTAssertEqual(queue.popFirst(), .CONNECT)
        XCTAssertNil(queue.popFirst())
    }
}
