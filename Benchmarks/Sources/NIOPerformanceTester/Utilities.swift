//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOPosix
import NIOEmbedded
import NIOHTTP1
import NIOFoundationCompat
import Dispatch
import NIOWebSocket

public var group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

// TODO: Do we need to do this as the benchmark process will be killed of for each test?
/*defer {
    try! group.syncShutdownGracefully()
}
*/
public let serverChannel = try! ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: true).flatMap {
            channel.pipeline.addHandler(SimpleHTTPServer())
        }
    }.bind(host: "127.0.0.1", port: 0).wait()

// TODO: Do we need to do this as the benchmark process will be killed of for each test?
/*
defer {
    try! serverChannel.close().wait()
}
*/
public var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/perf-test-1")

public final class SimpleHTTPServer: ChannelInboundHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    private var files: [String] = Array()
    private var seenEnd: Bool = false
    private var sentEnd: Bool = false
    private var isOpen: Bool = true

    private let cachedHead: HTTPResponseHead
    private let cachedBody: [UInt8]
    private let bodyLength = 1024
    private let numberOfAdditionalHeaders = 10

    public init() {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        head.headers.add(name: "Content-Length", value: "\(self.bodyLength)")
        for i in 0..<self.numberOfAdditionalHeaders {
            head.headers.add(name: "X-Random-Extra-Header", value: "\(i)")
        }
        self.cachedHead = head

        var body: [UInt8] = []
        body.reserveCapacity(self.bodyLength)
        for i in 0..<self.bodyLength {
            body.append(UInt8(i % Int(UInt8.max)))
        }
        self.cachedBody = body
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let req) = self.unwrapInboundIn(data) {
            switch req.uri {
            case "/perf-test-1":
                var buffer = context.channel.allocator.buffer(capacity: self.cachedBody.count)
                buffer.writeBytes(self.cachedBody)
                context.write(self.wrapOutboundOut(.head(self.cachedHead)), promise: nil)
                context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                return
            case "/perf-test-2":
                var req = HTTPResponseHead(version: .http1_1, status: .ok)
                for i in 1...8 {
                    req.headers.add(name: "X-ResponseHeader-\(i)", value: "foo")
                }
                req.headers.add(name: "content-length", value: "0")
                context.write(self.wrapOutboundOut(.head(req)), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                return
            default:
                fatalError("unknown uri \(req.uri)")
            }
        }
    }
}

public final class RepeatedRequests: ChannelInboundHandler {
    public typealias InboundIn = HTTPClientResponsePart
    public typealias OutboundOut = HTTPClientRequestPart

    private let numberOfRequests: Int
    private var remainingNumberOfRequests: Int
    private var doneRequests = 0
    private let isDonePromise: EventLoopPromise<Int>

    public init(numberOfRequests: Int, eventLoop: EventLoop) {
        self.remainingNumberOfRequests = numberOfRequests
        self.numberOfRequests = numberOfRequests
        self.isDonePromise = eventLoop.makePromise()
    }

    public func wait() throws -> Int {
        let reqs = try self.isDonePromise.futureResult.wait()
        precondition(reqs == self.numberOfRequests)
        return reqs
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.channel.close(promise: nil)
        self.isDonePromise.fail(error)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)
        if case .end(nil) = reqPart {
            if self.remainingNumberOfRequests <= 0 {
                context.channel.close().map { self.doneRequests }.cascade(to: self.isDonePromise)
            } else {
                self.doneRequests += 1
                self.remainingNumberOfRequests -= 1

                context.write(self.wrapOutboundOut(.head(head)), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

public func someString(size: Int) -> String {
    var s = "A"
    for f in 1..<size {
        s += String("\(f)".first!)
    }
    return s
}



