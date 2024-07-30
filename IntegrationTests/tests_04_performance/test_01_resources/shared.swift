//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

let localhostPickPort = try! SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 0)
let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

final class RepeatedRequests: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let numberOfRequests: Int
    private var remainingNumberOfRequests: Int
    private let isDonePromise: EventLoopPromise<Int>
    static var requestHead: HTTPRequestHead {
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/allocation-test-1")
        head.headers.add(name: "Host", value: "foo-\(ObjectIdentifier(self)).com")
        return head
    }

    init(numberOfRequests: Int, eventLoop: EventLoop) {
        self.remainingNumberOfRequests = numberOfRequests
        self.numberOfRequests = numberOfRequests
        self.isDonePromise = eventLoop.makePromise()
    }

    func wait() throws -> Int {
        let reqs = try self.isDonePromise.futureResult.wait()
        precondition(reqs == self.numberOfRequests)
        return reqs
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.channel.close(promise: nil)
        self.isDonePromise.fail(error)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let respPart = self.unwrapInboundIn(data)
        if case .end(nil) = respPart {
            if self.remainingNumberOfRequests <= 0 {
                context.channel.close().map { self.numberOfRequests - self.remainingNumberOfRequests }.cascade(
                    to: self.isDonePromise
                )
            } else {
                self.remainingNumberOfRequests -= 1
                context.write(self.wrapOutboundOut(.head(RepeatedRequests.requestHead)), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

private final class SimpleHTTPServer: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let bodyLength = 100
    private let numberOfAdditionalHeaders = 3

    private var responseHead: HTTPResponseHead {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        head.headers.add(name: "Content-Length", value: "\(self.bodyLength)")
        for i in 0..<self.numberOfAdditionalHeaders {
            head.headers.add(name: "X-Random-Extra-Header", value: "\(i)")
        }
        return head
    }

    private func responseBody(allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: self.bodyLength)
        for i in 0..<self.bodyLength {
            buffer.writeInteger(UInt8(i % Int(UInt8.max)))
        }
        return buffer
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        (context.channel as? SocketOptionProvider)?.setSoLinger(linger(l_onoff: 1, l_linger: 0))
            .whenFailure({ error in fatalError("Failed to set linger \(error)") })
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let req) = self.unwrapInboundIn(data), req.uri == "/allocation-test-1" {
            context.write(self.wrapOutboundOut(.head(self.responseHead)), promise: nil)
            context.write(
                self.wrapOutboundOut(.body(.byteBuffer(self.responseBody(allocator: context.channel.allocator)))),
                promise: nil
            )
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

func doRequests(group: EventLoopGroup, number numberOfRequests: Int) throws -> Int {
    let serverChannel = try ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline(
                withPipeliningAssistance: true,
                withErrorHandling: false
            ).flatMap {
                channel.pipeline.addHandler(SimpleHTTPServer())
            }
        }.bind(to: localhostPickPort).wait()

    defer {
        try! serverChannel.close().wait()
    }

    let repeatedRequestsHandler = RepeatedRequests(numberOfRequests: numberOfRequests, eventLoop: group.next())

    let clientChannel = try ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.pipeline.addHTTPClientHandlers().flatMap {
                channel.pipeline.addHandler(repeatedRequestsHandler)
            }
        }
        .connect(to: serverChannel.localAddress!)
        .wait()

    clientChannel.write(NIOAny(HTTPClientRequestPart.head(RepeatedRequests.requestHead)), promise: nil)
    try clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()
    let result = try repeatedRequestsHandler.wait()
    try clientChannel.closeFuture.wait()
    return result
}

func withAutoReleasePool<T>(_ execute: () throws -> T) rethrows -> T {
    #if os(Linux)
    return try execute()
    #else
    return try autoreleasepool {
        try execute()
    }
    #endif
}

// MARK: UDP Shared

/// Repeatedly send, echo and receive a number of UDP requests.
/// Based on the UDPEchoClient/Server example.
enum UDPShared {
    private final class EchoHandler: ChannelInboundHandler {
        public typealias InboundIn = AddressedEnvelope<ByteBuffer>
        public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

        public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            // As we are not really interested getting notified on success or failure we just pass nil as promise to
            // reduce allocations.
            context.write(data, promise: nil)
        }

        public func channelReadComplete(context: ChannelHandlerContext) {
            // As we are not really interested getting notified on success or failure we just pass nil as promise to
            // reduce allocations.
            context.flush()
        }

        public func errorCaught(context: ChannelHandlerContext, error: Error) {
            // Errors should never happen.
            fatalError("EchoHandler received errorCaught")
        }
    }

    private final class EchoHandlerClient: ChannelInboundHandler {
        public typealias InboundIn = AddressedEnvelope<ByteBuffer>
        public typealias OutboundOut = AddressedEnvelope<ByteBuffer>
        private var repetitionsRemaining: Int

        private let remoteAddress: SocketAddress

        init(remoteAddress: SocketAddress, numberOfRepetitions: Int) {
            self.remoteAddress = remoteAddress
            self.repetitionsRemaining = numberOfRepetitions
        }

        public func channelActive(context: ChannelHandlerContext) {
            // Channel is available. It's time to send the message to the server to initialize the ping-pong sequence.
            self.sendSomeDataIfDesiredOrClose(context: context)
        }

        private func sendSomeDataIfDesiredOrClose(context: ChannelHandlerContext) {
            if repetitionsRemaining > 0 {
                repetitionsRemaining -= 1

                // Set the transmission data.
                let line = "Something to send there and back again."
                let buffer = context.channel.allocator.buffer(string: line)

                // Forward the data.
                let envolope = AddressedEnvelope<ByteBuffer>(remoteAddress: remoteAddress, data: buffer)

                context.writeAndFlush(self.wrapOutboundOut(envolope), promise: nil)
            } else {
                // We're all done - hurrah!
                context.close(promise: nil)
            }
        }

        public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            // Got back a response - maybe send some more.
            self.sendSomeDataIfDesiredOrClose(context: context)
        }

        public func errorCaught(context: ChannelHandlerContext, error: Error) {
            // Errors should never happen.
            fatalError("EchoHandlerClient received errorCaught")
        }
    }

    static func doUDPRequests(group: EventLoopGroup, number numberOfRequests: Int) throws -> Int {
        let serverChannel = try DatagramBootstrap(group: group)
            // Set the handlers that are applied to the bound channel
            .channelInitializer { channel in
                channel.pipeline.addHandler(EchoHandler())
            }
            .bind(to: localhostPickPort).wait()

        defer {
            try! serverChannel.close().wait()
        }

        let remoteAddress = serverChannel.localAddress!

        let clientChannel = try DatagramBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    EchoHandlerClient(
                        remoteAddress: remoteAddress,
                        numberOfRepetitions: numberOfRequests
                    )
                )
            }
            .bind(to: localhostPickPort).wait()

        // Will be closed after all the work is done and replies received.
        try clientChannel.closeFuture.wait()
        return numberOfRequests
    }

}
