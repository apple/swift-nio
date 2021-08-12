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
import XCTest
@testable import NIOCore
import NIOEmbedded
@testable import NIOHTTP1

private extension ByteBuffer {
    func assertContainsOnly(_ string: String) {
        let innerData = self.getString(at: self.readerIndex, length: self.readableBytes)!
        XCTAssertEqual(innerData, string)
    }
}

class HTTPRequestEncoderTests: XCTestCase {
    private func sendRequest(withMethod method: HTTPMethod, andHeaders headers: HTTPHeaders) throws -> ByteBuffer {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertEqual(true, try? channel.finish().isClean)
        }

        try channel.pipeline.addHandler(HTTPRequestEncoder()).wait()
        var request = HTTPRequestHead(version: .http1_1, method: method, uri: "/uri")
        request.headers = headers
        try channel.writeOutbound(HTTPClientRequestPart.head(request))
        if let buffer = try channel.readOutbound(as: ByteBuffer.self) {
            return buffer
        } else {
            fatalError("Could not read ByteBuffer from channel")
        }
    }

    func testNoAutoHeadersForHEAD() throws {
        let writtenData = try sendRequest(withMethod: .HEAD, andHeaders: HTTPHeaders())
        writtenData.assertContainsOnly("HEAD /uri HTTP/1.1\r\n\r\n")
    }

    func testNoAutoHeadersForGET() throws {
        let writtenData = try sendRequest(withMethod: .GET, andHeaders: HTTPHeaders())
        writtenData.assertContainsOnly("GET /uri HTTP/1.1\r\n\r\n")
    }

    func testGETContentHeadersLeftAlone() throws {
        var headers = HTTPHeaders([("content-length", "17")])
        var writtenData = try sendRequest(withMethod: .GET, andHeaders: headers)
        writtenData.assertContainsOnly("GET /uri HTTP/1.1\r\ncontent-length: 17\r\n\r\n")

        headers = HTTPHeaders([("transfer-encoding", "chunked")])
        writtenData = try sendRequest(withMethod: .GET, andHeaders: headers)
        writtenData.assertContainsOnly("GET /uri HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n")
    }

    func testContentLengthHeadersForHEAD() throws {
        let headers = HTTPHeaders([("content-length", "0")])
        let writtenData = try sendRequest(withMethod: .HEAD, andHeaders: headers)
        writtenData.assertContainsOnly("HEAD /uri HTTP/1.1\r\ncontent-length: 0\r\n\r\n")
    }

    func testTransferEncodingHeadersForHEAD() throws {
        let headers = HTTPHeaders([("transfer-encoding", "chunked")])
        let writtenData = try sendRequest(withMethod: .HEAD, andHeaders: headers)
        writtenData.assertContainsOnly("HEAD /uri HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n")
    }

    func testNoContentLengthHeadersForTRACE() throws {
        let headers = HTTPHeaders([("content-length", "0")])
        let writtenData = try sendRequest(withMethod: .TRACE, andHeaders: headers)
        writtenData.assertContainsOnly("TRACE /uri HTTP/1.1\r\n\r\n")
    }

    func testNoTransferEncodingHeadersForTRACE() throws {
        let headers = HTTPHeaders([("transfer-encoding", "chunked")])
        let writtenData = try sendRequest(withMethod: .TRACE, andHeaders: headers)
        writtenData.assertContainsOnly("TRACE /uri HTTP/1.1\r\n\r\n")
    }

    func testNoChunkedEncodingForHTTP10() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertEqual(true, try? channel.finish().isClean)
        }

        XCTAssertNoThrow(try channel.pipeline.addHandler(HTTPRequestEncoder()).wait())

        // This request contains neither Transfer-Encoding: chunked or Content-Length.
        let request = HTTPRequestHead(version: .http1_0, method: .GET, uri: "/uri")
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(request)))
        let writtenData = try channel.readOutbound(as: ByteBuffer.self)!
        let writtenResponse = writtenData.getString(at: writtenData.readerIndex, length: writtenData.readableBytes)!
        XCTAssertEqual(writtenResponse, "GET /uri HTTP/1.0\r\n\r\n")
    }

    func testBody() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertEqual(true, try? channel.finish().isClean)
        }

        try channel.pipeline.addHandler(HTTPRequestEncoder()).wait()
        var request = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/uri")
        request.headers.add(name: "content-length", value: "4")

        var buf = channel.allocator.buffer(capacity: 4)
        buf.writeStaticString("test")

        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(request)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.body(.byteBuffer(buf))))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.end(nil)))

        assertOutboundContainsOnly(channel, "POST /uri HTTP/1.1\r\ncontent-length: 4\r\n\r\n")
        assertOutboundContainsOnly(channel, "test")
        assertOutboundContainsOnly(channel, "")
    }

    func testCONNECT() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertEqual(true, try? channel.finish().isClean)
        }

        let uri = "server.example.com:80"
        try channel.pipeline.addHandler(HTTPRequestEncoder()).wait()
        var request = HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: uri)
        request.headers.add(name: "Host", value: uri)

        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(request)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.end(nil)))

        assertOutboundContainsOnly(channel, "CONNECT \(uri) HTTP/1.1\r\nHost: \(uri)\r\n\r\n")
        assertOutboundContainsOnly(channel, "")
    }

    func testChunkedEncodingIsTheDefault() {
        let channel = EmbeddedChannel(handler: HTTPRequestEncoder())
        var buffer = channel.allocator.buffer(capacity: 16)
        var expected = channel.allocator.buffer(capacity: 32)

        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(.init(version: .http1_1,
                                                                                    method: .POST,
                                                                                    uri: "/"))))
        expected.writeString("POST / HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n")
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))

        buffer.writeString("foo")
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.body(.byteBuffer(buffer))))

        expected.clear()
        expected.writeString("3\r\n")
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))
        expected.clear()
        expected.writeString("foo")
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))
        expected.clear()
        expected.writeString("\r\n")
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))

        expected.clear()
        expected.writeString("0\r\n\r\n")
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.end(nil)))
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))

        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
    }

    func testChunkedEncodingCanBetEnabled() {
        let channel = EmbeddedChannel(handler: HTTPRequestEncoder())
        var buffer = channel.allocator.buffer(capacity: 16)
        var expected = channel.allocator.buffer(capacity: 32)

        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(.init(version: .http1_1,
                                                                                    method: .POST,
                                                                                    uri: "/",
                                                                                    headers: ["TrAnSfEr-encoding": "chuNKED"]))))
        expected.writeString("POST / HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n")
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))

        buffer.writeString("foo")
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.body(.byteBuffer(buffer))))

        expected.clear()
        expected.writeString("3\r\n")
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))
        expected.clear()
        expected.writeString("foo")
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))
        expected.clear()
        expected.writeString("\r\n")
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))

        expected.clear()
        expected.writeString("0\r\n\r\n")
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.end(nil)))
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))

        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
    }

    func testChunkedEncodingDealsWithZeroLengthChunks() {
        let channel = EmbeddedChannel(handler: HTTPRequestEncoder())
        var buffer = channel.allocator.buffer(capacity: 16)
        var expected = channel.allocator.buffer(capacity: 32)

        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(.init(version: .http1_1,
                                                                                    method: .POST,
                                                                                    uri: "/"))))
        expected.writeString("POST / HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n")
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))

        buffer.clear()
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.body(.byteBuffer(buffer))))
        XCTAssertNoThrow(XCTAssertEqual(0, try channel.readOutbound(as: ByteBuffer.self)?.readableBytes))

        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.end(["foo": "bar"])))

        expected.clear()
        expected.writeString("0\r\nfoo: bar\r\n\r\n")
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))

        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
    }

    func testChunkedEncodingWorksIfNoPromisesAreAttachedToTheWrites() {
        let channel = EmbeddedChannel(handler: HTTPRequestEncoder())
        var buffer = channel.allocator.buffer(capacity: 16)
        var expected = channel.allocator.buffer(capacity: 32)

        channel.write(HTTPClientRequestPart.head(.init(version: .http1_1,
                                                       method: .POST,
                                                       uri: "/")), promise: nil)
        channel.flush()
        expected.writeString("POST / HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n")
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))

        buffer.writeString("foo")
        channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
        channel.flush()

        expected.clear()
        expected.writeString("3\r\n")
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))
        expected.clear()
        expected.writeString("foo")
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))
        expected.clear()
        expected.writeString("\r\n")
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))

        expected.clear()
        expected.writeString("0\r\n\r\n")
        channel.write(HTTPClientRequestPart.end(nil), promise: nil)
        channel.flush()
        XCTAssertNoThrow(XCTAssertEqual(expected, try channel.readOutbound(as: ByteBuffer.self)))

        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
    }

    private func assertOutboundContainsOnly(_ channel: EmbeddedChannel, _ expected: String) {
        XCTAssertNoThrow(XCTAssertNotNil(try channel.readOutbound(as: ByteBuffer.self).map { buffer in
            buffer.assertContainsOnly(expected)
        }, "couldn't read ByteBuffer"))
    }
}

