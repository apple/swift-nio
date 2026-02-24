//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import NIOConcurrencyHelpers
import NIOCore
import NIOFoundationCompat
import NIOPosix
import XCTest

@testable import NIOHTTP1

extension Array where Array.Element == ByteBuffer {
    public func allAsBytes() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(self.reduce(0, { $0 + $1.readableBytes }))
        for bb in self {
            bb.withUnsafeReadableBytes { ptr in
                out.append(contentsOf: ptr)
            }
        }
        return out
    }

    public func allAsString() -> String? {
        String(decoding: self.allAsBytes(), as: Unicode.UTF8.self)
    }
}

// Must be unchecked because of inheritance.
internal class ArrayAccumulationHandler<T>: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = T
    private let received: NIOLockedValueBox<[T]>
    private let allDoneBlock: DispatchWorkItem

    init(completion: @escaping ([T]) -> Void) {
        let received = NIOLockedValueBox<[T]>([])
        self.received = received
        self.allDoneBlock = DispatchWorkItem {
            completion(received.withLockedValue { $0 })
        }
    }

    final func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.received.withLockedValue { $0.append(Self.unwrapInboundIn(data)) }
    }

    final func channelUnregistered(context: ChannelHandlerContext) {
        self.allDoneBlock.perform()
    }

    final func syncWaitForCompletion() {
        self.allDoneBlock.wait()
    }
}

class HTTPServerClientTest: XCTestCase {
    // needs to be something reasonably large and odd so it has good odds producing incomplete writes even on the loopback interface
    private static let massiveResponseLength = 1 * 1024 * 1024 + 7
    private static let massiveResponseBytes: [UInt8] = {
        Array(repeating: 0xff, count: HTTPServerClientTest.massiveResponseLength)
    }()

    enum SendMode {
        case byteBuffer
        case fileRegion
    }

    private class SimpleHTTPServer: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let mode: SendMode
        private var files: [String] = Array()
        private var seenEnd: Bool = false
        private var sentEnd: Bool = false
        private var isOpen: Bool = true

        init(_ mode: SendMode) {
            self.mode = mode
        }

        private func outboundBody(_ buffer: ByteBuffer) -> (body: HTTPServerResponsePart, destructor: () -> Void) {
            switch mode {
            case .byteBuffer:
                return (.body(.byteBuffer(buffer)), { () in })
            case .fileRegion:
                let filePath: String = "\(temporaryDirectory)/\(UUID().uuidString)"
                files.append(filePath)

                let content = buffer.getData(at: 0, length: buffer.readableBytes)!
                XCTAssertNoThrow(try content.write(to: URL(fileURLWithPath: filePath)))
                let fh = try! NIOFileHandle(_deprecatedPath: filePath)
                let region = FileRegion(
                    fileHandle: fh,
                    readerIndex: 0,
                    endIndex: buffer.readableBytes
                )
                return (.body(.fileRegion(region)), { try! fh.close() })
            }
        }

        public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let loopBoundContext = context.loopBound
            switch Self.unwrapInboundIn(data) {
            case .head(let req):
                switch req.uri {
                case "/helloworld":
                    let replyString = "Hello World!\r\n"
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Content-Length", value: "\(replyString.utf8.count)")
                    head.headers.add(name: "Connection", value: "close")
                    let r = HTTPServerResponsePart.head(head)
                    context.write(Self.wrapOutboundOut(r), promise: nil)
                    var b = context.channel.allocator.buffer(capacity: replyString.count)
                    b.writeString(replyString)

                    let outbound = self.outboundBody(b)
                    context.write(Self.wrapOutboundOut(outbound.body)).assumeIsolated().whenComplete {
                        (_: Result<Void, Error>) in
                        outbound.destructor()
                    }
                    context.write(Self.wrapOutboundOut(.end(nil))).recover { error in
                        XCTFail("unexpected error \(error)")
                    }.assumeIsolated().whenComplete { (_: Result<Void, Error>) in
                        let context = loopBoundContext.value
                        self.sentEnd = true
                        self.maybeClose(context: context)
                    }
                case "/count-to-ten":
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Connection", value: "close")
                    let r = HTTPServerResponsePart.head(head)
                    context.write(Self.wrapOutboundOut(r)).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }
                    var b = context.channel.allocator.buffer(capacity: 1024)
                    for i in 1...10 {
                        b.clear()
                        b.writeString("\(i)")

                        let outbound = self.outboundBody(b)
                        context.write(Self.wrapOutboundOut(outbound.body)).recover { error in
                            XCTFail("unexpected error \(error)")
                        }.assumeIsolated().whenComplete { (_: Result<Void, Error>) in
                            outbound.destructor()
                        }
                    }
                    context.write(Self.wrapOutboundOut(.end(nil))).recover { error in
                        XCTFail("unexpected error \(error)")
                    }.assumeIsolated().whenComplete { (_: Result<Void, Error>) in
                        let context = loopBoundContext.value
                        self.sentEnd = true
                        self.maybeClose(context: context)
                    }
                case "/trailers":
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Connection", value: "close")
                    head.headers.add(name: "Transfer-Encoding", value: "chunked")
                    let r = HTTPServerResponsePart.head(head)
                    context.write(Self.wrapOutboundOut(r)).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }
                    var b = context.channel.allocator.buffer(capacity: 1024)
                    for i in 1...10 {
                        b.clear()
                        b.writeString("\(i)")

                        let outbound = self.outboundBody(b)
                        context.write(Self.wrapOutboundOut(outbound.body)).recover { error in
                            XCTFail("unexpected error \(error)")
                        }.assumeIsolated().whenComplete { (_: Result<Void, Error>) in
                            outbound.destructor()
                        }
                    }

                    var trailers = HTTPHeaders()
                    trailers.add(name: "X-URL-Path", value: "/trailers")
                    trailers.add(name: "X-Should-Trail", value: "sure")
                    context.write(Self.wrapOutboundOut(.end(trailers))).recover { error in
                        XCTFail("unexpected error \(error)")
                    }.assumeIsolated().whenComplete { (_: Result<Void, Error>) in
                        let context = loopBoundContext.value
                        self.sentEnd = true
                        self.maybeClose(context: context)
                    }

                case "/massive-response":
                    var buf = context.channel.allocator.buffer(capacity: HTTPServerClientTest.massiveResponseLength)
                    buf.reserveCapacity(HTTPServerClientTest.massiveResponseLength)
                    buf.writeBytes(HTTPServerClientTest.massiveResponseBytes)
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Connection", value: "close")
                    head.headers.add(name: "Content-Length", value: "\(HTTPServerClientTest.massiveResponseLength)")
                    let r = HTTPServerResponsePart.head(head)
                    context.write(Self.wrapOutboundOut(r)).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }
                    let outbound = self.outboundBody(buf)
                    context.writeAndFlush(Self.wrapOutboundOut(outbound.body)).recover { error in
                        XCTFail("unexpected error \(error)")
                    }.assumeIsolated().whenComplete { (_: Result<Void, Error>) in
                        outbound.destructor()
                    }
                    context.write(Self.wrapOutboundOut(.end(nil))).recover { error in
                        XCTFail("unexpected error \(error)")
                    }.assumeIsolated().whenComplete { (_: Result<Void, Error>) in
                        let context = loopBoundContext.value
                        self.sentEnd = true
                        self.maybeClose(context: context)
                    }
                case "/head":
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Connection", value: "close")
                    head.headers.add(name: "Content-Length", value: "5000")
                    context.write(Self.wrapOutboundOut(.head(head))).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }
                    context.write(Self.wrapOutboundOut(.end(nil))).recover { error in
                        XCTFail("unexpected error \(error)")
                    }.assumeIsolated().whenComplete { (_: Result<Void, Error>) in
                        let context = loopBoundContext.value
                        self.sentEnd = true
                        self.maybeClose(context: context)
                    }
                case "/204":
                    var head = HTTPResponseHead(version: req.version, status: .noContent)
                    head.headers.add(name: "Connection", value: "keep-alive")
                    context.write(Self.wrapOutboundOut(.head(head))).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }
                    context.write(Self.wrapOutboundOut(.end(nil))).recover { error in
                        XCTFail("unexpected error \(error)")
                    }.assumeIsolated().whenComplete { (_: Result<Void, Error>) in
                        let context = loopBoundContext.value
                        self.sentEnd = true
                        self.maybeClose(context: context)
                    }
                case "/no-headers":
                    let replyString = "Hello World!\r\n"
                    let head = HTTPResponseHead(version: req.version, status: .ok)
                    let r = HTTPServerResponsePart.head(head)
                    context.write(Self.wrapOutboundOut(r), promise: nil)
                    var b = context.channel.allocator.buffer(capacity: replyString.count)
                    b.writeString(replyString)

                    let outbound = self.outboundBody(b)
                    context.write(Self.wrapOutboundOut(outbound.body)).assumeIsolated().whenComplete {
                        (_: Result<Void, Error>) in
                        outbound.destructor()
                    }
                    context.write(Self.wrapOutboundOut(.end(nil))).recover { error in
                        XCTFail("unexpected error \(error)")
                    }.assumeIsolated().whenComplete { (_: Result<Void, Error>) in
                        let context = loopBoundContext.value
                        self.sentEnd = true
                        self.maybeClose(context: context)
                    }
                case "/zero-length-body-part":

                    let r = HTTPServerResponsePart.head(.init(version: req.version, status: .ok))
                    context.write(Self.wrapOutboundOut(r)).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }

                    context.writeAndFlush(Self.wrapOutboundOut(.body(.byteBuffer(ByteBuffer())))).whenFailure { error in
                        XCTFail("unexpected error \(error)")
                    }
                    context.writeAndFlush(Self.wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "Hello World")))))
                        .whenFailure { error in
                            XCTFail("unexpected error \(error)")
                        }
                    context.write(Self.wrapOutboundOut(.end(nil))).recover { error in
                        XCTFail("unexpected error \(error)")
                    }.assumeIsolated().whenComplete { (_: Result<Void, Error>) in
                        let context = loopBoundContext.value
                        self.sentEnd = true
                        self.maybeClose(context: context)
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

        public func channelReadComplete(context: ChannelHandlerContext) {
            context.flush()
        }

        // We should only close the connection when the remote peer has sent the entire request
        // and we have sent our entire response.
        private func maybeClose(context: ChannelHandlerContext) {
            if sentEnd && seenEnd && self.isOpen {
                self.isOpen = false
                context.close().whenFailure { error in
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

    // @unchecked because of inheritance.
    private final class HTTPClientResponsePartAssertHandler: ArrayAccumulationHandler<HTTPClientResponsePart>,
        @unchecked Sendable
    {
        public init(
            _ expectedVersion: HTTPVersion,
            _ expectedStatus: HTTPResponseStatus,
            _ expectedHeaders: HTTPHeaders,
            _ expectedBody: String?,
            _ expectedTrailers: HTTPHeaders? = nil
        ) {
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

                XCTAssertEqual(expectedBody, String(decoding: bytes, as: Unicode.UTF8.self))

                if case .end(let trailers) = parts[parts.count - 1] {
                    XCTAssertEqual(expectedTrailers, trailers)
                } else {
                    XCTFail("unexpected type on index \(parts.count - 1) \(parts[parts.count - 1])")
                }
            }
        }
    }

    private func testSimpleGet(
        _ mode: SendMode,
        httpVersion: HTTPVersion = .http1_1,
        uri: String = "/helloworld",
        expectedHeaders maybeExpectedHeaders: HTTPHeaders? = nil
    ) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let expectedHeaders = maybeExpectedHeaders ?? HTTPHeaders([("content-length", "14"), ("connection", "close")])

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)

                // Set the handlers that are appled to the accepted Channels
                .childChannelInitializer { channel in
                    // Ensure we don't read faster than we can write by adding the BackPressureHandler into the pipeline.
                    channel.eventLoop.makeCompletedFuture {
                        let sync = channel.pipeline.syncOperations
                        try sync.configureHTTPServerPipeline(withPipeliningAssistance: false)
                        let httpHandler = SimpleHTTPServer(mode)
                        try sync.addHandlers(httpHandler)
                    }
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let accumulation = HTTPClientResponsePartAssertHandler(httpVersion, .ok, expectedHeaders, "Hello World!\r\n")
        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sync = channel.pipeline.syncOperations
                        try sync.addHTTPClientHandlers()
                        try sync.addHandler(accumulation)
                    }
                }
                .connect(to: serverChannel.localAddress!)
                .wait()
        )

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        let head = HTTPRequestHead(version: httpVersion, method: .GET, uri: uri, headers: ["Host": "apple.com"])
        try clientChannel.eventLoop.flatSubmit {
            let promise = clientChannel.eventLoop.makePromise(of: Void.self)
            clientChannel.pipeline.syncOperations.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
            clientChannel.pipeline.syncOperations.writeAndFlush(
                NIOAny(HTTPClientRequestPart.end(nil)),
                promise: promise
            )
            return promise.futureResult
        }.wait()

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

        let accumulation = HTTPClientResponsePartAssertHandler(.http1_1, .ok, expectedHeaders, "12345678910")

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)

                // Set the handlers that are appled to the accepted Channels
                .childChannelInitializer { channel in
                    // Ensure we don't read faster than we can write by adding the BackPressureHandler into the pipeline.
                    channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).flatMap {
                        channel.eventLoop.makeCompletedFuture {
                            let httpHandler = SimpleHTTPServer(mode)
                            return try channel.pipeline.syncOperations.addHandler(httpHandler)
                        }
                    }
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHTTPClientHandlers().flatMap {
                        channel.pipeline.addHandler(accumulation)
                    }
                }
                .connect(to: serverChannel.localAddress!)
                .wait()
        )

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/count-to-ten",
            headers: ["Host": "apple.com"]
        )
        try clientChannel.eventLoop.flatSubmit {
            let promise = clientChannel.eventLoop.makePromise(of: Void.self)
            clientChannel.pipeline.syncOperations.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
            clientChannel.pipeline.syncOperations.writeAndFlush(
                NIOAny(HTTPClientRequestPart.end(nil)),
                promise: promise
            )
            return promise.futureResult
        }.wait()
        accumulation.syncWaitForCompletion()
    }

    func testSimpleGetTrailersByteBuffer() throws {
        try testSimpleGetTrailers(.byteBuffer)
    }

    func testSimpleGetTrailersFileRegion() throws {
        try testSimpleGetTrailers(.fileRegion)
    }

    func testSimpleGetChunkedEncodingWithZeroLengthBodyPart() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        var expectedHeaders = HTTPHeaders()
        expectedHeaders.add(name: "transfer-encoding", value: "chunked")

        let accumulation = HTTPClientResponsePartAssertHandler(.http1_1, .ok, expectedHeaders, "Hello World")

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)

                // Set the handlers that are appled to the accepted Channels
                .childChannelInitializer { channel in
                    // Ensure we don't read faster than we can write by adding the BackPressureHandler into the pipeline.
                    channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: true).flatMap {
                        channel.eventLoop.makeCompletedFuture {
                            let httpHandler = SimpleHTTPServer(.byteBuffer)
                            return try channel.pipeline.syncOperations.addHandler(httpHandler)
                        }
                    }
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHTTPClientHandlers().flatMap {
                        channel.pipeline.addHandler(accumulation)
                    }
                }
                .connect(to: serverChannel.localAddress!)
                .wait()
        )

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/zero-length-body-part",
            headers: ["Host": "apple.com"]
        )
        try clientChannel.eventLoop.flatSubmit {
            let promise = clientChannel.eventLoop.makePromise(of: Void.self)
            clientChannel.pipeline.syncOperations.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
            clientChannel.pipeline.syncOperations.writeAndFlush(
                NIOAny(HTTPClientRequestPart.end(nil)),
                promise: promise
            )
            return promise.futureResult
        }.wait()
        accumulation.syncWaitForCompletion()
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

        let accumulation = HTTPClientResponsePartAssertHandler(
            .http1_1,
            .ok,
            expectedHeaders,
            "12345678910",
            expectedTrailers
        )

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).flatMap {
                        channel.eventLoop.makeCompletedFuture {
                            let httpHandler = SimpleHTTPServer(mode)
                            return try channel.pipeline.syncOperations.addHandler(httpHandler)
                        }
                    }
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHTTPClientHandlers().flatMap {
                        channel.pipeline.addHandler(accumulation)
                    }
                }
                .connect(to: serverChannel.localAddress!)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/trailers", headers: ["Host": "apple.com"])
        try clientChannel.eventLoop.flatSubmit {
            let promise = clientChannel.eventLoop.makePromise(of: Void.self)
            clientChannel.pipeline.syncOperations.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
            clientChannel.pipeline.syncOperations.writeAndFlush(
                NIOAny(HTTPClientRequestPart.end(nil)),
                promise: promise
            )
            return promise.futureResult
        }.wait()

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
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)

                // Set the handlers that are appled to the accepted Channels
                .childChannelInitializer { channel in
                    // Ensure we don't read faster than we can write by adding the BackPressureHandler into the pipeline.
                    channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).flatMap {
                        channel.eventLoop.makeCompletedFuture {
                            let httpHandler = SimpleHTTPServer(mode)
                            return try channel.pipeline.syncOperations.addHandler(httpHandler)
                        }
                    }
                }.bind(host: "127.0.0.1", port: 0).wait()
        )
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer({ $0.pipeline.addHandler(accumulation) })
                .connect(to: serverChannel.localAddress!)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)
        buffer.writeStaticString("GET /massive-response HTTP/1.1\r\nHost: nio.net\r\n\r\n")

        try clientChannel.writeAndFlush(buffer).wait()
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

        let accumulation = HTTPClientResponsePartAssertHandler(.http1_1, .ok, expectedHeaders, "")

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).flatMap {
                        channel.eventLoop.makeCompletedFuture {
                            let httpHandler = SimpleHTTPServer(.byteBuffer)
                            return try channel.pipeline.syncOperations.addHandler(httpHandler)
                        }
                    }
                }.bind(host: "127.0.0.1", port: 0).wait()
        )
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHTTPClientHandlers().flatMap {
                        channel.pipeline.addHandler(accumulation)
                    }
                }
                .connect(to: serverChannel.localAddress!)
                .wait()
        )

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        let head = HTTPRequestHead(version: .http1_1, method: .HEAD, uri: "/head", headers: ["Host": "apple.com"])
        try clientChannel.eventLoop.flatSubmit {
            let promise = clientChannel.eventLoop.makePromise(of: Void.self)
            clientChannel.pipeline.syncOperations.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
            clientChannel.pipeline.syncOperations.writeAndFlush(
                NIOAny(HTTPClientRequestPart.end(nil)),
                promise: promise
            )
            return promise.futureResult
        }.wait()

        accumulation.syncWaitForCompletion()
    }

    func test204() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        var expectedHeaders = HTTPHeaders()
        expectedHeaders.add(name: "connection", value: "keep-alive")

        let accumulation = HTTPClientResponsePartAssertHandler(.http1_1, .noContent, expectedHeaders, "")

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).flatMap {
                        channel.eventLoop.makeCompletedFuture {
                            let httpHandler = SimpleHTTPServer(.byteBuffer)
                            return try channel.pipeline.syncOperations.addHandler(httpHandler)
                        }
                    }
                }.bind(host: "127.0.0.1", port: 0).wait()
        )
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHTTPClientHandlers().flatMap {
                        channel.pipeline.addHandler(accumulation)
                    }
                }
                .connect(to: serverChannel.localAddress!)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/204", headers: ["Host": "apple.com"])
        try clientChannel.eventLoop.flatSubmit {
            let promise = clientChannel.eventLoop.makePromise(of: Void.self)
            clientChannel.pipeline.syncOperations.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
            clientChannel.pipeline.syncOperations.writeAndFlush(
                NIOAny(HTTPClientRequestPart.end(nil)),
                promise: promise
            )
            return promise.futureResult
        }.wait()

        accumulation.syncWaitForCompletion()
    }

    func testNoResponseHeaders() {
        XCTAssertNoThrow(
            try self.testSimpleGet(
                .byteBuffer,
                httpVersion: .http1_0,
                uri: "/no-headers",
                expectedHeaders: [:]
            )
        )
    }
}
