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
import NIOConcurrencyHelpers
import NIOFoundationCompat
import Dispatch
@testable import NIOHTTP1

extension Array where Array.Element == ByteBuffer {
    public func allAsBytes() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(self.reduce(0, { $0 + $1.readableBytes }))
        self.forEach { bb in
            bb.withUnsafeReadableBytes { ptr in
                out.append(contentsOf: ptr)
            }
        }
        return out
    }

    public func allAsString() -> String? {
        return String(decoding: self.allAsBytes(), as: UTF8.self)
    }
}

internal class ArrayAccumulationHandler<T>: ChannelInboundHandler {
    typealias InboundIn = T
    private var receiveds: [T] = []
    private var allDoneBlock: DispatchWorkItem! = nil

    public init(completion: @escaping ([T]) -> Void) {
        self.allDoneBlock = DispatchWorkItem { [unowned self] () -> Void in
            completion(self.receiveds)
        }
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        self.receiveds.append(self.unwrapInboundIn(data))
    }

    public func channelUnregistered(ctx: ChannelHandlerContext) {
        self.allDoneBlock.perform()
    }

    public func syncWaitForCompletion() {
        self.allDoneBlock.wait()
    }
}

class HTTPServerClientTest : XCTestCase {
    /* needs to be something reasonably large and odd so it has good odds producing incomplete writes even on the loopback interface */
    private static let massiveResponseLength = 5 * 1024 * 1024 + 7
    private static let massiveResponseBytes: [UInt8] = {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(HTTPServerClientTest.massiveResponseLength)
        for f in 0..<HTTPServerClientTest.massiveResponseLength {
            bytes.append(UInt8(f % 255))
        }
        return bytes
    }()

    enum SendMode {
        case byteBuffer
        case fileRegion
    }

    private class SimpleHTTPServer: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let mode: SendMode
        private let fileManager = FileManager.default
        private var files: [String] = Array()
        private var seenEnd: Bool = false
        private var sentEnd: Bool = false
        private var isOpen: Bool = true

        init(_ mode: SendMode) {
            self.mode = mode
        }

        private func outboundBody(_  buffer: ByteBuffer) -> (body: HTTPServerResponsePart, destructor: () -> Void) {
            switch mode {
            case .byteBuffer:
                return (.body(.byteBuffer(buffer)), { () in })
            case .fileRegion:
                let filePath: String
                #if os(Linux)
                    filePath = "/tmp/\(UUID().uuidString)"
                #else
                    if #available(OSX 10.12, *) {
                        filePath = "\(fileManager.temporaryDirectory.path)/\(UUID().uuidString)"
                    } else {
                        filePath = "/tmp/\(UUID().uuidString)"
                    }
                #endif
                files.append(filePath)

                let content = buffer.getData(at: 0, length: buffer.readableBytes)!
                XCTAssertNoThrow(try content.write(to: URL(fileURLWithPath: filePath)))
                let fh = try! FileHandle(path: filePath)
                let region = FileRegion(fileHandle: fh,
                                             readerIndex: 0,
                                             endIndex: buffer.readableBytes)
                return (.body(.fileRegion(region)), { try! fh.close() })
            }
        }

        public func handlerRemoved(ctx: ChannelHandlerContext) {
            for f in files {
                _ = try? fileManager.removeItem(atPath: f)
            }
        }

        public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
            switch self.unwrapInboundIn(data) {
            case .head(let req):
                switch req.uri {
                case "/helloworld":
                    let replyString = "Hello World!\r\n"
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Content-Length", value: "\(replyString.utf8.count)")
                    head.headers.add(name: "Connection", value: "close")
                    let r = HTTPServerResponsePart.head(head)
                    ctx.write(self.wrapOutboundOut(r), promise: nil)
                    var b = ctx.channel.allocator.buffer(capacity: replyString.count)
                    b.write(string: replyString)

                    let outbound = self.outboundBody(b)
                    ctx.write(self.wrapOutboundOut(outbound.body)).whenComplete {
                        outbound.destructor()
                    }
                    ctx.write(self.wrapOutboundOut(.end(nil))).mapIfError { error in
                        XCTFail("unexpected error \(error)")
                    }.whenComplete {
                        self.sentEnd = true
                        self.maybeClose(ctx: ctx)
                    }
                case "/count-to-ten":
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Connection", value: "close")
                    let r = HTTPServerResponsePart.head(head)
                    ctx.write(self.wrapOutboundOut(r)).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }
                    var b = ctx.channel.allocator.buffer(capacity: 1024)
                    for i in 1...10 {
                        b.clear()
                        b.write(string: "\(i)")

                        let outbound = self.outboundBody(b)
                        ctx.write(self.wrapOutboundOut(outbound.body)).mapIfError { error in
                            XCTFail("unexpected error \(error)")
                        }.whenComplete {
                            outbound.destructor()
                        }
                    }
                    ctx.write(self.wrapOutboundOut(.end(nil))).mapIfError { error in
                        XCTFail("unexpected error \(error)")
                    }.whenComplete {
                        self.sentEnd = true
                        self.maybeClose(ctx: ctx)
                    }
                case "/trailers":
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Connection", value: "close")
                    head.headers.add(name: "Transfer-Encoding", value: "chunked")
                    let r = HTTPServerResponsePart.head(head)
                    ctx.write(self.wrapOutboundOut(r)).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }
                    var b = ctx.channel.allocator.buffer(capacity: 1024)
                    for i in 1...10 {
                        b.clear()
                        b.write(string: "\(i)")

                        let outbound = self.outboundBody(b)
                        ctx.write(self.wrapOutboundOut(outbound.body)).mapIfError { error in
                            XCTFail("unexpected error \(error)")
                        }.whenComplete {
                            outbound.destructor()
                        }
                    }

                    var trailers = HTTPHeaders()
                    trailers.add(name: "X-URL-Path", value: "/trailers")
                    trailers.add(name: "X-Should-Trail", value: "sure")
                    ctx.write(self.wrapOutboundOut(.end(trailers))).mapIfError { error in
                        XCTFail("unexpected error \(error)")
                    }.whenComplete {
                        self.sentEnd = true
                        self.maybeClose(ctx: ctx)
                    }

                case "/massive-response":
                    var buf = ctx.channel.allocator.buffer(capacity: HTTPServerClientTest.massiveResponseLength)
                    buf.writeWithUnsafeMutableBytes { targetPtr in
                        return HTTPServerClientTest.massiveResponseBytes.withUnsafeBytes { srcPtr in
                            precondition(targetPtr.count >= srcPtr.count)
                            targetPtr.copyMemory(from: srcPtr)
                            return srcPtr.count
                        }
                    }
                    buf.write(bytes: HTTPServerClientTest.massiveResponseBytes)
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Connection", value: "close")
                    head.headers.add(name: "Content-Length", value: "\(HTTPServerClientTest.massiveResponseLength)")
                    let r = HTTPServerResponsePart.head(head)
                    ctx.write(self.wrapOutboundOut(r)).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }
                    let outbound = self.outboundBody(buf)
                    ctx.writeAndFlush(self.wrapOutboundOut(outbound.body)).mapIfError { error in
                        XCTFail("unexpected error \(error)")
                    }.whenComplete {
                        outbound.destructor()
                    }
                    ctx.write(self.wrapOutboundOut(.end(nil))).mapIfError { error in
                        XCTFail("unexpected error \(error)")
                    }.whenComplete {
                        self.sentEnd = true
                        self.maybeClose(ctx: ctx)
                    }
                case "/head":
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Connection", value: "close")
                    head.headers.add(name: "Content-Length", value: "5000")
                    ctx.write(self.wrapOutboundOut(.head(head))).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }
                    ctx.write(self.wrapOutboundOut(.end(nil))).mapIfError { error in
                        XCTFail("unexpected error \(error)")
                    }.whenComplete {
                        self.sentEnd = true
                        self.maybeClose(ctx: ctx)
                    }
                case "/204":
                    var head = HTTPResponseHead(version: req.version, status: .noContent)
                    head.headers.add(name: "Connection", value: "keep-alive")
                    ctx.write(self.wrapOutboundOut(.head(head))).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }
                    ctx.write(self.wrapOutboundOut(.end(nil))).mapIfError { error in
                        XCTFail("unexpected error \(error)")
                    }.whenComplete {
                        self.sentEnd = true
                        self.maybeClose(ctx: ctx)
                    }
                default:
                    XCTFail("received request to unknown URI \(req.uri)")
                }
            case .end(let trailers):
                XCTAssertNil(trailers)
                seenEnd = true
            default:
                XCTFail("wrong")
            }
        }

        public func channelReadComplete(ctx: ChannelHandlerContext) {
            ctx.flush()
        }

        // We should only close the connection when the remote peer has sent the entire request
        // and we have sent our entire response.
        private func maybeClose(ctx: ChannelHandlerContext) {
            if sentEnd && seenEnd && self.isOpen {
                self.isOpen = false
                ctx.close().whenFailure { error in
                    XCTFail("unexpected error \(error)")
                }
            }
        }
    }

    func testSimpleGetByteBuffer() throws {
        try testSimpleGet(.byteBuffer)
    }

    func testSimpleGetFileRegion() throws {
        try testSimpleGet(.fileRegion)
    }

    private class HTTPClientResponsePartAssertHandler: ArrayAccumulationHandler<HTTPClientResponsePart> {
        public init(_ expectedVersion: HTTPVersion, _ expectedStatus: HTTPResponseStatus, _ expectedHeaders: HTTPHeaders, _ expectedBody: String?, _ expectedTrailers: HTTPHeaders? = nil) {
            super.init { parts in
                guard parts.count >= 2 else {
                    XCTFail("only \(parts.count) parts")
                    return
                }
                if case .head(let h) = parts[0] {
                    XCTAssertEqual(expectedVersion, h.version)
                    XCTAssertEqual(expectedStatus, h.status)
                    XCTAssertEqual(expectedHeaders, h.headers)
                } else {
                    XCTFail("unexpected type on index 0 \(parts[0])")
                }

                var i = 1
                var bytes: [UInt8] = []
                while i < parts.count - 1 {
                    if case .body(let bb) = parts[i] {
                        bb.withUnsafeReadableBytes { ptr in
                            bytes.append(contentsOf: ptr)
                        }
                    } else {
                        XCTFail("unexpected type on index \(i) \(parts[i])")
                    }
                    i += 1
                }

                XCTAssertEqual(expectedBody, String(decoding: bytes, as: UTF8.self))

                if case .end(let trailers) = parts[parts.count - 1] {
                    XCTAssertEqual(expectedTrailers, trailers)
                } else {
                    XCTFail("unexpected type on index \(parts.count - 1) \(parts[parts.count - 1])")
                }
            }
        }
    }

    private func testSimpleGet(_ mode: SendMode) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        var expectedHeaders = HTTPHeaders()
        expectedHeaders.add(name: "content-length", value: "14")
        expectedHeaders.add(name: "connection", value: "close")

        let accumulation = HTTPClientResponsePartAssertHandler(HTTPVersion(major: 1, minor: 1), .ok, expectedHeaders, "Hello World!\r\n")

        let numBytes = 16 * 1024
        let httpHandler = SimpleHTTPServer(mode)
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are appled to the accepted Channels
            .childChannelInitializer { channel in
                // Ensure we don't read faster then we can write by adding the BackPressureHandler into the pipeline.
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).then {
                    channel.pipeline.add(handler: httpHandler)
                }
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().then {
                    channel.pipeline.add(handler: accumulation)
                }
            }
            .connect(to: serverChannel.localAddress!)
            .wait())

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/helloworld")
        head.headers.add(name: "Host", value: "apple.com")
        clientChannel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
        try clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()

        accumulation.syncWaitForCompletion()
    }

    func testSimpleGetChunkedEncodingByteBuffer() throws {
        try testSimpleGetChunkedEncoding(.byteBuffer)
    }

    func testSimpleGetChunkedEncodingFileRegion() throws {
        try testSimpleGetChunkedEncoding(.fileRegion)
    }

    private func testSimpleGetChunkedEncoding(_ mode: SendMode) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        var expectedHeaders = HTTPHeaders()
        expectedHeaders.add(name: "transfer-encoding", value: "chunked")
        expectedHeaders.add(name: "connection", value: "close")

        let accumulation = HTTPClientResponsePartAssertHandler(HTTPVersion(major: 1, minor: 1), .ok, expectedHeaders, "12345678910")

        let numBytes = 16 * 1024
        let httpHandler = SimpleHTTPServer(mode)
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are appled to the accepted Channels
            .childChannelInitializer { channel in
                // Ensure we don't read faster then we can write by adding the BackPressureHandler into the pipeline.
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).then {
                    channel.pipeline.add(handler: httpHandler)
                }
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().then {
                    channel.pipeline.add(handler: accumulation)
                }
            }
            .connect(to: serverChannel.localAddress!)
            .wait())

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/count-to-ten")
        head.headers.add(name: "Host", value: "apple.com")
        clientChannel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
        try clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()
        accumulation.syncWaitForCompletion()
    }

    func testSimpleGetTrailersByteBuffer() throws {
        try testSimpleGetTrailers(.byteBuffer)
    }

    func testSimpleGetTrailersFileRegion() throws {
        try testSimpleGetTrailers(.fileRegion)
    }

    private func testSimpleGetTrailers(_ mode: SendMode) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        var expectedHeaders = HTTPHeaders()
        expectedHeaders.add(name: "transfer-encoding", value: "chunked")
        expectedHeaders.add(name: "connection", value: "close")

        var expectedTrailers = HTTPHeaders()
        expectedTrailers.add(name: "x-url-path", value: "/trailers")
        expectedTrailers.add(name: "x-should-trail", value: "sure")

        let accumulation = HTTPClientResponsePartAssertHandler(HTTPVersion(major: 1, minor: 1), .ok, expectedHeaders, "12345678910", expectedTrailers)

        let numBytes = 16 * 1024
        let httpHandler = SimpleHTTPServer(mode)
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).then {
                    channel.pipeline.add(handler: httpHandler)
                }
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().then {
                    channel.pipeline.add(handler: accumulation)
                }
            }
            .connect(to: serverChannel.localAddress!)
            .wait())
        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/trailers")
        head.headers.add(name: "Host", value: "apple.com")
        clientChannel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
        try clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()

        accumulation.syncWaitForCompletion()
    }

    func testMassiveResponseByteBuffer() throws {
        try testMassiveResponse(.byteBuffer)
    }

    func testMassiveResponseFileRegion() throws {
        try testMassiveResponse(.fileRegion)
    }

    func testMassiveResponse(_ mode: SendMode) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let accumulation = ArrayAccumulationHandler<ByteBuffer> { bbs in
            let expectedSuffix = HTTPServerClientTest.massiveResponseBytes
            let actual = bbs.allAsBytes()
            XCTAssertGreaterThan(actual.count, expectedSuffix.count)
            let actualSuffix = actual[(actual.count - expectedSuffix.count)..<actual.count]
            XCTAssertEqual(expectedSuffix.count, actualSuffix.count)
            XCTAssert(expectedSuffix.elementsEqual(actualSuffix))
        }
        let numBytes = 16 * 1024
        let httpHandler = SimpleHTTPServer(mode)
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are appled to the accepted Channels
            .childChannelInitializer { channel in
                // Ensure we don't read faster then we can write by adding the BackPressureHandler into the pipeline.
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).then {
                    channel.pipeline.add(handler: httpHandler)
                }
            }.bind(host: "127.0.0.1", port: 0).wait())
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer({ $0.pipeline.add(handler: accumulation) })
            .connect(to: serverChannel.localAddress!)
            .wait())
        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)
        buffer.write(staticString: "GET /massive-response HTTP/1.1\r\nHost: nio.net\r\n\r\n")

        try clientChannel.writeAndFlush(NIOAny(buffer)).wait()
        accumulation.syncWaitForCompletion()
    }

    func testHead() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        var expectedHeaders = HTTPHeaders()
        expectedHeaders.add(name: "content-length", value: "5000")
        expectedHeaders.add(name: "connection", value: "close")

        let accumulation = HTTPClientResponsePartAssertHandler(HTTPVersion(major: 1, minor: 1), .ok, expectedHeaders, "")

        let numBytes = 16 * 1024
        let httpHandler = SimpleHTTPServer(.byteBuffer)
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).then {
                    channel.pipeline.add(handler: httpHandler)
                }
            }.bind(host: "127.0.0.1", port: 0).wait())
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().then {
                    channel.pipeline.add(handler: accumulation)
                }
            }
            .connect(to: serverChannel.localAddress!)
            .wait())

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .HEAD, uri: "/head")
        head.headers.add(name: "Host", value: "apple.com")
        clientChannel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
        try clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()

        accumulation.syncWaitForCompletion()
    }

    func test204() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        var expectedHeaders = HTTPHeaders()
        expectedHeaders.add(name: "connection", value: "keep-alive")

        let accumulation = HTTPClientResponsePartAssertHandler(HTTPVersion(major: 1, minor: 1), .noContent, expectedHeaders, "")

        let numBytes = 16 * 1024
        let httpHandler = SimpleHTTPServer(.byteBuffer)
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).then {
                    channel.pipeline.add(handler: httpHandler)
                }
            }.bind(host: "127.0.0.1", port: 0).wait())
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().then {
                    channel.pipeline.add(handler: accumulation)
                }
            }
            .connect(to: serverChannel.localAddress!)
            .wait())
        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/204")
        head.headers.add(name: "Host", value: "apple.com")
        clientChannel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
        try clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()

        accumulation.syncWaitForCompletion()
    }

    @available(*, deprecated, message: "Tests deprecated function addHTTPServerHandlers")
    func testDeprecatedPipelineConstruction() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        var expectedHeaders = HTTPHeaders()
        expectedHeaders.add(name: "content-length", value: "14")
        expectedHeaders.add(name: "connection", value: "close")

        let accumulation = HTTPClientResponsePartAssertHandler(HTTPVersion(major: 1, minor: 1), .ok, expectedHeaders, "Hello World!\r\n")

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHTTPServerHandlers().then {
                    channel.pipeline.add(handler: SimpleHTTPServer(.byteBuffer))
                }
            }.bind(host: "127.0.0.1", port: 0).wait())

        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().then {
                    channel.pipeline.add(handler: accumulation)
                }
            }
            .connect(to: serverChannel.localAddress!)
            .wait())
        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/helloworld")
        head.headers.add(name: "Host", value: "apple.com")
        clientChannel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
        try clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()

        accumulation.syncWaitForCompletion()
    }
}
