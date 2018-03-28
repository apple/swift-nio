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

import NIO
import NIOHTTP1
import Foundation
import AtomicCounter

private final class SimpleHTTPServer: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let bodyLength = 100
    private let numberOfAdditionalHeaders = 3

    private var responseHead: HTTPResponseHead {
        var head = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .ok)
        head.headers.add(name: "Content-Length", value: "\(self.bodyLength)")
        for i in 0..<self.numberOfAdditionalHeaders {
            head.headers.add(name: "X-Random-Extra-Header", value: "\(i)")
        }
        return head
    }

    private func responseBody(allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: self.bodyLength)
        for i in 0..<self.bodyLength {
            buffer.write(integer: UInt8(i % Int(UInt8.max)))
        }
        return buffer
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        if case .head(let req) = self.unwrapInboundIn(data), req.uri == "/allocation-test-1" {
            ctx.write(self.wrapOutboundOut(.head(self.responseHead)), promise: nil)
            ctx.write(self.wrapOutboundOut(.body(.byteBuffer(self.responseBody(allocator: ctx.channel.allocator)))), promise: nil)
            ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

@_cdecl("swift_main")
public func swiftMain() -> Int {
    final class RepeatedRequests: ChannelInboundHandler {
        typealias InboundIn = HTTPClientResponsePart
        typealias OutboundOut = HTTPClientRequestPart

        private let numberOfRequests: Int
        private var remainingNumberOfRequests: Int
        private let isDonePromise: EventLoopPromise<Int>
        static var requestHead: HTTPRequestHead {
            var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/allocation-test-1")
            head.headers.add(name: "Host", value: "foo-\(ObjectIdentifier(self)).com")
            return head
        }

        init(numberOfRequests: Int, eventLoop: EventLoop) {
            self.remainingNumberOfRequests = numberOfRequests
            self.numberOfRequests = numberOfRequests
            self.isDonePromise = eventLoop.newPromise()
        }

        func wait() throws -> Int {
            let reqs = try self.isDonePromise.futureResult.wait()
            precondition(reqs == self.numberOfRequests)
            return reqs
        }

        func errorCaught(ctx: ChannelHandlerContext, error: Error) {
            ctx.channel.close(promise: nil)
            self.isDonePromise.fail(error: error)
        }

        func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
            let respPart = self.unwrapInboundIn(data)
            if case .end(nil) = respPart {
                if self.remainingNumberOfRequests <= 0 {
                    ctx.channel.close().map { self.numberOfRequests - self.remainingNumberOfRequests }.cascade(promise: self.isDonePromise)
                } else {
                    self.remainingNumberOfRequests -= 1
                    ctx.write(self.wrapOutboundOut(.head(RepeatedRequests.requestHead)), promise: nil)
                    ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                }
            }
        }
    }

    func measure(_ fn: () -> Int) -> [Int] {
        func measureOne(_ fn: () -> Int) -> Int {
            AtomicCounter.reset_free_counter()
            _ = fn()
            return AtomicCounter.read_free_counter()
        }

        _ = measureOne(fn) /* pre-heat and throw away */
        var measurements: [Int] = []
        for _ in 0..<10 {
            measurements.append(measureOne(fn))
        }

        return measurements
    }

    func measureAndPrint(desc: String, fn: () -> Int) -> Void {
        print("\(desc): ", terminator: "")
        let measurements = measure(fn)
        print(measurements.min() ?? -1)
    }

    measureAndPrint(desc: "1000_reqs_1_conn") {
        let group = MultiThreadedEventLoopGroup(numThreads: System.coreCount)
        defer {
            try! group.syncShutdownGracefully()
        }

        let serverChannel = try! ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: true).then {
                    channel.pipeline.add(handler: SimpleHTTPServer())
                }
            }.bind(host: "127.0.0.1", port: 0).wait()

        defer {
            try! serverChannel.close().wait()
        }


        let repeatedRequestsHandler = RepeatedRequests(numberOfRequests: 1000, eventLoop: group.next())

        let clientChannel = try! ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().then {
                    channel.pipeline.add(handler: repeatedRequestsHandler)
                }
            }
            .connect(to: serverChannel.localAddress!)
            .wait()

        clientChannel.write(NIOAny(HTTPClientRequestPart.head(RepeatedRequests.requestHead)), promise: nil)
        try! clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()
        return try! repeatedRequestsHandler.wait()
    }

    return 0
}
