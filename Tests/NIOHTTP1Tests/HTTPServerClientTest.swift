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
import ConcurrencyHelpers
import NIO
import Dispatch
@testable import NIOHTTP1

private func assertSuccess(_ f: EventLoopFutureValue<()>, file: StaticString = #file, line: Int = #line) {
    switch f {
    case .success(()):
        ()
    case .failure(let err):
        XCTFail("error received: \(err)", file: file, line: UInt(line))
    }
}

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
        
        init(_ mode: SendMode) {
            self.mode = mode
        }
        
        private func outboundBody(_  buffer: ByteBuffer) -> HTTPServerResponsePart {
            switch mode {
            case .byteBuffer:
                return .body(.byteBuffer(buffer))
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
                
                let content = buffer.data(at: 0, length: buffer.readableBytes)!
                try! content.write(to: URL(fileURLWithPath: filePath))
                let region = try! FileRegion(file: filePath, readerIndex: 0, endIndex: buffer.readableBytes)
                return .body(.fileRegion(region))
            }
        }
        
        public func handleRemoved(ctx: ChannelHandlerContext) {
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
                    ctx.write(data: self.wrapOutboundOut(r), promise: nil)
                    var b = ctx.channel!.allocator.buffer(capacity: replyString.count)
                    b.write(string: replyString)
                    
                    ctx.write(data: self.wrapOutboundOut(self.outboundBody(b)), promise: nil)
                    ctx.write(data: self.wrapOutboundOut(.end(nil))).whenComplete { r in
                        assertSuccess(r)
                        ctx.close().whenComplete { r in
                            assertSuccess(r)
                        }
                    }
                case "/count-to-ten":
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Connection", value: "close")
                    let r = HTTPServerResponsePart.head(head)
                    ctx.write(data: self.wrapOutboundOut(r)).whenComplete { r in
                        assertSuccess(r)
                    }
                    var b = ctx.channel!.allocator.buffer(capacity: 1024)
                    for i in 1...10 {
                        b.clear()
                        b.write(string: "\(i)")
                        
                        ctx.write(data: self.wrapOutboundOut(self.outboundBody(b))).whenComplete { r in
                            assertSuccess(r)
                        }
                    }
                    ctx.write(data: self.wrapOutboundOut(.end(nil))).whenComplete { r in
                        assertSuccess(r)
                        ctx.close().whenComplete { r in
                            assertSuccess(r)
                        }
                    }
                case "/trailers":
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Connection", value: "close")
                    head.headers.add(name: "Transfer-Encoding", value: "chunked")
                    let r = HTTPServerResponsePart.head(head)
                    ctx.write(data: self.wrapOutboundOut(r)).whenComplete { r in
                        assertSuccess(r)
                    }
                    var b = ctx.channel!.allocator.buffer(capacity: 1024)
                    for i in 1...10 {
                        b.clear()
                        b.write(string: "\(i)")
                        
                        ctx.write(data: self.wrapOutboundOut(self.outboundBody(b))).whenComplete { r in
                            assertSuccess(r)
                        }
                    }

                    var trailers = HTTPHeaders()
                    trailers.add(name: "X-URL-Path", value: "/trailers")
                    trailers.add(name: "X-Should-Trail", value: "sure")
                    ctx.write(data: self.wrapOutboundOut(.end(trailers))).whenComplete { r in
                        assertSuccess(r)
                        ctx.close().whenComplete { r in
                            assertSuccess(r)
                        }
                    }

                case "/massive-response":
                    var buf = ctx.channel!.allocator.buffer(capacity: HTTPServerClientTest.massiveResponseLength)
                    buf.writeWithUnsafeMutableBytes { targetPtr in
                        return HTTPServerClientTest.massiveResponseBytes.withUnsafeBytes { srcPtr in
                            precondition(targetPtr.count >= srcPtr.count)
                            targetPtr.copyBytes(from: srcPtr)
                            return srcPtr.count
                        }
                    }
                    buf.write(bytes: HTTPServerClientTest.massiveResponseBytes)
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Connection", value: "close")
                    head.headers.add(name: "Content-Length", value: "\(HTTPServerClientTest.massiveResponseLength)")
                    let r = HTTPServerResponsePart.head(head)
                    ctx.write(data: self.wrapOutboundOut(r)).whenComplete { r in
                        assertSuccess(r)
                    }
                    ctx.writeAndFlush(data: self.wrapOutboundOut(self.outboundBody(buf))).whenComplete { r in
                        assertSuccess(r)
                    }
                    ctx.write(data: self.wrapOutboundOut(.end(nil))).whenComplete { r in
                        assertSuccess(r)
                        ctx.close().whenComplete { r in
                            assertSuccess(r)
                        }
                    }
                default:
                    XCTFail("received request to unknown URI \(req.uri)")
                }
            case .end(let trailers):
                XCTAssertNil(trailers)
            default:
                XCTFail("wrong")
            }
        }

        public func channelReadComplete(ctx: ChannelHandlerContext) {
            ctx.flush().whenComplete {
                assertSuccess($0)
            }
        }
    }

    func testSimpleGetByteBuffer() throws {
        try testSimpleGet(.byteBuffer)
    }
    
    func testSimpleGetFileRegion() throws {
        try testSimpleGet(.fileRegion)
    }
    
    private class HTTPClientResponsePartAssertHandler : ArrayAccumulationHandler<HTTPClientResponsePart> {
        public init(_ expectedVersion: HTTPVersion, _ expectedStatus: HTTPResponseStatus, _ expectedHeaders: HTTPHeaders, _ expectedBody: String?, _ expectedTrailers: HTTPHeaders? = nil) {
            super.init { parts in
                XCTAssertTrue(parts.count >= 3, "parts \(parts.count)")
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
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        var expectedHeaders = HTTPHeaders()
        expectedHeaders.add(name: "content-length", value: "14")
        expectedHeaders.add(name: "connection", value: "close")
        
        let accumulation = HTTPClientResponsePartAssertHandler(HTTPVersion(major: 1, minor: 1), .ok, expectedHeaders, "Hello World!\r\n")
        
        let numBytes = 16 * 1024
        let httpHandler = SimpleHTTPServer(mode)
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            
            // Set the handlers that are appled to the accepted Channels
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                // Ensure we not read faster then we can write by adding the BackPressureHandler into the pipeline.
                channel.pipeline.add(handler: HTTPRequestDecoder()).then {
                    channel.pipeline.add(handler: HTTPResponseEncoder()).then {
                        channel.pipeline.add(handler: httpHandler)
                    }
                }
            })).bind(to: "127.0.0.1", on: 0).wait()
        
        defer {
            _ = serverChannel.close()
        }
        
        let clientChannel = try ClientBootstrap(group: group)
            .handler(handler: ChannelInitializer(initChannel: { channel in
                channel.pipeline.add(handler: HTTPResponseDecoder()).then {
                    channel.pipeline.add(handler: HTTPRequestEncoder()).then {
                        channel.pipeline.add(handler: accumulation)
                    }
                }
            }))
            .connect(to: serverChannel.localAddress!)
            .wait()
        
        defer {
            _ = clientChannel.close()
        }
        
        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/helloworld")
        head.headers.add(name: "Host", value: "apple.com")
        try clientChannel.writeAndFlush(data: NIOAny(HTTPClientRequestPart.head(head))).wait()
        try clientChannel.writeAndFlush(data: NIOAny(HTTPClientRequestPart.end(nil))).wait()

        accumulation.syncWaitForCompletion()
    }
    
    func testSimpleGetChunkedEncodingByteBuffer() throws {
        try testSimpleGetChunkedEncoding(.byteBuffer)
    }
    
    func testSimpleGetChunkedEncodingFileRegion() throws {
        try testSimpleGetChunkedEncoding(.fileRegion)
    }
    
    private func testSimpleGetChunkedEncoding(_ mode: SendMode) throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }
        
        var expectedHeaders = HTTPHeaders()
        expectedHeaders.add(name: "transfer-encoding", value: "chunked")
        expectedHeaders.add(name: "connection", value: "close")
        
        let accumulation = HTTPClientResponsePartAssertHandler(HTTPVersion(major: 1, minor: 1), .ok, expectedHeaders, "12345678910")
        
        let numBytes = 16 * 1024
        let httpHandler = SimpleHTTPServer(mode)
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            
            // Set the handlers that are appled to the accepted Channels
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                // Ensure we not read faster then we can write by adding the BackPressureHandler into the pipeline.
                channel.pipeline.add(handler: HTTPRequestDecoder()).then {
                    channel.pipeline.add(handler: HTTPResponseEncoder()).then {
                        channel.pipeline.add(handler: httpHandler)
                    }
                }
            })).bind(to: "127.0.0.1", on: 0).wait()
        
        defer {
            _ = serverChannel.close()
        }
        
        let clientChannel = try ClientBootstrap(group: group)
            .handler(handler: ChannelInitializer(initChannel: { channel in
                channel.pipeline.add(handler: HTTPResponseDecoder()).then {
                    channel.pipeline.add(handler: HTTPRequestEncoder()).then {
                        channel.pipeline.add(handler: accumulation)
                    }
                }
            }))
            .connect(to: serverChannel.localAddress!)
            .wait()
        
        defer {
            _ = clientChannel.close()
        }
        
        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/count-to-ten")
        head.headers.add(name: "Host", value: "apple.com")
        try clientChannel.writeAndFlush(data: NIOAny(HTTPClientRequestPart.head(head))).wait()
        try clientChannel.writeAndFlush(data: NIOAny(HTTPClientRequestPart.end(nil))).wait()
        accumulation.syncWaitForCompletion()
    }

    func testSimpleGetTrailersByteBuffer() throws {
        try testSimpleGetTrailers(.byteBuffer)
    }
    
    func testSimpleGetTrailersFileRegion() throws {
        try testSimpleGetTrailers(.fileRegion)
    }
    
    private func testSimpleGetTrailers(_ mode: SendMode) throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
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
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                channel.pipeline.add(handler: HTTPRequestDecoder()).then {
                    channel.pipeline.add(handler: HTTPResponseEncoder()).then {
                        channel.pipeline.add(handler: httpHandler)
                    }
                }
            })).bind(to: "127.0.0.1", on: 0).wait()

        defer {
            _ = serverChannel.close()
        }

        let clientChannel = try ClientBootstrap(group: group)
            .handler(handler: ChannelInitializer(initChannel: { channel in
                channel.pipeline.add(handler: HTTPResponseDecoder()).then {
                    channel.pipeline.add(handler: HTTPRequestEncoder()).then {
                        channel.pipeline.add(handler: accumulation)
                    }
                }
            }))
            .connect(to: serverChannel.localAddress!)
            .wait()

        defer {
            _ = clientChannel.close()
        }

        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/trailers")
        head.headers.add(name: "Host", value: "apple.com")
        try clientChannel.writeAndFlush(data: NIOAny(HTTPClientRequestPart.head(head))).wait()
        try clientChannel.writeAndFlush(data: NIOAny(HTTPClientRequestPart.end(nil))).wait()
        
        accumulation.syncWaitForCompletion()
    }

    func testMassiveResponseByteBuffer() throws {
        try testMassiveResponse(.byteBuffer)
    }
    
    func testMassiveResponseFileRegion() throws {
        try testMassiveResponse(.fileRegion)
    }

    func testMassiveResponse(_ mode: SendMode) throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
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
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are appled to the accepted Channels
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                // Ensure we not read faster then we can write by adding the BackPressureHandler into the pipeline.
                channel.pipeline.add(handler: HTTPRequestDecoder()).then {
                    channel.pipeline.add(handler: HTTPResponseEncoder()).then {
                        channel.pipeline.add(handler: httpHandler)
                    }
                }
            })).bind(to: "127.0.0.1", on: 0).wait()

        defer {
            _ = serverChannel.close()
        }

        let clientChannel = try ClientBootstrap(group: group)
            .handler(handler: accumulation)
            .connect(to: serverChannel.localAddress!)
            .wait()

        defer {
            _ = clientChannel.close()
        }

        var buffer = clientChannel.allocator.buffer(capacity: numBytes)
        buffer.write(staticString: "GET /massive-response HTTP/1.1\r\nHost: nio.net\r\n\r\n")

        try clientChannel.writeAndFlush(data: NIOAny(buffer)).wait()
        accumulation.syncWaitForCompletion()
    }
}
