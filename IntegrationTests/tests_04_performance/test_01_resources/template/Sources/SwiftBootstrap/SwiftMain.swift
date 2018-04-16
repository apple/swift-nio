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

private struct PingPongFailure: Error, CustomStringConvertible {
    public var description: String

    init(problem: String) {
        self.description = problem
    }
}

private final class PingHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var pingBuffer: ByteBuffer!
    private let numberOfRequests: Int
    private var remainingNumberOfRequests: Int
    private let allDone: EventLoopPromise<Void>
    public static let pingCode: UInt8 = 0xbe

    public init(numberOfRequests: Int, eventLoop: EventLoop) {
        self.numberOfRequests = numberOfRequests
        self.remainingNumberOfRequests = numberOfRequests
        self.allDone = eventLoop.newPromise()
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        self.pingBuffer = ctx.channel.allocator.buffer(capacity: 1)
        self.pingBuffer.write(integer: PingHandler.pingCode)

        ctx.writeAndFlush(self.wrapOutboundOut(self.pingBuffer), promise: nil)
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        if buf.readableBytes == 1 &&
            buf.readInteger(as: UInt8.self) == PongHandler.pongCode {
            if self.remainingNumberOfRequests > 0 {
                self.remainingNumberOfRequests -= 1
                ctx.writeAndFlush(self.wrapOutboundOut(self.pingBuffer), promise: nil)
            } else {
                ctx.close(promise: self.allDone)
            }
        } else {
            ctx.close(promise: nil)
            self.allDone.fail(error: PingPongFailure(problem: "wrong buffer received: \(buf.debugDescription)"))
        }
    }

    public func wait() throws {
        try self.allDone.futureResult.wait()
    }
}

private final class PongHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var pongBuffer: ByteBuffer!
    public static let pongCode: UInt8 = 0xef

    public func channelActive(ctx: ChannelHandlerContext) {
        self.pongBuffer = ctx.channel.allocator.buffer(capacity: 1)
        self.pongBuffer.write(integer: PongHandler.pongCode)
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        if buf.readableBytes == 1 &&
            buf.readInteger(as: UInt8.self) == PingHandler.pingCode {
            ctx.writeAndFlush(self.wrapOutboundOut(self.pongBuffer), promise: nil)
        } else {
            ctx.close(promise: nil)
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

    func measure(_ fn: () -> Int) -> [[String: Int]] {
        func measureOne(_ fn: () -> Int) -> [String: Int] {
            AtomicCounter.reset_free_counter()
            AtomicCounter.reset_malloc_counter()
            _ = fn()
            usleep(100_000) // allocs/frees happen on multiple threads, allow some cool down time
            let frees = AtomicCounter.read_free_counter()
            let mallocs = AtomicCounter.read_malloc_counter()
            return ["total_allocations": mallocs,
                    "remaining_allocations": mallocs - frees]
        }

        _ = measureOne(fn) /* pre-heat and throw away */
        usleep(100_000) // allocs/frees happen on multiple threads, allow some cool down time
        var measurements: [[String: Int]] = []
        for _ in 0..<10 {
            measurements.append(measureOne(fn))
        }
        return measurements
    }

    func measureAndPrint(desc: String, fn: () -> Int) -> Void {
        let measurements = measure(fn)
        for k in measurements[0].keys {
            let vs = measurements.map { $0[k]! }
            print("\(desc).\(k): \(vs.min() ?? -1)")
        }
        print("DEBUG: \(measurements)")
    }

    func doRequests(group: EventLoopGroup, number numberOfRequests: Int) throws -> Int {
        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: true).then {
                    channel.pipeline.add(handler: SimpleHTTPServer())
                }
            }.bind(host: "127.0.0.1", port: 0).wait()

        defer {
            try! serverChannel.close().wait()
        }


        let repeatedRequestsHandler = RepeatedRequests(numberOfRequests: numberOfRequests, eventLoop: group.next())

        let clientChannel = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().then {
                    channel.pipeline.add(handler: repeatedRequestsHandler)
                }
            }
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .connect(to: serverChannel.localAddress!)
            .wait()

        clientChannel.write(NIOAny(HTTPClientRequestPart.head(RepeatedRequests.requestHead)), promise: nil)
        try clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()
        return try repeatedRequestsHandler.wait()
    }

    func doPingPongRequests(group: EventLoopGroup, number numberOfRequests: Int) throws -> Int {
        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 4))
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: PongHandler())
            }.bind(host: "127.0.0.1", port: 0).wait()

        defer {
            try! serverChannel.close().wait()
        }

        let pingHandler = PingHandler(numberOfRequests: numberOfRequests, eventLoop: group.next())
        _ = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.add(handler: pingHandler)
            }
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 4))
            .connect(to: serverChannel.localAddress!)
            .wait()

        try pingHandler.wait()
        return numberOfRequests
    }

    let group = MultiThreadedEventLoopGroup(numThreads: System.coreCount)
    defer {
        try! group.syncShutdownGracefully()
    }

    measureAndPrint(desc: "1000_reqs_1_conn") {
        let numberDone = try! doRequests(group: group, number: 1000)
        precondition(numberDone == 1000)
        return numberDone
    }

    measureAndPrint(desc: "1_reqs_1000_conn") {
        var numberDone = 1
        for _ in 0..<1000 {
            let newDones = try! doRequests(group: group, number: 1)
            precondition(newDones == 1)
            numberDone += newDones
        }
        return numberDone
    }

    measureAndPrint(desc: "ping_pong_1000_reqs_1_conn") {
        let numberDone = try! doPingPongRequests(group: group, number: 1000)
        precondition(numberDone == 1000)
        return numberDone
    }

    return 0
}
