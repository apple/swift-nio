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

import NIOCore
import NIOEmbedded
import NIOHTTP1
import Testing

@Suite struct HTTPHeaderValidationTests {
    @Test func encodingInvalidHeaderFieldNamesInRequests() throws {
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
        let weirdAllowedFieldName =
            "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHTTPClientHandlers()

        let headers = HTTPHeaders([("Host", "example.com"), (weirdAllowedFieldName, "present")])
        let goodRequest = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: headers)
        let goodRequestBytes = ByteBuffer(
            string: "GET / HTTP/1.1\r\nHost: example.com\r\n\(weirdAllowedFieldName): present\r\n\r\n"
        )

        #expect(throws: Never.self) { try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)) }
        #expect(throws: Never.self) { try channel.writeOutbound(HTTPClientRequestPart.end(nil)) }
        #expect(try channel.readOutbound(as: ByteBuffer.self) == goodRequestBytes)

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

            let error = #expect(throws: HTTPParserError.self) {
                try channel.writeOutbound(HTTPClientRequestPart.head(badRequest))
            }
            #expect(error == .invalidHeaderToken)
            _ = try? channel.finish()
        }
    }

    @Test func encodingInvalidTrailerFieldNamesInRequests() throws {
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
        let weirdAllowedFieldName =
            "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHTTPClientHandlers()

        let headers = HTTPHeaders([("Host", "example.com"), ("Transfer-Encoding", "chunked")])
        let goodRequest = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: headers)
        let goodRequestBytes = ByteBuffer(
            string: "POST / HTTP/1.1\r\nHost: example.com\r\ntransfer-encoding: chunked\r\n\r\n"
        )
        let goodTrailers = ByteBuffer(string: "0\r\n\(weirdAllowedFieldName): present\r\n\r\n")

        #expect(throws: Never.self) { try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)) }
        #expect(throws: Never.self) {
            try channel.writeOutbound(HTTPClientRequestPart.end([weirdAllowedFieldName: "present"]))
        }

        #expect(try channel.readOutbound(as: ByteBuffer.self) == goodRequestBytes)
        #expect(try channel.readOutbound(as: ByteBuffer.self) == goodTrailers)

        // Now confirm all other bytes are rejected.
        for byte in UInt8(0)...UInt8(255) {
            // Skip bytes that we already believe are allowed.
            if weirdAllowedFieldName.utf8.contains(byte) {
                continue
            }
            let forbiddenFieldName = weirdAllowedFieldName + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.addHTTPClientHandlers()

            #expect(throws: Never.self) { try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)) }

            let error = #expect(throws: HTTPParserError.self) {
                try channel.writeOutbound(HTTPClientRequestPart.end([forbiddenFieldName: "present"]))
            }
            #expect(error == .invalidHeaderToken)
            _ = try? channel.finish()
        }
    }

    @Test func encodingInvalidHeaderFieldValuesInRequests() throws {
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

        try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest))
        #expect(try channel.readOutbound(as: ByteBuffer.self) == goodRequestBytes)

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

            let error = #expect(throws: HTTPParserError.self) {
                try channel.writeOutbound(HTTPClientRequestPart.head(badRequest))
            }
            #expect(error == .invalidHeaderToken)
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

            #expect(throws: Never.self) { try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)) }
            #expect(try channel.readOutbound(as: ByteBuffer.self) == goodRequestBytes)
            _ = try? channel.finish()
        }
    }

    @Test func encodingInvalidTrailerFieldValuesInRequests() throws {
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

        #expect(throws: Never.self) { try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)) }
        #expect(throws: Never.self) {
            try channel.writeOutbound(HTTPClientRequestPart.end(["Weird-Value": weirdAllowedFieldValue]))
        }

        #expect(try channel.readOutbound(as: ByteBuffer.self) == goodRequestBytes)
        #expect(try channel.readOutbound(as: ByteBuffer.self) == goodTrailers)

        // Now confirm all other bytes in the ASCII range are rejected.
        for byte in UInt8(0)..<UInt8(128) {
            // Skip bytes that we already believe are allowed.
            if weirdAllowedFieldValue.utf8.contains(byte) {
                continue
            }
            let forbiddenFieldValue = weirdAllowedFieldValue + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.addHTTPClientHandlers()

            try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest))

            let error = #expect(throws: HTTPParserError.self) {
                try channel.writeOutbound(HTTPClientRequestPart.end(["Weird-Value": forbiddenFieldValue]))
            }
            #expect(error == .invalidHeaderToken)
            _ = try? channel.finish()
        }

        // All the bytes outside the ASCII range are fine though.
        for byte in UInt8(128)...UInt8(255) {
            let evenWeirderAllowedValue = weirdAllowedFieldValue + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.addHTTPClientHandlers()

            let weirdGoodTrailers = ByteBuffer(string: "0\r\nWeird-Value: \(evenWeirderAllowedValue)\r\n\r\n")

            #expect(throws: Never.self) { try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)) }
            #expect(throws: Never.self) {
                try channel.writeOutbound(
                    HTTPClientRequestPart.end(["Weird-Value": evenWeirderAllowedValue])
                )
            }
            #expect(try channel.readOutbound(as: ByteBuffer.self) == goodRequestBytes)
            #expect(try channel.readOutbound(as: ByteBuffer.self) == weirdGoodTrailers)
            _ = try? channel.finish()
        }
    }

    @Test func encodingInvalidHeaderFieldNamesInResponses() throws {
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
        let weirdAllowedFieldName =
            "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
        try channel.primeForResponse()

        let headers = HTTPHeaders([("Content-Length", "0"), (weirdAllowedFieldName, "present")])
        let goodResponse = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        let goodResponseBytes = ByteBuffer(
            string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\(weirdAllowedFieldName): present\r\n\r\n"
        )

        #expect(throws: Never.self) { try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse)) }
        #expect(throws: Never.self) { try channel.writeOutbound(HTTPServerResponsePart.end(nil)) }
        #expect(try channel.readOutbound(as: ByteBuffer.self) == goodResponseBytes)

        // Now confirm all other bytes are rejected.
        for byte in UInt8(0)...UInt8(255) {
            // Skip bytes that we already believe are allowed.
            if weirdAllowedFieldName.utf8.contains(byte) { continue }
            let forbiddenFieldName = weirdAllowedFieldName + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
            try channel.primeForResponse()

            let headers = HTTPHeaders([("Content-Length", "0"), (forbiddenFieldName, "present")])
            let badResponse = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)

            let error = #expect(throws: HTTPParserError.self) {
                try channel.writeOutbound(HTTPServerResponsePart.head(badResponse))
            }
            #expect(error == .invalidHeaderToken)
            _ = try? channel.finish()
        }
    }

    @Test func encodingInvalidTrailerFieldNamesInResponses() throws {
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
        let weirdAllowedFieldName =
            "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
        try channel.primeForResponse()

        let headers = HTTPHeaders([("Transfer-Encoding", "chunked")])
        let goodResponse = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        let goodResponseBytes = ByteBuffer(string: "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
        let goodTrailers = ByteBuffer(string: "0\r\n\(weirdAllowedFieldName): present\r\n\r\n")

        #expect(throws: Never.self) { try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse)) }
        #expect(throws: Never.self) {
            try channel.writeOutbound(HTTPServerResponsePart.end([weirdAllowedFieldName: "present"]))
        }

        #expect(try channel.readOutbound(as: ByteBuffer.self) == goodResponseBytes)
        #expect(try channel.readOutbound(as: ByteBuffer.self) == goodTrailers)

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

            try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse))

            let error = #expect(throws: HTTPParserError.self) {
                try channel.writeOutbound(HTTPServerResponsePart.end([forbiddenFieldName: "present"]))
            }
            #expect(error == .invalidHeaderToken)
            _ = try? channel.finish()
        }
    }

    @Test func encodingInvalidHeaderFieldValuesInResponses() throws {
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

        #expect(throws: Never.self) { try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse)) }
        #expect(try channel.readOutbound(as: ByteBuffer.self) == goodResponseBytes)

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

            let error = #expect(throws: HTTPParserError.self) {
                try channel.writeOutbound(HTTPServerResponsePart.head(badResponse))
            }
            #expect(error == .invalidHeaderToken)
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
                string:
                    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nWeird-Value: \(evenWeirderAllowedValue)\r\n\r\n"
            )

            #expect(throws: Never.self) { try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse)) }
            #expect(try channel.readOutbound(as: ByteBuffer.self) == goodResponseBytes)
            _ = try? channel.finish()
        }
    }

    @Test func encodingInvalidTrailerFieldValuesInResponses() throws {
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

        #expect(throws: Never.self) { try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse)) }
        #expect(throws: Never.self) {
            try channel.writeOutbound(HTTPServerResponsePart.end(["Weird-Value": weirdAllowedFieldValue]))
        }

        #expect(try channel.readOutbound(as: ByteBuffer.self) == goodResponseBytes)
        #expect(try channel.readOutbound(as: ByteBuffer.self) == goodTrailers)

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

            try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse))

            let error = #expect(throws: HTTPParserError.self) {
                try channel.writeOutbound(HTTPServerResponsePart.end(["Weird-Value": forbiddenFieldValue]))
            }
            #expect(error == .invalidHeaderToken)
            _ = try? channel.finish()
        }

        // All the bytes outside the ASCII range are fine though.
        for byte in UInt8(128)...UInt8(255) {
            let evenWeirderAllowedValue = weirdAllowedFieldValue + String(decoding: [byte], as: UTF8.self)

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
            try channel.primeForResponse()

            let weirdGoodTrailers = ByteBuffer(string: "0\r\nWeird-Value: \(evenWeirderAllowedValue)\r\n\r\n")

            #expect(throws: Never.self) { try channel.writeOutbound(HTTPServerResponsePart.head(goodResponse)) }
            #expect(throws: Never.self) {
                try channel.writeOutbound(
                    HTTPServerResponsePart.end(["Weird-Value": evenWeirderAllowedValue])
                )
            }
            #expect(try channel.readOutbound(as: ByteBuffer.self) == goodResponseBytes)
            #expect(try channel.readOutbound(as: ByteBuffer.self) == weirdGoodTrailers)
            _ = try? channel.finish()
        }
    }

    @Test func responseIsDroppedIfHeadersInvalid() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
        try channel.primeForResponse()

        // Read the first request.
        let requestHead = try #require(try channel.readInbound(as: HTTPServerRequestPart.self))
        guard case .head = requestHead else {
            Issue.record("Expected 'head'")
            return
        }

        let requestEnd = try #require(try channel.readInbound(as: HTTPServerRequestPart.self))
        guard case .end = requestEnd else {
            Issue.record("Expected 'end'")
            return
        }

        #expect(try channel.readInbound(as: HTTPServerRequestPart.self) == nil)

        // Respond with bad headers; they should cause an error and result in the rest of the
        // response being dropped.
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: [":pseudo-header": "not-here"])
        #expect(throws: (any Error).self) {
            try channel.writeOutbound(HTTPServerResponsePart.head(head))
        }
        #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)

        #expect(throws: (any Error).self) {
            try channel.writeOutbound(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer())))
        }
        #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)

        #expect(throws: (any Error).self) {
            try channel.writeOutbound(HTTPServerResponsePart.end(nil))
        }
        #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)
    }

    @Test func disablingValidationClientSide() throws {
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

        #expect(throws: Never.self) { try channel.writeOutbound(HTTPClientRequestPart.head(toleratedRequest)) }
        #expect(throws: Never.self) { try channel.writeOutbound(HTTPClientRequestPart.end(headers)) }

        #expect(try channel.readOutbound(as: ByteBuffer.self) == toleratedRequestBytes)
        #expect(try channel.readOutbound(as: ByteBuffer.self) == toleratedTrailerBytes)
    }

    @Test func disablingValidationServerSide() throws {
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
        let toleratedResponse = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        let toleratedResponseBytes = ByteBuffer(
            string:
                "HTTP/1.1 200 OK\r\nHost: example.com\r\n\(invalidHeaderName): \(invalidHeaderValue)\r\ntransfer-encoding: chunked\r\n\r\n"
        )
        let toleratedTrailerBytes = ByteBuffer(
            string:
                "0\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\(invalidHeaderName): \(invalidHeaderValue)\r\n\r\n"
        )

        #expect(throws: Never.self) { try channel.writeOutbound(HTTPServerResponsePart.head(toleratedResponse)) }
        #expect(throws: Never.self) { try channel.writeOutbound(HTTPServerResponsePart.end(headers)) }

        #expect(try channel.readOutbound(as: ByteBuffer.self) == toleratedResponseBytes)
        #expect(try channel.readOutbound(as: ByteBuffer.self) == toleratedTrailerBytes)
    }
}

extension EmbeddedChannel {
    fileprivate func primeForResponse() throws {
        let request = ByteBuffer(string: "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
        try self.writeInbound(request)
    }
}
