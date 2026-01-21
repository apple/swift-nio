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
        configuration: HTTPResponseEncoder.Configuration = .init()
    ) -> ByteBuffer {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertEqual(true, try? channel.finish().isClean)
        }

        XCTAssertNoThrow(
            try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder(configuration: configuration))
        )
        var switchingResponse = HTTPResponseHead(version: .http1_1, status: status)
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
}
