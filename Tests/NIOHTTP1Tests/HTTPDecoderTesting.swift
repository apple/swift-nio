//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
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

@Suite struct HTTPDecoderTesting {

    // MARK: - Default limit tests

    @Test func requestWithExcessiveNumberOfHeadersErrors() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPRequestDecoder()))

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("GET / HTTP/1.1\r\nHost: example.com\r\n")
        try channel.writeInbound(buffer)

        var threwError = false
        for i in 0..<1_000_000 {
            let headerBuffer = ByteBuffer(string: "X-Hdr-\(i): v\r\n")
            do {
                try channel.writeInbound(headerBuffer)
            } catch {
                threwError = true
                break
            }
        }

        #expect(threwError, "Expected the decoder to reject a request with an excessive number of headers")
        _ = try? channel.finish()
    }

    @Test func requestWithOversizedURIErrors() throws {
        var config = NIOHTTPDecoderLimitConfiguration()
        config.maxHeaderListSize = 100 * 1024
        let decoder = HTTPRequestDecoder(limitConfiguration: config)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(decoder))

        var buffer = channel.allocator.buffer(capacity: 8)
        buffer.writeString("GET ")
        try channel.writeInbound(buffer)
        #expect(try channel.readInbound(as: HTTPServerRequestPart.self) == nil)

        var chunk = channel.allocator.buffer(capacity: 1024)
        chunk.writeRepeatingByte(UInt8(ascii: "x"), count: 1024)

        for _ in 0..<80 {
            try channel.writeInbound(chunk)
            #expect(try channel.readInbound(as: HTTPServerRequestPart.self) == nil)
        }

        let lastByte = chunk.getSlice(at: chunk.readerIndex, length: 1)!
        let error = #expect(throws: HTTPParserError.self) {
            try channel.writeInbound(lastByte)
        }
        #expect(error == .headerOverflow)

        _ = try? channel.finish()
    }

    @Test func requestWithOversizedMethodErrors() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPRequestDecoder()))

        var chunk = channel.allocator.buffer(capacity: 3)
        chunk.writeRepeatingByte(UInt8(ascii: "X"), count: 3)

        var threwError = false
        var caughtError: (any Error)?
        for _ in 0..<81 {
            do {
                try channel.writeInbound(chunk)
            } catch {
                threwError = true
                caughtError = error
                break
            }
        }

        #expect(threwError, "Expected the decoder to reject a request with an oversized method")
        if let parserError = caughtError as? HTTPParserError {
            #expect(parserError == .invalidMethod)
        }

        _ = try? channel.finish()
    }

    // MARK: - Field count limit tests

    @Test func requestAtFieldCountLimitSucceeds() throws {
        var config = NIOHTTPDecoderLimitConfiguration()
        config.maxHeaderFieldCount = 10
        let decoder = HTTPRequestDecoder(limitConfiguration: config)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(decoder))

        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeString("GET / HTTP/1.1\r\n")
        // Write exactly 10 headers (at the limit)
        for i in 0..<10 {
            buffer.writeString("X-Hdr-\(i): value\r\n")
        }
        buffer.writeString("\r\n")
        try channel.writeInbound(buffer)

        let head = try channel.readInbound(as: HTTPServerRequestPart.self)
        guard case .head(let requestHead) = head else {
            Issue.record("Expected .head, got \(String(describing: head))")
            return
        }
        #expect(requestHead.headers.count == 10)

        _ = try? channel.finish()
    }

    @Test func requestExceedingFieldCountLimitErrors() throws {
        var config = NIOHTTPDecoderLimitConfiguration()
        config.maxHeaderFieldCount = 10
        let decoder = HTTPRequestDecoder(limitConfiguration: config)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(decoder))

        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeString("GET / HTTP/1.1\r\n")
        // Write 11 headers (one over the limit)
        for i in 0..<11 {
            buffer.writeString("X-Hdr-\(i): value\r\n")
        }
        buffer.writeString("\r\n")

        let error = #expect(throws: HTTPParserError.self) {
            try channel.writeInbound(buffer)
        }
        #expect(error == .headerOverflow)

        _ = try? channel.finish()
    }

    @Test func defaultFieldCountLimitRejectsExcessiveHeaders() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPRequestDecoder()))

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("GET / HTTP/1.1\r\nHost: example.com\r\n")
        try channel.writeInbound(buffer)

        // Default limit is 256 fields. Sending 257 should fail.
        var threwError = false
        for i in 0..<257 {
            let headerBuffer = ByteBuffer(string: "X-H-\(i): v\r\n")
            do {
                try channel.writeInbound(headerBuffer)
            } catch {
                threwError = true
                break
            }
        }

        #expect(threwError, "Expected default field count limit to reject request with 257+ headers")
        _ = try? channel.finish()
    }

    // MARK: - Max header list size tests

    @Test func requestExceedingMaxHeaderListSizeErrors() throws {
        var config = NIOHTTPDecoderLimitConfiguration()
        config.maxHeaderListSize = 256
        let decoder = HTTPRequestDecoder(limitConfiguration: config)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(decoder))

        var buffer = channel.allocator.buffer(capacity: 512)
        buffer.writeString("GET / HTTP/1.1\r\n")
        // Create a header that pushes total over 256 bytes
        let bigValue = String(repeating: "x", count: 300)
        buffer.writeString("X-Big: \(bigValue)\r\n\r\n")

        let error = #expect(throws: HTTPParserError.self) {
            try channel.writeInbound(buffer)
        }
        #expect(error == .headerOverflow)

        _ = try? channel.finish()
    }

    @Test func requestWithinMaxHeaderListSizeSucceeds() throws {
        var config = NIOHTTPDecoderLimitConfiguration()
        config.maxHeaderListSize = 1024
        let decoder = HTTPRequestDecoder(limitConfiguration: config)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(decoder))

        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeString("GET / HTTP/1.1\r\n")
        let value = String(repeating: "x", count: 100)
        buffer.writeString("X-Hdr: \(value)\r\n\r\n")
        try channel.writeInbound(buffer)

        let head = try channel.readInbound(as: HTTPServerRequestPart.self)
        guard case .head = head else {
            Issue.record("Expected .head, got \(String(describing: head))")
            return
        }

        _ = try? channel.finish()
    }

    @Test func defaultMaxHeaderListSizeIs2MB() throws {
        var config = NIOHTTPDecoderLimitConfiguration()
        config.maxHeaderFieldCount = 10_000
        let decoder = HTTPRequestDecoder(limitConfiguration: config)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(decoder))

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("GET / HTTP/1.1\r\n")
        try channel.writeInbound(buffer)

        // Default maxHeaderListSize is 16384 * 128 = 2 MB. Send headers totaling > 2 MB.
        // Use values just under the default 16 KB field-size limit so the field-size
        // limit doesn't trigger first.
        let valueSize = 16000
        var totalBytes = 0
        var threwError = false
        for i in 0..<200 {
            let name = "X-H-\(i)"
            let value = String(repeating: "a", count: valueSize)
            let headerBuffer = ByteBuffer(string: "\(name): \(value)\r\n")
            totalBytes += name.utf8.count + value.utf8.count
            do {
                try channel.writeInbound(headerBuffer)
            } catch {
                threwError = true
                break
            }
        }

        #expect(threwError, "Expected default 2 MB header list size limit to reject request")
        #expect(totalBytes > 16384 * 128, "Test should have exceeded 2 MB before error")
        _ = try? channel.finish()
    }

    // MARK: - Max header field size tests

    @Test func requestExceedingMaxHeaderFieldSizeErrors() throws {
        var config = NIOHTTPDecoderLimitConfiguration()
        config.maxHeaderFieldSize = 128
        let decoder = HTTPRequestDecoder(limitConfiguration: config)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(decoder))

        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeString("GET / HTTP/1.1\r\n")
        let bigValue = String(repeating: "x", count: 200)
        buffer.writeString("X-Hdr: \(bigValue)\r\n\r\n")

        let error = #expect(throws: HTTPParserError.self) {
            try channel.writeInbound(buffer)
        }
        #expect(error == .headerOverflow)

        _ = try? channel.finish()
    }

    @Test func requestWithinMaxHeaderFieldSizeSucceeds() throws {
        var config = NIOHTTPDecoderLimitConfiguration()
        config.maxHeaderFieldSize = 256
        let decoder = HTTPRequestDecoder(limitConfiguration: config)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(decoder))

        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeString("GET / HTTP/1.1\r\n")
        let value = String(repeating: "x", count: 100)
        buffer.writeString("X-Hdr: \(value)\r\n\r\n")
        try channel.writeInbound(buffer)

        let head = try channel.readInbound(as: HTTPServerRequestPart.self)
        guard case .head = head else {
            Issue.record("Expected .head, got \(String(describing: head))")
            return
        }

        _ = try? channel.finish()
    }

    // MARK: - Custom configuration allows larger traffic

    @Test func customLargerLimitsAllowPreviouslyRejectedTraffic() throws {
        var config = NIOHTTPDecoderLimitConfiguration()
        config.maxHeaderFieldSize = 200 * 1024  // 200 KB per field
        config.maxHeaderListSize = 10 * 1024 * 1024  // 10 MB total
        config.maxHeaderFieldCount = 10_000
        let decoder = HTTPRequestDecoder(limitConfiguration: config)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(decoder))

        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeString("GET / HTTP/1.1\r\n")
        // Write a header value larger than the default 80KB limit
        let bigValue = String(repeating: "x", count: 100 * 1024)
        buffer.writeString("X-Big: \(bigValue)\r\n\r\n")
        try channel.writeInbound(buffer)

        let head = try channel.readInbound(as: HTTPServerRequestPart.self)
        guard case .head(let requestHead) = head else {
            Issue.record("Expected .head, got \(String(describing: head))")
            return
        }
        #expect(requestHead.headers["X-Big"].first?.count == 100 * 1024)

        _ = try? channel.finish()
    }

    // MARK: - Trailer field count tests

    @Test func trailersCountTowardFieldCountLimit() throws {
        var config = NIOHTTPDecoderLimitConfiguration()
        config.maxHeaderFieldCount = 5
        config.maxHeaderListSize = 1024 * 1024
        let decoder = HTTPRequestDecoder(limitConfiguration: config)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(decoder))

        var buffer = channel.allocator.buffer(capacity: 512)
        // 4 headers (within limit of 5)
        buffer.writeString("GET / HTTP/1.1\r\n")
        buffer.writeString("Host: example.com\r\n")
        buffer.writeString("Transfer-Encoding: chunked\r\n")
        buffer.writeString("X-A: a\r\n")
        buffer.writeString("X-B: b\r\n")
        buffer.writeString("\r\n")
        // chunked body
        buffer.writeString("5\r\nhello\r\n0\r\n")
        // 2 trailers (pushing total fields to 6, over limit of 5)
        buffer.writeString("X-Trailer-1: t1\r\n")
        buffer.writeString("X-Trailer-2: t2\r\n")
        buffer.writeString("\r\n")

        let error = #expect(throws: HTTPParserError.self) {
            try channel.writeInbound(buffer)
        }
        #expect(error == .headerOverflow)

        _ = try? channel.finish()
    }
}
