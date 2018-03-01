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
            XCTAssertEqual(.some(false), try? channel.finish())
        }

        try channel.pipeline.add(handler: HTTPRequestEncoder()).wait()
        var request = HTTPRequestHead(version: HTTPVersion(major: 1, minor:1), method: method, uri: "/uri")
        request.headers = headers
        try channel.writeOutbound(HTTPClientRequestPart.head(request))
        if case .some(.byteBuffer(let buffer)) = channel.readOutbound() {
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

    func testNoContentLengthHeadersForHEAD() throws {
        let headers = HTTPHeaders([("content-length", "0")])
        let writtenData = try sendRequest(withMethod: .HEAD, andHeaders: headers)
        writtenData.assertContainsOnly("HEAD /uri HTTP/1.1\r\n\r\n")
    }

    func testNoTransferEncodingHeadersForHEAD() throws {
        let headers = HTTPHeaders([("transfer-encoding", "chunked")])
        let writtenData = try sendRequest(withMethod: .HEAD, andHeaders: headers)
        writtenData.assertContainsOnly("HEAD /uri HTTP/1.1\r\n\r\n")
    }

    func testNoChunkedEncodingForHTTP10() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertEqual(.some(false), try? channel.finish())
        }

        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestEncoder()).wait())

        // This request contains neither Transfer-Encoding: chunked or Content-Length.
        let request = HTTPRequestHead(version: HTTPVersion(major: 1, minor:0), method: .GET, uri: "/uri")
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(request)))
        let writtenData: IOData = channel.readOutbound()!

        switch writtenData {
        case .byteBuffer(let b):
            let writtenResponse = b.getString(at: b.readerIndex, length: b.readableBytes)!
            XCTAssertEqual(writtenResponse, "GET /uri HTTP/1.0\r\n\r\n")
        case .fileRegion:
            XCTFail("Unexpected file region")
        }
    }

    func testBody() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertEqual(.some(false), try? channel.finish())
        }

        try channel.pipeline.add(handler: HTTPRequestEncoder()).wait()
        var request = HTTPRequestHead(version: HTTPVersion(major: 1, minor:1), method: .POST, uri: "/uri")
        request.headers.add(name: "content-length", value: "4")

        var buf = channel.allocator.buffer(capacity: 4)
        buf.write(staticString: "test")

        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(request)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.body(.byteBuffer(buf))))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.end(nil)))

        assertOutboundContainsOnly(channel, "POST /uri HTTP/1.1\r\ncontent-length: 4\r\n\r\n")
        assertOutboundContainsOnly(channel, "test")
        assertOutboundContainsOnly(channel, "")
    }

    private func assertOutboundContainsOnly(_ channel: EmbeddedChannel, _ expected: String) {
        if case .some(.byteBuffer(let buffer)) = channel.readOutbound() {
            buffer.assertContainsOnly(expected)
        } else {
            fatalError("Could not read ByteBuffer from channel")
        }
    }
}

