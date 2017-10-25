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

private func assertSuccess(_ f: FutureValue<()>, file: StaticString = #file, line: Int = #line) {
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

    private class SimpleHTTPServer: ChannelInboundHandler {
        typealias InboundIn = HTTPRequestPart
        typealias OutboundOut = HTTPResponsePart
        
        public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
            switch self.unwrapInboundIn(data) {
            case .head(let req):
                switch req.uri {
                case "/helloworld":
                    let replyString = "Hello World!\r\n"
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Content-Length", value: "\(replyString.utf8.count)")
                    head.headers.add(name: "Connection", value: "close")
                    let r = HTTPResponsePart.head(head)
                    ctx.write(data: self.wrapOutboundOut(r), promise: nil)
                    var b = ctx.channel!.allocator.buffer(capacity: replyString.count)
                    b.write(string: replyString)
                    ctx.write(data: self.wrapOutboundOut(.body(b)), promise: nil)
                    ctx.write(data: self.wrapOutboundOut(.end(nil))).whenComplete { r in
                        assertSuccess(r)
                        ctx.close().whenComplete { r in
                            assertSuccess(r)
                        }
                    }
                case "/count-to-ten":
                    var head = HTTPResponseHead(version: req.version, status: .ok)
                    head.headers.add(name: "Connection", value: "close")
                    let r = HTTPResponsePart.head(head)
                    ctx.write(data: self.wrapOutboundOut(r)).whenComplete { r in
                        assertSuccess(r)
                    }
                    var b = ctx.channel!.allocator.buffer(capacity: 1024)
                    for i in 1...10 {
                        b.clear()
                        b.write(string: "\(i)")
                        ctx.write(data: self.wrapOutboundOut(.body(b))).whenComplete { r in
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
                    let r = HTTPResponsePart.head(head)
                    ctx.write(data: self.wrapOutboundOut(r)).whenComplete { r in
                        assertSuccess(r)
                    }
                    var b = ctx.channel!.allocator.buffer(capacity: 1024)
                    for i in 1...10 {
                        b.clear()
                        b.write(string: "\(i)")
                        ctx.write(data: self.wrapOutboundOut(.body(b))).whenComplete { r in
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
                    let r = HTTPResponsePart.head(head)
                    ctx.write(data: self.wrapOutboundOut(r)).whenComplete { r in
                        assertSuccess(r)
                    }
                    ctx.writeAndFlush(data: self.wrapOutboundOut(.body(buf))).whenComplete { r in
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

    func testSimpleGet() throws {
        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let accumulation = ArrayAccumulationHandler<ByteBuffer> { bbs in
            let expectedPrefix = "HTTP/1.1 200 OK\r\n"
            let expectedHeaderContentLength = "\r\ncontent-length: 14\r\n"
            let expectedHeaderConnection = "\r\nconnection: close\r\n"
            let expectedSuffix = "\r\n\r\nHello World!\r\n"
            let actual = bbs.allAsString() ?? "<nothing>"

            XCTAssert(actual.hasPrefix(expectedPrefix))
            XCTAssert(actual.hasSuffix(expectedSuffix))
            XCTAssert(actual.contains(expectedHeaderConnection))
            XCTAssert(actual.contains(expectedHeaderContentLength))
        }
        let numBytes = 16 * 1024
        let httpHandler = SimpleHTTPServer()
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            
            // Set the handlers that are appled to the accepted Channels
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                // Ensure we not read faster then we can write by adding the BackPressureHandler into the pipeline.
                channel.pipeline.add(handler: HTTPRequestDecoder()).then {
                    channel.pipeline.add(handler: HTTPResponseEncoder(allocator: channel.allocator)).then {
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
        buffer.write(staticString: "GET /helloworld HTTP/1.1\r\nHost: nio.net\r\n\r\n")
        
        try clientChannel.writeAndFlush(data: NIOAny(buffer)).wait()
        accumulation.syncWaitForCompletion()
    }
    
    func testSimpleGetChunkedEncoding() throws {
        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }
        
        let accumulation = ArrayAccumulationHandler<ByteBuffer> { bbs in
            let expectedPrefix = "HTTP/1.1 200 OK\r\n"
            let expectedSuffix = "\r\n1\r\n1\r\n1\r\n2\r\n1\r\n3\r\n1\r\n4\r\n1\r\n5\r\n1\r\n6\r\n1\r\n7\r\n1\r\n8\r\n1\r\n9\r\n2\r\n10\r\n0\r\n\r\n"
            let actual = bbs.allAsString() ?? "<nothing>"
            XCTAssert(actual.hasPrefix(expectedPrefix))
            XCTAssert(actual.hasSuffix(expectedSuffix))
            XCTAssert(actual.contains("\r\ntransfer-encoding: chunked\r\n"))
        }
        let numBytes = 16 * 1024
        let httpHandler = SimpleHTTPServer()
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            
            // Set the handlers that are appled to the accepted Channels
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                // Ensure we not read faster then we can write by adding the BackPressureHandler into the pipeline.
                channel.pipeline.add(handler: HTTPRequestDecoder()).then {
                    channel.pipeline.add(handler: HTTPResponseEncoder(allocator: channel.allocator)).then {
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
        buffer.write(staticString: "GET /count-to-ten HTTP/1.1\r\nHost: nio.net\r\n\r\n")
        
        try clientChannel.writeAndFlush(data: NIOAny(buffer)).wait()
        accumulation.syncWaitForCompletion()
    }

    func testSimpleGetTrailers() throws {
        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let accumulation = ArrayAccumulationHandler<ByteBuffer> { bbs in
            let expectedPrefix = "HTTP/1.1 200 OK\r\n"

            // Due to header order being random, there are two possible appearances for the trailer.
            let expectedSuffix1 = "0\r\nx-url-path: /trailers\r\nx-should-trail: sure\r\n\r\n"
            let expectedSuffix2 = "0\r\nx-should-trail: sure\r\nx-url-path: /trailers\r\n\r\n"

            let actual = bbs.allAsString() ?? "<nothing>"
            XCTAssert(actual.hasPrefix(expectedPrefix))
            XCTAssert(actual.hasSuffix(expectedSuffix1) || actual.hasSuffix(expectedSuffix2))
            XCTAssert(actual.contains("\r\ntransfer-encoding: chunked\r\n"))
        }
        let numBytes = 16 * 1024
        let httpHandler = SimpleHTTPServer()
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                channel.pipeline.add(handler: HTTPRequestDecoder()).then {
                    channel.pipeline.add(handler: HTTPResponseEncoder(allocator: channel.allocator)).then {
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
        buffer.write(staticString: "GET /trailers HTTP/1.1\r\nHost: nio.net\r\n\r\n")

        try clientChannel.writeAndFlush(data: NIOAny(buffer)).wait()
        accumulation.syncWaitForCompletion()
    }

    func testMassiveResponse() throws {
        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
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
        let httpHandler = SimpleHTTPServer()
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            // Set the handlers that are appled to the accepted Channels
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                // Ensure we not read faster then we can write by adding the BackPressureHandler into the pipeline.
                channel.pipeline.add(handler: HTTPRequestDecoder()).then {
                    channel.pipeline.add(handler: HTTPResponseEncoder(allocator: channel.allocator)).then {
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
