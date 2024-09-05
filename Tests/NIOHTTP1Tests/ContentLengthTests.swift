//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
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

final class ContentLengthTests: XCTestCase {

    /// Client receives a response longer than the content-length header
    func testResponseContentTooLong() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHTTPClientHandlers()
        defer {
            _ = try? channel.finish()
        }
        // Receive a response with a content-length header of 2 but a body of more than 2 bytes
        let badResponse = "HTTP/1.1 200 OK\r\nServer: foo\r\nContent-Length: 2\r\n\r\ntoo many bytes"

        XCTAssertThrowsError(try channel.sendRequestAndReceiveResponse(response: badResponse)) { error in
            XCTAssertEqual(error as? HTTPParserError, .invalidConstant)
        }

        channel.embeddedEventLoop.run()
    }

    /// Client receives a response shorter than the content-length header
    func testResponseContentTooShort() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHTTPClientHandlers()
        defer {
            _ = try? channel.finish()
        }
        // Receive a response with a content-length header of 100 but a body of less than 100 bytes
        let badResponse = "HTTP/1.1 200 OK\r\nServer: foo\r\nContent-Length: 100\r\n\r\nnot many bytes"

        // First is successful, it just waits for more bytes
        XCTAssertNoThrow(try channel.sendRequestAndReceiveResponse(response: badResponse))
        // It is waiting for 100-14 = 86 more bytes
        // We will send the same response again (75 bytes)
        // The client will consider this as part of the body of the previous response. No error expected
        XCTAssertNoThrow(try channel.sendRequestAndReceiveResponse(response: badResponse))
        // Now the client is expected only 86-75 = 11 bytes. We wil send the same 75 byte request again
        // An error is expected because everything from the 12th byte forward will be parsed as a new message, which isn't well formed
        XCTAssertThrowsError(try channel.sendRequestAndReceiveResponse(response: badResponse)) { error in
            XCTAssertEqual(error as? HTTPParserError, .invalidConstant)
        }

        channel.embeddedEventLoop.run()
    }

    /// Server receives a request longer than the content-length header
    func testRequestContentTooLong() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.configureHTTPServerPipeline()
        defer {
            _ = try? channel.finish()
        }
        // Receive a request with a content-length header of 2 but a body of more than 2 bytes
        let badRequest = "POST / HTTP/1.1\r\nContent-Length: 2\r\n\r\nhello"
        // First one is fine, the extra bytes will be treated as the next request
        XCTAssertNoThrow(try channel.receiveRequestAndSendResponse(request: badRequest, sendResponse: true))
        // Which means the next request is now malformed
        XCTAssertThrowsError(try channel.receiveRequestAndSendResponse(request: badRequest, sendResponse: true)) {
            error in
            XCTAssertEqual(error as? HTTPParserError, .invalidMethod)
        }

        channel.embeddedEventLoop.run()
    }

    /// Server receives a request shorter than the content-length header
    func testRequestContentTooShort() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.configureHTTPServerPipeline()
        defer {
            _ = try? channel.finish()
        }
        // Receive a request with a content-length header of 100 but a body of less
        let badRequest = "POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\nnot many bytes"
        // First one is fine, server will wait for 100-14 (86) further bytes to come
        XCTAssertNoThrow(try channel.receiveRequestAndSendResponse(request: badRequest, sendResponse: false))
        // The full request (60 bytes) will be treated as the body of the original request
        XCTAssertNoThrow(try channel.receiveRequestAndSendResponse(request: badRequest, sendResponse: false))
        // The original request is still 26 bytes short. Sending the request once more will complete it
        XCTAssertNoThrow(try channel.receiveRequestAndSendResponse(request: badRequest, sendResponse: true))
        // The leftover bytes from the previous write (we wrote 100 bytes where it wanted 26) will form a new malformed request
        XCTAssertThrowsError(try channel.receiveRequestAndSendResponse(request: badRequest, sendResponse: true)) {
            error in
            XCTAssertEqual(error as? HTTPParserError, .invalidMethod)
        }

        channel.embeddedEventLoop.run()
    }
}

extension EmbeddedChannel {
    /// Do a request-response cycle
    /// Asserts that sending the request won't fail
    /// Throws if receiving the response fails
    fileprivate func sendRequestAndReceiveResponse(response: String) throws {
        // Send a request
        XCTAssertNoThrow(
            try self.writeOutbound(HTTPClientRequestPart.head(.init(version: .http1_1, method: .GET, uri: "/")))
        )
        XCTAssertNoThrow(try self.writeOutbound(HTTPClientRequestPart.end(nil)))
        // Receive a response
        try self.writeInbound(ByteBuffer(string: response))
    }

    /// Do a response-request cycle
    /// Throws if receiving the request fails
    /// Asserts that sending the response won't fail
    fileprivate func receiveRequestAndSendResponse(request: String, sendResponse: Bool) throws {
        // Receive a request
        try self.writeInbound(ByteBuffer(string: request))
        // Send a response
        if sendResponse {
            XCTAssertNoThrow(try self.writeOutbound(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok))))
            XCTAssertNoThrow(try self.writeOutbound(HTTPServerResponsePart.end(nil)))
        }
    }
}
