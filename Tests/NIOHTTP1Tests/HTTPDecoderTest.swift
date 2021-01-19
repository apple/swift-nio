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
import NIO
import NIOHTTP1
import NIOTestUtils

class HTTPDecoderTest: XCTestCase {
    private var channel: EmbeddedChannel!
    private var loop: EmbeddedEventLoop {
        return self.channel.embeddedEventLoop
    }

    override func setUp() {
        self.channel = EmbeddedChannel()
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.channel?.finish(acceptAlreadyClosed: true))
        self.channel = nil
    }

    func testDoesNotDecodeRealHTTP09Request() throws {
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder())).wait())
        
        // This is an invalid HTTP/0.9 simple request (too many CRLFs), but we need to
        // trigger https://github.com/nodejs/http-parser/issues/386 or http_parser won't
        // actually parse this at all.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("GET /a-file\r\n\r\n")
        
        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssertEqual(.invalidVersion, error as? HTTPParserError)
        }
        
        self.loop.run()
    }

    func testDoesNotDecodeFakeHTTP09Request() throws {
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder())).wait())

        // This is a HTTP/1.1-formatted request that claims to be HTTP/0.9.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("GET / HTTP/0.9\r\nHost: whatever\r\n\r\n")

        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssertEqual(.invalidVersion, error as? HTTPParserError)
        }

        self.loop.run()
    }

    func testDoesNotDecodeHTTP2XRequest() throws {
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder())).wait())

        // This is a hypothetical HTTP/2.0 protocol request, assuming it is
        // byte for byte identical (which such a protocol would never be).
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("GET / HTTP/2.0\r\nHost: whatever\r\n\r\n")

        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssertEqual(.invalidVersion, error as? HTTPParserError)
        }

        self.loop.run()
    }

    func testToleratesHTTP13Request() throws {
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder())).wait())

        // We tolerate higher versions of HTTP/1 than we know about because RFC 7230
        // says that these should be treated like HTTP/1.1 by our users.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("GET / HTTP/1.3\r\nHost: whatever\r\n\r\n")

        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(try channel.finish())
    }

    func testDoesNotDecodeRealHTTP09Response() throws {
        XCTAssertNoThrow(try channel.pipeline.addHandler(HTTPRequestEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPResponseDecoder())).wait())

        // We need to prime the decoder by seeing a GET request.
        try channel.writeOutbound(HTTPClientRequestPart.head(HTTPRequestHead(version: .http0_9, method: .GET, uri: "/")))

        // The HTTP parser has no special logic for HTTP/0.9 simple responses, but we'll send
        // one anyway just to prove it explodes.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("This is file data\n")

        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssertEqual(.invalidConstant, error as? HTTPParserError)
        }

        self.loop.run()
    }

    func testDoesNotDecodeFakeHTTP09Response() throws {
        XCTAssertNoThrow(try channel.pipeline.addHandler(HTTPRequestEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPResponseDecoder())).wait())

        // We need to prime the decoder by seeing a GET request.
        try channel.writeOutbound(HTTPClientRequestPart.head(HTTPRequestHead(version: .http0_9, method: .GET, uri: "/")))

        // The HTTP parser rejects HTTP/1.1-formatted responses claiming 0.9 as a version.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("HTTP/0.9 200 OK\r\nServer: whatever\r\n\r\n")

        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssertEqual(.invalidVersion, error as? HTTPParserError)
        }

        self.loop.run()
    }

    func testDoesNotDecodeHTTP2XResponse() throws {
        XCTAssertNoThrow(try channel.pipeline.addHandler(HTTPRequestEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPResponseDecoder())).wait())

        // We need to prime the decoder by seeing a GET request.
        try channel.writeOutbound(HTTPClientRequestPart.head(HTTPRequestHead(version: .http2, method: .GET, uri: "/")))

        // This is a hypothetical HTTP/2.0 protocol response, assuming it is
        // byte for byte identical (which such a protocol would never be).
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("HTTP/2.0 200 OK\r\nServer: whatever\r\n\r\n")

        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssertEqual(.invalidVersion, error as? HTTPParserError)
        }

        self.loop.run()
    }

    func testToleratesHTTP13Response() throws {
        XCTAssertNoThrow(try channel.pipeline.addHandler(HTTPRequestEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPResponseDecoder())).wait())

        // We need to prime the decoder by seeing a GET request.
        try channel.writeOutbound(HTTPClientRequestPart.head(HTTPRequestHead(version: .http2, method: .GET, uri: "/")))

        // We tolerate higher versions of HTTP/1 than we know about because RFC 7230
        // says that these should be treated like HTTP/1.1 by our users.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("HTTP/1.3 200 OK\r\nServer: whatever\r\n\r\n")

        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(try channel.finish())
    }

    func testCorrectlyMaintainIndicesWhenDiscardReadBytes() throws {
        class Receiver: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let part = self.unwrapInboundIn(data)
                switch part {
                case .head(let h):
                    XCTAssertEqual("/SomeURL", h.uri)
                    for h in h.headers {
                        XCTAssertEqual("X-Header", h.name)
                        XCTAssertEqual("value", h.value)
                    }
                default:
                    break
                }
            }
        }

        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder())).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(Receiver()).wait())

        // This is a hypothetical HTTP/2.0 protocol response, assuming it is
        // byte for byte identical (which such a protocol would never be).
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.writeStaticString("GET /SomeURL HTTP/1.1\r\n")
        XCTAssertNoThrow(try channel.writeInbound(buffer))

        var written = 0
        repeat {
            var buffer2 = channel.allocator.buffer(capacity: 16)

            written += buffer2.writeStaticString("X-Header: value\r\n")
            try channel.writeInbound(buffer2)
        } while written < 8192 // Use a value that w

        var buffer3 = channel.allocator.buffer(capacity: 2)
        buffer3.writeStaticString("\r\n")

        XCTAssertNoThrow(try channel.writeInbound(buffer3))
        XCTAssertNoThrow(try channel.finish())
    }

    func testDropExtraBytes() throws {
        class Receiver: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let part = self.unwrapInboundIn(data)
                switch part {
                case .end:
                    // ignore
                    _ = context.pipeline.removeHandler(name: "decoder")
                default:
                    break
                }
            }
        }
        XCTAssertNoThrow(try
        channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder()),
                                    name: "decoder").wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(Receiver()).wait())

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\nXXXX")

        XCTAssertNoThrow(try channel.writeInbound(buffer))
        (channel.eventLoop as! EmbeddedEventLoop).run() // allow the event loop to run (removal is not synchronous here)
        XCTAssertNoThrow(try channel.pipeline.assertDoesNotContain(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self))
        XCTAssertNoThrow(try channel.finish())
    }

    func testDontDropExtraBytesRequest() throws {
        class ByteCollector: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            var called: Bool = false

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buffer = self.unwrapInboundIn(data)
                XCTAssertEqual("XXXX", buffer.readString(length: buffer.readableBytes)!)
                self.called = true
            }

            func handlerAdded(context: ChannelHandlerContext) {
                context.pipeline.removeHandler(name: "decoder").whenComplete { result in
                    _ = result.mapError { (error: Error) -> Error in
                        XCTFail("unexpected error \(error)")
                        return error
                    }
                }
            }

            func handlerRemoved(context: ChannelHandlerContext) {
                XCTAssertTrue(self.called)
            }
        }

        class Receiver: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = HTTPServerRequestPart
            let collector = ByteCollector()

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let part = self.unwrapInboundIn(data)
                switch part {
                case .end:
                    _ = context.pipeline.removeHandler(self).flatMap { _ in
                        context.pipeline.addHandler(self.collector)
                    }
                default:
                    // ignore
                    break
                }
            }
        }
        XCTAssertNoThrow(try
        channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                                    name: "decoder").wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(Receiver()).wait())

        // This connect call is semantically wrong, but it's how you active embedded channels properly right now.
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 8888)).wait())

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\nXXXX")

        XCTAssertNoThrow(try channel.writeInbound(buffer))
        (channel.eventLoop as! EmbeddedEventLoop).run() // allow the event loop to run (removal is not synchrnous here)
        XCTAssertNoThrow(try channel.pipeline.assertDoesNotContain(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self))
        XCTAssertNoThrow(try channel.finish())
    }
    
    func testDontDropExtraBytesResponse() throws {
        class ByteCollector: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            var called: Bool = false
            
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buffer = self.unwrapInboundIn(data)
                XCTAssertEqual("XXXX", buffer.readString(length: buffer.readableBytes)!)
                self.called = true
            }
            
            func handlerAdded(context: ChannelHandlerContext) {
                _ = context.pipeline.removeHandler(name: "decoder")
            }
            
            func handlerRemoved(context: ChannelHandlerContext) {
                XCTAssert(self.called)
            }
        }
        
        class Receiver: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = HTTPClientResponsePart
            typealias InboundOut = HTTPClientResponsePart
            typealias OutboundOut = HTTPClientRequestPart
            
            func channelActive(context: ChannelHandlerContext) {
                var upgradeReq = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
                upgradeReq.headers.add(name: "Connection", value: "Upgrade")
                upgradeReq.headers.add(name: "Upgrade", value: "myprot")
                upgradeReq.headers.add(name: "Host", value: "localhost")
                context.write(wrapOutboundOut(.head(upgradeReq)), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
            
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let part = self.unwrapInboundIn(data)
                switch part {
                case .end:
                    _ = context.pipeline.removeHandler(self).flatMap { _ in
                        context.pipeline.addHandler(ByteCollector())
                    }
                    break
                default:
                    // ignore
                    break
                }
            }
        }
        
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)),
                                                         name: "decoder").wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(Receiver()).wait())
        
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 8888)).wait())
        
        var buffer = channel.allocator.buffer(capacity: 32)
        buffer.writeStaticString("HTTP/1.1 101 Switching Protocols\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\nXXXX")
        
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        (channel.eventLoop as! EmbeddedEventLoop).run() // allow the event loop to run (removal is not synchrnous here)
        XCTAssertNoThrow(try channel.pipeline.assertDoesNotContain(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self))
        XCTAssertNoThrow(try channel.finish())
    }

    func testExtraCRLF() throws {
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder())).wait())

        // This is a simple HTTP/1.1 request with a few too many CRLFs before it, to trigger
        // https://github.com/nodejs/http-parser/pull/432.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("\r\nGET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
        try channel.writeInbound(buffer)

        let message: HTTPServerRequestPart? = try self.channel.readInbound()
        guard case .some(.head(let head)) = message else {
            XCTFail("Invalid message: \(String(describing: message))")
            return
        }

        XCTAssertEqual(head.method, .GET)
        XCTAssertEqual(head.uri, "/")
        XCTAssertEqual(head.version, .http1_1)
        XCTAssertEqual(head.headers, HTTPHeaders([("Host", "example.com")]))

        let secondMessage: HTTPServerRequestPart? = try self.channel.readInbound()
        guard case .some(.end(.none)) = secondMessage else {
            XCTFail("Invalid second message: \(String(describing: secondMessage))")
            return
        }

        XCTAssertNoThrow(try channel.finish())
    }

    func testSOURCEDoesntExplodeUs() throws {
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder())).wait())

        // This is a simple HTTP/1.1 request with the SOURCE verb which is newly added to
        // http_parser.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("SOURCE / HTTP/1.1\r\nHost: example.com\r\n\r\n")
        try channel.writeInbound(buffer)

        let message: HTTPServerRequestPart? = try self.channel.readInbound()
        guard case .some(.head(let head)) = message else {
            XCTFail("Invalid message: \(String(describing: message))")
            return
        }

        XCTAssertEqual(head.method, .RAW(value: "SOURCE"))
        XCTAssertEqual(head.uri, "/")
        XCTAssertEqual(head.version, .http1_1)
        XCTAssertEqual(head.headers, HTTPHeaders([("Host", "example.com")]))

        let secondMessage: HTTPServerRequestPart? = try self.channel.readInbound()
        guard case .some(.end(.none)) = secondMessage else {
            XCTFail("Invalid second message: \(String(describing: secondMessage))")
            return
        }

        XCTAssertNoThrow(try channel.finish())
    }

    func testExtraCarriageReturnBetweenSubsequentRequests() throws {
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder())).wait())

        // This is a simple HTTP/1.1 request with an extra \r between first and second message, designed to hit the code
        // changed in https://github.com/nodejs/http-parser/pull/432 .
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
        buffer.writeStaticString("\r") // this is extra
        buffer.writeStaticString("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
        try channel.writeInbound(buffer)

        let message: HTTPServerRequestPart? = try self.channel.readInbound()
        guard case .some(.head(let head)) = message else {
            XCTFail("Invalid message: \(String(describing: message))")
            return
        }

        XCTAssertEqual(head.method, .GET)
        XCTAssertEqual(head.uri, "/")
        XCTAssertEqual(head.version, .http1_1)
        XCTAssertEqual(head.headers, HTTPHeaders([("Host", "example.com")]))

        let secondMessage: HTTPServerRequestPart? = try self.channel.readInbound()
        guard case .some(.end(.none)) = secondMessage else {
            XCTFail("Invalid second message: \(String(describing: secondMessage))")
            return
        }

        XCTAssertNoThrow(try channel.finish())
    }

    func testIllegalHeaderNamesCauseError() {
        func writeToFreshRequestDecoderChannel(_ string: String) throws {
            let channel = EmbeddedChannel(handler: ByteToMessageHandler(HTTPRequestDecoder()))
            defer {
                XCTAssertNoThrow(try channel.finish())
            }
            var buffer = channel.allocator.buffer(capacity: 256)
            buffer.writeString(string)
            try channel.writeInbound(buffer)
        }

        // non-ASCII character in header name
        XCTAssertThrowsError(try writeToFreshRequestDecoderChannel("GET / HTTP/1.1\r\nföo: bar\r\n\r\n")) { error in
            XCTAssertEqual(HTTPParserError.invalidHeaderToken, error as? HTTPParserError)
        }

        // empty header name
        XCTAssertThrowsError(try writeToFreshRequestDecoderChannel("GET / HTTP/1.1\r\n: bar\r\n\r\n")) { error in
            XCTAssertEqual(HTTPParserError.invalidHeaderToken, error as? HTTPParserError)
        }

        // just a space as header name
        XCTAssertThrowsError(try writeToFreshRequestDecoderChannel("GET / HTTP/1.1\r\n : bar\r\n\r\n")) { error in
            XCTAssertEqual(HTTPParserError.invalidHeaderToken, error as? HTTPParserError)
        }
    }

    func testNonASCIIWorksAsHeaderValue() {
        func writeToFreshRequestDecoderChannel(_ string: String) throws -> HTTPServerRequestPart? {
            let channel = EmbeddedChannel(handler: ByteToMessageHandler(HTTPRequestDecoder()))
            defer {
                XCTAssertNoThrow(try channel.finish())
            }
            var buffer = channel.allocator.buffer(capacity: 256)
            buffer.writeString(string)
            try channel.writeInbound(buffer)
            return try channel.readInbound(as: HTTPServerRequestPart.self)
        }

        var expectedHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        expectedHead.headers.add(name: "foo", value: "bär")
        XCTAssertNoThrow(XCTAssertEqual(.head(expectedHead),
                                        try writeToFreshRequestDecoderChannel("GET / HTTP/1.1\r\nfoo: bär\r\n\r\n")))
    }

    func testDoesNotDeliverLeftoversUnnecessarily() {
        // This test isolates a nasty problem where the http parser offset would never be reset to zero. This would cause us to gradually leak
        // very small amounts of memory on each connection, or sometimes crash.
        let data: StaticString = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"

        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }
        var dataBuffer = channel.allocator.buffer(capacity: 128)
        dataBuffer.writeStaticString(data)

        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .fireError))).wait())
        XCTAssertNoThrow(try channel.writeInbound(dataBuffer.getSlice(at: 0, length: dataBuffer.readableBytes - 6)!))
        XCTAssertNoThrow(try channel.writeInbound(dataBuffer.getSlice(at: dataBuffer.readableBytes - 6, length: 6)!))

        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.fireChannelInactive()
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
    }

    func testHTTPResponseWithoutHeaders() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }
        var buffer = channel.allocator.buffer(capacity: 128)
        buffer.writeStaticString("HTTP/1.0 200 ok\r\n\r\n")

        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .fireError))).wait())
        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(.init(version: .http1_1,
                                                                                    method: .GET, uri: "/"))))
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(XCTAssertEqual(HTTPClientResponsePart.head(.init(version: .http1_0,
                                                                          status: .ok)), try channel.readInbound()))
    }

    func testBasicVerifications() {
        let byteBufferContainingJustAnX = ByteBuffer(string: "X")
        let expectedInOuts: [(String, [HTTPServerRequestPart])] = [
            ("GET / HTTP/1.1\r\n\r\n",
             [.head(.init(version: .http1_1, method: .GET, uri: "/")),
              .end(nil)]),
            ("POST /foo HTTP/1.1\r\n\r\n",
             [.head(.init(version: .http1_1, method: .POST, uri: "/foo")),
              .end(nil)]),
            ("POST / HTTP/1.1\r\ncontent-length: 1\r\n\r\nX",
             [.head(.init(version: .http1_1,
                          method: .POST,
                          uri: "/",
                          headers: .init([("content-length", "1")]))),
              .body(byteBufferContainingJustAnX),
              .end(nil)]),
            ("POST / HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n1\r\nX\r\n0\r\n\r\n",
             [.head(.init(version: .http1_1,
                          method: .POST,
                          uri: "/",
                          headers: .init([("transfer-encoding", "chunked")]))),
              .body(byteBufferContainingJustAnX),
              .end(nil)]),
            ("POST / HTTP/1.1\r\ntransfer-encoding: chunked\r\none: two\r\n\r\n1\r\nX\r\n0\r\nfoo: bar\r\n\r\n",
             [.head(.init(version: .http1_1,
                          method: .POST,
                          uri: "/",
                          headers: .init([("transfer-encoding", "chunked"), ("one", "two")]))),
              .body(byteBufferContainingJustAnX),
              .end(.init([("foo", "bar")]))]),
        ]

        let expectedInOutsBB: [(ByteBuffer, [HTTPServerRequestPart])] = expectedInOuts.map { io in
            return (ByteBuffer(string: io.0), io.1)
        }
        XCTAssertNoThrow(try ByteToMessageDecoderVerifier.verifyDecoder(inputOutputPairs: expectedInOutsBB,
                                                                        decoderFactory: { HTTPRequestDecoder() }))
    }

    func testNothingHappensOnEOFForLeftOversInAllLeftOversModes() throws {
        class Receiver: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart

            private var numberOfErrors = 0

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                XCTFail("unexpected error: \(error)")
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let part = self.unwrapInboundIn(data)
                switch part {
                case .head(let head):
                    XCTAssertEqual(.OPTIONS, head.method)
                case .body:
                    XCTFail("unexpected .body part")
                case .end:
                    ()
                }
            }
        }

        for leftOverBytesStrategy in [RemoveAfterUpgradeStrategy.dropBytes, .fireError, .forwardBytes] {
            let channel = EmbeddedChannel()
            var buffer = channel.allocator.buffer(capacity: 64)
            buffer.writeStaticString("OPTIONS * HTTP/1.1\r\nHost: L\r\nUpgrade: P\r\nConnection: upgrade\r\n\r\nXXXX")

            let decoder = HTTPRequestDecoder(leftOverBytesStrategy: leftOverBytesStrategy)
            XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(decoder)).wait())
            XCTAssertNoThrow(try channel.pipeline.addHandler(Receiver()).wait())
            XCTAssertNoThrow(try channel.writeInbound(buffer))
            XCTAssertNoThrow(XCTAssert(try channel.finish().isClean))
        }
    }

    func testBytesCanBeForwardedWhenHandlerRemoved() throws {
        class Receiver: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = HTTPServerRequestPart

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let part = self.unwrapInboundIn(data)
                switch part {
                case .head(let head):
                    XCTAssertEqual(.OPTIONS, head.method)
                case .body:
                    XCTFail("unexpected .body part")
                case .end:
                    ()
                }
            }
        }

        let channel = EmbeddedChannel()
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("OPTIONS * HTTP/1.1\r\nHost: L\r\nUpgrade: P\r\nConnection: upgrade\r\n\r\nXXXX")

        let receiver = Receiver()
        let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
        XCTAssertNoThrow(try channel.pipeline.addHandler(decoder).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(receiver).wait())
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        let removalFutures = [ channel.pipeline.removeHandler(receiver), channel.pipeline.removeHandler(decoder) ]
        channel.embeddedEventLoop.run()
        try removalFutures.forEach {
            XCTAssertNoThrow(try $0.wait())
        }
        XCTAssertNoThrow(XCTAssertEqual("XXXX", try channel.readInbound(as: ByteBuffer.self).map {
            String(decoding: $0.readableBytesView, as: Unicode.UTF8.self)
        }))
        XCTAssertNoThrow(XCTAssert(try channel.finish().isClean))
    }

    func testBytesCanBeFiredAsErrorWhenHandlerRemoved() throws {
        class Receiver: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = HTTPServerRequestPart

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let part = self.unwrapInboundIn(data)
                switch part {
                case .head(let head):
                    XCTAssertEqual(.OPTIONS, head.method)
                case .body:
                    XCTFail("unexpected .body part")
                case .end:
                    ()
                }
            }
        }

        let channel = EmbeddedChannel()
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("OPTIONS * HTTP/1.1\r\nHost: L\r\nUpgrade: P\r\nConnection: upgrade\r\n\r\nXXXX")

        let receiver = Receiver()
        let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .fireError))
        XCTAssertNoThrow(try channel.pipeline.addHandler(decoder).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(receiver).wait())
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        let removalFutures = [ channel.pipeline.removeHandler(receiver), channel.pipeline.removeHandler(decoder) ]
        channel.embeddedEventLoop.run()
        try removalFutures.forEach {
            XCTAssertNoThrow(try $0.wait())
        }
        XCTAssertThrowsError(try channel.throwIfErrorCaught()) { error in
            switch error as? ByteToMessageDecoderError {
            case .some(ByteToMessageDecoderError.leftoverDataWhenDone(let buffer)):
                XCTAssertEqual("XXXX", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
            case .some(let error):
                XCTFail("unexpected error: \(error)")
            case .none:
                XCTFail("unexpected error")
            }
        }
        XCTAssertNoThrow(XCTAssert(try channel.finish().isClean))
    }

    func testBytesCanBeDroppedWhenHandlerRemoved() throws {
        class Receiver: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = HTTPServerRequestPart

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let part = self.unwrapInboundIn(data)
                switch part {
                case .head(let head):
                    XCTAssertEqual(.OPTIONS, head.method)
                case .body:
                    XCTFail("unexpected .body part")
                case .end:
                    ()
                }
            }
        }

        let channel = EmbeddedChannel()
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("OPTIONS * HTTP/1.1\r\nHost: L\r\nUpgrade: P\r\nConnection: upgrade\r\n\r\nXXXX")

        let receiver = Receiver()
        let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes))
        XCTAssertNoThrow(try channel.pipeline.addHandler(decoder).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(receiver).wait())
        XCTAssertNoThrow(try channel.writeInbound(buffer))
        let removalFutures = [ channel.pipeline.removeHandler(receiver), channel.pipeline.removeHandler(decoder) ]
        channel.embeddedEventLoop.run()
        try removalFutures.forEach {
            XCTAssertNoThrow(try $0.wait())
        }
        XCTAssertNoThrow(XCTAssert(try channel.finish().isClean))
    }

    func testAppropriateErrorWhenReceivingUnsolicitedResponse() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("HTTP/1.1 200 OK\r\nServer: a-bad-server/1.0.0\r\n\r\n")

        let decoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes))
        XCTAssertNoThrow(try channel.pipeline.addHandler(decoder).wait())

        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssertEqual(error as? NIOHTTPDecoderError, .unsolicitedResponse)
        }
    }

    func testAppropriateErrorWhenReceivingUnsolicitedResponseDoesNotRecover() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("HTTP/1.1 200 OK\r\nServer: a-bad-server/1.0.0\r\n\r\n")

        let decoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes))
        XCTAssertNoThrow(try channel.pipeline.addHandler(decoder).wait())

        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssertEqual(error as? NIOHTTPDecoderError, .unsolicitedResponse)
        }

        // Write a request.
        let request = HTTPClientRequestPart.head(.init(version: .http1_1, method: .GET, uri: "/"))
        XCTAssertNoThrow(try channel.writeOutbound(request))

        // The server sending another response should lead to another error.
        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            guard case .some(.dataReceivedInErrorState(let baseError, _)) = error as? ByteToMessageDecoderError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }

            XCTAssertEqual(baseError as? NIOHTTPDecoderError, .unsolicitedResponse)
        }
    }

    func testOneRequestTwoResponses() {
        let eventCounter = EventCounterHandler()
        let responseDecoder = ByteToMessageHandler(HTTPResponseDecoder())
        let channel = EmbeddedChannel(handler: responseDecoder)
        XCTAssertNoThrow(try channel.pipeline.addHandler(eventCounter).wait())

        XCTAssertNoThrow(try channel.writeOutbound(HTTPClientRequestPart.head(.init(version: .http1_1,
                                                                                    method: .GET, uri: "/"))))
        var buffer = channel.allocator.buffer(capacity: 128)
        buffer.writeString("HTTP/1.1 200 ok\r\ncontent-length: 0\r\n\r\nHTTP/1.1 200 ok\r\ncontent-length: 0\r\n\r\n")
        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssertEqual(.unsolicitedResponse, error as? NIOHTTPDecoderError)
        }
        XCTAssertNoThrow(XCTAssertEqual(.head(.init(version: .http1_1,
                                                    status: .ok,
                                                    headers: ["content-length": "0"])),
                                        try channel.readInbound(as: HTTPClientResponsePart.self)))
        XCTAssertNoThrow(XCTAssertEqual(.end(nil),
                                        try channel.readInbound(as: HTTPClientResponsePart.self)))
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound(as: HTTPClientResponsePart.self)))
        XCTAssertNoThrow(XCTAssertNotNil(try channel.readOutbound()))
        XCTAssertEqual(1, eventCounter.writeCalls)
        XCTAssertEqual(1, eventCounter.flushCalls)
        XCTAssertEqual(2, eventCounter.channelReadCalls) // .head & .end
        XCTAssertEqual(1, eventCounter.channelReadCompleteCalls)
        XCTAssertEqual(["channelReadComplete", "write", "flush", "channelRead", "errorCaught"], eventCounter.allTriggeredEvents())
        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
    }

    func testRefusesRequestSmugglingAttempt() throws {
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder())).wait())

        // This is a request smuggling attempt caused by duplicating the Transfer-Encoding and Content-Length headers.
        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeString("POST /foo HTTP/1.1\r\n" +
                           "Host: localhost\r\n" +
                           "Content-length: 1\r\n" +
                           "Transfer-Encoding: gzip, chunked\r\n\r\n" +
                           "3\r\na=1\r\n0\r\n\r\n")

        XCTAssertThrowsError(try channel.writeInbound(buffer)) { error in
            XCTAssertEqual(.unexpectedContentLength, error as? HTTPParserError)
        }

        self.loop.run()
    }

    func testTrimsTrailingOWS() throws {
        XCTAssertNoThrow(try channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder())).wait())

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeStaticString("GET / HTTP/1.1\r\nHost: localhost\r\nFoo: bar \r\nBaz: Boz\r\n\r\n")

        XCTAssertNoThrow(try channel.writeInbound(buffer))
        let request = try assertNoThrowWithValue(channel.readInbound(as: HTTPServerRequestPart.self))
        guard case .some(.head(let head)) = request else {
            XCTFail("Unexpected first message: \(String(describing: request))")
            return
        }
        XCTAssertEqual(head.headers[canonicalForm: "Foo"], ["bar"])
        guard case .some(.end) = try assertNoThrowWithValue(channel.readInbound(as: HTTPServerRequestPart.self)) else {
            XCTFail("Unexpected last message")
            return
        }
    }

    func testMassiveChunkDoesNotBufferAndGivesUsHoweverMuchIsAvailable() {
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder())).wait())

        var buffer = self.channel.allocator.buffer(capacity: 64)
        buffer.writeString("POST / HTTP/1.1\r\nHost: localhost\r\ntransfer-encoding: chunked\r\n\r\n" +
                           "FFFFFFFFFFFFF\r\nfoo")

        XCTAssertNoThrow(try self.channel.writeInbound(buffer))

        var maybeHead: HTTPServerRequestPart?
        var maybeBodyChunk: HTTPServerRequestPart?

        XCTAssertNoThrow(maybeHead = try self.channel.readInbound())
        XCTAssertNoThrow(maybeBodyChunk = try self.channel.readInbound())
        XCTAssertNoThrow(XCTAssertNil(try self.channel.readInbound(as: HTTPServerRequestPart.self)))

        guard case .some(.head(let head)) = maybeHead, case .some(.body(let body)) = maybeBodyChunk else {
            XCTFail("didn't receive head & body")
            return
        }

        XCTAssertEqual(.POST, head.method)
        XCTAssertEqual("foo", String(decoding: body.readableBytesView, as: Unicode.UTF8.self))

        XCTAssertThrowsError(try self.channel.finish()) { error in
            XCTAssertEqual(.invalidEOFState, error as? HTTPParserError)
        }
    }
}
