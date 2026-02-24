//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

final class HTTPHeaderValidationTests: XCTestCase {
    func testEncodingInvalidHeaderFieldNamesInRequests() throws {
        // The spec in [RFC 9110](https://httpwg.org/specs/rfc9110.html#fields.values) defines the valid
        // characters as the following:
        //
        // ```
        // field-name     = token
        //
        // token          = 1*tchar
        //
        // tchar          = "!" / "#" / "$" / "%" / "&" / "'" / "*"
        //                / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~"
        //                / DIGIT / ALPHA
        //                ; any VCHAR, except delimiters
        let weirdAllowedFieldName = "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHTTPClientHandlers()

        let headers = HTTPHeaders([("Host", "example.com"), (weirdAllowedFieldName, "present")])
        let goodRequest = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: headers)
        let goodRequestBytes = ByteBuffer(
            string: "GET / HTTP/1.1\r\nHost: example.com\r\n\(weirdAllowedFieldName): present\r\n\r\n"
        )

        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.end(nil)))

        var maybeReceivedBytes: ByteBuffer?

        XCTAssertNoThrow(maybeReceivedBytes = try channel.readOutbound())
        XCTAssertEqual(maybeReceivedBytes, goodRequestBytes)

        // Now confirm all other bytes are rejected.
        for byte in UInt8(0)...UInt8(255) {
            // Skip bytes that we already believe are allowed.
            if weirdAllowedFieldName.utf8.contains(byte) {
                continue
            }
            let forbiddenFieldName = weirdAllowedFieldName + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.addHTTPClientHandlers()

            let headers = HTTPHeaders([("Host", "example.com"), (forbiddenFieldName, "present")])
            let badRequest = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: headers)

            XCTAssertThrowsError(
                try channel.writeOutbound(HTTPClientRequestPart.head(badRequest)),
                "Incorrectly tolerated character in header field name: \(String(decoding: [byte], as: UTF8.self))"
            ) { error in
                XCTAssertEqual(error as? HTTPParserError, .invalidHeaderToken)
            }
            _ = try? channel.finish()
        }
    }

    func testEncodingInvalidTrailerFieldNamesInRequests() throws {
        // The spec in [RFC 9110](https://httpwg.org/specs/rfc9110.html#fields.values) defines the valid
        // characters as the following:
        //
        // ```
        // field-name     = token
        //
        // token          = 1*tchar
        //
        // tchar          = "!" / "#" / "$" / "%" / "&" / "'" / "*"
        //                / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~"
        //                / DIGIT / ALPHA
        //                ; any VCHAR, except delimiters
        let weirdAllowedFieldName = "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHTTPClientHandlers()

        let headers = HTTPHeaders([("Host", "example.com"), ("Transfer-Encoding", "chunked")])
        let goodRequest = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: headers)
        let goodRequestBytes = ByteBuffer(
            string: "POST / HTTP/1.1\r\nHost: example.com\r\ntransfer-encoding: chunked\r\n\r\n"
        )
        let goodTrailers = ByteBuffer(string: "0\r\n\(weirdAllowedFieldName): present\r\n\r\n")

        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.end([weirdAllowedFieldName: "present"])))

        var maybeRequestHeadBytes: ByteBuffer?
        var maybeRequestEndBytes: ByteBuffer?

        XCTAssertNoThrow(maybeRequestHeadBytes = try channel.readOutbound())
        XCTAssertNoThrow(maybeRequestEndBytes = try channel.readOutbound())
        XCTAssertEqual(maybeRequestHeadBytes, goodRequestBytes)
        XCTAssertEqual(maybeRequestEndBytes, goodTrailers)

        // Now confirm all other bytes are rejected.
        for byte in UInt8(0)...UInt8(255) {
            // Skip bytes that we already believe are allowed.
            if weirdAllowedFieldName.utf8.contains(byte) {
                continue
            }
            let forbiddenFieldName = weirdAllowedFieldName + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.addHTTPClientHandlers()

            XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)))

            XCTAssertThrowsError(
                try channel.writeOutbound(HTTPClientRequestPart.end([forbiddenFieldName: "present"])),
                "Incorrectly tolerated character in trailer field name: \(String(decoding: [byte], as: UTF8.self))"
            ) { error in
                XCTAssertEqual(error as? HTTPParserError, .invalidHeaderToken)
            }
            _ = try? channel.finish()
        }
    }

    func testEncodingInvalidHeaderFieldValuesInRequests() throws {
        // We reject all ASCII control characters except HTAB and tolerate everything else.
        let weirdAllowedFieldValue =
            "!\" \t#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHTTPClientHandlers()

        let headers = HTTPHeaders([("Host", "example.com"), ("Weird-Value", weirdAllowedFieldValue)])
        let goodRequest = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: headers)
        let goodRequestBytes = ByteBuffer(
            string: "GET / HTTP/1.1\r\nHost: example.com\r\nWeird-Value: \(weirdAllowedFieldValue)\r\n\r\n"
        )

        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)))

        var maybeBytes: ByteBuffer?

        XCTAssertNoThrow(maybeBytes = try channel.readOutbound())
        XCTAssertEqual(maybeBytes, goodRequestBytes)

        // Now confirm all other bytes in the ASCII range are rejected.
        for byte in UInt8(0)..<UInt8(128) {
            // Skip bytes that we already believe are allowed.
            if weirdAllowedFieldValue.utf8.contains(byte) {
                continue
            }
            let forbiddenFieldValue = weirdAllowedFieldValue + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.addHTTPClientHandlers()

            let headers = HTTPHeaders([("Host", "example.com"), ("Weird-Value", forbiddenFieldValue)])
            let badRequest = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: headers)

            XCTAssertThrowsError(
                try channel.writeOutbound(HTTPClientRequestPart.head(badRequest)),
                "Incorrectly tolerated character in header field value: \(String(decoding: [byte], as: UTF8.self))"
            ) { error in
                XCTAssertEqual(error as? HTTPParserError, .invalidHeaderToken)
            }
            _ = try? channel.finish()
        }

        // All the bytes outside the ASCII range are fine though.
        for byte in UInt8(128)...UInt8(255) {
            let evenWeirderAllowedValue = weirdAllowedFieldValue + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.addHTTPClientHandlers()

            let headers = HTTPHeaders([("Host", "example.com"), ("Weird-Value", evenWeirderAllowedValue)])
            let goodRequest = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: headers)
            let goodRequestBytes = ByteBuffer(
                string: "GET / HTTP/1.1\r\nHost: example.com\r\nWeird-Value: \(evenWeirderAllowedValue)\r\n\r\n"
            )

            XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)))

            var maybeBytes: ByteBuffer?

            XCTAssertNoThrow(maybeBytes = try channel.readOutbound())
            XCTAssertEqual(maybeBytes, goodRequestBytes)

            _ = try? channel.finish()
        }
    }

    func testEncodingInvalidTrailerFieldValuesInRequests() throws {
        // We reject all ASCII control characters except HTAB and tolerate everything else.
        let weirdAllowedFieldValue =
            "!\" \t#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHTTPClientHandlers()

        let headers = HTTPHeaders([("Host", "example.com"), ("Transfer-Encoding", "chunked")])
        let goodRequest = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: headers)
        let goodRequestBytes = ByteBuffer(
            string: "POST / HTTP/1.1\r\nHost: example.com\r\ntransfer-encoding: chunked\r\n\r\n"
        )
        let goodTrailers = ByteBuffer(string: "0\r\nWeird-Value: \(weirdAllowedFieldValue)\r\n\r\n")

        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.end(["Weird-Value": weirdAllowedFieldValue])))

        var maybeRequestHeadBytes: ByteBuffer?
        var maybeRequestEndBytes: ByteBuffer?

        XCTAssertNoThrow(maybeRequestHeadBytes = try channel.readOutbound())
        XCTAssertNoThrow(maybeRequestEndBytes = try channel.readOutbound())
        XCTAssertEqual(maybeRequestHeadBytes, goodRequestBytes)
        XCTAssertEqual(maybeRequestEndBytes, goodTrailers)

        // Now confirm all other bytes in the ASCII range are rejected.
        for byte in UInt8(0)..<UInt8(128) {
            // Skip bytes that we already believe are allowed.
            if weirdAllowedFieldValue.utf8.contains(byte) {
                continue
            }
            let forbiddenFieldValue = weirdAllowedFieldValue + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.addHTTPClientHandlers()

            XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)))

            XCTAssertThrowsError(
                try channel.writeOutbound(HTTPClientRequestPart.end(["Weird-Value": forbiddenFieldValue])),
                "Incorrectly tolerated character in trailer field value: \(String(decoding: [byte], as: UTF8.self))"
            ) { error in
                XCTAssertEqual(error as? HTTPParserError, .invalidHeaderToken)
            }
            _ = try? channel.finish()
        }

        // All the bytes outside the ASCII range are fine though.
        for byte in UInt8(128)...UInt8(255) {
            let evenWeirderAllowedValue = weirdAllowedFieldValue + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.addHTTPClientHandlers()

            let weirdGoodTrailers = ByteBuffer(string: "0\r\nWeird-Value: \(evenWeirderAllowedValue)\r\n\r\n")

            XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)))
            XCTAssertNoThrow(
                try channel.writeOutbound(HTTPClientRequestPart.end(["Weird-Value": evenWeirderAllowedValue]))
            )
            XCTAssertNoThrow(maybeRequestHeadBytes = try channel.readOutbound())
            XCTAssertNoThrow(maybeRequestEndBytes = try channel.readOutbound())
            XCTAssertEqual(maybeRequestHeadBytes, goodRequestBytes)
            XCTAssertEqual(maybeRequestEndBytes, weirdGoodTrailers)

            _ = try? channel.finish()
        }
    }

    func testEncodingInvalidHeaderFieldNamesInResponses() throws {
        // The spec in [RFC 9110](https://httpwg.org/specs/rfc9110.html#fields.values) defines the valid
        // characters as the following:
        //
        // ```
        // field-name     = token
        //
        // token          = 1*tchar
        //
        // tchar          = "!" / "#" / "$" / "%" / "&" / "'" / "*"
        //                / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~"
        //                / DIGIT / ALPHA
        //                ; any VCHAR, except delimiters
        let weirdAllowedFieldName = "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
        try channel.primeForResponse()

        let headers = HTTPHeaders([("Content-Length", "0"), (weirdAllowedFieldName, "present")])
        let goodResponse = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        let goodResponseBytes = ByteBuffer(
            string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\(weirdAllowedFieldName): present\r\n\r\n"
        )

        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        var maybeReceivedBytes: ByteBuffer?

        XCTAssertNoThrow(maybeReceivedBytes = try channel.readOutbound())
        XCTAssertEqual(maybeReceivedBytes, goodResponseBytes)

        // Now confirm all other bytes are rejected.
        for byte in UInt8(0)...UInt8(255) {
            // Skip bytes that we already believe are allowed.
            if weirdAllowedFieldName.utf8.contains(byte) {
                continue
            }
            let forbiddenFieldName = weirdAllowedFieldName + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
            try channel.primeForResponse()

            let headers = HTTPHeaders([("Content-Length", "0"), (forbiddenFieldName, "present")])
            let badResponse = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)

            XCTAssertThrowsError(
                try channel.writeOutbound(HTTPServerResponsePart.head(badResponse)),
                "Incorrectly tolerated character in header field name: \(String(decoding: [byte], as: UTF8.self))"
            ) { error in
                XCTAssertEqual(error as? HTTPParserError, .invalidHeaderToken)
            }
            _ = try? channel.finish()
        }
    }

    func testEncodingInvalidTrailerFieldNamesInResponses() throws {
        // The spec in [RFC 9110](https://httpwg.org/specs/rfc9110.html#fields.values) defines the valid
        // characters as the following:
        //
        // ```
        // field-name     = token
        //
        // token          = 1*tchar
        //
        // tchar          = "!" / "#" / "$" / "%" / "&" / "'" / "*"
        //                / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~"
        //                / DIGIT / ALPHA
        //                ; any VCHAR, except delimiters
        let weirdAllowedFieldName = "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
        try channel.primeForResponse()

        let headers = HTTPHeaders([("Transfer-Encoding", "chunked")])
        let goodResponse = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        let goodResponseBytes = ByteBuffer(string: "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
        let goodTrailers = ByteBuffer(string: "0\r\n\(weirdAllowedFieldName): present\r\n\r\n")

        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end([weirdAllowedFieldName: "present"])))

        var maybeRequestHeadBytes: ByteBuffer?
        var maybeRequestEndBytes: ByteBuffer?

        XCTAssertNoThrow(maybeRequestHeadBytes = try channel.readOutbound())
        XCTAssertNoThrow(maybeRequestEndBytes = try channel.readOutbound())
        XCTAssertEqual(maybeRequestHeadBytes, goodResponseBytes)
        XCTAssertEqual(maybeRequestEndBytes, goodTrailers)

        // Now confirm all other bytes are rejected.
        for byte in UInt8(0)...UInt8(255) {
            // Skip bytes that we already believe are allowed.
            if weirdAllowedFieldName.utf8.contains(byte) {
                continue
            }
            let forbiddenFieldName = weirdAllowedFieldName + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
            try channel.primeForResponse()

            XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse)))

            XCTAssertThrowsError(
                try channel.writeOutbound(HTTPServerResponsePart.end([forbiddenFieldName: "present"])),
                "Incorrectly tolerated character in trailer field name: \(String(decoding: [byte], as: UTF8.self))"
            ) { error in
                XCTAssertEqual(error as? HTTPParserError, .invalidHeaderToken)
            }
            _ = try? channel.finish()
        }
    }

    func testEncodingInvalidHeaderFieldValuesInResponses() throws {
        // We reject all ASCII control characters except HTAB and tolerate everything else.
        let weirdAllowedFieldValue =
            "!\" \t#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
        try channel.primeForResponse()

        let headers = HTTPHeaders([("Content-Length", "0"), ("Weird-Value", weirdAllowedFieldValue)])
        let goodResponse = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        let goodResponseBytes = ByteBuffer(
            string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nWeird-Value: \(weirdAllowedFieldValue)\r\n\r\n"
        )

        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse)))

        var maybeBytes: ByteBuffer?

        XCTAssertNoThrow(maybeBytes = try channel.readOutbound())
        XCTAssertEqual(maybeBytes, goodResponseBytes)

        // Now confirm all other bytes in the ASCII range are rejected.
        for byte in UInt8(0)..<UInt8(128) {
            // Skip bytes that we already believe are allowed.
            if weirdAllowedFieldValue.utf8.contains(byte) {
                continue
            }
            let forbiddenFieldValue = weirdAllowedFieldValue + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
            try channel.primeForResponse()

            let headers = HTTPHeaders([("Content-Length", "0"), ("Weird-Value", forbiddenFieldValue)])
            let badResponse = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)

            XCTAssertThrowsError(
                try channel.writeOutbound(HTTPServerResponsePart.head(badResponse)),
                "Incorrectly tolerated character in header field value: \(String(decoding: [byte], as: UTF8.self))"
            ) { error in
                XCTAssertEqual(error as? HTTPParserError, .invalidHeaderToken)
            }
            _ = try? channel.finish()
        }

        // All the bytes outside the ASCII range are fine though.
        for byte in UInt8(128)...UInt8(255) {
            let evenWeirderAllowedValue = weirdAllowedFieldValue + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
            try channel.primeForResponse()

            let headers = HTTPHeaders([("Content-Length", "0"), ("Weird-Value", evenWeirderAllowedValue)])
            let goodResponse = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            let goodResponseBytes = ByteBuffer(
                string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nWeird-Value: \(evenWeirderAllowedValue)\r\n\r\n"
            )

            XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse)))

            var maybeBytes: ByteBuffer?

            XCTAssertNoThrow(maybeBytes = try channel.readOutbound())
            XCTAssertEqual(maybeBytes, goodResponseBytes)

            _ = try? channel.finish()
        }
    }

    func testEncodingInvalidTrailerFieldValuesInResponses() throws {
        // We reject all ASCII control characters except HTAB and tolerate everything else.
        let weirdAllowedFieldValue =
            "!\" \t#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
        try channel.primeForResponse()

        let headers = HTTPHeaders([("Transfer-Encoding", "chunked")])
        let goodResponse = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        let goodResponseBytes = ByteBuffer(string: "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
        let goodTrailers = ByteBuffer(string: "0\r\nWeird-Value: \(weirdAllowedFieldValue)\r\n\r\n")

        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(["Weird-Value": weirdAllowedFieldValue])))

        var maybeResponseHeadBytes: ByteBuffer?
        var maybeResponseEndBytes: ByteBuffer?

        XCTAssertNoThrow(maybeResponseHeadBytes = try channel.readOutbound())
        XCTAssertNoThrow(maybeResponseEndBytes = try channel.readOutbound())
        XCTAssertEqual(maybeResponseHeadBytes, goodResponseBytes)
        XCTAssertEqual(maybeResponseEndBytes, goodTrailers)

        // Now confirm all other bytes in the ASCII range are rejected.
        for byte in UInt8(0)..<UInt8(128) {
            // Skip bytes that we already believe are allowed.
            if weirdAllowedFieldValue.utf8.contains(byte) {
                continue
            }
            let forbiddenFieldValue = weirdAllowedFieldValue + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
            try channel.primeForResponse()

            XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse)))

            XCTAssertThrowsError(
                try channel.writeOutbound(HTTPServerResponsePart.end(["Weird-Value": forbiddenFieldValue])),
                "Incorrectly tolerated character in trailer field value: \(String(decoding: [byte], as: UTF8.self))"
            ) { error in
                XCTAssertEqual(error as? HTTPParserError, .invalidHeaderToken)
            }
            _ = try? channel.finish()
        }

        // All the bytes outside the ASCII range are fine though.
        for byte in UInt8(128)...UInt8(255) {
            let evenWeirderAllowedValue = weirdAllowedFieldValue + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
            try channel.primeForResponse()

            let weirdGoodTrailers = ByteBuffer(string: "0\r\nWeird-Value: \(evenWeirderAllowedValue)\r\n\r\n")

            XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse)))
            XCTAssertNoThrow(
                try channel.writeOutbound(HTTPServerResponsePart.end(["Weird-Value": evenWeirderAllowedValue]))
            )
            XCTAssertNoThrow(maybeResponseHeadBytes = try channel.readOutbound())
            XCTAssertNoThrow(maybeResponseEndBytes = try channel.readOutbound())
            XCTAssertEqual(maybeResponseHeadBytes, goodResponseBytes)
            XCTAssertEqual(maybeResponseEndBytes, weirdGoodTrailers)

            _ = try? channel.finish()
        }
    }

    func testResponseIsDroppedIfHeadersInvalid() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
        try channel.primeForResponse()

        func assertReadHead(from channel: EmbeddedChannel) throws {
            if case .head = try channel.readInbound(as: HTTPServerRequestPart.self) {
                ()
            } else {
                XCTFail("Expected 'head'")
            }
        }

        func assertReadEnd(from channel: EmbeddedChannel) throws {
            if case .end = try channel.readInbound(as: HTTPServerRequestPart.self) {
                ()
            } else {
                XCTFail("Expected 'end'")
            }
        }

        // Read the first request.
        try assertReadHead(from: channel)
        try assertReadEnd(from: channel)
        XCTAssertNil(try channel.readInbound(as: HTTPServerRequestPart.self))

        // Respond with bad headers; they should cause an error and result in the rest of the
        // response being dropped.
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: [":pseudo-header": "not-here"])
        XCTAssertThrowsError(try channel.writeOutbound(HTTPServerResponsePart.head(head)))
        XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self))
        XCTAssertThrowsError(try channel.writeOutbound(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer()))))
        XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self))
        XCTAssertThrowsError(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))
        XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self))
    }

    func testDisablingValidationClientSide() throws {
        let invalidHeaderName = "HeaderNameWith\"Quote"
        let invalidHeaderValue = "HeaderValueWith\rCR"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHTTPClientHandlers(enableOutboundHeaderValidation: false)

        let headers = HTTPHeaders([
            ("Host", "example.com"), ("Transfer-Encoding", "chunked"), (invalidHeaderName, invalidHeaderValue),
        ])
        let toleratedRequest = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: headers)
        let toleratedRequestBytes = ByteBuffer(
            string:
                "POST / HTTP/1.1\r\nHost: example.com\r\n\(invalidHeaderName): \(invalidHeaderValue)\r\ntransfer-encoding: chunked\r\n\r\n"
        )
        let toleratedTrailerBytes = ByteBuffer(
            string:
                "0\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\(invalidHeaderName): \(invalidHeaderValue)\r\n\r\n"
        )

        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(toleratedRequest)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.end(headers)))

        var maybeReceivedHeadBytes: ByteBuffer?
        var maybeReceivedTrailerBytes: ByteBuffer?

        XCTAssertNoThrow(maybeReceivedHeadBytes = try channel.readOutbound())
        XCTAssertNoThrow(maybeReceivedTrailerBytes = try channel.readOutbound())
        XCTAssertEqual(maybeReceivedHeadBytes, toleratedRequestBytes)
        XCTAssertEqual(maybeReceivedTrailerBytes, toleratedTrailerBytes)
    }

    func testDisablingValidationServerSide() throws {
        let invalidHeaderName = "HeaderNameWith\"Quote"
        let invalidHeaderValue = "HeaderValueWith\rCR"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.configureHTTPServerPipeline(
            withErrorHandling: false,
            withOutboundHeaderValidation: false
        )
        try channel.primeForResponse()

        let headers = HTTPHeaders([
            ("Host", "example.com"), ("Transfer-Encoding", "chunked"), (invalidHeaderName, invalidHeaderValue),
        ])
        let toleratedRequest = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        let toleratedRequestBytes = ByteBuffer(
            string:
                "HTTP/1.1 200 OK\r\nHost: example.com\r\n\(invalidHeaderName): \(invalidHeaderValue)\r\ntransfer-encoding: chunked\r\n\r\n"
        )
        let toleratedTrailerBytes = ByteBuffer(
            string:
                "0\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\(invalidHeaderName): \(invalidHeaderValue)\r\n\r\n"
        )

        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(toleratedRequest)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(headers)))

        var maybeReceivedHeadBytes: ByteBuffer?
        var maybeReceivedTrailerBytes: ByteBuffer?

        XCTAssertNoThrow(maybeReceivedHeadBytes = try channel.readOutbound())
        XCTAssertNoThrow(maybeReceivedTrailerBytes = try channel.readOutbound())
        XCTAssertEqual(maybeReceivedHeadBytes, toleratedRequestBytes)
        XCTAssertEqual(maybeReceivedTrailerBytes, toleratedTrailerBytes)
    }
}

extension EmbeddedChannel {
    fileprivate func primeForResponse() throws {
        let request = ByteBuffer(string: "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
        try self.writeInbound(request)
    }
}
