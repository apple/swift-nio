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

import NIOCore
import NIOPosix

private struct PingPongFailure: Error, CustomStringConvertible {
    public var description: String

    init(problem: String) {
        self.description = problem
    }
}

private final class PongDecoder: ByteToMessageDecoder {
    typealias InboundOut = UInt8

    public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) -> DecodingState {
        if let ping = buffer.readInteger(as: UInt8.self) {
            context.fireChannelRead(Self.wrapInboundOut(ping))
            return .continue
        } else {
            return .needMoreData
        }
    }

    public func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        .needMoreData
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
        self.allDone = eventLoop.makePromise()
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        (context.channel as? SocketOptionProvider)?.setSoLinger(linger(l_onoff: 1, l_linger: 0))
            .whenFailure({ error in fatalError("Failed to set linger \(error)") })
    }

    public func channelActive(context: ChannelHandlerContext) {
        self.pingBuffer = context.channel.allocator.buffer(capacity: 1)
        self.pingBuffer.writeInteger(PingHandler.pingCode)

        context.writeAndFlush(Self.wrapOutboundOut(self.pingBuffer), promise: nil)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        if buf.readableBytes == 1 && buf.readInteger(as: UInt8.self) == PongHandler.pongCode {
            if self.remainingNumberOfRequests > 0 {
                self.remainingNumberOfRequests -= 1
                context.writeAndFlush(Self.wrapOutboundOut(self.pingBuffer), promise: nil)
            } else {
                context.close(promise: self.allDone)
            }
        } else {
            context.close(promise: nil)
            self.allDone.fail(PingPongFailure(problem: "wrong buffer received: \(buf.debugDescription)"))
        }
    }

    public func wait() throws {
        try self.allDone.futureResult.wait()
    }
}

private final class PongHandler: ChannelInboundHandler {
    typealias InboundIn = UInt8
    typealias OutboundOut = ByteBuffer

    private var pongBuffer: ByteBuffer!
    public static let pongCode: UInt8 = 0xef

    public func handlerAdded(context: ChannelHandlerContext) {
        self.pongBuffer = context.channel.allocator.buffer(capacity: 1)
        self.pongBuffer.writeInteger(PongHandler.pongCode)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = Self.unwrapInboundIn(data)
        if data == PingHandler.pingCode {
            context.writeAndFlush(NIOAny(self.pongBuffer), promise: nil)
        } else {
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

func doPingPongRequests(group: EventLoopGroup, number numberOfRequests: Int) throws -> Int {
    let serverChannel = try ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 4))
        .childChannelInitializer { channel in
            channel.pipeline.addHandler(ByteToMessageHandler(PongDecoder())).flatMap {
                channel.pipeline.addHandler(PongHandler())
            }
        }.bind(host: "127.0.0.1", port: 0).wait()

    defer {
        try! serverChannel.close().wait()
    }

    let pingHandler = PingHandler(numberOfRequests: numberOfRequests, eventLoop: group.next())
    _ = try ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.pipeline.addHandler(pingHandler)
        }
        .channelOption(.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 4))
        .connect(to: serverChannel.localAddress!)
        .wait()

    try pingHandler.wait()
    return numberOfRequests
}

func run(identifier: String) {
    measure(identifier: identifier) {
        let numberDone = try! doPingPongRequests(group: group, number: 1000)
        precondition(numberDone == 1000)
        return numberDone
    }
}
