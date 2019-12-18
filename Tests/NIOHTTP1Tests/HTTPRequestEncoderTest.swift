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
@testable import NIO
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
        var request = HTTPRequestHead(version: HTTPVersion(major: 1, minor:1), method: method, uri: "/uri")
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
        let request = HTTPRequestHead(version: HTTPVersion(major: 1, minor:0), method: .GET, uri: "/uri")
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
        var request = HTTPRequestHead(version: HTTPVersion(major: 1, minor:1), method: .POST, uri: "/uri")
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
        var request = HTTPRequestHead(version: HTTPVersion(major: 1, minor:1), method: .CONNECT, uri: uri)
        request.headers.add(name: "Host", value: uri)

        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(request)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.end(nil)))

        assertOutboundContainsOnly(channel, "CONNECT \(uri) HTTP/1.1\r\nHost: \(uri)\r\n\r\n")
        assertOutboundContainsOnly(channel, "")
    }

    private func assertOutboundContainsOnly(_ channel: EmbeddedChannel, _ expected: String) {
        do {
            if let buffer = try channel.readOutbound(as: ByteBuffer.self) {
                buffer.assertContainsOnly(expected)
            } else {
                fatalError("Could not read ByteBuffer from channel")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

