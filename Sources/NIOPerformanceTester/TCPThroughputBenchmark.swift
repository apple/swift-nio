//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2023 Apple Inc. and the SwiftNIO project authors
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

/// Test measure a TCP channel throughput.
/// Server send 100K messages to the client,
/// measure the time from the very first message sent by the server
/// to the last message received by the client.

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class TCPThroughputBenchmark: Benchmark {

    private let messages: Int
    private let messageSize: Int

    private var group: EventLoopGroup!
    private var serverChannel: Channel!
    private var serverHandler: NIOLoopBound<ServerHandler>!
    private var clientChannel: Channel!

    private var message: ByteBuffer!
    private var serverEventLoop: EventLoop!

    final class ServerHandler: ChannelInboundHandler {
        public typealias InboundIn = ByteBuffer
        public typealias OutboundOut = ByteBuffer

        private let connectionEstablishedPromise: EventLoopPromise<EventLoop>
        private let eventLoop: EventLoop
        private var context: ChannelHandlerContext!

        init(_ connectionEstablishedPromise: EventLoopPromise<EventLoop>, eventLoop: EventLoop) {
            self.connectionEstablishedPromise = connectionEstablishedPromise
            self.eventLoop = eventLoop
        }

        public func channelActive(context: ChannelHandlerContext) {
            self.context = context
            connectionEstablishedPromise.succeed(context.eventLoop)
        }

        public func send(_ message: ByteBuffer, times count: Int) {
            for _ in 0..<count {
                _ = self.context.writeAndFlush(Self.wrapOutboundOut(message.slice()))
            }
        }
    }

    final class StreamDecoder: ByteToMessageDecoder {
        public typealias InboundIn = ByteBuffer
        public typealias InboundOut = ByteBuffer

        public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
            if let messageSize = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self) {
                if buffer.readableBytes >= messageSize {
                    context.fireChannelRead(Self.wrapInboundOut(buffer.readSlice(length: Int(messageSize))!))
                    return .continue
                }
            }
            return .needMoreData
        }
    }

    final class ClientHandler: ChannelInboundHandler {
        public typealias InboundIn = ByteBuffer
        public typealias OutboundOut = ByteBuffer

        private var messagesReceived: Int
        private var expectedMessages: Int?
        private var completionPromise: EventLoopPromise<Void>?

        init() {
            self.messagesReceived = 0
        }

        func prepareRun(expectedMessages: Int, promise: EventLoopPromise<Void>) {
            self.expectedMessages = expectedMessages
            self.completionPromise = promise
        }

        public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            self.messagesReceived += 1

            if self.expectedMessages == self.messagesReceived {
                let promise = self.completionPromise

                self.messagesReceived = 0
                self.expectedMessages = nil
                self.completionPromise = nil

                promise!.succeed()
            }
        }
    }

    public init(messages: Int, messageSize: Int) {
        self.messages = messages
        self.messageSize = messageSize
    }

    func setUp() throws {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 4)

        let connectionEstablishedPromise: EventLoopPromise<EventLoop> = self.group.next().makePromise()

        let promise = self.group.next().makePromise(of: NIOLoopBound<ServerHandler>.self)
        self.serverChannel = try ServerBootstrap(group: self.group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let serverHandler = ServerHandler(connectionEstablishedPromise, eventLoop: channel.eventLoop)
                    promise.succeed(NIOLoopBound(serverHandler, eventLoop: channel.eventLoop))
                    try channel.pipeline.syncOperations.addHandler(serverHandler)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()

        self.clientChannel = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(StreamDecoder()))
                    try channel.pipeline.syncOperations.addHandler(ClientHandler())
                }
            }
            .connect(to: serverChannel.localAddress!)
            .wait()

        self.serverHandler = try promise.futureResult.wait()

        var message = self.serverChannel.allocator.buffer(capacity: self.messageSize)
        message.writeInteger(UInt16(messageSize), as: UInt16.self)
        for idx in 0..<(self.messageSize - MemoryLayout<UInt16>.stride) {
            message.writeInteger(UInt8(truncatingIfNeeded: idx), endianness: .little, as: UInt8.self)
        }
        self.message = message

        self.serverEventLoop = try connectionEstablishedPromise.futureResult.wait()
    }

    func tearDown() {
        try! self.clientChannel.close().wait()
        try! self.serverChannel.close().wait()
        try! self.group.syncShutdownGracefully()
    }

    func run() throws -> Int {
        let isDonePromise = self.clientChannel.eventLoop.makePromise(of: Void.self)
        let clientChannel = self.clientChannel!
        let expectedMessages = self.messages

        try clientChannel.eventLoop.submit {
            try clientChannel.pipeline.syncOperations.handler(type: ClientHandler.self).prepareRun(
                expectedMessages: expectedMessages,
                promise: isDonePromise
            )
        }.wait()

        let serverHandler = self.serverHandler!
        let message = self.message!
        let messages = self.messages

        self.serverEventLoop.execute {
            serverHandler.value.send(message, times: messages)
        }
        try isDonePromise.futureResult.wait()
        return 0
    }
}
