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

            let error = #expect(
                throws: HTTPParserError.self,
                "Incorrectly tolerated character in header field name: \(String(decoding: [byte], as: UTF8.self))"
            ) {
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

            let error = #expect(
                throws: HTTPParserError.self,
                "Incorrectly tolerated character in trailer field name: \(String(decoding: [byte], as: UTF8.self))"
            ) {
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

            let error = #expect(
                throws: HTTPParserError.self,
                "Incorrectly tolerated character in header field value: \(String(decoding: [byte], as: UTF8.self))"
            ) {
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

            let error = #expect(
                throws: HTTPParserError.self,
                "Incorrectly tolerated character in trailer field value: \(String(decoding: [byte], as: UTF8.self))"
            ) {
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

            let error = #expect(
                throws: HTTPParserError.self,
                "Incorrectly tolerated character in header field name: \(String(decoding: [byte], as: UTF8.self))"
            ) {
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

            let error = #expect(
                throws: HTTPParserError.self,
                "Incorrectly tolerated character in trailer field name: \(String(decoding: [byte], as: UTF8.self))"
            ) {
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

            let error = #expect(
                throws: HTTPParserError.self,
                "Incorrectly tolerated character in header field value: \(String(decoding: [byte], as: UTF8.self))"
            ) {
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

            let error = #expect(
                throws: HTTPParserError.self,
                "Incorrectly tolerated character in trailer field value: \(String(decoding: [byte], as: UTF8.self))"
            ) {
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

    @Test func encodingInvalidUriInRequest() throws {
        // The spec in [RFC 9112](https://datatracker.ietf.org/doc/html/rfc9112#section-3.2) defines the valid
        // characters for the request-target as the following:
        //
        // ```
        // request-target = origin-form / absolute-form / authority-form / asterisk-form
        //
        // origin-form    = absolute-path [ "?" query ]
        // absolute-form  = absolute-URI
        // authority-form = uri-host ":" port              ; CONNECT only
        // asterisk-form  = "*"                            ; OPTIONS only
        // ```
        //
        // The component grammar comes from [RFC 3986](https://datatracker.ietf.org/doc/html/rfc3986#section-3)
        // (updated by [RFC 8820](https://datatracker.ietf.org/doc/html/rfc8820), which adds best-practice
        // guidance for URI design but does not change the syntax):
        //
        // ```
        // absolute-path = 1*( "/" segment )
        // segment       = *pchar
        // query         = *( pchar / "/" / "?" )
        //
        // pchar         = unreserved / pct-encoded / sub-delims / ":" / "@"
        // pct-encoded   = "%" HEXDIG HEXDIG
        //
        // unreserved    = ALPHA / DIGIT / "-" / "." / "_" / "~"
        // reserved      = gen-delims / sub-delims
        // gen-delims    = ":" / "/" / "?" / "#" / "[" / "]" / "@"
        // sub-delims    = "!" / "$" / "&" / "'" / "(" / ")"
        //               / "*" / "+" / "," / ";" / "="
        // ```
        //
        // In other words, the literal byte set allowed on the wire is:
        //
        // ```
        //   ALPHA          %x41-5A / %x61-7A      ; A–Z a–z
        //   DIGIT          %x30-39                ; 0–9
        //   unreserved     "-" "." "_" "~"
        //   gen-delims     ":" "/" "?" "#" "[" "]" "@"
        //   sub-delims     "!" "$" "&" "'" "(" ")" "*" "+" "," ";" "="
        //   pct-encoded    "%" HEXDIG HEXDIG      ; escape for anything else
        // ```
        //
        // Everything outside this set — SP, CTLs (%x00-1F / %x7F), non-ASCII (%x80-FF),
        // and `" < > \ ^ ` { | }` — MUST be percent-encoded. Bare CR, LF, or NUL in
        // the request-target MUST be rejected (request smuggling / response splitting).

        let allowed = "-._~:/?#[]@!$&'()*+,;=%0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHTTPClientHandlers()

        let headers = HTTPHeaders([("Host", "example.com")])
        let goodRequest = HTTPRequestHead(version: .http1_1, method: .GET, uri: allowed, headers: headers)
        let goodRequestBytes = ByteBuffer(
            string: "GET \(allowed) HTTP/1.1\r\nHost: example.com\r\n\r\n"
        )

        #expect(throws: Never.self) { try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)) }
        #expect(throws: Never.self) { try channel.writeOutbound(HTTPClientRequestPart.end(nil)) }
        #expect(try channel.readOutbound(as: ByteBuffer.self) == goodRequestBytes)

        // Now confirm all other bytes are rejected.
        for byte in UInt8(0)...UInt8(255) {
            // Skip bytes that we already believe are allowed.
            if allowed.utf8.contains(byte) {
                continue
            }

            guard let disallowedBytes = Self.makeStringContainingLiteralByte(byte) else {
                continue
            }

            let forbiddenUri = allowed + disallowedBytes

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.addHTTPClientHandlers()

            let headers = HTTPHeaders([("Host", "example.com")])
            let badRequest = HTTPRequestHead(version: .http1_1, method: .GET, uri: forbiddenUri, headers: headers)

            let error = #expect(
                throws: HTTPParserError.self,
                "Incorrectly tolerated character in method: \(String(decoding: [byte], as: UTF8.self))"
            ) {
                try channel.writeOutbound(HTTPClientRequestPart.head(badRequest))
            }
            #expect(error == .invalidHeaderToken)
            _ = try? channel.finish()
        }
    }

    @Test func encodingInvalidMethodInRequests() throws {
        // The spec in [RFC 9110](https://httpwg.org/specs/rfc9110.html#method.overview) defines the valid
        // characters as the following:
        //
        // ```
        // method = token
        //
        // token          = 1*tchar
        //
        // tchar          = "!" / "#" / "$" / "%" / "&" / "'" / "*"
        //                / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~"
        //                / DIGIT / ALPHA
        //                ; any VCHAR, except delimiters
        let weirdAllowedMethodName =
            "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHTTPClientHandlers()

        let headers = HTTPHeaders([("Host", "example.com")])
        let goodRequest = HTTPRequestHead(
            version: .http1_1,
            method: .RAW(value: weirdAllowedMethodName),
            uri: "/",
            headers: headers
        )
        let goodRequestBytes = ByteBuffer(
            string: "\(weirdAllowedMethodName) / HTTP/1.1\r\nHost: example.com\r\n\r\n"
        )

        #expect(throws: Never.self) { try channel.writeOutbound(HTTPClientRequestPart.head(goodRequest)) }
        #expect(throws: Never.self) { try channel.writeOutbound(HTTPClientRequestPart.end(nil)) }
        #expect(try channel.readOutbound(as: ByteBuffer.self) == goodRequestBytes)

        // Now confirm all other bytes are rejected.
        for byte in UInt8(0)...UInt8(255) {
            // Skip bytes that we already believe are allowed.
            if weirdAllowedMethodName.utf8.contains(byte) {
                continue
            }
            guard let extraString = Self.makeStringContainingLiteralByte(byte) else {
                continue
            }

            let forbiddenFieldName = weirdAllowedMethodName + extraString

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.addHTTPClientHandlers()

            let headers = HTTPHeaders([("Host", "example.com")])
            let badRequest = HTTPRequestHead(
                version: .http1_1,
                method: .RAW(value: forbiddenFieldName),
                uri: "/",
                headers: headers
            )

            let error = #expect(
                throws: HTTPParserError.self,
                "Incorrectly tolerated character in method: \(extraString)"
            ) {
                try channel.writeOutbound(HTTPClientRequestPart.head(badRequest))
            }
            #expect(error == .invalidHeaderToken)
            _ = try? channel.finish()
        }
    }

    @Test func encodingInvalidStatusReasonInResponses() throws {
        // The spec in [RFC 9112](https://datatracker.ietf.org/doc/html/rfc9112#section-4) defines the valid
        // characters as the following:
        //
        // ```
        // reason-phrase = 1*( HTAB / SP / VCHAR / obs-text )
        //
        // obs-text      = %x80-FF
        // ```

        let allowedRanges: [ClosedRange<UInt8>] = [
            9...9,  // HTAB
            32...32,  // SP
            33...126,  // VCHAR
            128...255,  // obs-text
        ]

        let base = "foo"
        let headers = HTTPHeaders([("transfer-encoding", "chunked")])

        // Now confirm all other bytes in the ASCII range are rejected.
        for byte in UInt8(0)..<UInt8(255) {
            let allowed = allowedRanges.contains(where: { $0.contains(byte) })

            guard let literalByteCanBeRepresented = Self.makeStringContainingLiteralByte(byte) else {
                continue
            }

            let testReason = base + literalByteCanBeRepresented

            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: false)
            try channel.primeForResponse()

            let response = HTTPResponseHead(
                version: .http1_1,
                status: .custom(code: 600, reasonPhrase: testReason),
                headers: headers
            )

            switch allowed {
            case true:
                let goodRequestBytes = ByteBuffer(
                    string: "HTTP/1.1 600 \(testReason)\r\ntransfer-encoding: chunked\r\n\r\n"
                )
                let goodEnd = ByteBuffer(string: "0\r\n\r\n")
                #expect(throws: Never.self, "Rejected reason phrase with byte: \(byte)") {
                    try channel.writeOutbound(HTTPServerResponsePart.head(response))
                }
                let bytes = try channel.readOutbound(as: ByteBuffer.self)
                #expect(bytes == goodRequestBytes)
                #expect(throws: Never.self) {
                    try channel.writeOutbound(HTTPServerResponsePart.end(nil))
                }
                #expect(try channel.readOutbound(as: ByteBuffer.self) == goodEnd)
            case false:
                let error = #expect(
                    throws: HTTPParserError.self,
                    "Incorrectly tolerated character in reason phrase: \(String(decoding: [byte], as: UTF8.self))"
                ) {
                    try channel.writeOutbound(HTTPServerResponsePart.head(response))
                }
                #expect(error == .invalidHeaderToken)
            }

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

    /// Returns a valid UTF-8 string whose utf8 bytes *literally contain* `byte`.
    /// Returns nil if `byte` cannot appear in any valid UTF-8 sequence.
    static func makeStringContainingLiteralByte(_ byte: UInt8) -> String? {
        switch byte {
        case 0x00...0x7F:
            // ASCII — appears as itself
            return String(Unicode.Scalar(byte))

        case 0x80...0xBF:
            // Continuation byte — pair with lead 0xC2 to form U+0080…U+00BF
            // UTF-8 of U+00XX (for 0x80…0xBF) is [0xC2, 0xXX]
            return String(Unicode.Scalar(byte))

        case 0xC0, 0xC1:
            return nil  // forbidden in UTF-8

        case 0xC2...0xDF:
            // Lead of 2-byte seq. Smallest scalar with this lead:
            // scalar = (byte & 0x1F) << 6  →  UTF-8 = [byte, 0x80]
            let scalar = UInt32(byte & 0x1F) << 6
            return Unicode.Scalar(scalar).map { String($0) }

        case 0xE0...0xEF:
            // Lead of 3-byte seq. Smallest non-overlong scalar:
            //   0xE0 → U+0800 (special: must be ≥ 0x0800 to avoid overlong)
            //   0xE1…0xEF → (byte & 0x0F) << 12
            let base = UInt32(byte & 0x0F) << 12
            let scalar = (byte == 0xE0) ? 0x0800 : base
            // Skip surrogates if we land in D800–DFFF (byte == 0xED)
            if byte == 0xED { return String(Unicode.Scalar(0xD000 - 0x0800 + base)!) }  // simple pick
            return Unicode.Scalar(scalar).map { String($0) }

        case 0xF0...0xF4:
            // Lead of 4-byte seq.
            //   0xF0 → U+10000 (minimum to avoid overlong)
            //   0xF1…0xF3 → (byte & 0x07) << 18
            //   0xF4 → must be ≤ U+10FFFF
            let scalar: UInt32
            switch byte {
            case 0xF0: scalar = 0x10000
            case 0xF4: scalar = 0x100000
            default: scalar = UInt32(byte & 0x07) << 18
            }
            return Unicode.Scalar(scalar).map { String($0) }

        default:  // 0xF5...0xFF
            return nil  // forbidden in UTF-8
        }
    }
}

extension EmbeddedChannel {
    fileprivate func primeForResponse() throws {
        let request = ByteBuffer(string: "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
        try self.writeInbound(request)
    }
}
