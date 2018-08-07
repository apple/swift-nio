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
import Dispatch
import NIO
import NIOHTTP1

class HTTPDecoderTest: XCTestCase {
    private var channel: EmbeddedChannel!
    private var loop: EmbeddedEventLoop!

    override func setUp() {
        self.channel = EmbeddedChannel()
        self.loop = (channel.eventLoop as! EmbeddedEventLoop)
    }

    override func tearDown() {
        self.channel = nil
        self.loop = nil
    }

    func testDoesNotDecodeRealHTTP09Request() throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestDecoder()).wait())

        // This is an invalid HTTP/0.9 simple request (too many CRLFs), but we need to
        // trigger https://github.com/nodejs/http-parser/issues/386 or http_parser won't
        // actually parse this at all.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.write(staticString: "GET /a-file\r\n\r\n")

        do {
            try channel.writeInbound(buffer)
            XCTFail("Did not error")
        } catch HTTPParserError.invalidVersion {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

       loop.run()
    }

    func testDoesNotDecodeFakeHTTP09Request() throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestDecoder()).wait())

        // This is a HTTP/1.1-formatted request that claims to be HTTP/0.9.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.write(staticString: "GET / HTTP/0.9\r\nHost: whatever\r\n\r\n")

        do {
            try channel.writeInbound(buffer)
            XCTFail("Did not error")
        } catch HTTPParserError.invalidVersion {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        loop.run()
    }

    func testDoesNotDecodeHTTP2XRequest() throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestDecoder()).wait())

        // This is a hypothetical HTTP/2.0 protocol request, assuming it is
        // byte for byte identical (which such a protocol would never be).
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.write(staticString: "GET / HTTP/2.0\r\nHost: whatever\r\n\r\n")

        do {
            try channel.writeInbound(buffer)
            XCTFail("Did not error")
        } catch HTTPParserError.invalidVersion {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        loop.run()
    }

    func testToleratesHTTP13Request() throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestDecoder()).wait())

        // We tolerate higher versions of HTTP/1 than we know about because RFC 7230
        // says that these should be treated like HTTP/1.1 by our users.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.write(staticString: "GET / HTTP/1.3\r\nHost: whatever\r\n\r\n")

        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(try channel.finish())
    }

    func testDoesNotDecodeRealHTTP09Response() throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPResponseDecoder()).wait())

        // We need to prime the decoder by seeing a GET request.
        try channel.writeOutbound(HTTPClientRequestPart.head(HTTPRequestHead(version: .init(major: 0, minor: 9), method: .GET, uri: "/")))

        // The HTTP parser has no special logic for HTTP/0.9 simple responses, but we'll send
        // one anyway just to prove it explodes.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.write(staticString: "This is file data\n")

        do {
            try channel.writeInbound(buffer)
            XCTFail("Did not error")
        } catch HTTPParserError.invalidConstant {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        loop.run()
    }

    func testDoesNotDecodeFakeHTTP09Response() throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPResponseDecoder()).wait())

        // We need to prime the decoder by seeing a GET request.
        try channel.writeOutbound(HTTPClientRequestPart.head(HTTPRequestHead(version: .init(major: 0, minor: 9), method: .GET, uri: "/")))

        // The HTTP parser rejects HTTP/1.1-formatted responses claiming 0.9 as a version.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.write(staticString: "HTTP/0.9 200 OK\r\nServer: whatever\r\n\r\n")

        do {
            try channel.writeInbound(buffer)
            XCTFail("Did not error")
        } catch HTTPParserError.invalidVersion {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        loop.run()
    }

    func testDoesNotDecodeHTTP2XResponse() throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPResponseDecoder()).wait())

        // We need to prime the decoder by seeing a GET request.
        try channel.writeOutbound(HTTPClientRequestPart.head(HTTPRequestHead(version: .init(major: 2, minor: 0), method: .GET, uri: "/")))

        // This is a hypothetical HTTP/2.0 protocol response, assuming it is
        // byte for byte identical (which such a protocol would never be).
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.write(staticString: "HTTP/2.0 200 OK\r\nServer: whatever\r\n\r\n")

        do {
            try channel.writeInbound(buffer)
            XCTFail("Did not error")
        } catch HTTPParserError.invalidVersion {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        loop.run()
    }

    func testToleratesHTTP13Response() throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPResponseDecoder()).wait())

        // We need to prime the decoder by seeing a GET request.
        try channel.writeOutbound(HTTPClientRequestPart.head(HTTPRequestHead(version: .init(major: 2, minor: 0), method: .GET, uri: "/")))

        // We tolerate higher versions of HTTP/1 than we know about because RFC 7230
        // says that these should be treated like HTTP/1.1 by our users.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.write(staticString: "HTTP/1.3 200 OK\r\nServer: whatever\r\n\r\n")

        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(try channel.finish())
    }

    func testCorrectlyMaintainIndicesWhenDiscardReadBytes() throws {
        class Receiver: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
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

        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestDecoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: Receiver()).wait())

        // This is a hypothetical HTTP/2.0 protocol response, assuming it is
        // byte for byte identical (which such a protocol would never be).
        var buffer = channel.allocator.buffer(capacity: 16)
        buffer.write(staticString: "GET /SomeURL HTTP/1.1\r\n")
        XCTAssertNoThrow(try channel.writeInbound(buffer))

        var written = 0
        repeat {
            var buffer2 = channel.allocator.buffer(capacity: 16)

            written += buffer2.write(staticString: "X-Header: value\r\n")
            try channel.writeInbound(buffer2)
        } while written < 8192 // Use a value that w

        var buffer3 = channel.allocator.buffer(capacity: 2)
        buffer3.write(staticString: "\r\n")

        XCTAssertNoThrow(try channel.writeInbound(buffer3))
        XCTAssertNoThrow(try channel.finish())
    }

    func testDropExtraBytes() throws {
        class Receiver: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                let part = self.unwrapInboundIn(data)
                switch part {
                case .end:
                    // ignore
                    _ = ctx.pipeline.remove(name: "decoder")
                default:
                    break
                }
            }
        }
        XCTAssertNoThrow(try channel.pipeline.add(name: "decoder", handler: HTTPRequestDecoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: Receiver()).wait())

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.write(staticString: "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\nXXXX")

        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(try channel.pipeline.assertDoesNotContain(handlerType: HTTPRequestDecoder.self))
        XCTAssertNoThrow(try channel.finish())
    }

    func testDontDropExtraBytes() throws {
        class ByteCollector: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            var called: Bool = false

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                var buffer = self.unwrapInboundIn(data)
                XCTAssertEqual("XXXX", buffer.readString(length: buffer.readableBytes)!)
                self.called = true
            }

            func handlerAdded(ctx: ChannelHandlerContext) {
                _ = ctx.pipeline.remove(name: "decoder")
            }
        }

        class Receiver: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            let collector = ByteCollector()

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                let part = self.unwrapInboundIn(data)
                switch part {
                case .end:
                    _ = ctx.pipeline.remove(handler: self).then { _ in
                        ctx.pipeline.add(handler: self.collector)
                    }
                default:
                    // ignore
                    break
                }
            }

            func channelInactive(ctx: ChannelHandlerContext) {
                XCTAssertTrue(collector.called)
            }
        }
        XCTAssertNoThrow(try channel.pipeline.add(name: "decoder", handler: HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: Receiver()).wait())

        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.write(staticString: "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\nXXXX")

        XCTAssertNoThrow(try channel.writeInbound(buffer))
        XCTAssertNoThrow(try channel.pipeline.assertDoesNotContain(handlerType: HTTPRequestDecoder.self))
        XCTAssertNoThrow(try channel.finish())
    }

    func testExtraCRLF() throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestDecoder()).wait())

        // This is a simple HTTP/1.1 request with a few too many CRLFs before it, to trigger
        // https://github.com/nodejs/http-parser/pull/432.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.write(staticString: "\r\nGET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
        try channel.writeInbound(buffer)

        let message: HTTPServerRequestPart? = self.channel.readInbound()
        guard case .some(.head(let head)) = message else {
            XCTFail("Invalid message: \(String(describing: message))")
            return
        }

        XCTAssertEqual(head.method, .GET)
        XCTAssertEqual(head.uri, "/")
        XCTAssertEqual(head.version, .init(major: 1, minor: 1))
        XCTAssertEqual(head.headers, HTTPHeaders([("Host", "example.com")]))

        let secondMessage: HTTPServerRequestPart? = self.channel.readInbound()
        guard case .some(.end(.none)) = secondMessage else {
            XCTFail("Invalid second message: \(String(describing: secondMessage))")
            return
        }

        XCTAssertNoThrow(try channel.finish())
    }

    func testSOURCEDoesntExplodeUs() throws {
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPRequestDecoder()).wait())

        // This is a simple HTTP/1.1 request with the SOURCE verb which is newly added to
        // http_parser.
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.write(staticString: "SOURCE / HTTP/1.1\r\nHost: example.com\r\n\r\n")
        try channel.writeInbound(buffer)

        let message: HTTPServerRequestPart? = self.channel.readInbound()
        guard case .some(.head(let head)) = message else {
            XCTFail("Invalid message: \(String(describing: message))")
            return
        }

        XCTAssertEqual(head.method, .RAW(value: "SOURCE"))
        XCTAssertEqual(head.uri, "/")
        XCTAssertEqual(head.version, .init(major: 1, minor: 1))
        XCTAssertEqual(head.headers, HTTPHeaders([("Host", "example.com")]))

        let secondMessage: HTTPServerRequestPart? = self.channel.readInbound()
        guard case .some(.end(.none)) = secondMessage else {
            XCTFail("Invalid second message: \(String(describing: secondMessage))")
            return
        }

        XCTAssertNoThrow(try channel.finish())
    }
}
